terraform {
  required_version = ">= 1.16.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "6.67.0"
    }
  }
  # Local state (gitignored); see docs/SECURITY.md accepted risks.
}

provider "aws" {
  region  = var.region
  profile = var.aws_profile

  default_tags {
    tags = {
      Project   = "AdPulse"
      Owner     = "jugal"
      ManagedBy = "Terraform"
      Ephemeral = "true"
    }
  }
}
