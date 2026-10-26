variable "name" {
  description = "Service name. Used for every Kubernetes object, the ECR repository and the log group."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", var.name))
    error_message = "name must be a valid Kubernetes DNS label (lowercase letters, digits, dashes)."
  }
}

variable "namespace" {
  description = "Existing Kubernetes namespace that receives the workload."
  type        = string
}

variable "cluster_name" {
  description = "EKS cluster name (used in the log group name and IAM role name)."
  type        = string
}

variable "part_of" {
  description = "Application this service belongs to (label app.kubernetes.io/part-of)."
  type        = string
}

variable "component" {
  description = "Role of the service, e.g. web or api (label app.kubernetes.io/component)."
  type        = string
  default     = "app"
}

variable "image_tag" {
  description = "Container image tag to deploy, normally the git commit SHA."
  type        = string
}

variable "create_ecr_repository" {
  description = "Create an ECR repository for this service. Set false to use image_repository instead."
  type        = bool
  default     = true
}

variable "ecr_repository_name" {
  description = "Name of the ECR repository to create. Defaults to the service name."
  type        = string
  default     = null
}

variable "ecr_max_image_count" {
  description = "How many images the ECR lifecycle policy keeps."
  type        = number
  default     = 20
}

variable "image_repository" {
  description = "Existing image repository URL. Required when create_ecr_repository is false."
  type        = string
  default     = null
}

variable "container_port" {
  description = "Port the container listens on."
  type        = number
}

variable "service_port" {
  description = "Port the Kubernetes Service exposes inside the cluster."
  type        = number
  default     = 80
}

variable "run_as_user" {
  description = "Numeric non-root user id the container runs as."
  type        = number
}

variable "read_only_root_filesystem" {
  description = "Mount the container's root filesystem read-only."
  type        = bool
  default     = true
}

variable "environment_variables" {
  description = "Non-secret configuration, stored in a ConfigMap and injected as environment variables."
  type        = map(string)
  default     = {}
}

variable "secret_name" {
  description = "Name of an existing Kubernetes Secret (for example created by External Secrets) injected as environment variables. Secret values never pass through Terraform."
  type        = string
  default     = null
}

variable "resources" {
  description = "CPU/memory requests (reserved) and limits (ceiling) for the container."
  type = object({
    requests = object({ cpu = string, memory = string })
    limits   = object({ cpu = string, memory = string })
  })
}

variable "health_check_path" {
  description = "HTTP path used by the liveness probe, readiness probe and the ALB health check."
  type        = string
  default     = "/healthz"
}

variable "autoscaling" {
  description = "Horizontal Pod Autoscaler settings. Use min_replicas = max_replicas for a fixed size."
  type = object({
    min_replicas           = number
    max_replicas           = number
    cpu_target_utilization = optional(number, 70)
  })
}

variable "ingress" {
  description = "ALB ingress. scheme is 'internal' (VPC only, the safe default) or 'internet-facing'. extra_annotations lets callers add e.g. WAF or OIDC authentication."
  type = object({
    enabled           = optional(bool, true)
    scheme            = optional(string, "internal")
    path              = optional(string, "/")
    host              = optional(string)
    certificate_arn   = optional(string)
    extra_annotations = optional(map(string), {})
  })
  default = {}

  validation {
    condition     = contains(["internal", "internet-facing"], var.ingress.scheme)
    error_message = "ingress.scheme must be 'internal' or 'internet-facing'."
  }
}

variable "ingress_class_name" {
  description = "IngressClass served by the AWS Load Balancer Controller."
  type        = string
  default     = "alb"
}

variable "log_retention_days" {
  description = "CloudWatch Logs retention for the service log group."
  type        = number
  default     = 30
}

variable "log_kms_key_id" {
  description = "Optional KMS key ARN to encrypt the log group."
  type        = string
  default     = null
}

variable "oidc_issuer_url" {
  description = "EKS cluster OIDC issuer URL. Required when iam_policy_json is set (IRSA)."
  type        = string
  default     = null
}

variable "iam_policy_json" {
  description = "IAM policy for the pod (IRSA). When set, an IAM role is created and linked to the service account."
  type        = string
  default     = null
}

variable "wait_for_rollout" {
  description = "Make 'terraform apply' wait until the Deployment is ready. Leave false for the first apply, before any image exists in ECR."
  type        = bool
  default     = false
}

variable "tags" {
  description = "Standard tags applied to AWS resources and the ALB."
  type        = map(string)
  default     = {}
}
