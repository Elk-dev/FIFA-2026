# FIFA 2026 World Cup Winner Prediction Using Poisson Regression and Monte Carlo Simulation

**Course:** CSC 642/542 — Statistical Learning  
**Author:** Elkin Huertas  
**Institution:** University of Miami  
**Date:** April 2026  
**GitHub Repository:** https://github.com/Elk-dev/FIFA-2026

---

## 1. Introduction

The FIFA World Cup is the most watched sporting event on the planet, drawing billions of viewers across 32 — and now 48 — nations. The 2026 edition, co-hosted by the United States, Canada, and Mexico, marks the first expansion to a 48-team format, introducing new dynamics in group stage competition and bracket structure. This expanded format increases the complexity of predicting tournament outcomes while simultaneously making the problem more statistically interesting.

This project addresses the following questions:

1. Which 2026 World Cup nations have the strongest attacking squads based on player performance data from Europe's top leagues?
2. Given two qualified nations, what is the expected scoreline and win probability for each team?
3. Simulating the full 48-team bracket 500 times, which nation is most likely to win the 2026 FIFA World Cup?

Predicting football outcomes is important beyond academic interest. It has applications in sports analytics, broadcasting strategy, sports betting markets, and team preparation. Accurate probabilistic models help teams understand their likely path through a tournament and identify high-risk matchups.

This project takes a different approach from typical classification-based prediction models. Rather than predicting Win/Draw/Loss as a discrete class, we model **goals scored as a Poisson process** — a statistically principled framework for count data — and derive match outcome probabilities from the resulting scoreline distribution. This approach, first formalized by Maher (1982), produces richer predictions: not just who wins, but by how much, and with what probability for every possible scoreline.

---

## 2. State of the Art

Predicting football match outcomes has been an active area of statistical research for decades. Early work by Maher (1982) modeled home and away goals as independent Poisson random variables, demonstrating that the Poisson distribution is a natural fit for football scoring data. Dixon and Coles (1997) extended this by introducing a correction factor for low-scoring matches (0-0, 1-0, 0-1, 1-1), which the basic Poisson model tends to underestimate. Karlis and Ntzoufras (2003) further developed the bivariate Poisson model, which accounts for correlation between home and away goals.

More recent approaches have incorporated machine learning methods. Hubáček et al. (2019) applied gradient boosting and neural networks to predict World Cup outcomes, finding that ensemble methods outperform simpler models on accuracy but lose interpretability. Several Kaggle competitions centered on the 2018 and 2022 World Cups have produced approaches combining ELO ratings, FIFA rankings, and player-level statistics from platforms like Understat and StatsBomb.

The reference project for this course (Aguiar et al., 2026) applied four classification models — Logistic Regression, SVM, Random Forest, and XGBoost — to predict match outcomes for the 2026 World Cup, achieving a best accuracy of 58.2% with Random Forest. That project identified several limitations: no cross-validation on temporal data, limited variable-level analysis, and no scoreline-level prediction. This project directly addresses those gaps by adopting a Poisson regression framework with rolling cross-validation and full scoreline probability simulation.

---

## 3. Materials and Methods

### 3.1 Dataset

Two datasets were used in this project:

| Dataset | Description | Records | Source |
|---|---|---|---|
| `player_data.csv` | Player-level statistics (xG, xA, xG Chain, Key Passes, minutes played) from Europe's Top 5 Leagues | 8,210 players | Understat / StatsBomb |
| `major_int_tournaments.csv` | International match results from 14 major competitions (2019–2025) | 511 matches | football-data.co.uk / Kaggle |

Both datasets were stored in a **Google Cloud Storage bucket** provisioned via Terraform and ingested through an automated ETL pipeline authenticated using Workload Identity Federation — a keyless GCP authentication pattern. A local fallback to the `data/` directory is available for environments without GCS credentials.

Matches were filtered to include only those involving two 2026 World Cup qualified nations, producing 511 usable match records spanning competitions including the FIFA World Cup, Copa América, UEFA Nations League, Africa Cup of Nations, and AFC Asian Cup. The date range covers March 2019 through July 2025.

