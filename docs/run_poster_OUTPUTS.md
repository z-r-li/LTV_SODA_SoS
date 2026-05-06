# `run_poster.m` — what each output file contains

Files land in `opts.out_dir` (defaults to `Project/`, same folder as the input xlsx) with stem `SODA_poster`. Two groups: per-scenario artifacts (one set per scenario) and a cross-scenario summary.

The four scenarios are `S1_baseline`, `S2_decision_support`, `S3_fully_autonomous`, `S4_regolith`. Substitute `<S>` below for any of them.

---

## Per-scenario artifacts (5 per scenario × 4 scenarios)

### Deterministic snapshot — `<S>_results.xlsx`, `<S>_nodes.csv`, `<S>_edges.csv`

The deterministic single-pass solve. `<S>_results.xlsx` has one sheet, 24 rows + header:

| Column | Meaning |
|---|---|
| `idx`, `label` | Node index and name |
| `SE_type` | `D` / `B` / `U`. In S4 the regolith nodes flip from `D` to `B`. |
| `SE` | Self-effectiveness used by the solve. For `B`-type nodes this is the Beta mean = 100·α/(α+β). |
| `Op` | Operability returned by `SODA` or `SODAcycle` (the network has cycles, so it’ll be `SODAcycle`). |

The two CSVs are the same data laid out for Gephi: `*_nodes.csv` has `Id, Label, SE_type, SE, Op, IsLeaf, IsRoot`; `*_edges.csv` has `Source, Target, Type, Weight, SOD, COD, IOD` with `Weight = SOD · COD/100` so a single edge weight already combines strength and criticality. Edges that the toggle changes (LTV decision-related in S2/S3) will have different weights between scenarios — that’s how you’d show the structural diff in a side-by-side network rendering.

### Centrality — `<S>_centrality.xlsx`, `<S>_centrality_nodes.csv`, `<S>_centrality.png`

Six centrality metrics per node. The xlsx has three sheets: `scores` (raw numbers), `ranks` (1 = highest in that metric, easier to compare across scenarios), `top10` (top-10 per metric in long format).

| Column | What it captures |
|---|---|
| `eig_out` / `eig_in` | Outgoing / incoming eigenvector centrality. Power-iteration on the SOD·COD-weighted adjacency, with SVD fallback if it doesn’t converge. |
| `katz_out` / `katz_in` | Katz with α = 0.9 / spectral_radius — counts walks of all lengths, discounted by α. Stable when eigenvector struggles. |
| `pagerank` | Damped random-walk importance, damping 0.85. Reach for this one if you want a single centrality number on the poster. |
| `hubs` / `authorities` | HITS pair: hubs point to authorities, authorities are pointed to by hubs. |

The CSV is the Gephi-ready version. The PNG is a 2×3 grid of horizontal bar charts (top 15 per metric) — quick visual check that nothing exploded.

Note that centrality depends only on edge structure, not on SE values, so **S1 and S4 have identical centrality** (regolith touches SE only). Don’t treat that as a bug; flag it on the poster if a reviewer asks.

### Monte Carlo — `<S>_mc.xlsx`, `<S>_mc_ci_nodes.csv`, `<S>_mc.png`

N = 2000 replications, seed 20260504, 95% CI. Three sheets in the xlsx:

`summary` — three rows, one each for `Onet` (mean Op across all 24 nodes), `leaf_mean` (mean Op across leaves only), and `leaf_min` (the bottleneck-leaf Op per replication). Columns: `mean, std, ci_low, ci_high, min, max`.

`per_node` — per-node `Op_mean, Op_std, Op_ci_low, Op_ci_high`. This is the source for per-node error bars.

`meta` — parameter and toggle echo plus timestamp. Useful audit trail when citing a number on the poster.

The diagnostic PNG is 2×2: Onet histogram with CI band, leaf-mean histogram, per-node boxplots, leaf-min histogram. **The per-node boxplot is where the regolith story lands** — in S1/S2/S3 only the Crew nodes are Beta, so MC variance is modest; in S4 LTV_Obs / LTV_Act / SciEq_Act also flip to Beta(5,2), and those CIs visibly widen. If they don’t, something is wrong.

### Robustness — `<S>_robustness.xlsx`, `<S>_robustness.png`

Single-node knockout sweep: for every non-leaf node, force SE → 0 and re-solve. Two sheets:

`summary` — one row per knockout:

