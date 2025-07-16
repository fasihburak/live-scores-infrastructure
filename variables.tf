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

# variable "instance_name" {
#   description = "Value of the EC2 instance's Name tag."
#   type        = string
#   default     = "learn-terraform"
# }

# variable "instance_type" {
#   description = "The EC2 instance's type."
#   type        = string
#   default     = "t2.micro"
# }

