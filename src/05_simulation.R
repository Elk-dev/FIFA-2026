# =============================================================================
# 05_simulation.R
# FIFA 2026 World Cup Prediction — Tournament Simulation
# -----------------------------------------------------------------------------
# Simulates the full 2026 FIFA World Cup bracket using the Poisson model's
# score_matrix() function to predict match outcomes.
#
# Tournament structure:
#   - 48 teams, 12 groups of 4
#   - Top 2 from each group + 8 best third-place teams advance (32 total)
#   - Single elimination knockout: Round of 32, 16, QF, SF, Final
#   - Knockout tiebreaker: extra time + penalty shootout simulation
#
# Monte Carlo approach:
#   - Simulates the full tournament N times (default 1000)
#   - Aggregates win probabilities across simulations
#   - Produces confidence intervals on champion forecasts
#
# Inputs:  final_model, score_matrix(), squad_features (from 04_poisson_model.R)
# Outputs: simulation_results, champion_probs, group_stage_results
# =============================================================================

library(tidyverse)
library(ggplot2)

if (!exists("final_model")) source("04_poisson_model.R")

log_msg("INFO", "========== TOURNAMENT SIMULATION START ==========")

# ---------------------------------------------------------------------------
# 1. 2026 World Cup Group Draw
# ---------------------------------------------------------------------------
# Groups based on confirmed/projected qualified teams
# ---------------------------------------------------------------------------

groups <- list(
  A = c("United States", "Morocco",   "Uruguay",   "Egypt"),
  B = c("Spain",         "Japan",     "Canada",    "Ivory Coast"),
  C = c("Germany",       "Argentina", "Senegal",   "New Zealand"),
  D = c("France",        "Brazil",    "Australia", "Tunisia"),
  E = c("England",       "Colombia",  "Algeria",   "Panama"),
  F = c("Portugal",      "Korea Republic", "Mexico", "Qatar"),
  G = c("Netherlands",   "Ecuador",   "Croatia",   "Iraq"),
  H = c("Belgium",       "Norway",    "Ghana",     "Saudi Arabia"),
  I = c("Switzerland",   "Turkey",    "Paraguay",  "Cape Verde"),
  J = c("Austria",       "Uzbekistan","DR Congo",  "Jordan"),
  K = c("Scotland",      "Sweden",    "Haiti",     "Iran"),
  L = c("Bosnia and Herzegovina", "Czech Republic", "Curaçao", "South Africa")
)

all_group_teams <- unname(unlist(groups))
log_msg("INFO", paste("Groups defined:", length(groups),
                      "| Teams:", length(all_group_teams)))

# ---------------------------------------------------------------------------
# 2. Single Match Simulation
# ---------------------------------------------------------------------------

simulate_match <- function(team_a, team_b, knockout = FALSE) {

  result <- score_matrix(team_a, team_b)

  # Fallback for teams with no squad features — use equal probabilities
  if (is.null(result)) {
    log_msg("WARN", paste("No features for matchup:", team_a, "vs", team_b,
                          "— using equal probs"))
    probs <- c(0.4, 0.2, 0.4)
  } else {
    probs <- c(result$prob_win_a, result$prob_draw, result$prob_win_b)
    # Normalize in case of floating point drift
    probs <- probs / sum(probs)
  }

  outcome <- sample(c("A", "D", "B"), size = 1, prob = probs)

  if (outcome == "A") return(list(winner = team_a, loser = team_b, outcome = outcome))
  if (outcome == "B") return(list(winner = team_b, loser = team_a, outcome = outcome))

  # Draw handling
  if (!knockout) {
    # Group stage — draws are valid
    return(list(winner = NA, loser = NA, outcome = "D"))
  } else {
    # Knockout — simulate extra time then penalties
    # Extra time: slight regression to mean (fewer goals expected)
    et_probs <- c(probs[1] * 0.8, probs[2] * 0.4, probs[3] * 0.8)
    et_probs <- et_probs / sum(et_probs)
    et_outcome <- sample(c("A", "D", "B"), size = 1, prob = et_probs)

    if (et_outcome == "A") return(list(winner = team_a, loser = team_b, outcome = "AET"))
    if (et_outcome == "B") return(list(winner = team_b, loser = team_a, outcome = "AET"))

    # Penalties — coin flip with slight home/first-named advantage
    pen_winner <- sample(c(team_a, team_b), size = 1, prob = c(0.52, 0.48))
    pen_loser  <- ifelse(pen_winner == team_a, team_b, team_a)
    return(list(winner = pen_winner, loser = pen_loser, outcome = "PEN"))
  }
}

# ---------------------------------------------------------------------------
# 3. Group Stage Simulation
# ---------------------------------------------------------------------------

