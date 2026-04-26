output "bucket_name" {
  description = "Name of the provisioned GCS bucket"
  value       = google_storage_bucket.wc2026_data.name
}

output "bucket_url" {
  description = "GCS URL for use in the ETL pipeline"
  value       = "gs://${google_storage_bucket.wc2026_data.name}"
}

output "bucket_self_link" {
  description = "Self-link of the GCS bucket"
  value       = google_storage_bucket.wc2026_data.self_link
}

output "workload_identity_provider" {
  description = "Workload Identity Provider resource name for GitHub Actions"
  value       = google_iam_workload_identity_pool_provider.github_provider.name
}

output "service_account_email" {
  description = "Service account email for GitHub Actions"
  value       = var.pipeline_sa_email
}