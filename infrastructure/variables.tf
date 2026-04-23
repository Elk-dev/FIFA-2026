variable "project_id" {
  description = "GCP project ID where resources will be provisioned"
  type        = string
}

variable "region" {
  description = "GCP region for the GCS bucket"
  type        = string
  default     = "US"
}

variable "bucket_name" {
  description = "Globally unique name for the GCS data bucket"
  type        = string
}

variable "pipeline_sa_email" {
  description = "Service account email used by the R ETL pipeline to access GCS"
  type        = string
}
