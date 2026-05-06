function summary = run_poster(xlsx_path, opts)
%RUN_POSTER  4-scenario driver for the AAE 560 Moon-to-Mars HMT poster.
%
% Locked in by the 2026-05-04 team meeting (Joel + Mus + Arthur + Zhuorui):
%   S1  Baseline (Decision Approval)        all toggles off
%   S2  Decision Support (graduated LTV)    ltv_DS = 1
%   S3  Fully Autonomous LTV                ltv_FA = 1
%   S4  Baseline + Regolith Build-up        regolith = 1, regolith_pct = 50
%
% For each scenario this script:
%   1. Loads cfg via load_SODA_config (toggles applied to the Default Network
%      Metrics tab of SODA_configurations_input.xlsx)
%   2. Runs run_baseline    -> deterministic Op vector + Onet
%   3. Runs run_centrality_cfg -> eigenvector / Katz / PageRank / Hubs / Auth
%      (also computes graph-theoretic closeness on the SOD-weighted digraph,
%       since the meeting notes called out closeness as a poster metric)
%   4. Runs run_mc          -> stochastic Onet + per-node CIs
%   5. Runs run_robustness_cfg -> single-node SE-zero knockout sweep,
%      reports worst-node dR_leaf and a "resilience" ratio
%      (Onet_disrupted / Onet_nominal under that knockout).
% Then assembles a single comparative xlsx whose 'Summary' tab is the
% headline table for the poster narrative.
%
% Usage (from Project/Code, with SODA_2.2_pcode on the path):
%   >> addpath('SODA_2.2_pcode')
%   >> summary = run_poster('../SODA_configurations_input.xlsx');
%
% Smoke test (small N, no plots):
%   >> opts.N = 200; opts.plot = false;
%   >> run_poster('../SODA_configurations_input.xlsx', opts);
%
% Inputs
% ------
%   xlsx_path : path to SODA_configurations_input.xlsx. The script also
%               accepts 'SODA_configurations_input (1).xlsx' if the file
%               hasn't been renamed yet.
%   opts (struct, all optional)
%     .N            MC replications per scenario        default 2000
%     .seed         rng seed (same for every scenario)  default 20260504
%     .ci_level     MC CI level                         default 0.95
%     .out_dir      where to write outputs              default same dir as xlsx
%     .out_stem     filename prefix for outputs         default 'SODA_poster'
%     .plot         emit per-scenario PNGs              default true
%     .verbose      log progress                        default true
%     .scenarios    cell array to override the default 4 (advanced)
%
% Output
% ------
%   summary : MATLAB table with one row per scenario and columns:
%               name, Onet_det, leaf_mean_det,
%               Onet_mc_mean, Onet_mc_ci_low, Onet_mc_ci_high,
%               worst_knockout, worst_dR_leaf, worst_resilience,
%               top_pagerank, top_eigout, top_closeness,
%               runtime_s
%
% Files written (in opts.out_dir, default = same folder as xlsx_path):
%   <stem>_S1_baseline_*           per-scenario artifacts (cfg dumps,
%   <stem>_S2_decision_support_*    centrality xlsx + png, mc xlsx + png,
%   <stem>_S3_fully_autonomous_*    robustness xlsx + png)
%   <stem>_S4_regolith_*
%   <stem>_summary.xlsx            comparative table for the poster
%   <stem>_summary.png             4-scenario Onet bar with MC error bars

% ---------------------------------------------------------------- inputs
if nargin < 1 || isempty(xlsx_path)
    xlsx_path = 'SODA_configurations_input.xlsx';
end
if exist(xlsx_path, 'file') ~= 2
    % Fallback: handle the "(1)" suffix that download dialogs sometimes add
    [xd, xb, xe] = fileparts(xlsx_path);
    alt = fullfile(xd, [xb ' (1)' xe]);
    if exist(alt, 'file') == 2
        xlsx_path = alt;
    else
        error('run_poster: cannot find %s (or %s)', xlsx_path, alt);
    end
end

if nargin < 2 || isempty(opts); opts = struct(); end
opts = set_default(opts, 'N',         2000);
opts = set_default(opts, 'seed',      20260504);
opts = set_default(opts, 'ci_level',  0.95);
opts = set_default(opts, 'plot',      true);
opts = set_default(opts, 'verbose',   true);
opts = set_default(opts, 'out_stem',  'SODA_poster');

[xd, ~, ~] = fileparts(xlsx_path);
if isempty(xd); xd = pwd; end
opts = set_default(opts, 'out_dir',   xd);
if exist(opts.out_dir, 'dir') ~= 7
    mkdir(opts.out_dir);
