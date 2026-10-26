provider "aws" {
  region = var.aws_region

  # Every taggable AWS resource gets these tags automatically.
  default_tags {
    tags = local.tags
  }
}

# The cluster already exists; we only read its connection details.
data "aws_eks_cluster" "this" {
  name = var.cluster_name
}

provider "kubernetes" {
  host                   = data.aws_eks_cluster.this.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)

  # Fetches a short-lived token through the AWS CLI each time, so it never expires mid-apply.
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", var.cluster_name, "--region", var.aws_region]
  }
}