| Column | Meaning |
|---|---|
| `name`, `idx`, `label` | Knocked-out node |
| `Onet_nom`, `Onet_dis` | Network-mean Op before / after the knockout |
| `dR_mean` | `Onet_nom – Onet_dis` (averaged across all nodes) |
| `leaf_nom`, `leaf_dis`, `dR_leaf` | Same idea but over leaf nodes only. **`dR_leaf` is the headline robustness number** for the poster. |
| `dR_min_leaf` | Drop in worst-leaf Op — captures whether the knockout broke the bottleneck leaf specifically. |
| `resilience` | `Onet_dis / Onet_nom` ∈ [0,1]. 1.0 = node didn’t matter; 0 = network collapse. |

`per_node_delta` — wide table (24 rows × ~14 knockouts): rows are nodes, columns are each knockout’s post-disruption Op. Lets you trace cascading impact (“when LTV_Ori failed, who else’s Op fell?”).

The PNG is a horizontal bar of `dR_leaf` per knockout, sorted descending. Top bar = most-fragile node in that scenario. Compare across scenarios for the “fragility shifts under autonomy” narrative.

---

## Cross-scenario summary — `SODA_poster_summary.xlsx` and `.png`

This is what actually goes on the poster.

### `SODA_poster_summary.xlsx`

Six sheets. The headline is `Summary` — one row per scenario, 14 columns:

| Column | Meaning |
|---|---|
| `name` | Display name |
| `Onet_det`, `leaf_mean_det` | Deterministic network and leaf-mean operability — the main numbers |
| `Onet_mc_mean`, `Onet_mc_ci_low`, `Onet_mc_ci_high` | MC mean and 95% CI on Onet. Should track `Onet_det` closely for S1–S3; may diverge for S4 (wider Beta). |
| `worst_KO`, `worst_dR_leaf`, `worst_resilience` | Most-fragile node from the knockout sweep, its leaf-mean drop, and the resilience ratio under that knockout |
| `top_pagerank`, `top_eigout`, `top_closeness`, `top_eig_sensitivity` | Highest-scoring node per metric — the centrality story in four columns |
| `runtime_s` | Wall time for that scenario |

Four more sheets give the per-node breakdown so you can write “node X dropped most between S1 and S3”: `Op_det_per_node`, `PageRank_per_node`, `Closeness_per_node`, `EigSensitivity_per_node`. Same shape — 24 rows × 4 scenario columns.

`EigSensitivity_per_node` deserves a sentence: it's per-node eigenvector sensitivity computed by `compute_eig_sensitivity.m`. For each node, scale every incident edge by ±10%, recompute eigenvector centrality, and report the L2 shift from the unperturbed centrality vector (sign-aligned via dot product). High value = small wobbles in this node's edge weights noticeably reorder the importance landscape. Useful counterpoint to PageRank: a node can be high-PageRank but low-sensitivity (it's important and stable) or low-PageRank but high-sensitivity (it's a quiet pivot point that the network's importance map depends on).

`Toggles_and_events` is the audit trail: per scenario, the toggle values and the full `events_log` from `load_SODA_config` joined into one cell. If a reviewer asks exactly what S3 did to the LTV decision node, the receipts are there.

### `SODA_poster_summary.png`

A 1×2 figure. Left: bar of `Onet_det` per scenario with MC 95% CI as black error bars on top, y-axis [0,100] — the headline figure. Right: bar of `worst_dR_leaf` per scenario with the worst-knockout node name annotated vertically — the fragility-shifts figure.

If only one chart fits the poster, it’s this one. If two fit, pair it with one of the per-scenario `<S>_centrality.png` images so the centrality detail behind the `top_*` columns has a visual.

---

## Reading the four scenarios against each other

The whole point of the pipeline is to answer four poster questions in one place:

- **Did operability change?** → `Onet_det` column on the Summary sheet, with the MC CIs telling you whether the differences are inside noise.
- **Did fragility move?** → `worst_KO` column. If the worst node changed between S1 and S3, that’s your “single point of failure shifts under autonomy” finding.
- **Did importance redistribute?** → the three `top_*` columns plus the per-node centrality sheets if you need the longer ranking.
- **Does uncertainty matter?** → CI width across rows, with S4 expected to be widest because of regolith.

The natural narrative drops out: "Onet moved from X to Y across scenarios, but more importantly the bottleneck shifted from A to B — which is where future architectural work should focus.”
