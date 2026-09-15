# AWS alerts scheduler

Terraform and Python for AWS EventBridge Scheduler/Lambda to call GitHub Actions workflows.

```
EventBridge Scheduler (cron)  ->  Lambda (Python dispatcher)  ->  GitHub workflow (target repo workflow_dispatch REST API)
```

This could all be eliminated by just using GitHub Actions built-in cron, but they're very unreliable. Edit `schedules` in `variables.tf` to change times/targets.

## Prerequisites

- Login to AWS account via terminal.
- A GitHub App setup in your GitHub org, which has read/write perms on Actions workflows and is installed on the target repos. You need the **Client ID** and **private key**, which Lambda will use to authenticate to GitHub.
- `terraform`, `uv`, and `make`.

## Deploy
Defaults to us-east-1 and MindPetal GitHub org. Override with `make apply REGION=... GH_OWNER=...`.

```sh
export TF_VAR_gh_app_client_id="Iv23li..."
export TF_VAR_gh_app_private_key="-----BEGIN RSA PRIVATE KEY-----
...paste the full key here with line breaks intact...
-----END RSA PRIVATE KEY-----"

make plan  # creates S3 state bucket, terraform plan
make apply # terraform apply, writes creds to SSM, IAM role/policy, 
           # packages + deploys Lambda, creates EventBridge schedules.
