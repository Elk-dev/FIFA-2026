# =============================================================================
# 06_visualizations.R
# FIFA 2026 World Cup Prediction — Results Visualizations & Summary
# -----------------------------------------------------------------------------
# Produces all final results figures and a model comparison summary table.
# Designed to be run after all model scripts have completed.
#
# Figures produced:
#   13 — Model comparison table
#   14 — Squad strength heatmap (all 48 nations)
#   15 — Expected goals heatmap by matchup (top contenders)
#   16 — Simulation funnel: QF → SF → Final → Champion probabilities
#   17 — Group stage predicted standings (all 12 groups)
#   18 — Head-to-head win probability matrix (top 8 teams)
#
# Inputs:  simulation_results, model_metrics, squad_features, cv_results
# Outputs: figures saved to docs/figures/
# =============================================================================

library(tidyverse)
library(ggplot2)
library(scales)
library(gridExtra)
library(ggtext)

select <- dplyr::select

if (!exists("simulation_results")) source("05_simulation.R")

figures_dir <- file.path(dirname(getwd()), "docs", "figures")
dir.create(figures_dir, recursive = TRUE, showWarnings = FALSE)

log_msg("INFO", "========== VISUALIZATIONS START ==========")

# ---------------------------------------------------------------------------
# 1. Model Comparison Table
# ---------------------------------------------------------------------------
# Summarizes all models with the best highlighted — addresses professor
# feedback requesting a comparison table with best model in bold
# ---------------------------------------------------------------------------

log_msg("INFO", "Building model comparison table...")

comparison_table <- tribble(
  ~Model,                  ~Type,            ~CV,       ~MAE,  ~RMSE, ~Accuracy, ~Notes,
  "Logistic Regression",   "Classification", "Lasso CV","—",   "—",   "48.9%",  "Reference project",
  "SVM (Linear)",          "Classification", "Grid CV", "—",   "—",   "47.3%",  "Reference project",
  "Random Forest",         "Classification", "MC Sim",  "—",   "—",   "58.2%",  "Reference project — best classifier",
  "XGBoost",               "Classification", "MC Sim",  "—",   "—",   "56.4%",  "Reference project",
  "**Poisson Regression**","**Goal Model**", "**Rolling CV**","—","—","**—**",  "**This project — scoreline distribution**"
)

# Add Poisson test metrics dynamically if available
if (exists("model_metrics")) {
  comparison_table <- comparison_table %>%
    mutate(
      MAE  = ifelse(str_detect(Model, "Poisson"),
                    as.character(model_metrics$MAE), MAE),
      RMSE = ifelse(str_detect(Model, "Poisson"),
                    as.character(model_metrics$RMSE), RMSE)
    )
}

log_msg("INFO", "Model comparison table:")
print(comparison_table)

write_csv(comparison_table,
          file.path(figures_dir, "model_comparison_table.csv"))
log_msg("INFO", "Saved: model_comparison_table.csv")

# ---------------------------------------------------------------------------
# 2. Squad Strength Heatmap — All 48 Nations
# ---------------------------------------------------------------------------

log_msg("INFO", "Plotting squad strength heatmap...")

p_squad_heat <- squad_features %>%
  filter(!is.na(squad_xg_weighted)) %>%
  mutate(
    team = reorder(team, squad_xg_weighted),
    xg_scaled = scale(squad_xg_weighted)[,1]
  ) %>%
  select(team, squad_xg_weighted, squad_xa_weighted,
         squad_xgchain_weighted, squad_depth_index) %>%
  pivot_longer(-team, names_to = "Metric", values_to = "Value") %>%
  mutate(Metric = recode(Metric,
    "squad_xg_weighted"      = "xG / 90",
    "squad_xa_weighted"      = "xA / 90",
    "squad_xgchain_weighted" = "xG Chain / 90",
    "squad_depth_index"      = "Depth Index"
  )) %>%
  group_by(Metric) %>%
  mutate(Value_scaled = scale(Value)[,1]) %>%
  ungroup() %>%
  ggplot(aes(x = Metric, y = team, fill = Value_scaled)) +
  geom_tile(color = "white", linewidth = 0.3) +
  scale_fill_gradient2(
    low      = "#F26419",
    mid      = "white",
    high     = "#2E86AB",
    midpoint = 0,
    name     = "Z-Score"
  ) +
  labs(
    title    = "Squad Strength Heatmap — 2026 World Cup Nations",
    subtitle = "Z-scored metrics from European league player data | Blue = stronger",
    x        = NULL,
    y        = NULL
  ) +
  theme_minimal(base_size = 9) +
  theme(
    plot.title   = element_text(face = "bold", size = 12),
    axis.text.y  = element_text(size = 7),
    axis.text.x  = element_text(size = 9, face = "bold"),
    legend.position = "right"
  )

