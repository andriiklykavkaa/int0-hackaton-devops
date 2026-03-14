resource "google_artifact_registry_repository" "retail_repo" {
  location      = var.region
  repository_id = "retail-images"
  description   = "Docker registry for microservices"
  format        = "DOCKER"
}