variable "TFC_AWS_PROVIDER_AUTH" {
  description = "Whether to enable AWS provider authentication for Terraform Cloud."
  type        = bool
}

variable "TFC_AWS_RUN_ROLE_ARN" {
  description = "The ARN of the AWS IAM role that Terraform Cloud will assume."
  type        = string
}

variable "AWS_REGION" {
  type        = string
}

variable "instance_type" {
  description = "The EC2 instance's type."
  type        = string
  default     = "t2.small"
}

variable "ami_id" {
  description = "The AMI ID to use for the EC2 instance."
  type        = string 
  default     = "ami-0a72753edf3e631b7" # AMI for Amazon Linux
}

variable "aurora_postgres_db_master_username" {
  type        = string
  sensitive   = true
}

variable "aurora_postgres_db_master_password" {
  type        = string
  sensitive   = true
}

variable "my_ip_address" {
  description = "Your public IP for SSH access"
  type        = string
}

variable "route53_hosted_zone_id" {
  description = "The Route53 Hosted Zone ID"
  type        = string
}

variable "route53_hosted_zone_name" {
  description = "The Route53 Hosted Zone name (e.g., example.com)"
  type        = string
}