ggsave(file.path(figures_dir, "13_squad_strength_heatmap.png"),
       p_squad_heat, width = 8, height = 14, dpi = 150)
log_msg("INFO", "Saved: 13_squad_strength_heatmap.png")

# ---------------------------------------------------------------------------
# 3. Simulation Funnel — QF to Champion
# ---------------------------------------------------------------------------

log_msg("INFO", "Plotting simulation funnel...")

top_contenders <- simulation_results %>%
  slice_head(n = 12)

funnel_data <- top_contenders %>%
  select(team, quarterfinal_prob, semifinal_prob, champion_prob) %>%
  pivot_longer(-team, names_to = "Stage", values_to = "Probability") %>%
  mutate(
    Stage = recode(Stage,
      "quarterfinal_prob" = "Quarter-Final",
      "semifinal_prob"    = "Semi-Final",
      "champion_prob"     = "Champion"
    ),
    Stage = factor(Stage,
                   levels = c("Quarter-Final", "Semi-Final", "Champion"))
  )

p_funnel <- ggplot(funnel_data,
                   aes(x = Stage, y = Probability,
                       color = team, group = team)) +
  geom_line(linewidth = 0.8, alpha = 0.8) +
  geom_point(size = 2.5) +
  scale_y_continuous(labels = percent, limits = c(0, NA)) +
  scale_color_manual(values = colorRampPalette(
    c("#2E86AB", "#F26419", "#6A4C93", "#2DC653",
      "#F72585", "#4CC9F0", "#F77F00", "#8338EC",
      "#3A86FF", "#FB5607", "#FFBE0B", "#43AA8B")
  )(12)) +
  labs(
    title    = "Tournament Progression Probabilities — Top 12 Contenders",
    subtitle = "Based on 500 Monte Carlo simulations",
    x        = "Stage",
    y        = "Probability of Reaching Stage",
    color    = "Team"
  ) +
  theme_minimal(base_size = 11) +
  theme(
    plot.title      = element_text(face = "bold"),
    legend.position = "right",
    legend.text     = element_text(size = 8)
  )

ggsave(file.path(figures_dir, "14_simulation_funnel.png"),
       p_funnel, width = 9, height = 6, dpi = 150)
log_msg("INFO", "Saved: 14_simulation_funnel.png")

# ---------------------------------------------------------------------------
# 4. Head-to-Head Win Probability Matrix — Top 8 Teams
# ---------------------------------------------------------------------------

log_msg("INFO", "Building head-to-head win probability matrix...")

top8 <- simulation_results %>%
  slice_head(n = 8) %>%
  pull(team)

h2h_matrix <- expand_grid(team_a = top8, team_b = top8) %>%
  filter(team_a != team_b) %>%
  mutate(
    prob_a_wins = map2_dbl(team_a, team_b, function(a, b) {
      res <- score_matrix(a, b)
      if (is.null(res)) return(0.5)
      return(res$prob_win_a)
    })
  )

p_h2h <- h2h_matrix %>%
  ggplot(aes(x = team_b, y = team_a, fill = prob_a_wins)) +
  geom_tile(color = "white", linewidth = 0.5) +
  geom_text(aes(label = percent(prob_a_wins, accuracy = 1)),
            size = 3, fontface = "bold") +
  scale_fill_gradient2(
    low      = "#F26419",
    mid      = "white",
    high     = "#2E86AB",
    midpoint = 0.5,
    limits   = c(0, 1),
    labels   = percent,
    name     = "Win Prob\n(Row Team)"
  ) +
  labs(
    title    = "Head-to-Head Win Probability Matrix — Top 8 Contenders",
    subtitle = "Row team win probability vs column team | Blue = row team favored",
    x        = "Opponent",
    y        = "Team"
  ) +
  theme_minimal(base_size = 11) +
  theme(
    plot.title   = element_text(face = "bold"),
    axis.text.x  = element_text(angle = 30, hjust = 1),
    legend.position = "right"
  )

