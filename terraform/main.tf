
resource "google_project_service" "enabled_apis" {
  for_each = toset([
    "compute.googleapis.com",          # for VPC and networkі
    "container.googleapis.com",        # for GKE cluster
    "artifactregistry.googleapis.com", # for Artifact Registry
    "secretmanager.googleapis.com",    # for Secret Manager
    "iam.googleapis.com"               # for managing Service Accounts
  ])
  
  project            = var.project_id
  service            = each.key
  disable_on_destroy = false
}