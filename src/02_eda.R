# =============================================================================
# 02_eda.R
# FIFA 2026 World Cup Prediction — Exploratory Data Analysis
# -----------------------------------------------------------------------------
# Performs in-depth analysis of the dataset including:
#   - Variable definitions and source documentation
#   - Distribution analysis (histograms, boxplots)
#   - Correlation analysis
#   - Outcome-stratified comparisons
#   - PCA for dimensionality insight
#
# Inputs:  player_data_clean, match_data_clean (from 01_data_prep.R)
# Outputs: Plots saved to /docs/figures/
# =============================================================================

library(tidyverse)
library(ggplot2)
library(corrplot)
library(FactoMineR)
library(factoextra)
library(gridExtra)
library(scales)

# Run upstream scripts if needed
if (!exists("player_data_clean")) source("01_data_prep.R")

# Create output directory for figures
figures_dir <- file.path(dirname(getwd()), "docs", "figures")
dir.create(figures_dir, recursive = TRUE, showWarnings = FALSE)

log_msg("INFO", "========== EDA START ==========")

# ---------------------------------------------------------------------------
# 1. Variable Definitions
# ---------------------------------------------------------------------------
# Documenting every metric used — addresses professor feedback on unexplained
# variables like "passing and chance creation metrics"
# ---------------------------------------------------------------------------

variable_definitions <- tribble(
  ~Variable,          ~Definition,                                              ~Source,
  "xG",               "Expected Goals: probability a shot results in a goal based on shot location, angle, and type. Ranges 0-1 per shot.", "Understat / StatsBomb",
  "xA",               "Expected Assists: xG value of shots assisted by a pass. Measures chance creation quality.", "Understat",
  "xG Chain",         "xG from all possessions a player is involved in — captures indirect contributions beyond shots/assists.", "Understat",
  "xG Buildup",       "xG from possessions excluding the shot and assist — measures off-ball buildup involvement.", "Understat",
  "np_xG",            "Non-Penalty xG: xG excluding penalty kicks, giving a cleaner read of open-play quality.", "Understat",
  "Key Passes",       "Passes that directly lead to a shot on goal.", "Understat / StatsBomb",
  "ELO Rating",       "Numerical team strength rating updated after each match using the Elo system (Elo, 1978). Higher = stronger team.", "Club Elo / Kaggle",
  "Minutes Played",   "Total minutes played — used to weight player contributions when aggregating to squad level.", "Understat",
  "Market Value",     "Transfermarkt estimated player market value in EUR — proxy for overall player quality.", "Transfermarkt",
  "Intl Caps",        "Number of senior international appearances — measures international experience.", "Transfermarkt"
)

log_msg("INFO", "Variable definitions loaded")
print(variable_definitions)

# ---------------------------------------------------------------------------
# 2. Match-Level Feature Engineering for EDA
# ---------------------------------------------------------------------------

match_eda <- match_data_clean %>%
  mutate(
    Outcome = case_when(
      HomeGoals > AwayGoals  ~ "Home Win",
      HomeGoals == AwayGoals ~ "Draw",
      HomeGoals < AwayGoals  ~ "Away Win"
    ),
    Outcome       = factor(Outcome, levels = c("Home Win", "Draw", "Away Win")),
    TotalGoals    = HomeGoals + AwayGoals,
    GoalDiff      = HomeGoals - AwayGoals,
    HighScoring   = TotalGoals >= 3
  )

# ---------------------------------------------------------------------------
# 3. Match Outcome Distribution
# ---------------------------------------------------------------------------

log_msg("INFO", "Plotting outcome distribution...")

