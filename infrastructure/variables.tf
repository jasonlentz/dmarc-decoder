variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Project name — used as a prefix for all resources"
  type        = string
  default     = "dmarc-decoder"
}

variable "s3_bucket_name" {
  description = "Globally unique S3 bucket name"
  type        = string
  default     = "dmarc-decoder"
}

variable "s3_force_destroy" {
  description = "If true, terraform destroy will delete the S3 bucket and all report data. Set false to protect data from accidental destruction."
  type        = bool
  default     = false
}

variable "db_name" {
  description = "Aurora database name"
  type        = string
  default     = "dmarcdb"
}

variable "db_username" {
  description = "Aurora master username"
  type        = string
  default     = "dmarcadmin"
}

variable "allowed_ips" {
  description = "List of IPs or CIDR blocks permitted to call the API (e.g. [\"1.2.3.4/32\", \"5.6.7.8/32\"])"
  type        = list(string)
  # Set this in terraform.tfvars — do not commit your IPs to the repo
}
