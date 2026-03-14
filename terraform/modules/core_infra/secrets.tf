resource "google_secret_manager_secret" "db_password" {
  secret_id = "db-password-${var.env_name}"
  
  replication {
    auto {}
  }

  depends_on = [google_project_service.enabled_apis]
}

resource "google_project_iam_member" "gke_sa_secret_accessor" {
  project = var.project_id
  role    = "roles/secretmanager.secretAccessor"
  member  = "serviceAccount:${google_service_account.gke_sa.email}"

  depends_on = [google_project_service.enabled_apis]
}