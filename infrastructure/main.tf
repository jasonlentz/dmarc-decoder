terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# -------------------------------------------------------
# S3 Bucket — single entry point for all DMARC reports
# -------------------------------------------------------
resource "aws_s3_bucket" "dmarc" {
  bucket        = var.s3_bucket_name
  force_destroy = var.s3_force_destroy
}

resource "aws_s3_bucket_server_side_encryption_configuration" "dmarc" {
  bucket = aws_s3_bucket.dmarc.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "dmarc" {
  bucket                  = aws_s3_bucket.dmarc.id
  block_public_acls       = true
  block_public_policy     = false  # allows the bucket policy below to grant public read on frontend/*
  ignore_public_acls      = true
  restrict_public_buckets = false  # required for the website endpoint to serve public objects
}

# Allow public read of frontend files only — raw/ remains inaccessible
resource "aws_s3_bucket_policy" "dmarc" {
  bucket = aws_s3_bucket.dmarc.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "PublicReadFrontend"
      Effect    = "Allow"
      Principal = "*"
      Action    = "s3:GetObject"
      Resource  = "${aws_s3_bucket.dmarc.arn}/frontend/*"
    }]
  })

  depends_on = [aws_s3_bucket_public_access_block.dmarc]
}

resource "aws_s3_bucket_cors_configuration" "dmarc" {
  bucket = aws_s3_bucket.dmarc.id

  cors_rule {
    allowed_headers = ["*"]
    allowed_methods = ["PUT", "GET", "HEAD"]
    allowed_origins = ["*"]
    expose_headers  = ["ETag"]
    max_age_seconds = 3000
  }
}

resource "aws_s3_bucket_website_configuration" "dmarc" {
  bucket = aws_s3_bucket.dmarc.id
  index_document {
    suffix = "index.html"
  }
  error_document {
    key = "index.html"
  }
}

# S3 event — trigger parser Lambda on any object landing in raw/
resource "aws_s3_bucket_notification" "dmarc" {
  bucket = aws_s3_bucket.dmarc.id

  lambda_function {
    lambda_function_arn = aws_lambda_function.parser.arn
    events              = ["s3:ObjectCreated:*"]
    filter_prefix       = "raw/"
  }

  depends_on = [aws_lambda_permission.s3_invoke_parser]
}

# -------------------------------------------------------
# Aurora Serverless v2 — PostgreSQL, Data API enabled
# -------------------------------------------------------
resource "random_password" "aurora" {
  length  = 32
  special = false
}

resource "aws_secretsmanager_secret" "aurora" {
  name                    = "${var.project_name}-aurora-credentials"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "aurora" {
  secret_id = aws_secretsmanager_secret.aurora.id
  secret_string = jsonencode({
    username = var.db_username
    password = random_password.aurora.result
  })
}

resource "aws_rds_cluster" "dmarc" {
  cluster_identifier      = "${var.project_name}-cluster"
  engine                  = "aurora-postgresql"
  engine_mode             = "provisioned"
  engine_version          = "16.4"
  database_name           = var.db_name
  master_username         = var.db_username
  master_password         = random_password.aurora.result
  skip_final_snapshot     = true
  deletion_protection     = false
  enable_http_endpoint    = true  # required for Data API
  backup_retention_period = 1     # minimum allowed; raw reports in S3 are the true source of truth

  serverlessv2_scaling_configuration {
    min_capacity = 0
    max_capacity = 1
  }

  tags = {
    Project = var.project_name
  }
}

resource "aws_rds_cluster_instance" "dmarc" {
  cluster_identifier = aws_rds_cluster.dmarc.id
  instance_class     = "db.serverless"
  engine             = aws_rds_cluster.dmarc.engine
  engine_version     = aws_rds_cluster.dmarc.engine_version
}

# -------------------------------------------------------
# IAM — shared Lambda execution role
# -------------------------------------------------------
resource "aws_iam_role" "lambda_exec" {
  name = "${var.project_name}-lambda-exec"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "lambda_policy" {
  name = "${var.project_name}-lambda-policy"
  role = aws_iam_role.lambda_exec.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "S3Access"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:ListBucket"
        ]
        Resource = [
          aws_s3_bucket.dmarc.arn,
          "${aws_s3_bucket.dmarc.arn}/*"
        ]
      },
      {
        Sid    = "AuroraDataAPI"
        Effect = "Allow"
        Action = [
          "rds-data:ExecuteStatement",
          "rds-data:BatchExecuteStatement",
          "rds-data:BeginTransaction",
          "rds-data:CommitTransaction",
          "rds-data:RollbackTransaction"
        ]
        Resource = aws_rds_cluster.dmarc.arn
      },
      {
        Sid      = "SecretsManager"
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = aws_secretsmanager_secret.aurora.arn
      },
      {
        Sid    = "Logging"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:*:*:*"
      }
    ]
  })
}