ggsave(file.path(figures_dir, "15_h2h_probability_matrix.png"),
       p_h2h, width = 8, height = 6, dpi = 150)
log_msg("INFO", "Saved: 15_h2h_probability_matrix.png")

# ---------------------------------------------------------------------------
# 5. Top Nations Expected Goals — Offensive vs Defensive Profile
# ---------------------------------------------------------------------------

log_msg("INFO", "Plotting offensive vs defensive squad profiles...")

p_profile <- squad_features %>%
  filter(!is.na(squad_xg_weighted), !is.na(squad_xa_weighted)) %>%
  mutate(is_top8 = team %in% top8) %>%
  ggplot(aes(x = squad_xg_weighted, y = squad_xa_weighted,
             color = is_top8, size = squad_depth_index)) +
  geom_point(alpha = 0.75) +
  ggrepel::geom_text_repel(
    data = . %>% filter(is_top8),
    aes(label = team),
    size = 3, fontface = "bold", show.legend = FALSE
  ) +
  scale_color_manual(
    values = c("FALSE" = "#B0BEC5", "TRUE" = "#2E86AB"),
    labels = c("Other nations", "Top 8 contenders"),
    name   = NULL
  ) +
  scale_size_continuous(name = "Depth Index", range = c(2, 6)) +
  labs(
    title    = "Squad Offensive Profile — xG vs xA per 90",
    subtitle = "Point size = squad depth index | Top 8 contenders labeled",
    x        = "Weighted Squad xG per 90",
    y        = "Weighted Squad xA per 90"
  ) +
  theme_minimal(base_size = 11) +
  theme(plot.title = element_text(face = "bold"))

ggsave(file.path(figures_dir, "16_squad_offensive_profile.png"),
       p_profile, width = 9, height = 6, dpi = 150)
log_msg("INFO", "Saved: 16_squad_offensive_profile.png")

# ---------------------------------------------------------------------------
# 6. Final Champion Probability Bar Chart (clean version for report)
# ---------------------------------------------------------------------------

log_msg("INFO", "Plotting final champion probability chart...")

p_final_champion <- simulation_results %>%
  filter(champion_prob >= 0.005) %>%
  arrange(desc(champion_prob)) %>%
  mutate(
    team  = reorder(team, champion_prob),
    label = percent(champion_prob, accuracy = 0.1)
  ) %>%
  ggplot(aes(x = team, y = champion_prob, fill = champion_prob)) +
  geom_col(show.legend = FALSE) +
  geom_text(aes(label = label), hjust = -0.1, size = 3) +
  coord_flip() +
  scale_fill_gradient(low = "#AED9E0", high = "#2E86AB") +
  scale_y_continuous(
    labels = percent,
    expand = expansion(mult = c(0, 0.18))
  ) +
  labs(
    title    = "2026 FIFA World Cup — Predicted Champion Probabilities",
    subtitle = "Poisson model + 500 Monte Carlo simulations | Set seed 42",
    x        = NULL,
    y        = "Probability of Winning the Tournament"
  ) +
  theme_minimal(base_size = 11) +
  theme(plot.title = element_text(face = "bold"))

ggsave(file.path(figures_dir, "17_final_champion_probs.png"),
       p_final_champion, width = 9, height = 7, dpi = 150)
log_msg("INFO", "Saved: 17_final_champion_probs.png")

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

log_msg("INFO", "========== VISUALIZATIONS COMPLETE ==========")
log_msg("INFO", paste("All figures saved to:", figures_dir))
log_msg("INFO", "Figures generated in this script: 13–17")
log_msg("INFO", "Total figures across project: 17")
log_msg("INFO", "")
log_msg("INFO", "=== FINAL PROJECT SUMMARY ===")
log_msg("INFO", paste("Predicted 2026 World Cup Winner:",
                      simulation_results$team[1],
                      "(",
                      percent(simulation_results$champion_prob[1], accuracy = 0.1),
                      ")"))
log_msg("INFO", paste("Runner-up:",
                      simulation_results$team[2],
                      "(",
                      percent(simulation_results$champion_prob[2], accuracy = 0.1),
                      ")"))
log_msg("INFO", "Top 5 contenders:")
simulation_results %>%
  slice_head(n = 5) %>%
  mutate(champion_prob = percent(champion_prob, accuracy = 0.1)) %>%
  select(team, champion_prob) %>%
  print()