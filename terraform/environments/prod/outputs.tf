output "stage_ingress_ip" {
  description = "Static IP for Prod Ingress"
  value       = module.core_infra.ingress_static_ip 
}

output "stage_name_servers" {
  value = module.core_infra.name_servers
}