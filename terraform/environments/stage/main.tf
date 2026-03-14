module "core_infra" {
  source = "../../modules/core_infra"

  project_id = var.project_id
  region     = var.region
  env_name   = "stage" 
}

provider "kubernetes" {
  host                   = "https://${module.core_infra.cluster_endpoint}"
  token                  = data.google_client_config.default.access_token
  cluster_ca_certificate = base64decode(module.core_infra.cluster_ca_certificate)
}

provider "helm" {
  kubernetes = {
    host                   = "https://${module.core_infra.cluster_endpoint}"
    token                  = data.google_client_config.default.access_token
    cluster_ca_certificate = base64decode(module.core_infra.cluster_ca_certificate)
  }
}

data "google_client_config" "default" {}

resource "kubernetes_namespace" "retail_store" {
  metadata {
    name = "retail-store-stage" 
  }
}

resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  namespace        = "argocd"
  create_namespace = true
  version          = "7.7.0"

  set = {
    name  = "server.service.type"
    value = "ClusterIP"
  }
}