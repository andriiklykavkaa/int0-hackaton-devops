resource "google_project_service" "enabled_apis" {
  for_each = toset([
    "cloudresourcemanager.googleapis.com",
    "compute.googleapis.com",
    "container.googleapis.com",
    "artifactregistry.googleapis.com",
    "secretmanager.googleapis.com",
    "iam.googleapis.com"
  ])
  
  project            = var.project_id
  service            = each.key
  disable_on_destroy = false
}


data "google_client_config" "default" {}

provider "kubernetes" {
  host                   = "https://${module.core_infra.cluster_endpoint}"
  token                  = data.google_client_config.default.access_token
  cluster_ca_certificate = base64decode(module.core_infra.cluster_ca_certificate)
}

resource "kubernetes_namespace" "retail_store" {
  metadata {
    name = "retail-store-${var.env_name}" 
  }
}