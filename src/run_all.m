function run_all(xlsx_path, opts)
%RUN_ALL  End-to-end driver for the AAE 560 final-deliverable network.
% Loads cfg, runs the deterministic baseline, eigenvector-family centralities,
% and the two parametric experiments (Set 1 SE drop, Set 2 LTV-dependency
% sweep). Produces every artifact needed for the poster + report.
%
% Outputs (next to xlsx_path):
%   SODA_configurations_baseline_results.xlsx / _nodes.csv / _edges.csv
%   SODA_configurations_baseline_centrality.xlsx / _centrality_nodes.csv
%   SODA_configurations_baseline_centrality.png
%   SODA_configurations_set1_compare.xlsx / .png
%   SODA_configurations_set2_compare.xlsx / .png
%
% Usage (from Project/Code):
%   >> addpath('SODA_2.2_pcode')
%   >> run_all('../SODA_configurations_input.xlsx')
%
% Override defaults (e.g., faster MC for a smoke test):
%   >> opts.N = 200;  opts.toggles.crew3 = 1;
%   >> run_all('../SODA_configurations_input.xlsx', opts);

if nargin < 1 || isempty(xlsx_path)
    xlsx_path = 'SODA_configurations_input.xlsx';
end
if nargin < 2 || isempty(opts); opts = struct(); end

% Defaults
if ~isfield(opts, 'toggles');  opts.toggles  = struct(); end       % default LTV
if ~isfield(opts, 'N');        opts.N        = 2000; end
if ~isfield(opts, 'seed');     opts.seed     = 20260503; end
if ~isfield(opts, 'ci_level'); opts.ci_level = 0.95; end

[xd, xb, ~] = fileparts(xlsx_path);
if isempty(xd); xd = pwd; end
stem = strrep(xb, '_input', '');           % e.g. 'SODA_configurations'

t_total = tic;

% ---------------------------------------- 1. Deterministic baseline
fprintf('\n========= 1. Deterministic baseline =========\n');
cfg = load_SODA_config(xlsx_path, opts.toggles);
out_pref_base = fullfile(xd, [stem '_baseline']);
[~, info_b] = run_baseline(cfg, out_pref_base);
fprintf('  Onet = %.2f  leaf_mean = %.2f  (runtime %.2fs)\n', ...
    info_b.Onet, info_b.leaf_mean, info_b.runtime_s);

% ---------------------------------------- 2. Centrality
fprintf('\n========= 2. Centrality on baseline =========\n');
run_centrality_cfg(cfg, out_pref_base, struct('verbose', false));

% ---------------------------------------- 3. Set 1: SE drop sweep
fprintf('\n========= 3. Set 1: SE drop (Crew1 / Crew2) =========\n');
set1_opts = struct( ...
    'out_dir',    xd, ...
    'out_stem',   [stem '_set1'], ...
    'toggles',    opts.toggles, ...
    'N',          opts.N, ...
    'seed',       opts.seed, ...
    'ci_level',   opts.ci_level);
run_set1_se_sweep(xlsx_path, set1_opts);

% ---------------------------------------- 4. Set 2: LTV dependency sweep
fprintf('\n========= 4. Set 2: LTV-dependency sweep =========\n');
set2_opts = struct( ...
    'out_dir',    xd, ...
    'out_stem',   [stem '_set2'], ...
    'toggles',    opts.toggles, ...
    'N',          opts.N, ...
    'seed',       opts.seed, ...
    'ci_level',   opts.ci_level);
run_set2_dep_sweep(xlsx_path, set2_opts);

fprintf('\nAll done in %.1f s.\n', toc(t_total));
end
