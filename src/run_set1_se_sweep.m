function [results, info] = run_set1_se_sweep(xlsx_path, opts)
%RUN_SET1_SE_SWEEP  Joel's Set 1 experiment: drop one Crew member's SE to
% a low value (default 15) and compare Mission Effectiveness vs Baseline.
%
% Scenarios (per Recap 27Apr26):
%   Baseline : all crew at Beta(5,2) per the new file (no override).
%   S1       : Crew1 OODA SE pinned to 15 (deterministic), with uniform
%              +/-10 jitter at MC time. Other crew remain Beta(5,2).
%   S2       : same as S1 but for Crew2.
%   S3 (opt) : Crew3 also dropped (only meaningful when toggles.crew3 = 1).
%
% Each scenario runs through run_mc with N replications. Results are
% written to a single comparison XLSX and PNG so the poster has a clean
% Baseline / S1 / S2 panel.
%
% Inputs
% ------
%   xlsx_path : path to SODA_configurations_input.xlsx
%   opts      : struct (all optional)
%     .out_dir       output directory (default: same as xlsx)
%     .out_stem      output filename stem (default: 'SODA_set1')
%     .toggles       toggle struct passed to load_SODA_config (default:
%                    Decision-Approval LTV, no Crew3, no Regolith)
%     .drop_value    SE pin (default 15)
%     .unif_jitter   uniform half-width on dropped Crew (default 10)
%     .N             MC replications per scenario (default 2000)
%     .seed          base RNG seed (default 20260503)
%     .ci_level      0..1 (default 0.95)
%     .include_S3    true to also run S3 if Crew3 toggle is on (default true)
%
% Outputs
% -------
%   results : struct array, one entry per scenario, with fields
%     .name (Baseline/S1/S2/S3), .toggles, .overrides, .summary, .Onet,
%     .leaf_mean, .leaf_min, .Op_mean, .Op_ci_low, .Op_ci_high
%   info    : echo of opts + comparison table
%
% Files written:
%   <out_stem>_compare.xlsx  (sheet per scenario + 'compare')
%   <out_stem>_compare.png   (Onet + leaf bars across scenarios)

if nargin < 1 || isempty(xlsx_path)
    xlsx_path = 'SODA_configurations_input.xlsx';
end
assert(exist(xlsx_path, 'file') == 2, 'XLSX not found: %s', xlsx_path);

if nargin < 2 || isempty(opts); opts = struct(); end
opts = default_opts(opts, xlsx_path);

scen = {};
scen{end+1} = struct('name','Baseline', 'crew', '');
scen{end+1} = struct('name','S1',       'crew', 'Crew1');
scen{end+1} = struct('name','S2',       'crew', 'Crew2');
if opts.include_S3 && opts.toggles.crew3 == 1
    scen{end+1} = struct('name','S3',   'crew', 'Crew3');
end
nS = numel(scen);

stem_out = fullfile(opts.out_dir, opts.out_stem);
xlsx_out = [stem_out '_compare.xlsx'];
png_out  = [stem_out '_compare.png'];

results = repmat(struct(), 1, nS);
fprintf('\nrun_set1_se_sweep: %d scenarios, N=%d each\n', nS, opts.N);

for s = 1:nS
    name = scen{s}.name;
    crew = scen{s}.crew;
    fprintf('\n----- Scenario %s -----\n', name);

    if isempty(crew)
        cfg = load_SODA_config(xlsx_path, opts.toggles);
        jitter_nodes = {};
    else
        % Pin all 4 OODA nodes of the chosen crew to drop_value (deterministic)
        ovr = make_se_drop_overrides({[crew '_Obs'],[crew '_Ori'], ...
                                      [crew '_Dec'],[crew '_Act']}, opts.drop_value);
        cfg = load_SODA_config(xlsx_path, opts.toggles, ovr);
        jitter_nodes = {[crew '_']};
    end

    % MC params for this scenario
    mc_params = struct();
    mc_params.N            = opts.N;
    mc_params.seed         = opts.seed + s;        % distinct stream per scenario
    mc_params.unif_jitter  = opts.unif_jitter * ~isempty(crew); % zero on Baseline
    mc_params.jitter_nodes = jitter_nodes;
    mc_params.ci_level     = opts.ci_level;
    mc_params.plot         = false;                 % combined plot at the end
    mc_params.verbose      = false;

    [dist, mc_info] = run_mc(cfg, '', mc_params);

    R = struct();
    R.name        = name;
    R.crew        = crew;
    R.cfg_summary = sprintf('crew3=%d FA=%d DS=%d rego=%d', ...
        cfg.toggles.crew3, cfg.toggles.ltv_FA, cfg.toggles.ltv_DS, ...
        cfg.toggles.regolith);
    R.summary_mat = mc_info.summary_mat;            % 3x6
    R.metric_names= mc_info.metric_names{1};
    R.Onet        = dist.Onet;
    R.leaf_mean   = dist.leaf_mean;
    R.leaf_min    = dist.leaf_min;
    R.Op_mean     = mean(dist.Op, 1);
    R.Op_std      = std(dist.Op, 0, 1);
    alpha = 1 - opts.ci_level;
    R.Op_ci_low   = quantile(dist.Op, alpha/2,     1);
    R.Op_ci_high  = quantile(dist.Op, 1 - alpha/2, 1);
    R.labels      = cfg.labels;
    R.leaves      = cfg.leaves;
    R.toggles     = cfg.toggles;
    R.events_log  = cfg.events_log;
    results(s)    = R;

    fprintf('  Onet      mean=%.2f  CI=[%.2f, %.2f]\n', ...
        R.summary_mat(1,1), R.summary_mat(1,3), R.summary_mat(1,4));
    fprintf('  leaf_mean mean=%.2f  CI=[%.2f, %.2f]\n', ...
        R.summary_mat(2,1), R.summary_mat(2,3), R.summary_mat(2,4));
    fprintf('  leaf_min  mean=%.2f  CI=[%.2f, %.2f]\n', ...
        R.summary_mat(3,1), R.summary_mat(3,3), R.summary_mat(3,4));
