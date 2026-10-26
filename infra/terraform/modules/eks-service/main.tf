data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  selector_labels = {
    "app.kubernetes.io/name"     = var.name
    "app.kubernetes.io/instance" = var.part_of
  }

  labels = merge(local.selector_labels, {
    "app.kubernetes.io/component"  = var.component
    "app.kubernetes.io/part-of"    = var.part_of
    "app.kubernetes.io/managed-by" = "terraform"
    "app.kubernetes.io/version"    = var.image_tag
  })

  image_repository = var.create_ecr_repository ? aws_ecr_repository.this[0].repository_url : var.image_repository
  image            = "${local.image_repository}:${var.image_tag}"

  create_irsa = var.iam_policy_json != null
  oidc_host   = var.oidc_issuer_url == null ? "" : replace(var.oidc_issuer_url, "https://", "")

  alb_tags = join(",", [for key, value in var.tags : "${key}=${value}"])

  https_annotations = var.ingress.certificate_arn == null ? {} : {
    "alb.ingress.kubernetes.io/listen-ports"    = jsonencode([{ HTTP = 80 }, { HTTPS = 443 }])
    "alb.ingress.kubernetes.io/ssl-redirect"    = "443"
    "alb.ingress.kubernetes.io/certificate-arn" = var.ingress.certificate_arn
  }

  ingress_annotations = merge(
    {
      "alb.ingress.kubernetes.io/scheme"           = var.ingress.scheme
      "alb.ingress.kubernetes.io/target-type"      = "ip"
      "alb.ingress.kubernetes.io/healthcheck-path" = var.health_check_path
      "alb.ingress.kubernetes.io/tags"             = local.alb_tags
    },
    local.https_annotations,
    var.ingress.extra_annotations,
  )
}

# ------------------------------------------------------------------ ECR
resource "aws_ecr_repository" "this" {
  count = var.create_ecr_repository ? 1 : 0

  name                 = coalesce(var.ecr_repository_name, var.name)
  image_tag_mutability = "IMMUTABLE" # a tag always means the same image

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = var.tags
}

resource "aws_ecr_lifecycle_policy" "this" {
  count = var.create_ecr_repository ? 1 : 0

  repository = aws_ecr_repository.this[0].name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep only the most recent images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = var.ecr_max_image_count
      }
      action = { type = "expire" }
    }]
  })
}

# ------------------------------------------------------------------ Logging
# Created up front so retention is enforced; a log agent (Fluent Bit / CloudWatch Observability add-on)
# is configured to write this service's container logs into it.
resource "aws_cloudwatch_log_group" "this" {
  name              = "/aws/eks/${var.cluster_name}/${var.namespace}/${var.name}"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.log_kms_key_id
  tags              = var.tags
}

