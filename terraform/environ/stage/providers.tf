terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }

  backend "gcs" {
    bucket = "int-final-tfstate-bucket"
    prefix = "terraform/state/stage"
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}