# -------------------------------------------------------
# Lambda — Parser (S3-triggered, not API Gateway-backed)
# -------------------------------------------------------
data "archive_file" "parser" {
  type        = "zip"
  source_dir  = "${path.module}/../lambda/parser"
  output_path = "${path.module}/builds/parser.zip"
}

resource "aws_lambda_function" "parser" {
  function_name    = "${var.project_name}-parser"
  role             = aws_iam_role.lambda_exec.arn
  handler          = "handler.lambda_handler"
  runtime          = "python3.12"
  filename         = data.archive_file.parser.output_path
  source_code_hash = data.archive_file.parser.output_base64sha256
  timeout          = 60
  memory_size      = 256

  environment {
    variables = {
      AURORA_CLUSTER_ARN = aws_rds_cluster.dmarc.arn
      AURORA_SECRET_ARN  = aws_secretsmanager_secret.aurora.arn
      DB_NAME            = var.db_name
      S3_BUCKET          = aws_s3_bucket.dmarc.bucket
    }
  }

  tags = { Project = var.project_name }
}

resource "aws_lambda_permission" "s3_invoke_parser" {
  statement_id  = "AllowS3Invoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.parser.function_name
  principal     = "s3.amazonaws.com"
  source_arn    = aws_s3_bucket.dmarc.arn
}

resource "aws_cloudwatch_log_group" "parser" {
  name              = "/aws/lambda/${aws_lambda_function.parser.function_name}"
  retention_in_days = 30
}

# -------------------------------------------------------
# Lambda — SES Inbound Handler
# Deployed but not yet active. See README for activation.
# -------------------------------------------------------
data "archive_file" "ses_handler" {
  type        = "zip"
  source_dir  = "${path.module}/../lambda/ses_handler"
  output_path = "${path.module}/builds/ses_handler.zip"
}

resource "aws_lambda_function" "ses_handler" {
  function_name    = "${var.project_name}-ses-handler"
  role             = aws_iam_role.lambda_exec.arn
  handler          = "handler.lambda_handler"
  runtime          = "python3.12"
  filename         = data.archive_file.ses_handler.output_path
  source_code_hash = data.archive_file.ses_handler.output_base64sha256
  timeout          = 30
  memory_size      = 128

  environment {
    variables = {
      S3_BUCKET = aws_s3_bucket.dmarc.bucket
    }
  }

  tags = { Project = var.project_name }
}

resource "aws_cloudwatch_log_group" "ses_handler" {
  name              = "/aws/lambda/${aws_lambda_function.ses_handler.function_name}"
  retention_in_days = 30
}

# -------------------------------------------------------
# Lambda — Presigned URL Generator
# -------------------------------------------------------
data "archive_file" "presigned_url" {
  type        = "zip"
  source_dir  = "${path.module}/../lambda/presigned_url"
  output_path = "${path.module}/builds/presigned_url.zip"
}

resource "aws_lambda_function" "presigned_url" {
  function_name    = "${var.project_name}-presigned-url"
  role             = aws_iam_role.lambda_exec.arn
  handler          = "handler.lambda_handler"
  runtime          = "python3.12"
  filename         = data.archive_file.presigned_url.output_path
  source_code_hash = data.archive_file.presigned_url.output_base64sha256
  timeout          = 10
  memory_size      = 128

  environment {
    variables = {
      S3_BUCKET = aws_s3_bucket.dmarc.bucket
    }
  }

  tags = { Project = var.project_name }
}

resource "aws_cloudwatch_log_group" "presigned_url" {
  name              = "/aws/lambda/${aws_lambda_function.presigned_url.function_name}"
  retention_in_days = 30
}

# -------------------------------------------------------
# Lambda — Query Handler (reporting)
# -------------------------------------------------------
data "archive_file" "query_handler" {
  type        = "zip"
  source_dir  = "${path.module}/../lambda/query_handler"
  output_path = "${path.module}/builds/query_handler.zip"
}