Player data was filtered to players with more than 0 minutes played from qualified nations, yielding 8,210 player records across 42 of the 48 qualified nations. Six nations — Iran, Jordan, Qatar, Saudi Arabia, Curaçao, and Iraq — had no representation in Europe's top 5 leagues and could not be assigned player-level features.

#### Key Variable Definitions

| Variable | Definition | Source |
|---|---|---|
| xG | Expected Goals — probability a shot results in a goal based on location, angle, and shot type | Understat |
| xA | Expected Assists — xG value of the shot that was assisted by a given pass | Understat |
| xG Chain | xG from all possessions a player is involved in, capturing indirect contributions | Understat |
| xG Buildup | xG from possessions excluding the shot and assist — measures off-ball buildup | Understat |
| Key Passes | Passes that directly lead to a shot on goal | Understat |
| ELO Rating | Team strength rating updated after each match using the Elo system (Elo, 1978) | Club Elo |
| Minutes Played | Total minutes played — used as aggregation weight for squad-level features | Understat |

### 3.2 Data Pre-processing

Team name normalization was applied to align naming conventions across datasets (e.g., "IR Iran" → "Iran", "Côte d'Ivoire" → "Ivory Coast"). Matches with missing scorelines were removed. Player records with missing minutes were excluded. All remaining numeric null values were filled with zero, reflecting a player not recording a given statistical event rather than missing data.

### 3.3 Feature Engineering

Player statistics were aggregated to the national team level using **minutes-weighted averages** across the top 15 players by playing time per nation. This approach gives more weight to players who feature regularly, producing more reliable squad-level estimates than a simple top-N slice.

A **squad depth index** was also computed for each nation, measuring how evenly distributed goal contribution is across the squad rather than concentrated in one star player. Higher values indicate more balanced squads.

For classification-style analysis, differential features were constructed as `home_metric - away_metric` for each squad statistic, capturing relative strength between two teams in a given matchup.

For the Poisson model, the dataset was restructured into long format — one row per team per match — with the opposing team's metrics included as opponent features.

A **time-based train/test split** was applied: the oldest 80% of matches by date form the training set (March 2019 – March 2024) and the most recent 20% form the test set (March 2024 – July 2025). This prevents data leakage that would occur with random splitting of temporal data.

### 3.4 Methods

#### Bivariate Poisson Regression

Goals scored by each team are modeled as a Poisson process:

```
Goals_i ~ Poisson(λ_i)
log(λ_i) = β₀ + β₁·xG + β₂·xA + β₃·xG_chain + β₄·opp_xG + β₅·depth_index + β₆·is_home
```

Where `λ_i` is the expected number of goals for team `i` in a given match. The log link ensures predicted goal counts are always positive. The `is_home` indicator captures the well-documented home advantage effect in international football.

An overdispersion check was performed by comparing residual deviance to degrees of freedom. A dispersion ratio of 1.229 confirmed that the standard Poisson distribution is appropriate (ratio > 1.5 would indicate overdispersion requiring a Negative Binomial model).

From the fitted model, a **score matrix** is derived for any two teams — a matrix of probabilities for every scoreline from 0-0 to 5-5 using the Poisson probability mass function. Win, draw, and loss probabilities are then aggregated from this matrix.

#### Rolling Time-Series Cross-Validation

A 5-fold rolling cross-validation was applied to evaluate model stability across time. Each fold trains on all historical data up to a cutoff date and validates on the subsequent window, expanding the training set with each fold. This approach respects the temporal ordering of matches and prevents future information from leaking into model training — a critical consideration for sports prediction tasks.

#### Monte Carlo Tournament Simulation

The full 2026 World Cup bracket was simulated 500 times using the following structure:

- **Group stage:** 12 groups of 4 teams, round-robin format. Goals are simulated as Poisson draws from each team's predicted λ. Points are awarded (3W / 1D / 0L) and standings computed by points, goal difference, and goals scored.
- **Knockout stage:** Top 2 from each group plus the 8 best third-place teams advance (32 teams total). Single-elimination rounds from Round of 32 through the Final.
- **Tiebreakers:** Knockout draws trigger extra time simulation followed by a penalty shootout (modeled as a weighted coin flip).

Champion counts are aggregated across all 500 simulations to produce championship probabilities for each nation.

### 3.5 Evaluation

Model performance was evaluated on the held-out test set using:

