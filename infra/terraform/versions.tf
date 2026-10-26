terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.30"
    }
  }

  # Remote state (recommended for teams): create an S3 bucket + DynamoDB lock table, then uncomment.
  # backend "s3" {
  #   bucket         = "<STATE_BUCKET>"
  #   key            = "merck-shop/terraform.tfstate"
  #   region         = "<REGION>"
  #   dynamodb_table = "<LOCK_TABLE>"
  #   encrypt        = true
  # }
}
