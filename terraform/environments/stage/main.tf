module "core_infra" {
  source = "../../modules/core_infra"

  project_id = var.project_id
  region     = var.region
  env_name   = "stage" 
}