resource "aws_lambda_function" "query_handler" {
  function_name    = "${var.project_name}-query-handler"
  role             = aws_iam_role.lambda_exec.arn
  handler          = "handler.lambda_handler"
  runtime          = "python3.12"
  filename         = data.archive_file.query_handler.output_path
  source_code_hash = data.archive_file.query_handler.output_base64sha256
  timeout          = 30
  memory_size      = 128

  environment {
    variables = {
      AURORA_CLUSTER_ARN = aws_rds_cluster.dmarc.arn
      AURORA_SECRET_ARN  = aws_secretsmanager_secret.aurora.arn
      DB_NAME            = var.db_name
    }
  }

  tags = { Project = var.project_name }
}

resource "aws_cloudwatch_log_group" "query_handler" {
  name              = "/aws/lambda/${aws_lambda_function.query_handler.function_name}"
  retention_in_days = 30
}

# -------------------------------------------------------
# API Gateway — REST API (v1)
# IP allowlist enforced natively via resource policy.
# -------------------------------------------------------
resource "aws_api_gateway_rest_api" "dmarc" {
  name        = "${var.project_name}-api"
  description = "DMARC Decoder — presigned URL and reporting endpoints"

  endpoint_configuration {
    types = ["REGIONAL"]
  }
}

# Native IP allowlist — blocks all traffic outside var.allowed_ips
# before any Lambda is ever invoked
resource "aws_api_gateway_rest_api_policy" "ip_allowlist" {
  rest_api_id = aws_api_gateway_rest_api.dmarc.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Deny"
        Principal = "*"
        Action    = "execute-api:Invoke"
        Resource  = "${aws_api_gateway_rest_api.dmarc.execution_arn}/*"
        Condition = {
          NotIpAddress = {
            "aws:SourceIp" = var.allowed_ips
          }
        }
      },
      {
        Effect    = "Allow"
        Principal = "*"
        Action    = "execute-api:Invoke"
        Resource  = "${aws_api_gateway_rest_api.dmarc.execution_arn}/*"
      }
    ]
  })
}

# -------------------------------------------------------
# Route: GET /upload-url
# -------------------------------------------------------
resource "aws_api_gateway_resource" "upload_url" {
  rest_api_id = aws_api_gateway_rest_api.dmarc.id
  parent_id   = aws_api_gateway_rest_api.dmarc.root_resource_id
  path_part   = "upload-url"
}

resource "aws_api_gateway_method" "upload_url_get" {
  rest_api_id   = aws_api_gateway_rest_api.dmarc.id
  resource_id   = aws_api_gateway_resource.upload_url.id
  http_method   = "GET"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "upload_url" {
  rest_api_id             = aws_api_gateway_rest_api.dmarc.id
  resource_id             = aws_api_gateway_resource.upload_url.id
  http_method             = aws_api_gateway_method.upload_url_get.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.presigned_url.invoke_arn
}

resource "aws_lambda_permission" "apigw_presigned_url" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.presigned_url.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.dmarc.execution_arn}/*/*"
}

# CORS preflight for /upload-url
resource "aws_api_gateway_method" "upload_url_options" {
  rest_api_id   = aws_api_gateway_rest_api.dmarc.id
  resource_id   = aws_api_gateway_resource.upload_url.id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "upload_url_options" {
  rest_api_id = aws_api_gateway_rest_api.dmarc.id
  resource_id = aws_api_gateway_resource.upload_url.id
  http_method = aws_api_gateway_method.upload_url_options.http_method
  type        = "MOCK"
  request_templates = {
    "application/json" = "{\"statusCode\": 200}"
  }
}

resource "aws_api_gateway_method_response" "upload_url_options" {
  rest_api_id = aws_api_gateway_rest_api.dmarc.id
  resource_id = aws_api_gateway_resource.upload_url.id
  http_method = aws_api_gateway_method.upload_url_options.http_method
  status_code = "200"
  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = true
    "method.response.header.Access-Control-Allow-Methods" = true
    "method.response.header.Access-Control-Allow-Origin"  = true
  }
}

resource "aws_api_gateway_integration_response" "upload_url_options" {
  rest_api_id = aws_api_gateway_rest_api.dmarc.id
  resource_id = aws_api_gateway_resource.upload_url.id
  http_method = aws_api_gateway_method.upload_url_options.http_method
  status_code = "200"
  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = "'Content-Type'"
    "method.response.header.Access-Control-Allow-Methods" = "'GET,OPTIONS'"
    "method.response.header.Access-Control-Allow-Origin"  = "'*'"
  }
  depends_on = [aws_api_gateway_integration.upload_url_options]
}

# -------------------------------------------------------
# Route: GET /query/{report_type}
# -------------------------------------------------------
resource "aws_api_gateway_resource" "query" {
  rest_api_id = aws_api_gateway_rest_api.dmarc.id
  parent_id   = aws_api_gateway_rest_api.dmarc.root_resource_id
  path_part   = "query"
}

resource "aws_api_gateway_resource" "query_report_type" {
  rest_api_id = aws_api_gateway_rest_api.dmarc.id
  parent_id   = aws_api_gateway_resource.query.id
  path_part   = "{report_type}"
}

resource "aws_api_gateway_method" "query_get" {
  rest_api_id   = aws_api_gateway_rest_api.dmarc.id
  resource_id   = aws_api_gateway_resource.query_report_type.id
  http_method   = "GET"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "query_handler" {
  rest_api_id             = aws_api_gateway_rest_api.dmarc.id
  resource_id             = aws_api_gateway_resource.query_report_type.id
  http_method             = aws_api_gateway_method.query_get.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.query_handler.invoke_arn
}

resource "aws_lambda_permission" "apigw_query_handler" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.query_handler.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.dmarc.execution_arn}/*/*"
}