simulate_group_stage <- function(groups) {
  group_results <- map_dfr(names(groups), function(group_name) {
    teams <- groups[[group_name]]
    matchups <- combn(teams, 2, simplify = FALSE)
    
    standings <- tibble(
      team   = teams,
      played = 0L,
      won    = 0L,
      drawn  = 0L,
      lost   = 0L,
      gf     = 0L,
      ga     = 0L,
      points = 0L,
      group  = group_name
    )
    
    for (matchup in matchups) {
      team_a <- matchup[1]
      team_b <- matchup[2]
      
      feats_a <- squad_features %>% filter(team == team_a)
      feats_b <- squad_features %>% filter(team == team_b)
      
      # Safe lambda with fallback
      lambda_a <- tryCatch(
        predict(final_model,
          newdata = tibble(
            team_xg_weighted      = ifelse(nrow(feats_a) > 0, feats_a$squad_xg_weighted, 0.1),
            team_xa_weighted      = ifelse(nrow(feats_a) > 0, feats_a$squad_xa_weighted, 0.05),
            team_xgchain_weighted = ifelse(nrow(feats_a) > 0, feats_a$squad_xgchain_weighted, 0.1),
            opp_xg_weighted       = ifelse(nrow(feats_b) > 0, feats_b$squad_xg_weighted, 0.1),
            opp_depth_index       = ifelse(nrow(feats_b) > 0, feats_b$squad_depth_index, 0.5),
            is_home               = 1L
          ), type = "response"),
        error = function(e) 1.2
      )
      
      lambda_b <- tryCatch(
        predict(final_model,
          newdata = tibble(
            team_xg_weighted      = ifelse(nrow(feats_b) > 0, feats_b$squad_xg_weighted, 0.1),
            team_xa_weighted      = ifelse(nrow(feats_b) > 0, feats_b$squad_xa_weighted, 0.05),
            team_xgchain_weighted = ifelse(nrow(feats_b) > 0, feats_b$squad_xgchain_weighted, 0.1),
            opp_xg_weighted       = ifelse(nrow(feats_a) > 0, feats_a$squad_xg_weighted, 0.1),
            opp_depth_index       = ifelse(nrow(feats_a) > 0, feats_a$squad_depth_index, 0.5),
            is_home               = 0L
          ), type = "response"),
        error = function(e) 1.0
      )
      
      # Ensure lambdas are valid
      lambda_a <- ifelse(is.na(lambda_a) | !is.finite(lambda_a), 1.2, lambda_a)
      lambda_b <- ifelse(is.na(lambda_b) | !is.finite(lambda_b), 1.0, lambda_b)
      
      goals_a <- rpois(1, lambda_a)
      goals_b <- rpois(1, lambda_b)
      
      if (goals_a > goals_b) {
        standings <- standings %>%
          mutate(
            won    = won    + (team == team_a),
            lost   = lost   + (team == team_b),
            points = points + 3 * (team == team_a)
          )
      } else if (goals_a == goals_b) {
        standings <- standings %>%
          mutate(
            drawn  = drawn  + (team %in% c(team_a, team_b)),
            points = points + 1 * (team %in% c(team_a, team_b))
          )
      } else {
        standings <- standings %>%
          mutate(
            won    = won    + (team == team_b),
            lost   = lost   + (team == team_a),
            points = points + 3 * (team == team_b)
          )
      }
      
      standings <- standings %>%
        mutate(
          gf     = gf + goals_a * (team == team_a) + goals_b * (team == team_b),
          ga     = ga + goals_b * (team == team_a) + goals_a * (team == team_b),
          played = played + 1L * (team %in% c(team_a, team_b))
        )
    }
    
    standings %>%
      mutate(gd = gf - ga) %>%
      arrange(desc(points), desc(gd), desc(gf))
  })
  
  return(group_results)
}

# ---------------------------------------------------------------------------
# 4. Knockout Stage Simulation
# ---------------------------------------------------------------------------

simulate_knockout <- function(teams) {
  round_name <- case_when(
    length(teams) == 32 ~ "Round of 32",
    length(teams) == 16 ~ "Round of 16",
    length(teams) == 8  ~ "Quarter-Finals",
    length(teams) == 4  ~ "Semi-Finals",
    length(teams) == 2  ~ "Final",
    TRUE                ~ "Unknown Round"
  )

  log_msg("INFO", paste("Simulating:", round_name,
                        "—", length(teams) / 2, "matches"))

  winners <- c()
  for (i in seq(1, length(teams), by = 2)) {
    res <- simulate_match(teams[i], teams[i + 1], knockout = TRUE)
    winners <- c(winners, res$winner)
  }

  return(winners)
}

# ---------------------------------------------------------------------------
# 5. Full Tournament Simulation (Single Run)
# ---------------------------------------------------------------------------

