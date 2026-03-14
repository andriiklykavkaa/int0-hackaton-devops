output "ingress_static_ip" {
    value = google_compute_global_address.ingress_ip.address
    description = "Static IP for the Global HTTP(S)"
}

output "name_servers" {
    value       = google_dns_managed_zone.ecommerce_zone.name_servers
    description = "NS records to configure at domain registrar"
}

output "cluster_endpoint" {
  value = google_container_cluster.primary.endpoint
}

output "cluster_ca_certificate" {
  value = google_container_cluster.primary.master_auth[0].cluster_ca_certificate
}