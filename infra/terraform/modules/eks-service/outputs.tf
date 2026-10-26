output "service_name" {
  description = "Kubernetes Service name; other services use it as an in-cluster DNS host."
  value       = kubernetes_service_v1.this.metadata[0].name
}

output "service_port" {
  description = "Port exposed by the Kubernetes Service."
  value       = var.service_port
}

output "image" {
  description = "Full image reference that is deployed."
  value       = local.image
}

output "ecr_repository_url" {
  description = "URL to push images to (null when the repository is not managed here)."
  value       = var.create_ecr_repository ? aws_ecr_repository.this[0].repository_url : null
}

output "log_group_name" {
  description = "CloudWatch log group for the service's container logs."
  value       = aws_cloudwatch_log_group.this.name
}

output "iam_role_arn" {
  description = "IRSA role ARN (null when no iam_policy_json was given)."
  value       = local.create_irsa ? aws_iam_role.this[0].arn : null
}

output "ingress_hostname" {
  description = "ALB DNS name once the load balancer is provisioned (null before that or when ingress is disabled)."
  value       = var.ingress.enabled ? try(kubernetes_ingress_v1.this[0].status[0].load_balancer[0].ingress[0].hostname, null) : null
}
