# =============================================================================
# 04_poisson_model.R
# FIFA 2026 World Cup Prediction — Bivariate Poisson Regression Model
# -----------------------------------------------------------------------------
# Models goals scored by each team as a Poisson process, a statistically
# principled approach for count data like football scorelines.
#
# Why Poisson?
#   Goals in football are rare, discrete, independent events — exactly the
#   conditions under which a Poisson distribution applies (Maher, 1982).
#   Unlike classification models that predict Win/Draw/Loss directly, the
#   Poisson model predicts the full scoreline distribution, allowing us to
#   derive win probabilities, expected goals, and simulate tournaments.
#
# Model:
#   Goals_i ~ Poisson(lambda_i)
#   log(lambda_i) = b0 + b1*team_xg + b2*team_xa + b3*opp_xg + b4*is_home
#
# Cross-Validation:
#   Rolling time-series CV — train on past, validate on future windows.
#   Prevents data leakage inherent in random k-fold for temporal data.
#
# Inputs:  train_goals, test_goals (from 03_feature_engineering.R)
# Outputs: poisson_model, model_metrics, score_matrix function
# =============================================================================

library(tidyverse)
library(MASS)
library(caret)
library(ggplot2)

if (!exists("train_goals")) source("03_feature_engineering.R")

log_msg("INFO", "========== POISSON MODEL START ==========")

# ---------------------------------------------------------------------------
# 1. Baseline Poisson Model
# ---------------------------------------------------------------------------

log_msg("INFO", "Fitting baseline Poisson regression model...")

poisson_model <- glm(
  Goals ~ team_xg_weighted +
          team_xa_weighted +
          team_xgchain_weighted +
          opp_xg_weighted +
          opp_depth_index +
          is_home,
  data   = train_goals,
  family = poisson(link = "log")
)

log_msg("INFO", "Model summary:")
print(summary(poisson_model))

# Check for overdispersion — if residual deviance >> df, use negative binomial
dispersion_ratio <- poisson_model$deviance / poisson_model$df.residual
log_msg("INFO", paste("Dispersion ratio:", round(dispersion_ratio, 3),
                      "| (>1.5 suggests overdispersion)"))

# ---------------------------------------------------------------------------
# 2. Negative Binomial Fallback (if overdispersed)
# ---------------------------------------------------------------------------

if (dispersion_ratio > 1.5) {
  log_msg("WARN", "Overdispersion detected — fitting Negative Binomial model")

  nb_model <- glm.nb(
    Goals ~ team_xg_weighted +
            team_xa_weighted +
            team_xgchain_weighted +
            opp_xg_weighted +
            opp_depth_index +
            is_home,
    data = train_goals
  )

  log_msg("INFO", "Negative Binomial model summary:")
  print(summary(nb_model))

  # Use NB model going forward
  final_model      <- nb_model
  final_model_name <- "Negative Binomial"
} else {
  log_msg("INFO", "No overdispersion — Poisson model is appropriate")
  final_model      <- poisson_model
  final_model_name <- "Poisson"
}

log_msg("INFO", paste("Selected model:", final_model_name))

# ---------------------------------------------------------------------------
# 3. Rolling Time-Series Cross-Validation
# ---------------------------------------------------------------------------
# Addresses professor feedback: "no CV"
# Rolling window: train on first N months, validate on next M months,
# then expand window forward — never trains on future data.
# ---------------------------------------------------------------------------

log_msg("INFO", "Running rolling time-series cross-validation...")

rolling_cv <- function(df, n_folds = 5) {

  df     <- df %>% arrange(Date)
  dates  <- sort(unique(df$Date))
  n      <- length(dates)

  # Create fold cutpoints — each fold uses more historical data
  fold_size   <- floor(n / (n_folds + 1))
  fold_results <- map_dfr(1:n_folds, function(fold) {

    train_cutoff    <- dates[fold * fold_size]
    val_start       <- dates[fold * fold_size + 1]
    val_cutoff      <- dates[min((fold + 1) * fold_size, n)]

    fold_train <- df %>% filter(Date <= train_cutoff)
    fold_val   <- df %>% filter(Date > train_cutoff & Date <= val_cutoff)

    if (nrow(fold_train) < 30 || nrow(fold_val) < 10) return(NULL)

    # Fit model on fold train
    fold_model <- tryCatch(
      glm(Goals ~ team_xg_weighted + team_xa_weighted +
                  team_xgchain_weighted + opp_xg_weighted +
                  opp_depth_index + is_home,
          data   = fold_train,
          family = poisson(link = "log")),
      error = function(e) {
        log_msg("WARN", paste("Fold", fold, "failed:", conditionMessage(e)))
        return(NULL)
      }
    )

    if (is.null(fold_model)) return(NULL)

    # Predict on fold validation set
    fold_val <- fold_val %>%
      mutate(predicted_goals = predict(fold_model, newdata = fold_val,
                                       type = "response"))

    # Metrics
    mae  <- mean(abs(fold_val$Goals - fold_val$predicted_goals))
    rmse <- sqrt(mean((fold_val$Goals - fold_val$predicted_goals)^2))

    tibble(
      fold           = fold,
      train_cutoff   = train_cutoff,
      val_start      = val_start,
      val_cutoff     = val_cutoff,
      n_train        = nrow(fold_train),
      n_val          = nrow(fold_val),
      mae            = round(mae, 4),
      rmse           = round(rmse, 4)
    )
  })

  return(fold_results)
}

