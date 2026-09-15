terraform {
  required_version = "1.14.8"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "6.39.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.7"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
  }

  backend "s3" {
    bucket  = ""
    key     = "aws/lambda/alerts-scheduler-terraform.tfstate"
    region  = ""
    encrypt = true
  }
}

provider "aws" {
  region = var.region
}

resource "aws_ssm_parameter" "gh_app_client_id" {
  name      = "/alerts-scheduler/gh_app_client_id"
  type      = "String"
  value     = var.gh_app_client_id
  overwrite = true
  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_ssm_parameter" "gh_app_private_key" {
  name      = "/alerts-scheduler/gh_app_private_key"
  type      = "SecureString"
  value     = var.gh_app_private_key
  overwrite = true
  lifecycle {
    create_before_destroy = true
  }
}

resource "null_resource" "lambda_build" {
  triggers = {
    handler      = filebase64sha256("${path.module}/lambda/handler.py")
    requirements = filebase64sha256("${path.module}/lambda/requirements.txt")
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -euo pipefail
      rm -rf "${path.module}/build"
      mkdir -p "${path.module}/build"
      uv pip install --target "${path.module}/build" -r "${path.module}/lambda/requirements.txt"
      cp "${path.module}/lambda/handler.py" "${path.module}/build/"
    EOT
  }
}

data "archive_file" "lambda_zip" {
  type        = "zip"
  source_dir  = "${path.module}/build"
  output_path = "${path.module}/alerts_scheduler.zip"

  depends_on = [null_resource.lambda_build]
}

resource "aws_iam_role" "lambda_role" {
  name = "alerts_scheduler_lambda_role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Action = "sts:AssumeRole",
        Effect = "Allow",
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy" "lambda_policy" {
  name = "alerts_scheduler_lambda_policy"
  role = aws_iam_role.lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Action = ["ssm:GetParameter"],
        Resource = [
          aws_ssm_parameter.gh_app_client_id.arn,
          aws_ssm_parameter.gh_app_private_key.arn,
        ]
      },
      {
        Effect   = "Allow",
        Action   = ["kms:Decrypt"],
        Resource = "*",
        Condition = {
          StringEquals = {
            "kms:ViaService" = "ssm.${var.region}.amazonaws.com"
          }
        }
      },
      {
        Effect = "Allow",
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
        ],
        Resource = "arn:aws:logs:${var.region}:*:log-group:/aws/lambda/*"
      }
    ]
  })
}

resource "aws_lambda_function" "dispatcher" {
  function_name    = "alerts_scheduler_dispatcher"
  runtime          = "python3.13"
  handler          = "handler.lambda_handler"
  role             = aws_iam_role.lambda_role.arn
  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  timeout          = 30
  memory_size      = 128

  environment {
    variables = {
      LOG_LEVEL       = "INFO"
      GH_OWNER        = var.gh_owner
      SSM_CLIENT_ID   = aws_ssm_parameter.gh_app_client_id.name
      SSM_PRIVATE_KEY = aws_ssm_parameter.gh_app_private_key.name
    }
  }
}

# Dead-letter queue for schedules that fail to deliver after retries.
resource "aws_sqs_queue" "scheduler_dlq" {
  name                      = "alerts-scheduler-dlq"
  sqs_managed_sse_enabled   = true
  message_retention_seconds = 1209600 # 14 days
}

resource "aws_iam_role" "scheduler_role" {
  name = "alerts_scheduler_invoke_role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Action = "sts:AssumeRole",
        Effect = "Allow",
        Principal = {
          Service = "scheduler.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy" "scheduler_policy" {
  name = "alerts_scheduler_invoke_policy"
  role = aws_iam_role.scheduler_role.id

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect   = "Allow",
        Action   = "lambda:InvokeFunction",
        Resource = aws_lambda_function.dispatcher.arn
      },
      {
        Effect   = "Allow",
        Action   = "sqs:SendMessage",
        Resource = aws_sqs_queue.scheduler_dlq.arn
      }
    ]
  })
}

resource "aws_scheduler_schedule" "job" {
  for_each = var.schedules

  name       = each.key
  group_name = "default"

  flexible_time_window {
    mode = "OFF"
  }

  schedule_expression          = each.value.cron
  schedule_expression_timezone = var.timezone

  target {
    arn      = aws_lambda_function.dispatcher.arn
    role_arn = aws_iam_role.scheduler_role.arn

    input = jsonencode({
      repo          = each.value.repo
      workflow_file = each.value.workflow_file
      ref           = each.value.ref
    })

    retry_policy {
      maximum_retry_attempts = 3
    }

    dead_letter_config {
      arn = aws_sqs_queue.scheduler_dlq.arn
    }
  }
}

output "lambda_function_name" {
  value = aws_lambda_function.dispatcher.function_name
}

output "schedule_names" {
  value = [for s in aws_scheduler_schedule.job : s.name]
}

output "dlq_url" {
  value = aws_sqs_queue.scheduler_dlq.url
}
