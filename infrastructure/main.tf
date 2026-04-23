terraform {
  required_version = ">= 1.3.0"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

# ---------------------------------------------------------------------------
# GCS Bucket — stores raw and processed World Cup datasets
# ---------------------------------------------------------------------------
resource "google_storage_bucket" "wc2026_data" {
  name          = var.bucket_name
  location      = var.region
  force_destroy = false

  # Prevent accidental public exposure
  public_access_prevention = "enforced"

  uniform_bucket_level_access = true

  versioning {
    enabled = true
  }

  lifecycle_rule {
    action {
      type = "Delete"
    }
    condition {
      num_newer_versions = 3
    }
  }

  labels = {
    project     = "wc2026-prediction"
    environment = "research"
    managed_by  = "terraform"
  }
}

# ---------------------------------------------------------------------------
# IAM — grants the pipeline service account read/write access to the bucket
# ---------------------------------------------------------------------------
resource "google_storage_bucket_iam_member" "pipeline_rw" {
  bucket = google_storage_bucket.wc2026_data.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${var.pipeline_sa_email}"
}