cv_results <- rolling_cv(train_goals, n_folds = 5)

log_msg("INFO", "Rolling CV Results:")
print(cv_results)
log_msg("INFO", paste("Mean MAE across folds: ",
                      round(mean(cv_results$mae, na.rm = TRUE), 4)))
log_msg("INFO", paste("Mean RMSE across folds:",
                      round(mean(cv_results$rmse, na.rm = TRUE), 4)))

# ---------------------------------------------------------------------------
# 4. Test Set Evaluation
# ---------------------------------------------------------------------------

log_msg("INFO", "Evaluating on held-out test set...")

test_goals <- test_goals %>%
  mutate(predicted_goals = predict(final_model, newdata = test_goals,
                                   type = "response"))

test_mae  <- mean(abs(test_goals$Goals - test_goals$predicted_goals))
test_rmse <- sqrt(mean((test_goals$Goals - test_goals$predicted_goals)^2))

# Pearson correlation between predicted and actual
test_cor <- cor(test_goals$Goals, test_goals$predicted_goals)

log_msg("INFO", paste("Test MAE: ", round(test_mae, 4)))
log_msg("INFO", paste("Test RMSE:", round(test_rmse, 4)))
log_msg("INFO", paste("Test Correlation (predicted vs actual):",
                      round(test_cor, 4)))

# ---------------------------------------------------------------------------
# 5. Score Matrix — Probability of Each Scoreline
# ---------------------------------------------------------------------------
# Given two teams, computes the probability of every scoreline 0-0 to 5-5
# and derives win/draw/loss probabilities from the distribution.
# ---------------------------------------------------------------------------

score_matrix <- function(team_a, team_b, max_goals = 5) {

  # Get squad features for both teams
  feats_a <- squad_features %>% filter(team == team_a)
  feats_b <- squad_features %>% filter(team == team_b)

  if (nrow(feats_a) == 0 || nrow(feats_b) == 0) {
    log_msg("WARN", paste("Missing features for:", team_a, "or", team_b))
    return(NULL)
  }

  # Build prediction rows
  row_a <- tibble(
    team_xg_weighted      = feats_a$squad_xg_weighted,
    team_xa_weighted      = feats_a$squad_xa_weighted,
    team_xgchain_weighted = feats_a$squad_xgchain_weighted,
    opp_xg_weighted       = feats_b$squad_xg_weighted,
    opp_depth_index       = feats_b$squad_depth_index,
    is_home               = 1L
  )

  row_b <- tibble(
    team_xg_weighted      = feats_b$squad_xg_weighted,
    team_xa_weighted      = feats_b$squad_xa_weighted,
    team_xgchain_weighted = feats_b$squad_xgchain_weighted,
    opp_xg_weighted       = feats_a$squad_xg_weighted,
    opp_depth_index       = feats_a$squad_depth_index,
    is_home               = 0L
  )

  lambda_a <- predict(final_model, newdata = row_a, type = "response")
  lambda_b <- predict(final_model, newdata = row_b, type = "response")

  # Scoreline probability matrix
  goals_seq <- 0:max_goals
  prob_mat  <- outer(
    dpois(goals_seq, lambda_a),
    dpois(goals_seq, lambda_b)
  )
  rownames(prob_mat) <- paste0(team_a, "_", goals_seq)
  colnames(prob_mat) <- paste0(team_b, "_", goals_seq)

  # Aggregate to match outcome probabilities
  win_a <- sum(prob_mat[lower.tri(prob_mat, diag = FALSE)])  # team_a scores more
  draw  <- sum(diag(prob_mat))
  win_b <- sum(prob_mat[upper.tri(prob_mat, diag = FALSE)])  # team_b scores more

  list(
    team_a       = team_a,
    team_b       = team_b,
    lambda_a     = round(lambda_a, 3),
    lambda_b     = round(lambda_b, 3),
    prob_win_a   = round(win_a, 4),
    prob_draw    = round(draw, 4),
    prob_win_b   = round(win_b, 4),
    prob_matrix  = prob_mat
  )
}