p_outcome <- match_eda %>%
  count(Outcome) %>%
  mutate(Pct = n / sum(n),
         Label = paste0(n, "\n(", percent(Pct, accuracy = 0.1), ")")) %>%
  ggplot(aes(x = Outcome, y = n, fill = Outcome)) +
  geom_col(width = 0.6, show.legend = FALSE) +
  geom_text(aes(label = Label), vjust = -0.4, size = 3.5, fontface = "bold") +
  scale_fill_manual(values = c(
    "Home Win" = "#2E86AB",
    "Draw"     = "#F6AE2D",
    "Away Win" = "#F26419"
  )) +
  scale_y_continuous(expand = expansion(mult = c(0, 0.15))) +
  labs(
    title    = "Match Outcome Distribution (2021–2025)",
    subtitle = "International matches between 2026 World Cup qualifiers",
    x        = NULL,
    y        = "Number of Matches"
  ) +
  theme_minimal(base_size = 12) +
  theme(plot.title = element_text(face = "bold"))

ggsave(file.path(figures_dir, "01_outcome_distribution.png"),
       p_outcome, width = 7, height = 5, dpi = 150)
log_msg("INFO", "Saved: 01_outcome_distribution.png")

# ---------------------------------------------------------------------------
# 4. Goals Distribution
# ---------------------------------------------------------------------------

log_msg("INFO", "Plotting goals distributions...")

p_home_goals <- ggplot(match_eda, aes(x = HomeGoals)) +
  geom_histogram(binwidth = 1, fill = "#2E86AB", color = "white") +
  labs(title = "Home Goals Distribution", x = "Goals", y = "Frequency") +
  theme_minimal(base_size = 11)

p_away_goals <- ggplot(match_eda, aes(x = AwayGoals)) +
  geom_histogram(binwidth = 1, fill = "#F26419", color = "white") +
  labs(title = "Away Goals Distribution", x = "Goals", y = "Frequency") +
  theme_minimal(base_size = 11)

p_total_goals <- ggplot(match_eda, aes(x = TotalGoals)) +
  geom_histogram(binwidth = 1, fill = "#6A4C93", color = "white") +
  labs(title = "Total Goals per Match", x = "Total Goals", y = "Frequency") +
  theme_minimal(base_size = 11)

p_goals_combined <- grid.arrange(p_home_goals, p_away_goals, p_total_goals, ncol = 3)
ggsave(file.path(figures_dir, "02_goals_distributions.png"),
       p_goals_combined, width = 12, height = 4, dpi = 150)
log_msg("INFO", "Saved: 02_goals_distributions.png")

# ---------------------------------------------------------------------------
# 5. Goals by Competition Type
# ---------------------------------------------------------------------------

log_msg("INFO", "Plotting goals by competition...")

p_comp_goals <- match_eda %>%
  mutate(Competition_Short = str_trunc(Competition_Name, 30)) %>%
  ggplot(aes(x = reorder(Competition_Short, TotalGoals, median),
             y = TotalGoals, fill = Competition_Short)) +
  geom_boxplot(show.legend = FALSE, outlier.alpha = 0.4) +
  coord_flip() +
  labs(
    title    = "Goals per Match by Competition",
    subtitle = "Median total goals vary by tournament type",
    x        = NULL,
    y        = "Total Goals"
  ) +
  theme_minimal(base_size = 11) +
  theme(plot.title = element_text(face = "bold"))

ggsave(file.path(figures_dir, "03_goals_by_competition.png"),
       p_comp_goals, width = 9, height = 6, dpi = 150)
log_msg("INFO", "Saved: 03_goals_by_competition.png")

# ---------------------------------------------------------------------------
# 6. Player-Level xG / xA Distributions by Position
# ---------------------------------------------------------------------------

log_msg("INFO", "Plotting player stat distributions...")

player_plot_data <- player_data_clean %>%
  filter(minutes >= 180, !is.na(position_group)) %>%
  select(position_group, xg_per90, xa_per90, xgchain_per90, key_passes_per90) %>%
  pivot_longer(-position_group, names_to = "Metric", values_to = "Value") %>%
  mutate(Metric = recode(Metric,
    "xg_per90"         = "xG per 90",
    "xa_per90"         = "xA per 90",
    "xgchain_per90"    = "xG Chain per 90",
    "key_passes_per90" = "Key Passes per 90"
  ))

