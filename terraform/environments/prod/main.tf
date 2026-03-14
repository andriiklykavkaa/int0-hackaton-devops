module "core_infra" {
  source = "../../modules/core_infra"

  project_id = var.project_id
  region     = var.region
  env_name   = "prod" 
}

data "google_client_config" "default" {}

provider "kubernetes" {
  host                   = "https://${module.core_infra.cluster_endpoint}"
  token                  = data.google_client_config.default.access_token
  cluster_ca_certificate = base64decode(module.core_infra.cluster_ca_certificate)
}

resource "kubernetes_namespace" "retail_store" {
  metadata {
    name = "retail-store-prod" 
  }
}