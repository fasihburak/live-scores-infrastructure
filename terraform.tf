terraform {
  # cloud {
  #   organization = "showcase-dev"

  #   workspaces {
  #     project = "Learn Terraform"
  #     name    = "learn-terraform-aws-get-started"
  #   }
  # }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "6.2.0"
    }
  }
  required_version = ">= 1.2"
}

