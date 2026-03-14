output "ingress_static_ip" {
    value = google_compute_global_address.ingress_ip.address
    description = "Static IP for the Global HTTP(S)"
}

output "name_servers" {
    value       = google_dns_managed_zone.ecommerce_zone.name_servers
    description = "NS records to configure at domain registrar"
}