# CORS preflight for /query/{report_type}
resource "aws_api_gateway_method" "query_options" {
  rest_api_id   = aws_api_gateway_rest_api.dmarc.id
  resource_id   = aws_api_gateway_resource.query_report_type.id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "query_options" {
  rest_api_id = aws_api_gateway_rest_api.dmarc.id
  resource_id = aws_api_gateway_resource.query_report_type.id
  http_method = aws_api_gateway_method.query_options.http_method
  type        = "MOCK"
  request_templates = {
    "application/json" = "{\"statusCode\": 200}"
  }
}

resource "aws_api_gateway_method_response" "query_options" {
  rest_api_id = aws_api_gateway_rest_api.dmarc.id
  resource_id = aws_api_gateway_resource.query_report_type.id
  http_method = aws_api_gateway_method.query_options.http_method
  status_code = "200"
  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = true
    "method.response.header.Access-Control-Allow-Methods" = true
    "method.response.header.Access-Control-Allow-Origin"  = true
  }
}

resource "aws_api_gateway_integration_response" "query_options" {
  rest_api_id = aws_api_gateway_rest_api.dmarc.id
  resource_id = aws_api_gateway_resource.query_report_type.id
  http_method = aws_api_gateway_method.query_options.http_method
  status_code = "200"
  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = "'Content-Type'"
    "method.response.header.Access-Control-Allow-Methods" = "'GET,OPTIONS'"
    "method.response.header.Access-Control-Allow-Origin"  = "'*'"
  }
  depends_on = [aws_api_gateway_integration.query_options]
}

# -------------------------------------------------------
# Deployment — REST API requires explicit deployment.
# Triggers redeployment when any API definition changes.
# -------------------------------------------------------
resource "aws_api_gateway_deployment" "dmarc" {
  rest_api_id = aws_api_gateway_rest_api.dmarc.id

  triggers = {
    redeployment = sha1(jsonencode([
      aws_api_gateway_rest_api_policy.ip_allowlist,
      aws_api_gateway_resource.upload_url,
      aws_api_gateway_method.upload_url_get,
      aws_api_gateway_integration.upload_url,
      aws_api_gateway_resource.query,
      aws_api_gateway_resource.query_report_type,
      aws_api_gateway_method.query_get,
      aws_api_gateway_integration.query_handler,
    ]))
  }

  lifecycle {
    create_before_destroy = true
  }

  depends_on = [
    aws_api_gateway_integration.upload_url,
    aws_api_gateway_integration.query_handler,
    aws_api_gateway_integration.upload_url_options,
    aws_api_gateway_integration.query_options,
  ]
}

resource "aws_api_gateway_stage" "dmarc" {
  rest_api_id   = aws_api_gateway_rest_api.dmarc.id
  deployment_id = aws_api_gateway_deployment.dmarc.id
  stage_name    = "v1"

  tags = { Project = var.project_name }
}

resource "aws_api_gateway_method_settings" "dmarc" {
  rest_api_id = aws_api_gateway_rest_api.dmarc.id
  stage_name  = aws_api_gateway_stage.dmarc.stage_name
  method_path = "*/*"

  settings {
    throttling_burst_limit = 10
    throttling_rate_limit  = 5
  }
}