# ------------------------------------------------------------------ IAM role for the pod (IRSA)
data "aws_iam_policy_document" "assume_role" {
  count = local.create_irsa ? 1 : 0

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = ["arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/${local.oidc_host}"]
    }

    # Only this exact service account may assume the role.
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:sub"
      values   = ["system:serviceaccount:${var.namespace}:${var.name}"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "this" {
  count = local.create_irsa ? 1 : 0

  name               = "${var.part_of}-${var.name}-${var.cluster_name}"
  assume_role_policy = data.aws_iam_policy_document.assume_role[0].json
  tags               = var.tags

  lifecycle {
    precondition {
      condition     = var.oidc_issuer_url != null
      error_message = "oidc_issuer_url is required when iam_policy_json is set."
    }
  }
}

resource "aws_iam_role_policy" "this" {
  count = local.create_irsa ? 1 : 0

  name   = "${var.name}-access"
  role   = aws_iam_role.this[0].id
  policy = var.iam_policy_json
}

# ------------------------------------------------------------------ Kubernetes workload
resource "kubernetes_service_account_v1" "this" {
  metadata {
    name        = var.name
    namespace   = var.namespace
    labels      = local.labels
    annotations = local.create_irsa ? { "eks.amazonaws.com/role-arn" = aws_iam_role.this[0].arn } : {}
  }

  automount_service_account_token = false
}

resource "kubernetes_config_map_v1" "this" {
  metadata {
    name      = "${var.name}-config"
    namespace = var.namespace
    labels    = local.labels
  }

  data = var.environment_variables
}

resource "kubernetes_deployment_v1" "this" {
  metadata {
    name      = var.name
    namespace = var.namespace
    labels    = local.labels
  }

  wait_for_rollout = var.wait_for_rollout

  spec {
    revision_history_limit = 3

    selector {
      match_labels = local.selector_labels
    }

    strategy {
      type = "RollingUpdate"

      rolling_update {
        max_surge       = "1"
        max_unavailable = "0"
      }
    }

    template {
      metadata {
        labels = local.labels
        annotations = {
          # Pods restart when the ConfigMap content changes.
          "checksum/config" = sha256(jsonencode(var.environment_variables))
        }
      }

      spec {
        service_account_name            = kubernetes_service_account_v1.this.metadata[0].name
        automount_service_account_token = false

        security_context {
          run_as_non_root = true
          run_as_user     = var.run_as_user

          seccomp_profile {
            type = "RuntimeDefault"
          }
        }

        container {
          name  = var.name
          image = local.image

          port {
            name           = "http"
            container_port = var.container_port
          }

          env_from {
            config_map_ref {
              name = kubernetes_config_map_v1.this.metadata[0].name
            }
          }

          dynamic "env_from" {
            for_each = var.secret_name == null ? [] : [var.secret_name]

            content {
              secret_ref {
                name = env_from.value
              }
            }
          }

          resources {
            requests = var.resources.requests
            limits   = var.resources.limits
          }

          liveness_probe {
            http_get {
              path = var.health_check_path
              port = "http"
            }

            initial_delay_seconds = 10
            period_seconds        = 10
            failure_threshold     = 3
          }

          readiness_probe {
            http_get {
              path = var.health_check_path
              port = "http"
            }

            initial_delay_seconds = 3
            period_seconds        = 5
            failure_threshold     = 3
          }
        }
      }
    }
  }
}

resource "kubernetes_service_v1" "this" {
  metadata {
    name      = var.name
    namespace = var.namespace
    labels    = local.labels
  }

  spec {
    type     = "ClusterIP"
    selector = local.selector_labels

    port {
      name        = "http"
      port        = var.service_port
      target_port = "http"
    }
  }
}

resource "kubernetes_ingress_v1" "this" {
  count = var.ingress.enabled ? 1 : 0

  metadata {
    name        = var.name
    namespace   = var.namespace
    labels      = local.labels
    annotations = local.ingress_annotations
  }

  spec {
    ingress_class_name = var.ingress_class_name

    rule {
      host = var.ingress.host

      http {
        path {
          path      = var.ingress.path
          path_type = "Prefix"

          backend {
            service {
              name = kubernetes_service_v1.this.metadata[0].name

              port {
                name = "http"
              }
            }
          }
        }
      }
    }
  }
}

resource "kubernetes_horizontal_pod_autoscaler_v2" "this" {
  metadata {
    name      = var.name
    namespace = var.namespace
    labels    = local.labels
  }

  spec {
    min_replicas = var.autoscaling.min_replicas
    max_replicas = var.autoscaling.max_replicas

    scale_target_ref {
      api_version = "apps/v1"
      kind        = "Deployment"
      name        = kubernetes_deployment_v1.this.metadata[0].name
    }

    metric {
      type = "Resource"

      resource {
        name = "cpu"

        target {
          type                = "Utilization"
          average_utilization = var.autoscaling.cpu_target_utilization
        }
      }
    }

    behavior {
      scale_down {
        stabilization_window_seconds = 300 # wait 5 min before shrinking to avoid flapping
        select_policy                = "Min"

        policy {
          type           = "Percent"
          value          = 50
          period_seconds = 60
        }
      }
    }
  }
}
