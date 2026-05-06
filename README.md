# LTV-SODA-SoS

System-of-Systems analysis of Human–Machine Teaming (HMT) architectures for extended lunar surface exploration, anchored to NASA's DRM-5 (Artemis, lunar South Pole, LTV + xEVA + HLS + Gateway). Built for **AAE 560 — System of Systems Modeling and Analysis**, Purdue, Spring 2026, Prof. Cesare Guariniello.

The team modelled an LTV-centric SoS (24 nodes, OODA-decomposed) on top of Cesare's **SODA 2.2** framework, then exercised it under four poster scenarios that vary the level of LTV autonomy and an environmental stressor:

1. **S1 — Baseline (Decision Approval).** All toggles off; LTV requires crew approval for every action.
2. **S2 — Decision Support.** LTV proposes courses of action; crew retains authority.
3. **S3 — Fully Autonomous LTV.** LTV plans and acts independently; crewmember 1 re-assigned to science equipment.
4. **S4 — Baseline + Regolith Build-up.** Regolith dust degrades LTV/SE self-effectiveness from deterministic to wider Beta(α, β) distributions.

Each scenario is solved with the cyclic SODA fixed-point (`SODAcycle`) because the network has feedback loops (Crew_OODA ↔ LTV_Act ↔ LTV_Obs).

Per scenario the pipeline reports:

- Deterministic operability per node and `Onet` (network mean)
- Eigenvector / Katz / PageRank / HITS / closeness / eigenvector-sensitivity centralities
- Monte Carlo distributions on `Onet`, leaf-mean, and leaf-min (N = 2000, 95 % CI)
- Single-node knockout robustness (worst-case `ΔR_leaf` and resilience ratio)

A cross-scenario summary table (`SODA_poster_summary.xlsx`) and headline figure (`SODA_poster_summary.png`) are produced for the poster narrative.

## Repository layout

```
LTV_SODA_SoS/
├── main.m                           Top-level entry point
├── src/                             Student-authored MATLAB
│   ├── load_SODA_config.m           24-node loader + Event-Register toggles
│   ├── run_baseline.m               Deterministic single-pass solve
│   ├── run_centrality_cfg.m         Eigenvector/Katz/PageRank/HITS
│   ├── compute_eig_sensitivity.m    Per-node eigenvector sensitivity (±10 %)
│   ├── run_mc.m                     Monte Carlo with per-node CIs
│   ├── run_robustness_cfg.m         Single-node SE → 0 knockout sweep
│   ├── run_set1_se_sweep.m          Set 1: Crew SE drop sweep
│   ├── run_set2_dep_sweep.m         Set 2: LTV→Crew dependency sweep
│   ├── run_poster.m                 4-scenario poster driver
│   ├── run_all.m                    Baseline + centrality + Set 1 + Set 2
│   ├── verify_load_SODA_config.m    Loader smoke-test (7 scenarios)
│   ├── SODAcycle.m                  Fixed-point SODA solver for cyclic graphs
│   ├── failureImpactRange.m         Multi-node failure cascade (helper)
│   └── PlotSODA.m                   Single-edge SODA curve illustration
├── data/
│   └── SODA_configurations_input.xlsx   24-node network + Event Register
├── docs/
│   └── run_poster_OUTPUTS.md        Output-by-output specification
└── third_party/
    └── SODA_2.2_pcode/              Cesare Guariniello, SODA 2.2 (2017)
```

`results/` is created by `main.m` on first run and is gitignored.

## Quick start

```matlab
% From the repo root in MATLAB R2022b or newer:
summary = main();              % full run (~minutes; N = 2000 MC reps)

% Smoke test — small MC, no plots:
opts.N = 200; opts.plot = false;
summary = main(opts);
```

`main.m` does three things: adds `src/` and `third_party/SODA_2.2_pcode/` to the path, points `run_poster` at `data/SODA_configurations_input.xlsx`, and routes outputs to `results/`. From there `run_poster` loads each of the four scenarios via `load_SODA_config` (toggles in the workbook's *Event Register* tab), then runs `run_baseline → run_centrality_cfg → run_mc → run_robustness_cfg` per scenario and assembles the cross-scenario summary.

To run only the loader smoke test:

```matlab
addpath src third_party/SODA_2.2_pcode
verify_load_SODA_config('data/SODA_configurations_input.xlsx');
```

## Network model

The active sheet in `SODA_configurations_input.xlsx` is **Default Network Metrics** (24 nodes, no HOST rollups). Crew SE is `Beta(5, 2)` stochastic; LTV/HLS/GC SE is deterministic at 80. Toggles live on the **Event Register** tab and are interpreted by `load_SODA_config.m`:

| Toggle (cell)   | Effect when on                                                       |
| --------------- | -------------------------------------------------------------------- |
| `crew3` (B2/C2) | Adds Crewmember 3 (OODA + dependencies)                              |
| `ltv_FA` (B37)  | Re-points LTV decision edges to a fully-autonomous configuration     |
| `ltv_DS` (B50)  | Routes LTV outputs through Decision Support (graduated autonomy)     |
| `regolith` (B66)| Flips LTV/SE-related nodes from deterministic to Beta(α, β) under stress |

`ltv_FA` and `ltv_DS` are mutually exclusive (both off ≡ Decision Approval).

The network has cycles (Crew_OODA → LTV_Act → Crew_Obs and LTV_Act → LTV_Obs), so every solve dispatches to `SODAcycle.m` rather than the DAG path.

## Outputs

For each scenario `<S>` ∈ {`S1_baseline`, `S2_decision_support`, `S3_fully_autonomous`, `S4_regolith`}, `run_poster` writes:

- `SODA_poster_<S>_results.xlsx` + `_nodes.csv` + `_edges.csv` — deterministic snapshot, Gephi-ready
- `SODA_poster_<S>_centrality.xlsx` + `_centrality_nodes.csv` + `.png` — six centrality metrics, ranks, top-10
- `SODA_poster_<S>_mc.xlsx` + `_mc_ci_nodes.csv` + `.png` — Monte Carlo distributions and per-node CIs
- `SODA_poster_<S>_robustness.xlsx` + `.png` — single-node knockout sweep

Plus the comparative roll-up: `SODA_poster_summary.xlsx` and `SODA_poster_summary.png`.

A field-by-field reference for every output column is in [`docs/run_poster_OUTPUTS.md`](docs/run_poster_OUTPUTS.md).

## Team

Mustakeen ul Bari, Zhuorui Li, Arthur Middlebrooks, Joel Oviedo. Instructor: Prof. Cesare Guariniello.

## Acknowledgements & licensing

- Student-authored code under `main.m`, `src/`, and `data/SODA_configurations_input.xlsx` is released under the MIT License (see [`LICENSE`](LICENSE)).
- `third_party/SODA_2.2_pcode/` is the **SODA 2.2** release © Cesare Guariniello, 2017, included with the instructor's permission for course use. It is *not* covered by the MIT License above. Anyone redistributing this repo for non-course use should obtain SODA from Prof. Guariniello directly.

## References

- Guariniello, C., DeLaurentis, D. *Communications, information, and risk management in System-of-Systems*. (SODA framework papers.)
- NASA. *Moon-to-Mars Architecture Definition Document* (DRM-5).
- NASA. *Extravehicular Activity and Human Surface Mobility Program (EHP) CONOPS*.
- Torkjazi, M. *System-of-Architectures for Sub-Architecture Selection*.
