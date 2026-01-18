# infrastructure/backend.tf
# This file is typically configured per environment
terraform {
  backend "gcs" {
    # These values are typically passed via CLI or workspace
    # bucket = "tf-state-${var.project_id}"
    # prefix = "trade-pipeline/${var.environment}"
  }
}

# Example: Create the state bucket if it doesn't exist
resource "google_storage_bucket" "terraform_state" {
  count = var.create_state_bucket ? 1 : 0
  
  name          = "tf-state-${var.project_id}"
  location      = var.region
  force_destroy = var.environment == "dev"  # Be careful with this in prod
  
  versioning {
    enabled = true
  }
  
  lifecycle_rule {
    condition {
      age = 90  # Keep state for 90 days
    }
    action {
      type = "Delete"
    }
  }
  
  encryption {
    default_kms_key_name = google_kms_crypto_key.terraform_state[0].id
  }
  
  labels = {
    environment = var.environment
    managed-by  = "terraform"
  }
}

# Optional: KMS key for state encryption
resource "google_kms_key_ring" "terraform_state" {
  count = var.create_state_bucket ? 1 : 0
  
  name     = "terraform-state"
  location = var.region
  
  lifecycle {
    prevent_destroy = true
  }
}

resource "google_kms_crypto_key" "terraform_state" {
  count = var.create_state_bucket ? 1 : 0
  
  name            = "state-encryption"
  key_ring        = google_kms_key_ring.terraform_state[0].id
  rotation_period = "7776000s"  # 90 days
  
  lifecycle {
    prevent_destroy = true
  }
}
