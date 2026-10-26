resource "kubernetes_namespace_v1" "this" {
  metadata {
    name = local.namespace

    labels = {
      "app.kubernetes.io/part-of"          = var.project
      "app.kubernetes.io/managed-by"       = "terraform"
      "pod-security.kubernetes.io/enforce" = "restricted"
    }
  }
}

# One call per service: the same module serves both, and any other service could reuse it too.
module "backend" {
  source = "./modules/eks-service"

  name         = "backend"
  component    = "api"
  part_of      = var.project
  namespace    = kubernetes_namespace_v1.this.metadata[0].name
  cluster_name = var.cluster_name

  ecr_repository_name = "${var.project}/backend"
  image_tag           = var.backend_image_tag
  container_port      = local.backend.port
  service_port        = local.backend.port
  run_as_user         = 10001

  environment_variables = local.backend.environment
  secret_name           = var.backend_secret_name
  resources             = local.backend.resources
  autoscaling           = var.backend_autoscaling

  # Internal ALB: reachable inside the VPC only.
  ingress = {
    scheme = "internal"
  }

  oidc_issuer_url = data.aws_eks_cluster.this.identity[0].oidc[0].issuer
  iam_policy_json = local.backend_iam_policy

  log_retention_days = var.log_retention_days
  tags               = local.tags
}

module "frontend" {
  source = "./modules/eks-service"

  name         = "frontend"
  component    = "web"
  part_of      = var.project
  namespace    = kubernetes_namespace_v1.this.metadata[0].name
  cluster_name = var.cluster_name

  ecr_repository_name = "${var.project}/frontend"
  image_tag           = var.frontend_image_tag
  container_port      = local.frontend.port
  run_as_user         = 101

  # nginx writes its generated config and pid file at start-up.
  read_only_root_filesystem = false

  environment_variables = {
    BACKEND_HOST = module.backend.service_name
    BACKEND_PORT = tostring(module.backend.service_port)
  }
  resources   = local.frontend.resources
  autoscaling = var.frontend_autoscaling

  # The only internet-facing entry point.
  ingress = {
    scheme          = "internet-facing"
    host            = var.frontend_host
    certificate_arn = var.certificate_arn
  }

  log_retention_days = var.log_retention_days
  tags               = local.tags
}
