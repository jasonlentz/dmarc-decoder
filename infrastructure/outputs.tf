output "s3_bucket_name" {
  description = "S3 bucket name"
  value       = aws_s3_bucket.dmarc.bucket
}

output "aws_region" {
  description = "AWS region"
  value       = var.aws_region
}

output "db_name" {
  description = "Aurora database name"
  value       = var.db_name
}

output "api_gateway_url" {
  description = "API Gateway base URL — used by the frontend config"
  value       = "https://${aws_api_gateway_rest_api.dmarc.id}.execute-api.${var.aws_region}.amazonaws.com/${aws_api_gateway_stage.dmarc.stage_name}"
}

output "aurora_cluster_arn" {
  description = "Aurora cluster ARN"
  value       = aws_rds_cluster.dmarc.arn
}

output "aurora_secret_arn" {
  description = "Secrets Manager ARN for Aurora credentials"
  value       = aws_secretsmanager_secret.aurora.arn
}