end

% ---------------------------------------------------- scenario definitions
% Each scenario: short_name, display_name, toggle struct.
% Mutual exclusion: ltv_FA and ltv_DS cannot both be 1 (load_SODA_config asserts).
default_scenarios = { ...
    struct('short','S1_baseline',          'name','Baseline (Decision Approval)', ...
           'toggles', struct()), ...
    struct('short','S2_decision_support',  'name','Decision Support (graduated LTV)', ...
           'toggles', struct('ltv_DS', 1, 'ltv_DS_pct', 100)), ...
    struct('short','S3_fully_autonomous',  'name','Fully Autonomous LTV', ...
           'toggles', struct('ltv_FA', 1, 'ltv_FA_pct', 100)), ...
    struct('short','S4_regolith',          'name','Baseline + Regolith Build-up', ...
           'toggles', struct('regolith', 1, 'regolith_pct', 50))};

opts = set_default(opts, 'scenarios', default_scenarios);
S = opts.scenarios;
nS = numel(S);

if opts.verbose
    fprintf('\n==== run_poster: %d scenarios on %s ====\n', nS, xlsx_path);
    fprintf('  out_dir : %s\n', opts.out_dir);
    fprintf('  MC N    : %d   seed: %d   ci: %.2f\n', ...
        opts.N, opts.seed, opts.ci_level);
end

% ---------------------------------------------------------- result holder
results = repmat(struct( ...
    'short','', 'name','', 'toggles',struct(), ...
    'cfg', [], ...
    'Op_det', [], 'Onet_det', NaN, 'leaf_mean_det', NaN, ...
    'centrality', table(), ...
    'closeness', [], ...
    'eig_sensitivity', [], ...
    'Onet_mc_mean', NaN, 'Onet_mc_ci_low', NaN, 'Onet_mc_ci_high', NaN, ...
    'leaf_mc_mean', NaN, 'leaf_mc_ci_low', NaN, 'leaf_mc_ci_high', NaN, ...
    'worst_knockout','', 'worst_dR_leaf', NaN, 'worst_resilience', NaN, ...
    'top_pagerank','', 'top_eigout','', 'top_closeness','', ...
    'top_eig_sensitivity','', ...
    'runtime_s', NaN), 1, nS);

