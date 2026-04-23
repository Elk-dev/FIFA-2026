# =============================================================================
# 01_data_prep.R
# FIFA 2026 World Cup Prediction — Data Preparation
# -----------------------------------------------------------------------------
# Loads raw datasets from the ETL pipeline, standardizes team names, filters
# to 2026 World Cup qualifiers, and produces clean match and player datasets
# ready for feature engineering.
#
# Inputs:  player_data, major_tournaments (from 00_etl_pipeline.R)
# Outputs: player_data_clean, match_data_clean
# =============================================================================

library(tidyverse)

# Run ETL pipeline if datasets are not already in the environment
if (!exists("player_data") || !exists("major_tournaments")) {
  source("00_etl_pipeline.R")
}

log_msg("INFO", "========== DATA PREP START ==========")

# ---------------------------------------------------------------------------
# 1. Qualified Teams — 2026 FIFA World Cup
# ---------------------------------------------------------------------------
# 48 teams across 6 confederations

qualified_teams <- list(
  Hosts = c(
    "Canada", "Mexico", "United States"
  ),
  AFC_Asia = c(
    "Japan", "Iran", "Uzbekistan", "Korea Republic",
    "Jordan", "Australia", "Qatar", "Saudi Arabia"
  ),
  CAF_Africa = c(
    "Morocco", "Tunisia", "Egypt", "Algeria", "Ghana",
    "Cape Verde", "South Africa", "Senegal", "Ivory Coast"
  ),
  CONMEBOL_South_America = c(
    "Argentina", "Brazil", "Ecuador", "Colombia", "Paraguay", "Uruguay"
  ),
  UEFA_Europe = c(
    "England", "France", "Croatia", "Portugal", "Norway",
    "Germany", "Netherlands", "Austria", "Belgium", "Scotland",
    "Spain", "Switzerland"
  ),
  CONCACAF = c(
    "Curaçao", "Haiti", "Panama"
  ),
  OFC_Oceania = c(
    "New Zealand"
  ),
  Additional = c(
    "Bosnia and Herzegovina", "Sweden", "Turkey",
    "Czech Republic", "DR Congo", "Iraq"
  )
)

all_teams <- unname(unlist(qualified_teams))
log_msg("INFO", paste("Total qualified teams:", length(all_teams)))

# ---------------------------------------------------------------------------
# 2. Clean Player Data
# ---------------------------------------------------------------------------

log_msg("INFO", "Cleaning player data...")

player_data_clean <- player_data %>%
  # Standardize nation names to match team list
  mutate(nation = case_match(nation,
    "Kingdom of the Netherlands" ~ "Netherlands",
    "South Korea"                ~ "Korea Republic",
    "Democratic Republic of the Congo" ~ "DR Congo",
    .default = nation
  )) %>%
  # Keep only players from qualified nations
  filter(nation %in% all_teams) %>%
  # Drop rows with no meaningful playing time
  filter(!is.na(minutes), minutes > 0) %>%
  # Fill NA numeric stats with 0 (player did not record the stat)
  mutate(across(where(is.numeric), ~ replace_na(.x, 0)))

log_msg("INFO", paste("Player records after cleaning:", nrow(player_data_clean)))
log_msg("INFO", paste("Nations represented:", n_distinct(player_data_clean$nation)))

# Teams with no European league players — expected given data source
missing_nations <- setdiff(all_teams, player_data_clean$nation)
if (length(missing_nations) > 0) {
  log_msg("WARN", paste(
    "Nations with no European league player data:",
    paste(missing_nations, collapse = ", ")
  ))
}

# ---------------------------------------------------------------------------
# 3. Clean Match Data
# ---------------------------------------------------------------------------

log_msg("INFO", "Cleaning match data...")

match_data_clean <- major_tournaments %>%
  # Parse date column
  mutate(Date = as.Date(Date)) %>%
  # Standardize team name formatting — remove trailing/leading locale codes
  mutate(
    Home = str_trim(str_remove(Home, "\\s+[a-z]{2,3}$")),
    Away = str_trim(str_remove(Away, "^[a-z]{2,3}\\s+"))
  ) %>%
  # Normalize team name variants
  mutate(across(c(Home, Away), ~ case_match(.,
    "IR Iran"          ~ "Iran",
    "Côte d'Ivoire"    ~ "Ivory Coast",
    "Bosnia & Herz'na" ~ "Bosnia and Herzegovina",
    "Rep. of Ireland"  ~ "Ireland",
    "Türkiye"          ~ "Turkey",
    "Czechia"          ~ "Czech Republic",
    "Trin & Tobago"    ~ "Trinidad and Tobago",
    "China PR"         ~ "China",
    "Gambia"           ~ "The Gambia",
    "Congo DR"         ~ "DR Congo",
    .default = .
  ))) %>%
  # Keep only matches where both teams are 2026 qualifiers
  filter(Home %in% all_teams & Away %in% all_teams) %>%
  # Keep only matches from 2021 onward (aligns with player data window)
  filter(Season_End_Year >= 2021) %>%
  # Drop rows with missing scorelines
  filter(!is.na(HomeGoals), !is.na(AwayGoals)) %>%
  # Clean up — drop columns not needed downstream
  select(Date, Home, Away, HomeGoals, AwayGoals, Competition_Name, Season_End_Year)

log_msg("INFO", paste("Match records after cleaning:", nrow(match_data_clean)))
log_msg("INFO", paste(
  "Date range:",
  min(match_data_clean$Date), "to", max(match_data_clean$Date)
))
log_msg("INFO", paste(
  "Competitions included:",
  paste(unique(match_data_clean$Competition_Name), collapse = ", ")
))

# ---------------------------------------------------------------------------
# 4. Summary diagnostics
# ---------------------------------------------------------------------------

log_msg("INFO", "--- Match outcome distribution ---")
match_data_clean %>%
  mutate(Outcome = case_when(
    HomeGoals > AwayGoals ~ "Home Win",
    HomeGoals == AwayGoals ~ "Draw",
    HomeGoals < AwayGoals ~ "Away Win"
  )) %>%
  count(Outcome) %>%
  mutate(Pct = round(n / sum(n) * 100, 1)) %>%
  print()

log_msg("INFO", "--- Goals per match summary ---")
match_data_clean %>%
  summarise(
    avg_home_goals = round(mean(HomeGoals), 2),
    avg_away_goals = round(mean(AwayGoals), 2),
    avg_total_goals = round(mean(HomeGoals + AwayGoals), 2),
    max_goals_in_match = max(HomeGoals + AwayGoals)
  ) %>%
  print()

log_msg("INFO", "========== DATA PREP COMPLETE ==========")
log_msg("INFO", "Objects ready: player_data_clean, match_data_clean, all_teams, qualified_teams")