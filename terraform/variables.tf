variable "project_id" {
  description = "The ID of the GCP project"
  type        = string
}

variable "region" {
  description = "The region to deploy resources to (Central Europe)"
  type        = string
  default     = "europe-central2"
}

variable "cluster_name" {
  description = "The name of the GKE cluster"
  type        = string
  default     = "squad-ecommerce"
}