% ---------------------------------------------------------- per-scenario loop
for s = 1:nS
    sc = S{s};
    t_s = tic;

    if opts.verbose
        fprintf('\n---- Scenario %d/%d: %s (%s) ----\n', s, nS, sc.name, sc.short);
    end

    % 1. Load cfg (toggles applied)
    cfg = load_SODA_config(xlsx_path, sc.toggles);

    % Output prefix for THIS scenario's artifacts
    out_pref = fullfile(opts.out_dir, [opts.out_stem '_' sc.short]);

    % 2. Deterministic baseline
    [~, info_b] = run_baseline(cfg, out_pref, ...
        struct('verbose', opts.verbose));
    Op_det        = info_b.Op;
    Onet_det      = info_b.Onet;
    leaf_mean_det = info_b.leaf_mean;

    % 3. Centrality (eigenvector / Katz / PageRank / Hubs / Authorities)
    cent_params = struct('verbose', opts.verbose, 'plot', opts.plot);
    cent = run_centrality_cfg(cfg, out_pref, cent_params);

    % 3b. Closeness on the SOD-weighted digraph (added per meeting notes)
    closeness = compute_closeness(cfg);

    % 3c. Eigenvector sensitivity (per-node L2 shift under +/-10% edge perturb)
    eig_sens = compute_eig_sensitivity(cfg, ...
        struct('eps_pct', 0.10, 'verbose', false));

    % 4. Monte Carlo
    mc_params = struct( ...
        'N',        opts.N, ...
        'seed',     opts.seed, ...
        'ci_level', opts.ci_level, ...
        'plot',     opts.plot, ...
        'verbose',  opts.verbose);
    [dist, mc_info] = run_mc(cfg, out_pref, mc_params); %#ok<ASGLU>
    Onet_mc        = mc_info.summary_mat(1, 1);
    Onet_mc_lo     = mc_info.summary_mat(1, 3);
    Onet_mc_hi     = mc_info.summary_mat(1, 4);
    leaf_mc        = mc_info.summary_mat(2, 1);
    leaf_mc_lo     = mc_info.summary_mat(2, 3);
    leaf_mc_hi     = mc_info.summary_mat(2, 4);

    % 5. Robustness sweep (single-node knockout)
    rob_params = struct('plot', opts.plot, 'verbose', opts.verbose);
    [~, rob_info] = run_robustness_cfg(cfg, out_pref, rob_params);

    % --- top-1 by selected metrics (for the headline summary)
    top_pr = top_label(cent.pagerank,  cfg.labels);
    top_ev = top_label(cent.eig_out,   cfg.labels);
    top_cl = top_label(closeness,      cfg.labels);
    top_es = top_label(eig_sens,       cfg.labels);

    % --- store
    results(s).short            = sc.short;
    results(s).name             = sc.name;
    results(s).toggles          = cfg.toggles;
    results(s).cfg              = cfg;
    results(s).Op_det           = Op_det;
    results(s).Onet_det         = Onet_det;
    results(s).leaf_mean_det    = leaf_mean_det;
    results(s).centrality       = cent;
    results(s).closeness        = closeness;
    results(s).eig_sensitivity  = eig_sens;
    results(s).Onet_mc_mean     = Onet_mc;
    results(s).Onet_mc_ci_low   = Onet_mc_lo;
    results(s).Onet_mc_ci_high  = Onet_mc_hi;
    results(s).leaf_mc_mean     = leaf_mc;
    results(s).leaf_mc_ci_low   = leaf_mc_lo;
    results(s).leaf_mc_ci_high  = leaf_mc_hi;
    results(s).worst_knockout   = rob_info.worst_label;
    results(s).worst_dR_leaf    = rob_info.worst_dR_leaf;
    results(s).worst_resilience = rob_info.worst_resilience;
    results(s).top_pagerank        = top_pr;
    results(s).top_eigout          = top_ev;
    results(s).top_closeness       = top_cl;
    results(s).top_eig_sensitivity = top_es;
    results(s).runtime_s           = toc(t_s);

    if opts.verbose
        fprintf('  -> Onet_det=%.2f  Onet_mc=%.2f [%.2f, %.2f]  worst KO=%s\n', ...
            Onet_det, Onet_mc, Onet_mc_lo, Onet_mc_hi, rob_info.worst_label);
        fprintf('  scenario runtime: %.1fs\n', results(s).runtime_s);
    end
end

% ---------------------------------------------------------- summary table
summary = build_summary_table(results);
if opts.verbose
    fprintf('\n==== Comparative summary ====\n');
    disp(summary);
end

% ---------------------------------------------------------- write summary
sum_xlsx = fullfile(opts.out_dir, [opts.out_stem '_summary.xlsx']);
write_summary_xlsx(sum_xlsx, results, summary);
if opts.verbose; fprintf('Saved: %s\n', sum_xlsx); end

% ---------------------------------------------------------- summary plot
if opts.plot
    sum_png = fullfile(opts.out_dir, [opts.out_stem '_summary.png']);
    plot_summary(sum_png, results);
    if opts.verbose; fprintf('Saved: %s\n', sum_png); end
end

if opts.verbose
    fprintf('\nrun_poster done. %d scenarios in %.1fs total.\n', ...
        nS, sum([results.runtime_s]));
end
end


% ======================================================================
function P = set_default(P, name, val)
if ~isfield(P, name) || isempty(P.(name))
    P.(name) = val;
end
end

% ======================================================================
function lbl = top_label(scores, labels)
[~, k] = max(scores);
lbl = labels{k};
end

% ======================================================================
function c = compute_closeness(cfg)
% Closeness centrality on the SOD-weighted digraph (incoming).
% Falls back to graph-theoretic closeness via MATLAB's centrality()
% on a digraph built from |SOD| > 0, weighted by 1 ./ (SOD .* COD/100)
% (cost = inverse of edge strength). Returns a column vector length n.
n   = cfg.n;
SOD = cfg.SOD;
COD = cfg.COD;
A   = double(abs(SOD) > 0);
[ii, jj] = find(A);
if isempty(ii)
    c = zeros(n, 1);
    return;
end
W = abs(SOD(sub2ind(size(SOD), ii, jj))) .* (COD(sub2ind(size(COD), ii, jj)) / 100);
% Cost = 1/strength; clip strengths near zero
W(W <= 0) = 1e-6;
costs = 1 ./ W;
G = digraph(ii, jj, costs, n);
% 'incloseness' weights distances using G.Edges.Weight by default
try
    c = centrality(G, 'incloseness', 'Cost', G.Edges.Weight);
catch
    c = centrality(G, 'incloseness');