p_player_box <- ggplot(player_plot_data,
                       aes(x = position_group, y = Value, fill = position_group)) +
  geom_boxplot(outlier.alpha = 0.2, show.legend = FALSE) +
  facet_wrap(~ Metric, scales = "free_y", ncol = 2) +
  labs(
    title    = "Player Metric Distributions by Position Group",
    subtitle = "Players with 180+ minutes | Top 5 European Leagues 2021–2026",
    x        = NULL,
    y        = "Value per 90 minutes"
  ) +
  theme_minimal(base_size = 11) +
  theme(
    axis.text.x  = element_text(angle = 30, hjust = 1),
    plot.title   = element_text(face = "bold"),
    strip.text   = element_text(face = "bold")
  )

ggsave(file.path(figures_dir, "04_player_metrics_by_position.png"),
       p_player_box, width = 10, height = 7, dpi = 150)
log_msg("INFO", "Saved: 04_player_metrics_by_position.png")

# ---------------------------------------------------------------------------
# 7. Top 10 Nations by Average Squad xG per 90
# ---------------------------------------------------------------------------

log_msg("INFO", "Plotting top nations by squad xG...")

p_nation_xg <- player_data_clean %>%
  filter(minutes >= 180) %>%
  group_by(nation) %>%
  summarise(
    avg_xg_per90       = mean(xg_per90, na.rm = TRUE),
    avg_xa_per90       = mean(xa_per90, na.rm = TRUE),
    avg_xgchain_per90  = mean(xgchain_per90, na.rm = TRUE),
    n_players          = n(),
    .groups = "drop"
  ) %>%
  slice_max(avg_xg_per90, n = 10) %>%
  ggplot(aes(x = reorder(nation, avg_xg_per90), y = avg_xg_per90, fill = avg_xg_per90)) +
  geom_col(show.legend = FALSE) +
  geom_text(aes(label = round(avg_xg_per90, 3)), hjust = -0.1, size = 3.2) +
  coord_flip() +
  scale_fill_gradient(low = "#AED9E0", high = "#2E86AB") +
  scale_y_continuous(expand = expansion(mult = c(0, 0.15))) +
  labs(
    title    = "Top 10 Nations by Average Squad xG per 90",
    subtitle = "Aggregated from players in Europe's Top 5 Leagues",
    x        = NULL,
    y        = "Average xG per 90"
  ) +
  theme_minimal(base_size = 11) +
  theme(plot.title = element_text(face = "bold"))

ggsave(file.path(figures_dir, "05_top_nations_xg.png"),
       p_nation_xg, width = 8, height = 5, dpi = 150)
log_msg("INFO", "Saved: 05_top_nations_xg.png")

# ---------------------------------------------------------------------------
# 8. Correlation Matrix of Player Metrics
# ---------------------------------------------------------------------------

log_msg("INFO", "Computing correlation matrix...")

cor_data <- player_data_clean %>%
  filter(minutes >= 180) %>%
  select(xg_per90, xa_per90, xgchain_per90, xgbuildup_per90,
         key_passes_per90, shots_per90, goals_per90, minutes) %>%
  rename(
    "xG/90"          = xg_per90,
    "xA/90"          = xa_per90,
    "xG Chain/90"    = xgchain_per90,
    "xG Buildup/90"  = xgbuildup_per90,
    "Key Passes/90"  = key_passes_per90,
    "Shots/90"       = shots_per90,
    "Goals/90"       = goals_per90,
    "Minutes"        = minutes
  ) %>%
  na.omit()

cor_matrix <- cor(cor_data)

png(file.path(figures_dir, "06_correlation_matrix.png"),
    width = 800, height = 700, res = 120)
