resource "google_artifact_registry_repository" "retail_repo" {
  location      = var.region
  repository_id = "retail-images-${var.env_name}"
  description   = "Docker registry for microservices (${var.env_name})"
  format        = "DOCKER"

  depends_on = [google_project_service.enabled_apis]
}