end
c = c(:);
end

% ======================================================================
function T = build_summary_table(results)
nS = numel(results);
name           = strings(nS, 1);
Onet_det       = zeros(nS, 1);
leaf_mean_det  = zeros(nS, 1);
Onet_mc_mean   = zeros(nS, 1);
Onet_mc_ci_low = zeros(nS, 1);
Onet_mc_ci_high= zeros(nS, 1);
worst_KO       = strings(nS, 1);
worst_dR_leaf  = zeros(nS, 1);
worst_resilience = zeros(nS, 1);
top_pr         = strings(nS, 1);
top_ev         = strings(nS, 1);
top_cl         = strings(nS, 1);
top_es         = strings(nS, 1);
runtime_s      = zeros(nS, 1);
for s = 1:nS
    name(s)             = string(results(s).name);
    Onet_det(s)         = results(s).Onet_det;
    leaf_mean_det(s)    = results(s).leaf_mean_det;
    Onet_mc_mean(s)     = results(s).Onet_mc_mean;
    Onet_mc_ci_low(s)   = results(s).Onet_mc_ci_low;
    Onet_mc_ci_high(s)  = results(s).Onet_mc_ci_high;
    worst_KO(s)         = string(results(s).worst_knockout);
    worst_dR_leaf(s)    = results(s).worst_dR_leaf;
    worst_resilience(s) = results(s).worst_resilience;
    top_pr(s)           = string(results(s).top_pagerank);
    top_ev(s)           = string(results(s).top_eigout);
    top_cl(s)           = string(results(s).top_closeness);
    top_es(s)           = string(results(s).top_eig_sensitivity);
    runtime_s(s)        = results(s).runtime_s;
end
T = table(name, Onet_det, leaf_mean_det, ...
    Onet_mc_mean, Onet_mc_ci_low, Onet_mc_ci_high, ...
    worst_KO, worst_dR_leaf, worst_resilience, ...
    top_pr, top_ev, top_cl, top_es, runtime_s);
end

% ======================================================================
function write_summary_xlsx(path, results, summary)
% Sheet 1: Summary  (the comparative headline)
hdr = summary.Properties.VariableNames;
cell_summary = [hdr; table2cell(summary)];
write_xlsx_safe(path, cell_summary, 'Summary');

% Sheet 2: Per-node deterministic Op for every scenario
n      = results(1).cfg.n;
labels = results(1).cfg.labels;
nS = numel(results);
op_hdr = [{'idx','label'}, arrayfun(@(s) results(s).short, 1:nS, ...
    'UniformOutput', false)];
op_cell = cell(n + 1, numel(op_hdr));
op_cell(1, :) = op_hdr;
for i = 1:n
    op_cell{i+1, 1} = i;
    op_cell{i+1, 2} = labels{i};
    for s = 1:nS
        op_cell{i+1, 2+s} = results(s).Op_det(i);
    end
end
write_xlsx_safe(path, op_cell, 'Op_det_per_node');

% Sheet 3: Per-node centrality stack (PageRank only, for poster brevity)
pr_hdr = [{'idx','label'}, arrayfun(@(s) results(s).short, 1:nS, ...
    'UniformOutput', false)];
pr_cell = cell(n + 1, numel(pr_hdr));
pr_cell(1, :) = pr_hdr;
for i = 1:n
    pr_cell{i+1, 1} = i;
    pr_cell{i+1, 2} = labels{i};
    for s = 1:nS
        pr_cell{i+1, 2+s} = results(s).centrality.pagerank(i);
    end
end
write_xlsx_safe(path, pr_cell, 'PageRank_per_node');

% Sheet 4: Closeness per node per scenario
cl_hdr = pr_hdr;
cl_cell = cell(n + 1, numel(cl_hdr));
cl_cell(1, :) = cl_hdr;
for i = 1:n
    cl_cell{i+1, 1} = i;
    cl_cell{i+1, 2} = labels{i};
    for s = 1:nS
        cl_cell{i+1, 2+s} = results(s).closeness(i);
    end
end
write_xlsx_safe(path, cl_cell, 'Closeness_per_node');

% Sheet 5: Eigenvector sensitivity per node per scenario
es_hdr = pr_hdr;
es_cell = cell(n + 1, numel(es_hdr));
es_cell(1, :) = es_hdr;
for i = 1:n
    es_cell{i+1, 1} = i;
    es_cell{i+1, 2} = labels{i};
    for s = 1:nS
        es_cell{i+1, 2+s} = results(s).eig_sensitivity(i);
    end
