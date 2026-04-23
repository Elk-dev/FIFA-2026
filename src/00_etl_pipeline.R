# =============================================================================
# 00_etl_pipeline.R
# FIFA 2026 World Cup Prediction — ETL Pipeline
# -----------------------------------------------------------------------------
# Pulls cleaned datasets from Google Cloud Storage into the local R session.
# Falls back to the local data/ directory if GCS credentials are unavailable
# (e.g., when running without Application Default Credentials configured).
#
# Infrastructure: GCS bucket provisioned via Terraform (see /infrastructure)
# Authentication: gcloud ADC locally | GitHub Actions SA key in CI
# =============================================================================

library(tidyverse)

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

GCS_BUCKET    <- "wc2026-prediction-data-elkinhuertas"
GCS_AVAILABLE <- FALSE   # flipped to TRUE if googleCloudStorageR loads cleanly

DATASETS <- list(
  player_data        = "player_data.csv",
  major_tournaments  = "major_int_tournaments.csv"
)

LOCAL_DATA_DIR <- file.path(dirname(getwd()), "data")

# ---------------------------------------------------------------------------
# Logging helper
# ---------------------------------------------------------------------------

log_msg <- function(level = "INFO", msg) {
  ts <- format(Sys.time(), "%Y-%m-%d %H:%M:%S")
  cat(sprintf("[%s] [%s] %s\n", ts, level, msg))
}

# ---------------------------------------------------------------------------
# GCS availability check
# ---------------------------------------------------------------------------

check_gcs <- function() {
  if (!requireNamespace("googleCloudStorageR", quietly = TRUE)) {
    log_msg("WARN", "googleCloudStorageR not installed — falling back to local data/")
    return(FALSE)
  }

  tryCatch({
    library(googleCloudStorageR)
    gcs_global_bucket(GCS_BUCKET)
    log_msg("INFO", paste("GCS authenticated — bucket:", GCS_BUCKET))
    return(TRUE)
  }, error = function(e) {
    log_msg("WARN", paste("GCS auth failed:", conditionMessage(e)))
    log_msg("WARN", "Falling back to local data/ directory")
    return(FALSE)
  })
}

# ---------------------------------------------------------------------------
# Data validation
# ---------------------------------------------------------------------------

validate_dataset <- function(df, name) {
  log_msg("INFO", paste("Validating:", name))

  # Row count
  if (nrow(df) == 0) stop(paste(name, "has 0 rows — check source file"))
  log_msg("INFO", paste(" Rows:", nrow(df), "| Cols:", ncol(df)))

  # Null check
  null_counts <- colSums(is.na(df))
  high_null   <- null_counts[null_counts > nrow(df) * 0.5]
  if (length(high_null) > 0) {
    log_msg("WARN", paste(" High null columns (>50%):", paste(names(high_null), collapse = ", ")))
  }

  # Schema check — expected columns per dataset
  expected <- list(
    player_data       = c("nation", "player", "minutes", "xg", "xa", "xgchain"),
    major_tournaments = c("Home", "Away", "HomeGoals", "AwayGoals", "Date")
  )

  if (name %in% names(expected)) {
    missing_cols <- setdiff(expected[[name]], colnames(df))
    if (length(missing_cols) > 0) {
      stop(paste(name, "missing expected columns:", paste(missing_cols, collapse = ", ")))
    }
    log_msg("INFO", paste(" Schema check passed for", name))
  }

  log_msg("INFO", paste(" Validation complete for", name))
  return(df)
}

# ---------------------------------------------------------------------------
# Loaders
# ---------------------------------------------------------------------------

load_from_gcs <- function(filename, dataset_name) {
  log_msg("INFO", paste("Pulling from GCS:", filename))
  tmp <- tempfile(fileext = ".csv")
  googleCloudStorageR::gcs_get_object(filename, saveToDisk = tmp, overwrite = TRUE)
  df <- read_csv(tmp, show_col_types = FALSE)
  log_msg("INFO", paste("Successfully loaded from GCS:", filename))
  return(df)
}

load_from_local <- function(filename, dataset_name) {
  path <- file.path(LOCAL_DATA_DIR, filename)
  if (!file.exists(path)) {
    stop(paste("Local fallback not found:", path))
  }
  log_msg("INFO", paste("Loading from local fallback:", path))
  df <- read_csv(path, show_col_types = FALSE)
  log_msg("INFO", paste("Successfully loaded locally:", filename))
  return(df)
}

# ---------------------------------------------------------------------------
# Main pipeline
# ---------------------------------------------------------------------------

run_etl <- function() {
  log_msg("INFO", "========== ETL PIPELINE START ==========")

  # Check GCS availability
  GCS_AVAILABLE <<- check_gcs()

  # Load and validate each dataset
  loaded <- list()

  for (dataset_name in names(DATASETS)) {
    filename <- DATASETS[[dataset_name]]

    log_msg("INFO", paste("--- Loading:", dataset_name, "---"))

    df <- tryCatch({
      if (GCS_AVAILABLE) {
        load_from_gcs(filename, dataset_name)
      } else {
        load_from_local(filename, dataset_name)
      }
    }, error = function(e) {
      log_msg("ERROR", paste("Failed to load", dataset_name, ":", conditionMessage(e)))
      stop(e)
    })

    # Validate
    df <- validate_dataset(df, dataset_name)

    # Store in list
    loaded[[dataset_name]] <- df
  }

  log_msg("INFO", "========== ETL PIPELINE COMPLETE ==========")
  log_msg("INFO", paste("Datasets ready:", paste(names(loaded), collapse = ", ")))

  return(loaded)
}

# ---------------------------------------------------------------------------
# Execute
# ---------------------------------------------------------------------------

etl_data <- run_etl()

# Expose datasets to the global environment for downstream scripts
player_data       <- etl_data$player_data
major_tournaments <- etl_data$major_tournaments

log_msg("INFO", "Datasets assigned to global environment: player_data, major_tournaments")