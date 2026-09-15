"""GitHub Actions workflow_dispatch trigger.

Invoked by EventBridge Scheduler with an input payload identifying the target:

    {"repo": "sam-search", "workflow_file": "sam-search-run.yaml", "ref": "main"}

Authenticates as a GitHub App: signs a short-lived RS256 JWT with the App
private key (read from SSM at runtime), exchanges it for an installation token
scoped to the target repo, then POSTs the workflow dispatch.
"""

import base64
import json
import logging
import os
import time
import urllib.request

import boto3  # provided by the Lambda runtime
import rsa

logger = logging.getLogger()
logger.setLevel(os.environ.get("LOG_LEVEL", "INFO"))

API = "https://api.github.com"
OWNER = os.environ["GH_OWNER"]

_ssm = boto3.client("ssm")
_ssm_cache: dict[tuple[str, bool], str] = {}


def _b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def _get_ssm_parameter(name: str, decrypt: bool = False) -> str:
    key = (name, decrypt)
    if key not in _ssm_cache:
        resp = _ssm.get_parameter(Name=name, WithDecryption=decrypt)
        _ssm_cache[key] = resp["Parameter"]["Value"]
    return _ssm_cache[key]


def _build_app_jwt(client_id: str, private_key_pem: str) -> str:
    now = int(time.time())
    header = {"alg": "RS256", "typ": "JWT"}
    payload = {"iat": now - 60, "exp": now + 540, "iss": client_id}
    signing_input = (
        _b64url(json.dumps(header, separators=(",", ":")).encode())
        + "."
        + _b64url(json.dumps(payload, separators=(",", ":")).encode())
    ).encode("ascii")
    priv = rsa.PrivateKey.load_pkcs1(private_key_pem.encode())
    signature = rsa.sign(signing_input, priv, "SHA-256")
    return signing_input.decode("ascii") + "." + _b64url(signature)


def _request(method: str, url: str, token: str, data: dict | None = None):
    headers = {
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
        "User-Agent": "alerts-scheduler",
        "Authorization": f"Bearer {token}",
    }
    body = None
    if data is not None:
        body = json.dumps(data).encode()
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=body, headers=headers, method=method)
    with urllib.request.urlopen(req, timeout=15) as resp:
        raw = resp.read()
        return resp.status, (json.loads(raw) if raw else None)


def _installation_token(owner: str, repo: str, app_jwt: str) -> str:
    _, install = _request("GET", f"{API}/repos/{owner}/{repo}/installation", app_jwt)
    installation_id = install["id"]
    _, token = _request(
        "POST", f"{API}/app/installations/{installation_id}/access_tokens", app_jwt
    )
    return token["token"]


def lambda_handler(event, context):
    owner = OWNER
    repo = event["repo"]
    workflow_file = event["workflow_file"]
    ref = event.get("ref", "main")

    client_id = _get_ssm_parameter(os.environ["SSM_CLIENT_ID"])
    private_key = _get_ssm_parameter(os.environ["SSM_PRIVATE_KEY"], decrypt=True)

    app_jwt = _build_app_jwt(client_id, private_key)
    token = _installation_token(owner, repo, app_jwt)

    url = f"{API}/repos/{owner}/{repo}/actions/workflows/{workflow_file}/dispatches"
    status, _ = _request("POST", url, token, data={"ref": ref})

    logger.info(
        "Dispatched %s/%s workflow=%s ref=%s status=%s",
        owner,
        repo,
        workflow_file,
        ref,
        status,
    )
    return {"status": status, "repo": repo, "workflow_file": workflow_file, "ref": ref}