end
write_xlsx_safe(path, es_cell, 'EigSensitivity_per_node');

% Sheet 6: Toggle echo + events log per scenario
ev_rows = {'scenario', 'short', 'crew3', 'ltv_FA', 'ltv_DS', ...
           'regolith', 'regolith_pct', 'events_log'};
ev_cell = cell(nS + 1, numel(ev_rows));
ev_cell(1, :) = ev_rows;
for s = 1:nS
    t = results(s).cfg.toggles;
    ev_cell{s+1, 1} = results(s).name;
    ev_cell{s+1, 2} = results(s).short;
    ev_cell{s+1, 3} = t.crew3;
    ev_cell{s+1, 4} = t.ltv_FA;
    ev_cell{s+1, 5} = t.ltv_DS;
    ev_cell{s+1, 6} = t.regolith;
    ev_cell{s+1, 7} = t.regolith_pct;
    ev_cell{s+1, 8} = strjoin(results(s).cfg.events_log, ' | ');
end
write_xlsx_safe(path, ev_cell, 'Toggles_and_events');
end

% ======================================================================
function plot_summary(png_out, results)
% 1x2 figure: (a) Onet_det vs scenario with MC CI error bars,
%             (b) worst-node dR_leaf bar, scenario-colored.
nS = numel(results);
xs = 1:nS;
Onet_det = arrayfun(@(s) results(s).Onet_det,        1:nS);
Onet_mc  = arrayfun(@(s) results(s).Onet_mc_mean,    1:nS);
ci_lo    = arrayfun(@(s) results(s).Onet_mc_ci_low,  1:nS);
ci_hi    = arrayfun(@(s) results(s).Onet_mc_ci_high, 1:nS);
dR       = arrayfun(@(s) results(s).worst_dR_leaf,   1:nS);
names    = arrayfun(@(s) results(s).short, 1:nS, 'UniformOutput', false);
worst    = arrayfun(@(s) results(s).worst_knockout, 1:nS, ...
    'UniformOutput', false);

fig = figure('Position',[100 100 1400 600], 'Visible','off', 'Color','w');

subplot(1, 2, 1);
bar(xs, Onet_det, 0.55, 'FaceColor', [0.30 0.50 0.85], ...
    'EdgeColor', 'none'); hold on;
errorbar(xs, Onet_mc, Onet_mc - ci_lo, ci_hi - Onet_mc, 'k.', ...
    'LineWidth', 1.4, 'CapSize', 10);
set(gca, 'XTick', xs, 'XTickLabel', names, ...
    'TickLabelInterpreter','none', 'FontSize', 10);
xtickangle(20);
ylim([0 100]); ylabel('O_{net} (network operability)'); grid on;
title('Network operability per scenario  (bar = deterministic; error = MC 95% CI)');

subplot(1, 2, 2);
b = bar(xs, dR, 0.55, 'FaceColor', [0.80 0.22 0.22], 'EdgeColor', 'none');
set(gca, 'XTick', xs, 'XTickLabel', names, ...
    'TickLabelInterpreter','none', 'FontSize', 10);
xtickangle(20);
ylabel('Worst single-node knockout: \Delta R_{leaf}'); grid on;
title('Worst-case single-node knockout per scenario');
% Annotate each bar with the worst node name
for s = 1:nS
    text(s, dR(s), [' ' worst{s}], 'Rotation', 90, 'FontSize', 9, ...
        'VerticalAlignment','bottom', 'HorizontalAlignment','left', ...
        'Interpreter','none');
end

if exist('exportgraphics','file') == 2 || exist('exportgraphics','builtin') == 5
    exportgraphics(fig, png_out, 'Resolution', 150);
else
    print(fig, png_out, '-dpng', '-r150');
end
close(fig);
end

% ======================================================================
function write_xlsx_safe(path, cell_data, sheet)
if exist('writecell', 'builtin') || exist('writecell', 'file')
    writecell(cell_data, path, 'Sheet', sheet);
else
    try
        xlswrite(path, cell_data, sheet);
    catch
        javaaddpath(fullfile('xlwrite', 'poi_library', 'poi-3.8-20120326.jar'));
        javaaddpath(fullfile('xlwrite', 'poi_library', ...
            'poi-ooxml-3.8-20120326.jar'));
        javaaddpath(fullfile('xlwrite', 'poi_library', ...
            'poi-ooxml-schemas-3.8-20120326.jar'));
        xlwrite(path, cell_data, sheet);
    end
end
end