corrplot(cor_matrix,
         method      = "color",
         type        = "upper",
         tl.col      = "black",
         tl.srt      = 45,
         addCoef.col = "black",
         number.cex  = 0.65,
         title       = "Correlation Matrix — Player Performance Metrics",
         mar         = c(0, 0, 2, 0))
dev.off()
log_msg("INFO", "Saved: 06_correlation_matrix.png")

# ---------------------------------------------------------------------------
# 9. Goals per Match Over Time (Trend)
# ---------------------------------------------------------------------------

log_msg("INFO", "Plotting goals trend over time...")

p_trend <- match_eda %>%
  mutate(YearMonth = floor_date(Date, "quarter")) %>%
  group_by(YearMonth) %>%
  summarise(
    avg_total_goals = mean(TotalGoals),
    n_matches       = n(),
    .groups = "drop"
  ) %>%
  filter(n_matches >= 3) %>%
  ggplot(aes(x = YearMonth, y = avg_total_goals)) +
  geom_line(color = "#2E86AB", linewidth = 1) +
  geom_point(aes(size = n_matches), color = "#2E86AB", alpha = 0.7) +
  geom_smooth(method = "loess", se = TRUE, color = "#F26419",
              fill = "#F26419", alpha = 0.15) +
  scale_size_continuous(name = "Matches", range = c(2, 6)) +
  labs(
    title    = "Average Goals per Match Over Time",
    subtitle = "Quarterly averages with LOESS trend | International matches 2021–2025",
    x        = NULL,
    y        = "Avg Total Goals per Match"
  ) +
  theme_minimal(base_size = 11) +
  theme(plot.title = element_text(face = "bold"))

ggsave(file.path(figures_dir, "07_goals_trend.png"),
       p_trend, width = 9, height = 5, dpi = 150)
log_msg("INFO", "Saved: 07_goals_trend.png")

# ---------------------------------------------------------------------------
# 10. PCA on Player Metrics
# ---------------------------------------------------------------------------

log_msg("INFO", "Running PCA on player metrics...")

pca_data <- player_data_clean %>%
  filter(minutes >= 180) %>%
  select(xg_per90, xa_per90, xgchain_per90, xgbuildup_per90,
         key_passes_per90, shots_per90, goals_per90) %>%
  na.omit()

res_pca <- PCA(pca_data, scale.unit = TRUE, graph = FALSE)

p_scree <- fviz_eig(res_pca,
                    addlabels = TRUE,
                    ylim      = c(0, 60),
                    barfill   = "#2E86AB",
                    barcolor  = "#2E86AB",
                    main      = "Scree Plot: Variance Explained by Principal Components")

p_loadings <- fviz_pca_var(res_pca,
                            col.var       = "contrib",
                            gradient.cols = c("#AED9E0", "#2E86AB", "#F26419"),
                            repel         = TRUE,
                            title         = "PCA Variable Loadings")

ggsave(file.path(figures_dir, "08_pca_scree.png"),
       p_scree, width = 7, height = 5, dpi = 150)
ggsave(file.path(figures_dir, "09_pca_loadings.png"),
       p_loadings, width = 7, height = 6, dpi = 150)
log_msg("INFO", "Saved: 08_pca_scree.png, 09_pca_loadings.png")

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

log_msg("INFO", "========== EDA COMPLETE ==========")
log_msg("INFO", paste("Figures saved to:", figures_dir))
log_msg("INFO", paste("Total figures generated: 9"))
log_msg("INFO", "Key findings:")
log_msg("INFO", paste(
  " Home Win rate:",
  percent(mean(match_eda$Outcome == "Home Win"), accuracy = 0.1)
))
log_msg("INFO", paste(
  " Draw rate:",
  percent(mean(match_eda$Outcome == "Draw"), accuracy = 0.1)
))
log_msg("INFO", paste(
  " Avg goals per match:",
  round(mean(match_eda$TotalGoals), 2)
))