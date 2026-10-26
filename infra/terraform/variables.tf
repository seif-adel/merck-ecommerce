variable "aws_region" {
  description = "AWS region of the EKS cluster."
  type        = string
  default     = "eu-central-1"
}

variable "cluster_name" {
  description = "Name of the existing EKS cluster."
  type        = string
}

variable "project" {
  description = "Project name; used for the namespace, labels, ECR repositories and IAM roles."
  type        = string
  default     = "merck-shop"
}

variable "environment" {
  description = "Environment name, e.g. dev, stage or prod."
  type        = string
  default     = "dev"
}

variable "owner" {
  description = "Team that owns this workload (tag)."
  type        = string
  default     = "platform-engineering"
}

variable "namespace" {
  description = "Kubernetes namespace to create. Defaults to the project name."
  type        = string
  default     = null
}

variable "backend_image_tag" {
  description = "Backend image tag to deploy (git commit SHA)."
  type        = string
}

variable "frontend_image_tag" {
  description = "Frontend image tag to deploy (git commit SHA)."
  type        = string
}

variable "frontend_host" {
  description = "DNS name served by the internet-facing ALB, e.g. shop.example.com. Null matches any host."
  type        = string
  default     = null
}

variable "certificate_arn" {
  description = "ACM certificate ARN. When set, the frontend ALB serves HTTPS and redirects HTTP to it."
  type        = string
  default     = null
}

variable "backend_secret_name" {
  description = "Existing Kubernetes Secret holding backend credentials (created by External Secrets from Secrets Manager)."
  type        = string
  default     = "backend-secrets"
}

variable "ml_api_url" {
  description = "Invoke URL of the private recommendation API in the ML account (not a secret). Passed to the backend as ML_API_URL; null leaves it unset."
  type        = string
  default     = null
}

variable "backend_autoscaling" {
  description = "Backend HPA"
  type = object({
    min_replicas           = number
    max_replicas           = number
    cpu_target_utilization = optional(number, 70)
  })
  default = {
    min_replicas = 1
    max_replicas = 5
  }
}

variable "frontend_autoscaling" {
  description = "Frontend HPA."
  type = object({
    min_replicas           = number
    max_replicas           = number
    cpu_target_utilization = optional(number, 70)
  })
  default = {
    min_replicas = 2
    max_replicas = 4
  }
}

variable "ml_service_role_arn" {
  description = "Role in the ML account that grants execute-api:Invoke on the recommendation API. When set, the backend pod may assume it."
  type        = string
  default     = null
}

variable "log_retention_days" {
  description = "CloudWatch Logs retention."
  type        = number
  default     = 30
}
