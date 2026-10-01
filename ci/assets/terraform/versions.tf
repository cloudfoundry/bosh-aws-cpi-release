terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
      version = "~> 3.75.0"
    }
  }
  required_version = ">= 0.15"
}