- **Mean Absolute Error (MAE):** Average absolute difference between predicted and actual goals
- **Root Mean Squared Error (RMSE):** Penalizes larger prediction errors more heavily
- **Pearson Correlation:** Measures linear association between predicted λ and actual goals
- **Rolling CV MAE/RMSE:** Average error across 5 time-based validation folds

---

## 4. Results

### 4.1 Descriptive Analysis

The match dataset shows a clear home advantage: home teams win 44.4% of matches, draws occur 28.2% of the time, and away teams win 27.4% of matches. The average match produces 2.59 total goals (1.52 home, 1.08 away).

![Outcome Distribution](figures/01_outcome_distribution.png)

![Goals Distributions](figures/02_goals_distributions.png)

Goals per match vary considerably by competition type, with friendlies tending to produce more goals than competitive knockout matches.

![Goals by Competition](figures/03_goals_by_competition.png)

Player metric distributions show clear positional patterns — forwards lead in xG and shots per 90 while midfielders lead in key passes and xA, validating that the features capture meaningful positional differences.

![Player Metrics by Position](figures/04_player_metrics_by_position.png)

The correlation matrix reveals strong positive correlations between xG, shots per 90, and goals per 90, while xG Buildup shows lower correlation with direct goal threat metrics — confirming it captures a distinct dimension of play.

![Correlation Matrix](figures/06_correlation_matrix.png)

PCA analysis confirms that the first two principal components explain approximately 65% of variance in player metrics, with xG, shots, and goals loading heavily on PC1 (direct attacking threat) and xG Buildup and xG Chain loading on PC2 (indirect involvement).

![PCA Loadings](figures/09_pca_loadings.png)

The squad strength heatmap ranks all 48 qualified nations across four metrics. European nations dominate in xG and xA, reflecting the concentration of top players in Europe's leagues.

![Squad Heatmap](figures/13_squad_strength_heatmap.png)

### 4.2 Model Performance

The Poisson regression model coefficients show statistically significant effects for team xA (p = 0.034), opponent xG (p = 0.004), and home advantage (p < 0.001). The home advantage coefficient (β = 0.360) corresponds to approximately 43% more expected goals for the home team, consistent with prior literature.

Rolling CV results show consistent performance across all 5 folds:

![Rolling CV](figures/11_rolling_cv_results.png)

| Fold | Train Size | Val Size | MAE | RMSE |
|---|---|---|---|---|
| 1 | 92 | 100 | 1.030 | 1.230 |
| 2 | 192 | 92 | 0.943 | 1.150 |
| 3 | 284 | 140 | 0.985 | 1.230 |
| 4 | 424 | 122 | 0.882 | 1.140 |
| 5 | 546 | 128 | 0.945 | 1.220 |
| **Mean** | — | — | **0.957** | **1.194** |

Test set performance:

![Predicted vs Actual](figures/10_poisson_pred_vs_actual.png)

### 4.3 Model Comparison

| Model | Type | CV Method | MAE | RMSE | Accuracy |
|---|---|---|---|---|---|
| Logistic Regression | Classification | LASSO CV | — | — | 48.9% |
| SVM (Linear) | Classification | Grid CV | — | — | 47.3% |
| Random Forest | Classification | MC Sim | — | — | 58.2% |
| XGBoost | Classification | MC Sim | — | — | 56.4% |
| **Poisson Regression** | **Goal Model** | **Rolling CV** | **0.892** | **1.208** | **—** |

> Note: The Poisson model is not directly comparable to classifiers on accuracy since it predicts full scoreline distributions rather than discrete Win/Draw/Loss outcomes. Its MAE of 0.892 goals on the test set indicates predictions are within approximately 1 goal of actual scorelines.

### 4.4 Example Matchup Predictions

| Team A | Team B | Exp. Goals A | Exp. Goals B | P(Win A) | P(Draw) | P(Win B) |
|---|---|---|---|---|---|---|
| France | Brazil | 1.44 | 0.95 | 47.9% | 26.7% | 25.0% |
| Argentina | England | 1.57 | 0.95 | 51.2% | 25.3% | 22.9% |
| Spain | Germany | 1.47 | 1.07 | 46.0% | 26.1% | 27.4% |
| Portugal | Netherlands | 1.73 | 1.10 | 51.4% | 23.7% | 23.9% |
| United States | Mexico | 1.55 | 1.01 | 49.3% | 25.5% | 24.6% |

