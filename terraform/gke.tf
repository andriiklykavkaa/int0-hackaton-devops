resource "google_container_cluster" "primary" {
  name     = var.cluster_name
  location = var.region
  
  network    = google_compute_network.vpc.name
  subnetwork = google_compute_subnetwork.subnet.name

  # Rule the nodes manually
  remove_default_node_pool = true
  initial_node_count       = 1

  ip_allocation_policy {
    cluster_secondary_range_name  = "pods-range"
    services_secondary_range_name = "services-range"
  }

  # Allow K8s provider to connect without shitting itself
  deletion_protection = false
}

# custom Service Account for GKE
resource "google_service_account" "gke_sa" {
  account_id   = "${var.cluster_name}-sa"
  display_name = "Service Account for GKE Nodes"
}

# access to Artifact Registry
resource "google_project_iam_member" "gke_sa_registry_reader" {
  project = var.project_id
  role    = "roles/artifactregistry.reader"
  member  = "serviceAccount:${google_service_account.gke_sa.email}"
}

# access to logs and metrics
resource "google_project_iam_member" "gke_sa_logging" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.gke_sa.email}"
}
resource "google_project_iam_member" "gke_sa_monitoring" {
  project = var.project_id
  role    = "roles/monitoring.metricWriter"
  member  = "serviceAccount:${google_service_account.gke_sa.email}"
}

resource "google_container_node_pool" "primary_nodes" {
  name       = "${var.cluster_name}-node-pool"
  # location <- cluster
  location   = var.region
  cluster    = google_container_cluster.primary.name

  node_locations = [
    "${var.region}-a",
    "${var.region}-b",
    "${var.region}-c"
  ]
  
  # autoscaling
  autoscaling {
    min_node_count = 1
    max_node_count = 4
  }

  node_config {
    machine_type = "e2-standard-4"
    disk_size_gb = 50

    service_account = google_service_account.gke_sa.email
    oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"]
  }
}
