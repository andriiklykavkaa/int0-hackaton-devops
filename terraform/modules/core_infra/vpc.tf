resource "google_compute_network" "vpc" {
  name                    = "squad-ecommerce-${var.env_name}-vpc"
  auto_create_subnetworks = false

  depends_on = [google_project_service.enabled_apis]
}

resource "google_compute_subnetwork" "subnet" {
  name          = "squad-ecommerce-${var.env_name}-subnet"
  region        = var.region
  network       = google_compute_network.vpc.name
  ip_cidr_range = "10.10.0.0/16"

  secondary_ip_range {
    range_name    = "pods-range"
    ip_cidr_range = "10.20.0.0/16"
  }

  secondary_ip_range {
    range_name    = "services-range"
    ip_cidr_range = "10.30.0.0/20"
  }
}