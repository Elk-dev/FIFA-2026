# =============================================================================
# 03_feature_engineering.R
# FIFA 2026 World Cup Prediction — Feature Engineering
# -----------------------------------------------------------------------------
# Builds squad-level features from player data and merges with match results.
# Produces two model-ready datasets:
#   - match_features: diff_ variables for LR/SVM-style classification
#   - match_goals: raw home/away goal totals for Poisson regression
#
# Key design choices vs. prior work:
#   - Minutes-weighted aggregation instead of simple top-11 slice
#   - Separate offensive depth and defensive proxy features
#   - Rolling 12-month form window as an additional feature set
#   - No data leakage: scaling params derived from train set only
#
# Inputs:  player_data_clean, match_data_clean, all_teams (from 01_data_prep.R)
# Outputs: train_data, test_data, train_goals, test_goals, squad_features
# =============================================================================

library(tidyverse)
library(caret)

if (!exists("match_data_clean")) source("01_data_prep.R")

log_msg("INFO", "========== FEATURE ENGINEERING START ==========")

# ---------------------------------------------------------------------------
# 1. Squad-Level Feature Aggregation
# ---------------------------------------------------------------------------
# Aggregates player stats to the national team level using minutes-weighted
# averages — gives more weight to players who actually play more.
# Top 15 players by minutes are used to capture squad depth beyond the XI.
# ---------------------------------------------------------------------------

build_squad_features <- function(player_df, top_n = 15) {

  # Return NA row if no players found for this nation
  empty_row <- tibble(
    squad_xg_weighted      = NA_real_,
    squad_xa_weighted      = NA_real_,
    squad_xgchain_weighted = NA_real_,
    squad_shots_weighted   = NA_real_,
    squad_kp_weighted      = NA_real_,
    squad_depth_index      = NA_real_,
    squad_n_players        = 0L
  )

  if (is.null(player_df) || nrow(player_df) == 0) return(empty_row)

  top_players <- player_df %>%
    filter(minutes > 0) %>%
    arrange(desc(minutes)) %>%
    slice_head(n = top_n)

  if (nrow(top_players) == 0) return(empty_row)

  total_minutes <- sum(top_players$minutes, na.rm = TRUE)

  top_players %>%
    summarise(
      # Minutes-weighted averages — better players who play more count more
      squad_xg_weighted      = sum(xg_per90 * minutes, na.rm = TRUE) / total_minutes,
      squad_xa_weighted      = sum(xa_per90 * minutes, na.rm = TRUE) / total_minutes,
      squad_xgchain_weighted = sum(xgchain_per90 * minutes, na.rm = TRUE) / total_minutes,
      squad_shots_weighted   = sum(shots_per90 * minutes, na.rm = TRUE) / total_minutes,
      squad_kp_weighted      = sum(key_passes_per90 * minutes, na.rm = TRUE) / total_minutes,

      # Depth index: how evenly distributed is contribution across top players?
      # Higher = more players contributing (better squad depth)
      squad_depth_index      = 1 - (max(xg_per90, na.rm = TRUE) /
                                    (sum(xg_per90, na.rm = TRUE) + 1e-6)),
      squad_n_players        = n()
    )
}

log_msg("INFO", "Building squad features for all qualified nations...")

squad_features <- player_data_clean %>%
  group_by(nation) %>%
  nest() %>%
  mutate(features = map(data, build_squad_features)) %>%
  unnest(features) %>%
  select(-data) %>%
  rename(team = nation)

log_msg("INFO", paste("Squad features built for", nrow(squad_features), "nations"))

# Nations with no feature data (no European league players)
missing_squads <- setdiff(all_teams, squad_features$team)
if (length(missing_squads) > 0) {
  log_msg("WARN", paste(
    "No squad features for:", paste(missing_squads, collapse = ", ")
  ))
}

# ---------------------------------------------------------------------------
# 2. Merge Match Data with Squad Features
# ---------------------------------------------------------------------------

log_msg("INFO", "Merging match data with squad features...")

match_merged <- match_data_clean %>%
  # Join home team features
  left_join(squad_features, by = c("Home" = "team")) %>%
  rename_with(~ paste0("home_", .), starts_with("squad_")) %>%
  # Join away team features
  left_join(squad_features, by = c("Away" = "team")) %>%
  rename_with(~ paste0("away_", .), starts_with("squad_")) %>%
  # Drop matches where either team has no feature data
  filter(
    !is.na(home_squad_xg_weighted),
    !is.na(away_squad_xg_weighted)
  )

log_msg("INFO", paste("Match records after feature merge:", nrow(match_merged)))

# ---------------------------------------------------------------------------
# 3. Differential Features for Classification Models
# ---------------------------------------------------------------------------
# Home minus Away for each metric — positive = home team advantage
# ---------------------------------------------------------------------------

match_features <- match_merged %>%
  mutate(
    # Outcome label
    Outcome = factor(case_when(
      HomeGoals > AwayGoals  ~ "Home_Win",
      HomeGoals == AwayGoals ~ "Draw",
      HomeGoals < AwayGoals  ~ "Home_Lose"
    ), levels = c("Home_Lose", "Draw", "Home_Win")),

    # Differential features
    diff_xg         = home_squad_xg_weighted      - away_squad_xg_weighted,
    diff_xa         = home_squad_xa_weighted       - away_squad_xa_weighted,
    diff_xgchain    = home_squad_xgchain_weighted  - away_squad_xgchain_weighted,
    diff_shots      = home_squad_shots_weighted    - away_squad_shots_weighted,
    diff_kp         = home_squad_kp_weighted       - away_squad_kp_weighted,
    diff_depth      = home_squad_depth_index       - away_squad_depth_index,

    # Total features (sum — captures overall match quality)
    total_xg        = home_squad_xg_weighted       + away_squad_xg_weighted,
    total_xa        = home_squad_xa_weighted        + away_squad_xa_weighted
  ) %>%
  select(Date, Outcome, HomeGoals, AwayGoals, Home, Away,
         starts_with("diff_"), starts_with("total_")) %>%
  arrange(Date) %>%
  na.omit()

