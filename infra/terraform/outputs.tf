output "namespace" {
  description = "Namespace that holds the application."
  value       = kubernetes_namespace_v1.this.metadata[0].name
}

output "ecr_repository_urls" {
  description = "Where CI pushes the container images."
  value = {
    backend  = module.backend.ecr_repository_url
    frontend = module.frontend.ecr_repository_url
  }
}

output "backend_iam_role_arn" {
  description = "IRSA role of the backend pod (null unless ml_service_role_arn is set)."
  value       = module.backend.iam_role_arn
}

output "frontend_alb_hostname" {
  description = "Public ALB DNS name. Point your DNS record (or CloudFront origin) at it. Empty until the controller creates the ALB; run apply again or check 'kubectl get ingress'."
  value       = module.frontend.ingress_hostname
}

output "backend_internal_alb_hostname" {
  description = "Internal ALB DNS name of the backend (VPC only)."
  value       = module.backend.ingress_hostname
}
