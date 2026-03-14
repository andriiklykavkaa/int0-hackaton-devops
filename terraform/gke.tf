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

resource "google_container_node_pool" "primary_nodes" {
  name       = "${var.cluster_name}-node-pool"
  # location <- cluster
  location   = var.region
  cluster    = google_container_cluster.primary.name
  
  # autoscaling
  autoscaling {
    min_node_count = 1
    max_node_count = 4
  }

  node_config {
    machine_type = "e2-standard-4"
    disk_size_gb = 50

    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform"
    ]
  }
}
