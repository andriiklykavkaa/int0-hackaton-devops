
resource "google_compute_global_address" "ingress_ip" {
    name = "squad-${var.env_name}-static-ip"
}

resource "google_dns_managed_zone" "ecommerce_zone" {
    name        = "squad-${var.env_name}-zone"
    dns_name    = "squad-team.com."
    description = "DNS zone for ${var.env_name} environment"
}

resource "google_dns_record_set" "a_record" {
    name         = google_dns_managed_zone.ecommerce_zone.dns_name
    managed_zone = google_dns_managed_zone.ecommerce_zone.name
    type         = "A"
    ttl          = 300
    rrdatas      = [google_compute_global_address.ingress_ip.address]
}


