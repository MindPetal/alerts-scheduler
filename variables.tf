variable "region" {
  default = "us-east-1"
}

variable "gh_owner" {
  type        = string
  description = "GitHub org/user that owns the target repos."
  default     = "MindPetal"
}

variable "timezone" {
  type        = string
  description = "IANA timezone used by all EventBridge schedules (handles DST)."
  default     = "America/New_York"
}

variable "gh_app_client_id" {
  type        = string
  description = "GitHub App Client ID, used as the JWT issuer."
  default     = "placeholder"
}

variable "gh_app_private_key" {
  type        = string
  sensitive   = true
  description = "GitHub App private key PEM."
  default     = "placeholder"
}

# EventBridge Scheduler format:
#   cron(minutes hours day-of-month month day-of-week year)
# Exactly one of day-of-month / day-of-week must be "?".

variable "schedules" {
  type = map(object({
    repo          = string
    workflow_file = string
    cron          = string
    ref           = optional(string, "main")
  }))

  default = {
    sam-search-daily = {
      repo          = "sam-search"
      workflow_file = "sam-search-run.yaml"
      cron          = "cron(0 8 * * ? *)" # 8:00 AM ET, every day
    }
    sam-contract-alerts-daily = {
      repo          = "sam-contract-alerts"
      workflow_file = "sam-contract-alerts-run.yaml"
      cron          = "cron(0 8 * * ? *)" # 8:00 AM ET, every day
    }
    protest-alerts-daily = {
      repo          = "protest-alerts"
      workflow_file = "protest-alerts-run.yaml"
      cron          = "cron(0 8 * * ? *)" # 8:00 AM ET, every day
    }
    protest-roundup-weekly = {
      repo          = "protest-alerts"
      workflow_file = "protest-roundup-run.yaml"
      cron          = "cron(0 15 ? * FRI *)" # 3:00 PM ET, every Friday
    }
  }
}
