function [results, info] = run_set2_dep_sweep(xlsx_path, opts)
%RUN_SET2_DEP_SWEEP  Joel's Set 2 experiment: vary the SOD/COD/IOD on the
% LTV_Ori -> Crew_Dec edge (LTV's route-planning influence on the crew),
% and compare Mission Effectiveness across Reduced / Baseline / Increased.
%
% Frames how heavily the crew leans on the LTV's autonomous route plan
% (low SOD/COD/IOD = crew prefers to plan themselves; high = crew defers
% to LTV). Treated as a measure of effective Human-Machine Teaming.
%
% Default sweep levels (from Recap 27Apr26):
%   Reduced  : SOD=0.2, COD=25, IOD=25
%   Baseline : SOD=0.5, COD=50, IOD=50  (matches Default Network Metrics
%              for SOD/COD; IOD default is 70 in the file but 50 in Joel's
%              spec -- we use Joel's spec for the comparison.)
%   Increased: SOD=0.9, COD=75, IOD=75
%
% Receivers: by default, sweeps the LTV_Ori -> Crew1_Dec edge (the only
% one in the default network). With opts.receivers you can sweep the
% same edge into Crew2_Dec / Crew3_Dec as well, if those edges are
% intended to exist in the variant under test.
%
% Inputs
% ------
%   xlsx_path : path to SODA_configurations_input.xlsx
%   opts      : struct (all optional)
%     .out_dir       output dir (default: same as xlsx)
%     .out_stem      output stem (default: 'SODA_set2')
%     .toggles       toggles for load_SODA_config (default: defaults)
%     .levels        Mx3 numeric [SOD COD IOD]  (default 3 levels above)
%     .level_names   1xM cellstr labels         (default {'Reduced','Baseline','Increased'})
%     .feeder        single feeder label    (default 'LTV_Ori')
%     .receivers     cellstr of receivers   (default {'Crew1_Dec'})
%     .N             MC reps per scenario   (default 2000)
%     .seed          base RNG seed          (default 20260503)
%     .ci_level      0..1                   (default 0.95)
%
% Outputs
% -------
%   results : struct array, one per level, with summary_mat, distributions,
%             per-node Op mean/CI, etc.
%   info    : echo of opts + scenario list
%
% Files written:
%   <out_stem>_compare.xlsx  (compare + leaves + per_node_*)
%   <out_stem>_compare.png   (Onet/leaf bars across levels + dose-response)

if nargin < 1 || isempty(xlsx_path)
    xlsx_path = 'SODA_configurations_input.xlsx';
end
assert(exist(xlsx_path, 'file') == 2, 'XLSX not found: %s', xlsx_path);

if nargin < 2 || isempty(opts); opts = struct(); end
opts = default_opts(opts, xlsx_path);

levels      = opts.levels;            % M x 3
level_names = opts.level_names;       % 1 x M
M           = size(levels, 1);
assert(numel(level_names) == M, 'levels and level_names size mismatch');

stem_out = fullfile(opts.out_dir, opts.out_stem);
xlsx_out = [stem_out '_compare.xlsx'];
png_out  = [stem_out '_compare.png'];

results = repmat(struct(), 1, M);
fprintf('\nrun_set2_dep_sweep: %d levels x %d receiver(s) (N=%d each)\n', ...
    M, numel(opts.receivers), opts.N);

for s = 1:M
    nm  = level_names{s};
    sod = levels(s, 1); cod = levels(s, 2); iod = levels(s, 3);
    fprintf('\n----- Level %s (SOD=%.2f COD=%.0f IOD=%.0f) -----\n', ...
        nm, sod, cod, iod);

    % Build override list: same SOD/COD/IOD on every requested receiver
    ovr = struct('target',{},'feeder',{},'receiver',{},'value',{});
    for r = 1:numel(opts.receivers)
        rcv = opts.receivers{r};
        ovr(end+1) = struct('target','SOD','feeder',opts.feeder, ...
            'receiver',rcv,'value',sod); %#ok<AGROW>
        ovr(end+1) = struct('target','COD','feeder',opts.feeder, ...
            'receiver',rcv,'value',cod); %#ok<AGROW>
        ovr(end+1) = struct('target','IOD','feeder',opts.feeder, ...
            'receiver',rcv,'value',iod); %#ok<AGROW>
    end

    cfg = load_SODA_config(xlsx_path, opts.toggles, ovr);

    mc_params = struct( ...
        'N',           opts.N, ...
        'seed',        opts.seed + s, ...
        'ci_level',    opts.ci_level, ...
        'plot',        false, ...
        'verbose',     false);
    [dist, mc_info] = run_mc(cfg, '', mc_params);

    R = struct();
    R.name        = nm;
    R.sod         = sod; R.cod = cod; R.iod = iod;
    R.summary_mat = mc_info.summary_mat;
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
end

% --------------------------------------------- comparison XLSX
labels = results(1).labels;
n      = numel(labels);
leaves = results(1).leaves;

comp_hdr = {'level','SOD','COD','IOD','feeder','receivers', ...
    'Onet_mean','Onet_ci_low','Onet_ci_high', ...
    'leaf_mean_mean','leaf_mean_ci_low','leaf_mean_ci_high', ...
    'leaf_min_mean','leaf_min_ci_low','leaf_min_ci_high'};
comp_cell = [comp_hdr; cell(M, numel(comp_hdr))];
recv_str  = strjoin(opts.receivers, '|');
for s = 1:M
    R = results(s);
    comp_cell{s+1, 1}  = R.name;
    comp_cell{s+1, 2}  = R.sod;
    comp_cell{s+1, 3}  = R.cod;
    comp_cell{s+1, 4}  = R.iod;
    comp_cell{s+1, 5}  = opts.feeder;
    comp_cell{s+1, 6}  = recv_str;
    comp_cell{s+1, 7}  = R.summary_mat(1,1);
    comp_cell{s+1, 8}  = R.summary_mat(1,3);
    comp_cell{s+1, 9}  = R.summary_mat(1,4);
    comp_cell{s+1, 10} = R.summary_mat(2,1);
    comp_cell{s+1, 11} = R.summary_mat(2,3);
    comp_cell{s+1, 12} = R.summary_mat(2,4);
    comp_cell{s+1, 13} = R.summary_mat(3,1);
    comp_cell{s+1, 14} = R.summary_mat(3,3);
    comp_cell{s+1, 15} = R.summary_mat(3,4);
end
write_xlsx_safe(xlsx_out, comp_cell, 'compare');

% per-leaf table
leaf_hdr = {'leaf'};
for s = 1:M
    leaf_hdr{end+1} = [results(s).name '_mean'];
    leaf_hdr{end+1} = [results(s).name '_ci_low'];
    leaf_hdr{end+1} = [results(s).name '_ci_high'];
end
leaf_cell = [leaf_hdr; cell(numel(leaves), numel(leaf_hdr))];
for k = 1:numel(leaves)
    li = leaves(k);
    leaf_cell{k+1, 1} = labels{li};
    col = 2;
    for s = 1:M
        R = results(s);
        leaf_cell{k+1, col}     = R.Op_mean(li);
        leaf_cell{k+1, col+1}   = R.Op_ci_low(li);
        leaf_cell{k+1, col+2}   = R.Op_ci_high(li);
        col = col + 3;
    end
end
write_xlsx_safe(xlsx_out, leaf_cell, 'leaves');

% per-scenario detail
for s = 1:M
    R = results(s);
    pn_hdr = {'idx','label','Op_mean','Op_std','Op_ci_low','Op_ci_high','IsLeaf'};
    pn_cell = [pn_hdr; cell(n, numel(pn_hdr))];
    for i = 1:n
        pn_cell{i+1,1} = i;
        pn_cell{i+1,2} = labels{i};
        pn_cell{i+1,3} = R.Op_mean(i);
        pn_cell{i+1,4} = R.Op_std(i);
        pn_cell{i+1,5} = R.Op_ci_low(i);
        pn_cell{i+1,6} = R.Op_ci_high(i);
        pn_cell{i+1,7} = double(ismember(i, leaves));
    end
    write_xlsx_safe(xlsx_out, pn_cell, sprintf('per_node_%s', R.name));
end

fprintf('\nSaved: %s\n', xlsx_out);

% --------------------------------------------- comparison PNG
plot_set2_compare(png_out, results, leaves, labels, levels, level_names);
fprintf('Saved: %s\n', png_out);

% --------------------------------------------- info
info = opts;
info.xlsx_path = xlsx_path;
info.scenarios = level_names;
info.timestamp = datestr(now, 'yyyy-mm-dd HH:MM:SS'); %#ok<DATST,TNOW1>
end


% ======================================================================
function opts = default_opts(opts, xlsx_path)
[xd, xb, ~] = fileparts(xlsx_path);
if isempty(xd); xd = pwd; end
defaults = struct( ...
    'out_dir',     xd, ...
    'out_stem',    [strrep(xb, '_input', '') '_set2'], ...
    'toggles',     struct(), ...
    'levels',      [0.2 25 25; 0.5 50 50; 0.9 75 75], ...
    'level_names', {{'Reduced','Baseline','Increased'}}, ...
    'feeder',      'LTV_Ori', ...
    'receivers',   {{'Crew1_Dec'}}, ...
    'N',           2000, ...
    'seed',        20260503, ...
    'ci_level',    0.95);
fn = fieldnames(defaults);
for k = 1:numel(fn)
    if ~isfield(opts, fn{k}) || (isempty(opts.(fn{k})) && ~isstruct(opts.(fn{k})))
        opts.(fn{k}) = defaults.(fn{k});
    end
end
end

% ======================================================================
function plot_set2_compare(png_out, results, leaves, labels, levels, level_names)
M = numel(results);
fig = figure('Position',[100 100 1400 900], 'Visible','off', 'Color','w');
clr = lines(M);

% Top-left: dose-response on Onet (mean + 95% CI vs SOD level)
subplot(2,2,1); hold on; grid on;
sods = levels(:, 1);
mu  = arrayfun(@(R) R.summary_mat(1,1), results);
lo  = arrayfun(@(R) R.summary_mat(1,3), results);
hi  = arrayfun(@(R) R.summary_mat(1,4), results);
plot(sods, mu, '-o', 'LineWidth', 1.6, 'Color', [0.2 0.4 0.7], ...
    'MarkerFaceColor', [0.2 0.4 0.7]);
fill([sods; flipud(sods)], [lo'; flipud(hi')], [0.4 0.6 0.85], ...
    'FaceAlpha', 0.2, 'EdgeColor', 'none');
xlabel('SOD level (LTV_{Ori} \rightarrow Crew_{Dec})');
ylabel('O_{net}  (mean +/- 95%% CI)');
title('Dose-response: O_{net} vs LTV-route-plan trust');
set(gca, 'XTick', sods, 'XTickLabel', ...
    arrayfun(@(s, c, i) sprintf('%s\n(%.1f/%g/%g)', level_names{i}, ...
    levels(i,1), levels(i,2), levels(i,3)), ...
    sods, levels(:,2), (1:M)', 'UniformOutput', false));

% Top-right: Onet histograms overlaid
subplot(2,2,2); hold on; grid on;
for s = 1:M
    histogram(results(s).Onet, 25, 'FaceColor', clr(s,:), 'FaceAlpha', 0.5, ...
        'EdgeColor', 'none', 'DisplayName', results(s).name);
end
xlabel('O_{net}'); ylabel('count');
title('Onet distribution by level'); legend('Location','best');

% Bottom-left: per-leaf bars
subplot(2,2,3); hold on; grid on;
nL = numel(leaves);
Mmat = zeros(nL, M);
LO = zeros(nL, M); HI = zeros(nL, M);
for s = 1:M
    R = results(s);
    Mmat(:, s) = R.Op_mean(leaves);
    LO(:, s)   = R.Op_ci_low(leaves);
    HI(:, s)   = R.Op_ci_high(leaves);
end
b = bar(Mmat, 'grouped');
for s = 1:M; b(s).FaceColor = clr(s,:); b(s).EdgeColor = 'none'; end
ngroups = size(Mmat,1); nbars = size(Mmat,2);
gw = min(0.8, nbars/(nbars+1.5));
for s = 1:nbars
    x = (1:ngroups) - gw/2 + (2*s-1)*gw/(2*nbars);
    errorbar(x, Mmat(:,s), Mmat(:,s)-LO(:,s), HI(:,s)-Mmat(:,s), 'k', ...
        'LineStyle','none', 'CapSize', 4);
end
set(gca, 'XTick', 1:nL, 'XTickLabel', labels(leaves));
xtickangle(30);
ylabel('Op (mean +/- 95%% CI)');
title('Per-leaf Op by level'); legend({results.name}, 'Location','best');

% Bottom-right: leaf_mean histograms
subplot(2,2,4); hold on; grid on;
for s = 1:M
    histogram(results(s).leaf_mean, 25, 'FaceColor', clr(s,:), 'FaceAlpha', 0.5, ...
        'EdgeColor', 'none', 'DisplayName', results(s).name);
end
xlabel('mean Op over leaves'); ylabel('count');
title('Leaf-mean distribution by level'); legend('Location','best');

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