end

% --------------------------------------------- comparison XLSX
labels = results(1).labels;
n      = numel(labels);
leaves = results(1).leaves;

% 'compare' sheet: one row per scenario with the 3 network-level metrics
comp_hdr = {'scenario','crew_dropped','drop_value','unif_jitter', ...
            'Onet_mean','Onet_ci_low','Onet_ci_high', ...
            'leaf_mean_mean','leaf_mean_ci_low','leaf_mean_ci_high', ...
            'leaf_min_mean','leaf_min_ci_low','leaf_min_ci_high', ...
            'cfg_summary'};
comp_cell = [comp_hdr; cell(nS, numel(comp_hdr))];
for s = 1:nS
    R = results(s);
    comp_cell{s+1, 1}  = R.name;
    comp_cell{s+1, 2}  = R.crew;
    comp_cell{s+1, 3}  = opts.drop_value * ~isempty(R.crew);
    comp_cell{s+1, 4}  = opts.unif_jitter * ~isempty(R.crew);
    comp_cell{s+1, 5}  = R.summary_mat(1,1);
    comp_cell{s+1, 6}  = R.summary_mat(1,3);
    comp_cell{s+1, 7}  = R.summary_mat(1,4);
    comp_cell{s+1, 8}  = R.summary_mat(2,1);
    comp_cell{s+1, 9}  = R.summary_mat(2,3);
    comp_cell{s+1, 10} = R.summary_mat(2,4);
    comp_cell{s+1, 11} = R.summary_mat(3,1);
    comp_cell{s+1, 12} = R.summary_mat(3,3);
    comp_cell{s+1, 13} = R.summary_mat(3,4);
    comp_cell{s+1, 14} = R.cfg_summary;
end
write_xlsx_safe(xlsx_out, comp_cell, 'compare');

% per-leaf comparison (Op_mean +/- CI for each leaf node, one column per scenario)
leaf_names = labels(leaves);
nL = numel(leaves);
leaf_hdr = [{'leaf'}, reshape([ ...
    strcat({'_'}, {'mean'}); ...
    strcat({'_'}, {'ci_low'}); ...
    strcat({'_'}, {'ci_high'})], 1, [])];
% Build header: scenario_mean / scenario_ci_low / scenario_ci_high columns
leaf_hdr = {'leaf'};
for s = 1:nS
    leaf_hdr{end+1} = [results(s).name '_mean'];
    leaf_hdr{end+1} = [results(s).name '_ci_low'];
    leaf_hdr{end+1} = [results(s).name '_ci_high'];
end
leaf_cell = [leaf_hdr; cell(nL, numel(leaf_hdr))];
for k = 1:nL
    li = leaves(k);
    leaf_cell{k+1, 1} = leaf_names{k};
    col = 2;
    for s = 1:nS
        R = results(s);
        leaf_cell{k+1, col}     = R.Op_mean(li);
        leaf_cell{k+1, col+1}   = R.Op_ci_low(li);
        leaf_cell{k+1, col+2}   = R.Op_ci_high(li);
        col = col + 3;
    end
end
write_xlsx_safe(xlsx_out, leaf_cell, 'leaves');

% per-scenario sheets (full per-node detail)
for s = 1:nS
    R = results(s);
    pn_hdr = {'idx','label','SE_type','Op_mean','Op_std','Op_ci_low','Op_ci_high','IsLeaf'};
    pn_cell = [pn_hdr; cell(n, numel(pn_hdr))];
    for i = 1:n
        pn_cell{i+1,1} = i;
        pn_cell{i+1,2} = labels{i};
        pn_cell{i+1,3} = R.toggles.crew3;     % placeholder; SE_type not stored per-node here
        pn_cell{i+1,4} = R.Op_mean(i);
        pn_cell{i+1,5} = R.Op_std(i);
        pn_cell{i+1,6} = R.Op_ci_low(i);
        pn_cell{i+1,7} = R.Op_ci_high(i);
        pn_cell{i+1,8} = double(ismember(i, leaves));
    end
    write_xlsx_safe(xlsx_out, pn_cell, sprintf('per_node_%s', R.name));