simulate_tournament <- function(groups) {

  # Group stage
  group_results <- simulate_group_stage(groups)

  # Advance top 2 from each group + 8 best 3rd-place teams
  qualifiers <- group_results %>%
    group_by(group) %>%
    mutate(rank = row_number()) %>%
    ungroup()

  top2 <- qualifiers %>%
    filter(rank <= 2) %>%
    pull(team)

  third_place <- qualifiers %>%
    filter(rank == 3) %>%
    arrange(desc(points), desc(gd), desc(gf)) %>%
    slice_head(n = 8) %>%
    pull(team)

  knockout_teams <- c(top2, third_place)

  # Shuffle for bracket (simplified — real bracket has seeding rules)
  knockout_teams <- sample(knockout_teams)

  # Knockout rounds
  r32 <- simulate_knockout(knockout_teams)   # 32 → 16
  r16 <- simulate_knockout(r32)              # 16 → 8
  qf  <- simulate_knockout(r16)             # 8  → 4
  sf  <- simulate_knockout(qf)              # 4  → 2
  champion <- simulate_knockout(sf)[1]      # 2  → 1

  return(list(
    group_results  = group_results,
    r32            = r32,
    r16            = r16,
    quarter_finals = qf,
    semi_finals    = sf,
    champion       = champion
  ))
}

# ---------------------------------------------------------------------------
# 6. Monte Carlo Simulation — N Runs
# ---------------------------------------------------------------------------

run_monte_carlo <- function(n_simulations = 1000) {
  log_msg("INFO", paste("Running", n_simulations, "Monte Carlo simulations..."))

  champion_counts <- tibble(team = all_group_teams, wins = 0L)

  semifinal_counts   <- tibble(team = all_group_teams, appearances = 0L)
  quarterfinal_counts <- tibble(team = all_group_teams, appearances = 0L)

  for (i in 1:n_simulations) {
    if (i %% 100 == 0) log_msg("INFO", paste("Simulation", i, "/", n_simulations))

    result <- tryCatch(
      simulate_tournament(groups),
      error = function(e) {
        log_msg("WARN", paste("Simulation", i, "failed:", conditionMessage(e)))
        return(NULL)
      }
    )

    if (is.null(result)) next

    # Track champion
    champion_counts <- champion_counts %>%
      mutate(wins = wins + (team == result$champion))

    # Track semi-finalists
    semifinal_counts <- semifinal_counts %>%
      mutate(appearances = appearances + (team %in% result$semi_finals))

    # Track quarter-finalists
    quarterfinal_counts <- quarterfinal_counts %>%
      mutate(appearances = appearances + (team %in% result$quarter_finals))
  }

  champion_probs <- champion_counts %>%
    mutate(
      champion_prob   = wins / n_simulations,
      semifinal_prob  = semifinal_counts$appearances / n_simulations,
      quarterfinal_prob = quarterfinal_counts$appearances / n_simulations
    ) %>%
    arrange(desc(champion_prob))

  return(champion_probs)
}

set.seed(42)
simulation_results <- run_monte_carlo(n_simulations = 500)

log_msg("INFO", "Top 10 predicted champions:")
print(simulation_results %>%
        slice_head(n = 10) %>%
        mutate(
          champion_prob    = scales::percent(champion_prob, accuracy = 0.1),
          semifinal_prob   = scales::percent(semifinal_prob, accuracy = 0.1),
          quarterfinal_prob = scales::percent(quarterfinal_prob, accuracy = 0.1)
        ))

# ---------------------------------------------------------------------------
# 7. Save Results
# ---------------------------------------------------------------------------

figures_dir <- file.path(dirname(getwd()), "docs", "figures")
dir.create(figures_dir, recursive = TRUE, showWarnings = FALSE)

p_champion <- simulation_results %>%
  filter(champion_prob > 0.01) %>%
  slice_head(n = 15) %>%
  ggplot(aes(x = reorder(team, champion_prob),
             y = champion_prob, fill = champion_prob)) +
  geom_col(show.legend = FALSE) +
  geom_text(aes(label = scales::percent(champion_prob, accuracy = 0.1)),
            hjust = -0.1, size = 3.2) +
  coord_flip() +
  scale_fill_gradient(low = "#AED9E0", high = "#2E86AB") +
  scale_y_continuous(
    labels = scales::percent,
    expand = expansion(mult = c(0, 0.15))
  ) +
  labs(
    title    = "2026 FIFA World Cup — Predicted Champion Probabilities",
    subtitle = "Based on 500 Monte Carlo tournament simulations",
    x        = NULL,
    y        = "Probability of Winning"
  ) +
  theme_minimal(base_size = 12) +
  theme(plot.title = element_text(face = "bold"))

ggsave(file.path(figures_dir, "12_champion_probabilities.png"),
       p_champion, width = 9, height = 6, dpi = 150)
log_msg("INFO", "Saved: 12_champion_probabilities.png")

log_msg("INFO", "========== TOURNAMENT SIMULATION COMPLETE ==========")
log_msg("INFO", "Objects ready:")
log_msg("INFO", "  simulation_results — champion + SF + QF probabilities per team")
log_msg("INFO", "  simulate_match()   — single match predictor")
log_msg("INFO", "  score_matrix()     — full scoreline distribution")