### 4.5 Tournament Simulation Results

![Champion Probabilities](figures/17_final_champion_probs.png)

![Simulation Funnel](figures/14_simulation_funnel.png)

![H2H Matrix](figures/15_h2h_probability_matrix.png)

The head-to-head win probability matrix shows Portugal, France, Spain, and Germany as the strongest contenders based on squad metrics, with win probabilities consistently above 50% against most opponents.

---

## 5. Conclusions and Future Work

### 5.1 Conclusions

This project developed a full end-to-end statistical pipeline for predicting the 2026 FIFA World Cup winner using Bivariate Poisson Regression and Monte Carlo simulation. Key findings include:

- **Home advantage is statistically significant** — teams playing at home score approximately 43% more goals on average (β = 0.360, p < 0.001)
- **xA and opponent xG are the strongest predictors** of goals scored, suggesting that chance creation quality and defensive solidity are more predictive than raw shot volume
- **Portugal leads championship probabilities** at 5.6% across 500 simulations, followed by Spain (4.8%) and France (4.0%)
- **Rolling CV shows consistent model performance** across time windows (mean MAE: 0.957), indicating the model generalizes well to unseen future matches
- The Poisson framework provides richer predictions than classification approaches — not just who wins, but the full distribution of possible scorelines

### 5.2 Limitations

- **Missing squad data:** Teams with no representation in Europe's top 5 leagues (Iran, Jordan, Qatar, Saudi Arabia, Curaçao, Iraq, Cape Verde, Haiti) default to equal match probabilities in the simulation, artificially inflating their championship likelihood. This explains anomalous results such as Cape Verde and Haiti appearing in the top 5 predicted champions.
- **No ELO integration:** The model relies solely on player-level stats from European leagues. Teams competing primarily outside Europe are underrepresented.
- **Static squad snapshot:** Player features reflect the most recent season and do not account for injuries, suspensions, or form going into the tournament.
- **Simplified bracket seeding:** The knockout bracket uses random team ordering rather than the official 2026 seeding rules.

### 5.3 Future Work

- **ELO/FIFA ranking fallback:** Replace equal-probability assumptions for data-sparse teams with FIFA ranking points or ELO ratings as a baseline strength metric, producing more realistic simulation outcomes for all 48 nations.
- **Proper bracket seeding:** Implement the official 2026 bracket seeding rules (group winners vs. third-place teams by confederation).
- **Injury and form weighting:** Incorporate rolling form windows and injury reports closer to the tournament start date using a live data feed.
- **Dixon-Coles correction:** Apply the Dixon and Coles (1997) correction factor for low-scoring matches to improve scoreline probability estimates.
- **Automated CI/CD pipeline:** Extend the GitHub Actions workflow to rerun the full modeling pipeline and commit updated figures on each push, creating a fully automated end-to-end ML pipeline with fresh data from GCS.

---

## References

1. Maher, M.J. (1982). Modelling association football scores. *Statistica Neerlandica*, 36(3), 109–118.
2. Dixon, M., & Coles, S. (1997). Modelling association football scores and inefficiencies in the football betting market. *Journal of the Royal Statistical Society*, 46(2), 265–280.
3. Karlis, D., & Ntzoufras, I. (2003). Analysis of sports data by using bivariate Poisson models. *Journal of the Royal Statistical Society*, 52(3), 381–393.
4. Elo, A.E. (1978). *The Rating of Chessplayers, Past and Present*. Arpad Elo.
5. Hubáček, O., Šourek, G., & Železný, F. (2019). Exploiting sports-betting market using machine learning. *International Journal of Forecasting*, 35(2), 783–796.
6. Understat. (2025). *Expected goals data for European football leagues*. https://understat.com
7. football-data.co.uk. (2025). *International football results dataset*. https://www.football-data.co.uk
8. Transfermarkt. (2025). *Player market values and international caps*. https://www.transfermarkt.com
9. StatsBomb. (2025). *Open data and metrics definitions*. https://statsbomb.com/what-we-do/hub/free-data/

---

*University of Miami — Data Science M.S. | CSC 642/542 | April 2026*