# ---------------------------------------------------------------------------
# 6. Example Predictions — High-Profile Matchups
# ---------------------------------------------------------------------------

log_msg("INFO", "Running example matchup predictions...")

example_matchups <- list(
  c("France",    "Brazil"),
  c("Argentina", "England"),
  c("Spain",     "Germany"),
  c("Portugal",  "Netherlands"),
  c("United States", "Mexico")
)

matchup_results <- map_dfr(example_matchups, function(teams) {
  result <- score_matrix(teams[1], teams[2])
  if (is.null(result)) return(NULL)
  tibble(
    Team_A       = result$team_a,
    Team_B       = result$team_b,
    Exp_Goals_A  = result$lambda_a,
    Exp_Goals_B  = result$lambda_b,
    P_Win_A      = percent(result$prob_win_a, accuracy = 0.1),
    P_Draw       = percent(result$prob_draw,  accuracy = 0.1),
    P_Win_B      = percent(result$prob_win_b, accuracy = 0.1)
  )
})

log_msg("INFO", "Example matchup predictions:")
print(matchup_results)

# ---------------------------------------------------------------------------
# 7. Predicted vs Actual Goals Plot
# ---------------------------------------------------------------------------

figures_dir <- file.path(dirname(getwd()), "docs", "figures")
dir.create(figures_dir, recursive = TRUE, showWarnings = FALSE)

p_pred_actual <- test_goals %>%
  ggplot(aes(x = Goals, y = predicted_goals)) +
  geom_jitter(alpha = 0.4, color = "#2E86AB", width = 0.15, height = 0) +
  geom_abline(slope = 1, intercept = 0, color = "#F26419",
              linetype = "dashed", linewidth = 1) +
  geom_smooth(method = "lm", se = TRUE, color = "#6A4C93", alpha = 0.15) +
  scale_x_continuous(breaks = 0:8) +
  labs(
    title    = "Poisson Model: Predicted vs Actual Goals",
    subtitle = paste0("Test set | MAE: ", round(test_mae, 3),
                      " | RMSE: ", round(test_rmse, 3),
                      " | r: ", round(test_cor, 3)),
    x        = "Actual Goals",
    y        = "Predicted Goals (lambda)"
  ) +
  theme_minimal(base_size = 12) +
  theme(plot.title = element_text(face = "bold"))

ggsave(file.path(figures_dir, "10_poisson_pred_vs_actual.png"),
       p_pred_actual, width = 7, height = 5, dpi = 150)
log_msg("INFO", "Saved: 10_poisson_pred_vs_actual.png")

# CV results plot
p_cv <- cv_results %>%
  pivot_longer(c(mae, rmse), names_to = "Metric", values_to = "Value") %>%
  ggplot(aes(x = fold, y = Value, color = Metric, group = Metric)) +
  geom_line(linewidth = 1) +
  geom_point(size = 3) +
  scale_color_manual(values = c(mae = "#2E86AB", rmse = "#F26419")) +
  labs(
    title    = "Rolling CV Performance Across Folds",
    subtitle = "Each fold trains on more historical data (expanding window)",
    x        = "Fold",
    y        = "Error",
    color    = "Metric"
  ) +
  theme_minimal(base_size = 12) +
  theme(plot.title = element_text(face = "bold"))

ggsave(file.path(figures_dir, "11_rolling_cv_results.png"),
       p_cv, width = 7, height = 5, dpi = 150)
log_msg("INFO", "Saved: 11_rolling_cv_results.png")

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

model_metrics <- tibble(
  Model      = final_model_name,
  MAE        = round(test_mae, 4),
  RMSE       = round(test_rmse, 4),
  Correlation = round(test_cor, 4),
  CV_MAE     = round(mean(cv_results$mae, na.rm = TRUE), 4),
  CV_RMSE    = round(mean(cv_results$rmse, na.rm = TRUE), 4)
)

log_msg("INFO", "========== POISSON MODEL COMPLETE ==========")
log_msg("INFO", "Objects ready:")
log_msg("INFO", "  final_model    — fitted Poisson/NB model")
log_msg("INFO", "  model_metrics  — test set performance summary")
log_msg("INFO", "  score_matrix() — function to predict any matchup")
log_msg("INFO", "  cv_results     — rolling CV fold results")
print(model_metrics)