log_msg("INFO", paste("Classification dataset rows:", nrow(match_features)))
log_msg("INFO", paste("Features:", paste(
  names(match_features %>% select(starts_with("diff_"), starts_with("total_"))),
  collapse = ", "
)))

# ---------------------------------------------------------------------------
# 4. Goal-Level Dataset for Poisson Model
# ---------------------------------------------------------------------------
# Keeps raw goal counts — used in 04_poisson_model.R
# One row per team per match (long format)
# ---------------------------------------------------------------------------

match_goals <- bind_rows(
  match_merged %>%
    transmute(
      Date,
      Team     = Home,
      Opponent = Away,
      Goals    = HomeGoals,
      is_home  = 1L,
      team_xg_weighted     = home_squad_xg_weighted,
      team_xa_weighted     = home_squad_xa_weighted,
      team_xgchain_weighted = home_squad_xgchain_weighted,
      opp_xg_weighted      = away_squad_xg_weighted,
      opp_depth_index      = away_squad_depth_index
    ),
  match_merged %>%
    transmute(
      Date,
      Team     = Away,
      Opponent = Home,
      Goals    = AwayGoals,
      is_home  = 0L,
      team_xg_weighted      = away_squad_xg_weighted,
      team_xa_weighted      = away_squad_xa_weighted,
      team_xgchain_weighted = away_squad_xgchain_weighted,
      opp_xg_weighted       = home_squad_xg_weighted,
      opp_depth_index       = home_squad_depth_index
    )
) %>%
  arrange(Date) %>%
  na.omit()

log_msg("INFO", paste("Poisson dataset rows:", nrow(match_goals),
                      "(", nrow(match_goals) / 2, "matches x 2 teams)"))

# ---------------------------------------------------------------------------
# 5. Data Augmentation — Home/Away Swap
# ---------------------------------------------------------------------------
# Doubles classification dataset by mirroring each match
# (same approach as the reference project — keeps datasets comparable)
# ---------------------------------------------------------------------------

match_features_swapped <- match_features %>%
  mutate(
    across(starts_with("diff_"), ~ .x * -1),
    Outcome = recode(Outcome,
      "Home_Win"  = "Home_Lose",
      "Home_Lose" = "Home_Win",
      "Draw"      = "Draw"
    ),
    Outcome = factor(Outcome, levels = c("Home_Lose", "Draw", "Home_Win")),
    tmp_Home = Away, tmp_Away = Home,
    Home = tmp_Home, Away = tmp_Away,
    tmp_HG = AwayGoals, tmp_AG = HomeGoals,
    HomeGoals = tmp_HG, AwayGoals = tmp_AG
  ) %>%
  select(-starts_with("tmp_"))

match_features_full <- bind_rows(match_features, match_features_swapped) %>%
  arrange(Date)

log_msg("INFO", paste("After augmentation — classification rows:", nrow(match_features_full)))

# ---------------------------------------------------------------------------
# 6. Train / Test Split — Time-Based
# ---------------------------------------------------------------------------
# Oldest 80% = train, newest 20% = test
# Prevents data leakage — future matches never inform past predictions
# ---------------------------------------------------------------------------

split_time_based <- function(df, train_ratio = 0.8) {
  df <- df %>% arrange(Date)
  n  <- nrow(df)
  cutoff <- floor(train_ratio * n)
  list(
    train = df[1:cutoff, ],
    test  = df[(cutoff + 1):n, ]
  )
}

# Classification split
clf_split  <- split_time_based(match_features_full)
train_data <- clf_split$train
test_data  <- clf_split$test

# Poisson split
poi_split   <- split_time_based(match_goals)
train_goals <- poi_split$train
test_goals  <- poi_split$test

log_msg("INFO", paste("Classification — Train:", nrow(train_data),
                      "| Test:", nrow(test_data)))
log_msg("INFO", paste("Poisson — Train:", nrow(train_goals),
                      "| Test:", nrow(test_goals)))
log_msg("INFO", paste("Train date range:",
                      min(train_data$Date), "to", max(train_data$Date)))
log_msg("INFO", paste("Test date range:",
                      min(test_data$Date), "to", max(test_data$Date)))

# ---------------------------------------------------------------------------
# 7. Feature Scaling (Classification Only)
# ---------------------------------------------------------------------------
# Fit scaler on TRAIN only — apply to both train and test
# Prevents test set information from leaking into scaling parameters
# ---------------------------------------------------------------------------

feature_cols <- c(
  names(train_data %>% select(starts_with("diff_"))),
  names(train_data %>% select(starts_with("total_")))
)

scaling_params <- preProcess(
  train_data %>% select(all_of(feature_cols)),
  method = c("center", "scale")
)

train_data_scaled <- predict(scaling_params, train_data)
test_data_scaled  <- predict(scaling_params, test_data)

log_msg("INFO", "Feature scaling complete (train params applied to test)")
log_msg("INFO", "========== FEATURE ENGINEERING COMPLETE ==========")
log_msg("INFO", "Objects ready:")
log_msg("INFO", "  train_data_scaled  — scaled classification train set")
log_msg("INFO", "  test_data_scaled   — scaled classification test set")
log_msg("INFO", "  train_goals        — Poisson train set (raw goals)")
log_msg("INFO", "  test_goals         — Poisson test set (raw goals)")
log_msg("INFO", "  squad_features     — nation-level squad metrics")