end

fprintf('\nSaved: %s\n', xlsx_out);

% --------------------------------------------- comparison PNG
plot_set1_compare(png_out, results, leaves, labels, opts);
fprintf('Saved: %s\n', png_out);

% --------------------------------------------- info
info = opts;
info.xlsx_path  = xlsx_path;
info.scenarios  = {results.name};
info.timestamp  = datestr(now, 'yyyy-mm-dd HH:MM:SS'); %#ok<DATST,TNOW1>
end


% ======================================================================
function opts = default_opts(opts, xlsx_path)
[xd, xb, ~] = fileparts(xlsx_path);
if isempty(xd); xd = pwd; end
defaults = struct( ...
    'out_dir',     xd, ...
    'out_stem',    [strrep(xb, '_input', '') '_set1'], ...
    'toggles',     struct(), ...     % default Decision-Approval LTV
    'drop_value',  15, ...
    'unif_jitter', 10, ...
    'N',           2000, ...
    'seed',        20260503, ...
    'ci_level',    0.95, ...
    'include_S3',  true);
fn = fieldnames(defaults);
for k = 1:numel(fn)
    if ~isfield(opts, fn{k}) || (isempty(opts.(fn{k})) && ~isstruct(opts.(fn{k})))
        opts.(fn{k}) = defaults.(fn{k});
    end
end
end

% ======================================================================
function ovr = make_se_drop_overrides(node_names, value)
ovr = struct('target',{},'feeder',{},'receiver',{},'value',{});
for k = 1:numel(node_names)
    ovr(end+1) = struct('target','SE_type', ...
        'feeder', node_names{k}, 'receiver','', 'value','D'); %#ok<AGROW>
    ovr(end+1) = struct('target','SE_value', ...
        'feeder', node_names{k}, 'receiver','', 'value', value); %#ok<AGROW>
end
end

% ======================================================================
function plot_set1_compare(png_out, results, leaves, labels, opts) %#ok<INUSL>
nS = numel(results);
fig = figure('Position',[100 100 1400 900], 'Visible','off', 'Color','w');

% Top-left: Onet histograms overlaid
subplot(2,2,1); hold on; grid on;
clr = lines(nS);
for s = 1:nS
    histogram(results(s).Onet, 25, 'FaceColor', clr(s,:), 'FaceAlpha', 0.5, ...
        'EdgeColor', 'none', 'DisplayName', results(s).name);
end
xlabel('O_{net}'); ylabel('count');
title('Mission Effectiveness (O_{net}) by scenario');
legend('Location','best');

% Top-right: bar chart of Onet mean +/- CI per scenario
subplot(2,2,2); hold on; grid on;
xs = 1:nS;
mu  = arrayfun(@(R) R.summary_mat(1,1), results);
lo  = arrayfun(@(R) R.summary_mat(1,3), results);
hi  = arrayfun(@(R) R.summary_mat(1,4), results);
bar(xs, mu, 'FaceColor', [0.4 0.6 0.85], 'EdgeColor', 'none');
errorbar(xs, mu, mu-lo, hi-mu, 'k', 'LineStyle','none', 'CapSize', 10);
set(gca, 'XTick', xs, 'XTickLabel', {results.name});
ylabel('O_{net}  (mean +/- 95%% CI)');
title('Onet mean +/- CI');

% Bottom-left: per-leaf grouped bars (mean by scenario)
subplot(2,2,3); hold on; grid on;
nL = numel(leaves);
M = zeros(nL, nS);
LO = zeros(nL, nS); HI = zeros(nL, nS);
for s = 1:nS
    R = results(s);
    M(:, s)  = R.Op_mean(leaves);
    LO(:, s) = R.Op_ci_low(leaves);
    HI(:, s) = R.Op_ci_high(leaves);
end
b = bar(M, 'grouped');
for s = 1:nS; b(s).FaceColor = clr(s,:); b(s).EdgeColor = 'none'; end
% error bars on grouped bars
ngroups = size(M,1); nbars = size(M,2);
groupwidth = min(0.8, nbars/(nbars+1.5));
for s = 1:nbars
    x = (1:ngroups) - groupwidth/2 + (2*s-1)*groupwidth/(2*nbars);
    errorbar(x, M(:,s), M(:,s)-LO(:,s), HI(:,s)-M(:,s), 'k', ...
        'LineStyle','none', 'CapSize', 4);
end
set(gca, 'XTick', 1:nL, 'XTickLabel', labels(leaves));
xtickangle(30);
ylabel('Op (mean +/- 95%% CI)');
title('Per-leaf Op by scenario');
legend({results.name}, 'Location','best');

% Bottom-right: leaf_mean histograms overlaid
subplot(2,2,4); hold on; grid on;
for s = 1:nS
    histogram(results(s).leaf_mean, 25, 'FaceColor', clr(s,:), 'FaceAlpha', 0.5, ...
        'EdgeColor', 'none', 'DisplayName', results(s).name);
end
xlabel('mean Op over leaves'); ylabel('count');
title('Leaf mean by scenario');
legend('Location','best');

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
