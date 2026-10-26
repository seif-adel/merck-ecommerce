locals {
  namespace = var.project

  tags = {
    Project     = var.project
    Environment = var.environment
    Owner       = var.owner
    ManagedBy   = "Software Engineer-Platform-2"
  }

  backend = {
    port = 8000
    resources = {
      requests = { cpu = "100m", memory = "128Mi" }
      limits   = { cpu = "500m", memory = "256Mi" }
    }
    environment = merge(
      {
        APP_ENV     = var.environment
        LOG_LEVEL   = "INFO"
        ENABLE_DOCS = "false"
      },
      var.ml_api_url == null ? {} : { ML_API_URL = var.ml_api_url },
    )
  }

  frontend = {
    port = 8080
    resources = {
      requests = { cpu = "50m", memory = "32Mi" }
      limits   = { cpu = "200m", memory = "64Mi" }
    }
  }

  # Lets the backend pod assume the ML-account role; null means no IAM role is created.
  backend_iam_policy = var.ml_service_role_arn == null ? null : jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "sts:AssumeRole"
      Resource = var.ml_service_role_arn
    }]
  })
}
