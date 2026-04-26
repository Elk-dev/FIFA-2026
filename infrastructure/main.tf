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

# ---------------------------------------------------------------------------
# Workload Identity Federation — Keyless GitHub Actions Authentication
# ---------------------------------------------------------------------------

resource "google_iam_workload_identity_pool" "github_pool" {
  workload_identity_pool_id = "github-pool"
  display_name              = "GitHub Actions Pool"
  description               = "Identity pool for GitHub Actions CI/CD"
  project                   = var.project_id
}

resource "google_iam_workload_identity_pool_provider" "github_provider" {
  workload_identity_pool_id          = google_iam_workload_identity_pool.github_pool.workload_identity_pool_id
  workload_identity_pool_provider_id = "github-provider"
  project                            = var.project_id
  display_name                       = "GitHub Provider"

  attribute_mapping = {
    "google.subject"       = "assertion.sub"
    "attribute.repository" = "assertion.repository"
  }

  attribute_condition = "attribute.repository == 'Elk-dev/FIFA-2026'"

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}

resource "google_service_account_iam_member" "github_wif_binding" {
  service_account_id = "projects/${var.project_id}/serviceAccounts/${var.pipeline_sa_email}"
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github_pool.name}/attribute.repository/${var.github_repo}"
}