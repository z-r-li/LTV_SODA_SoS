function [dist, info] = run_mc(cfg, out_prefix, params)
%RUN_MC  Stochastic SODA driver for the new 24-node SoS network.
% Re-uses the cfg struct produced by load_SODA_config so the same MC
% machinery works for any toggle / override combination.
%
%   [dist, info] = run_mc(cfg, out_prefix, params)
%
% Sampling rules (encoded in cfg by load_SODA_config):
%   SE_type 'D' -> deterministic SE = SE_v1   (no draw)
%   SE_type 'B' -> Beta(SE_v1, SE_v2) on [0, 1] then *100
%   SE_type 'U' -> Uniform(SE_v1, SE_v2)
%   On top of the draw, an optional uniform jitter +/- params.unif_jitter
%   is applied to nodes listed in params.jitter_nodes (used for the Set 1
%   "15 +/- 10" sweep around the dropped-SE point).
%
% Inputs
% ------
%   cfg        : struct from load_SODA_config(...).
%   out_prefix : string. Outputs:
%                  <out_prefix>_mc.xlsx     (summary, per_node, meta)
%                  <out_prefix>_mc.png      (2x2 diagnostics)
%                  <out_prefix>_mc_ci_nodes.csv
%                Pass '' to skip writing files.
%   params (struct, all optional)
%     .N             number of MC replications      default 2000
%     .seed          rng() seed                     default 20260503
%     .unif_jitter   uniform half-width on jitter_nodes (SE units) default 0
%     .jitter_nodes  cell of label strings (substrings ok) or numeric idx
%                    Applied AFTER the D/U/B draw, clamped to [0,100]. For
%                    Joel's "15 +/- 10" sweep: set Crew*_OODA SE_value=15
%                    via overrides, then pass unif_jitter=10 with
%                    jitter_nodes={'Crew1_'} or {'Crew2_'}.
%     .env_jitter    Gaussian sigma (SE units) on EVERY node draw   default 0
%                    (Use sparingly. Set 1/Set 2 don't need it because the
%                    Crew Beta(5,2) already provides per-rep variation.)
%     .ci_level      0..1 confidence interval                       default 0.95
%     .plot          true to write _mc.png                           default true
%     .save_samples  true to dump full per-rep Op samples            default false
%     .verbose       true to log progress to console                 default true
%
% Outputs
% -------
%   dist : struct with Onet, leaf_mean, leaf_min, Op (N x n)
%   info : params actually used + topology echo

t0 = tic;

P = default_params();
if nargin >= 3 && ~isempty(params)
    fn = fieldnames(params);
    for k = 1:numel(fn); P.(fn{k}) = params.(fn{k}); end
end
if nargin < 2; out_prefix = ''; end

assert(P.N >= 1, 'N must be >= 1 (got %d)', P.N);
assert(P.ci_level > 0 && P.ci_level < 1, 'ci_level in (0,1) required');
assert(P.unif_jitter >= 0, 'unif_jitter must be >= 0');
assert(P.env_jitter  >= 0, 'env_jitter must be >= 0');

n      = cfg.n;
labels = cfg.labels;
SOD    = cfg.SOD;
COD    = cfg.COD;
IOD    = cfg.IOD;
SE_t   = cfg.SE_type;
SE_a   = cfg.SE_v1;
SE_b   = cfg.SE_v2;

leaves = cfg.leaves;
assert(~isempty(leaves), 'No leaf nodes in cfg.leaves; check the loader');

jit_idx = [];
if ~isempty(P.jitter_nodes)
    jit_idx = resolve_node_selector(P.jitter_nodes, labels);
end

nB = sum(strcmp(SE_t, 'B'));
nU = sum(strcmp(SE_t, 'U'));
nD = sum(strcmp(SE_t, 'D'));
have_betarnd = (exist('betarnd', 'file') == 2) || ...
               (exist('betarnd', 'builtin') == 5);
if nB > 0 && ~have_betarnd
    error(['SE has %d Beta-type rows but betarnd is not on the path. ', ...
           'Install Statistics & Machine Learning Toolbox or convert to D.'], ...
           nB);
end

if P.verbose
    fprintf('\nrun_mc: N = %d, seed = %d, ci = %.2f\n', ...
        P.N, P.seed, P.ci_level);
    fprintf('  SE: %d D, %d U, %d B\n', nD, nU, nB);
    if P.unif_jitter > 0
        fprintf('  uniform jitter +/-%g on %d node(s) [%s]\n', ...
            P.unif_jitter, numel(jit_idx), strjoin(labels(jit_idx), ','));
    end
    if P.env_jitter > 0
        fprintf('  env Gaussian sigma %g on every node\n', P.env_jitter);
    end
end

if cfg.is_dag
    sodaFun = @(se) SODA(se, SOD, COD, IOD);
else
    sodaFun = @(se) SODAcycle(se, SOD, COD, IOD);
end

rng(P.seed);
N             = P.N;
Op_samples    = zeros(N, n);
Onet_vec      = zeros(N, 1);
leaf_mean_vec = zeros(N, 1);
leaf_min_vec  = zeros(N, 1);

log_every = max(1, ceil(N / 10));
for k = 1:N
    se = draw_SE(SE_t, SE_a, SE_b);
    if P.unif_jitter > 0 && ~isempty(jit_idx)
        delta = (2*rand(1, numel(jit_idx)) - 1) * P.unif_jitter;
        se(jit_idx) = se(jit_idx) + delta;
    end
    if P.env_jitter > 0
        se = se + P.env_jitter * randn(1, n);
    end
    se = clamp01_100(se);

    op = sodaFun(se);
    op = op(:).';
    if any(~isfinite(op))
        bad = find(~isfinite(op));
        error('Non-finite Op at rep %d for node(s) %s', k, mat2str(bad));
    end

    Op_samples(k, :)  = op;
    Onet_vec(k)       = mean(op);
    leaf_mean_vec(k)  = mean(op(leaves));
    leaf_min_vec(k)   = min(op(leaves));

    if P.verbose && (mod(k, log_every) == 0 || k == N)
        fprintf('  rep %5d/%d   Onet = %5.2f   leafMean = %5.2f\n', ...
            k, N, Onet_vec(k), leaf_mean_vec(k));
    end
end

alpha = 1 - P.ci_level;
lo_q  = alpha / 2;
hi_q  = 1 - alpha / 2;

metric_names = {'Onet', 'leaf_mean', 'leaf_min'};
metric_data  = [Onet_vec, leaf_mean_vec, leaf_min_vec];
nm = numel(metric_names);
summary_mat = zeros(nm, 6);
for m = 1:nm
    v = metric_data(:, m);
    summary_mat(m, :) = [mean(v), std(v), ...
        quantile(v, lo_q), quantile(v, hi_q), min(v), max(v)];
end

Op_mean    = mean(Op_samples, 1);
Op_std     = std(Op_samples, 0, 1);
Op_ci_low  = quantile(Op_samples, lo_q, 1);
Op_ci_high = quantile(Op_samples, hi_q, 1);

if P.verbose
    fprintf('\n%-11s  %8s  %8s  %8s  %8s\n', ...
        'metric', 'mean', 'std', 'ci_low', 'ci_high');
    for m = 1:nm
        fprintf('%-11s  %8.3f  %8.3f  %8.3f  %8.3f\n', metric_names{m}, ...
            summary_mat(m, 1), summary_mat(m, 2), ...
            summary_mat(m, 3), summary_mat(m, 4));
    end
end

if ~isempty(out_prefix)
    [out_dir, out_base, out_ext] = fileparts(out_prefix);
    if isempty(out_dir); out_dir = pwd; end
    stem = fullfile(out_dir, [out_base out_ext]);

    xlsx_out = [stem '_mc.xlsx'];

    sum_hdr  = {'metric','mean','std','ci_low','ci_high','min','max','N','ci_level'};
    sum_cell = [sum_hdr; cell(nm, numel(sum_hdr))];
    for m = 1:nm
        sum_cell{m+1, 1} = metric_names{m};
        for c = 1:6
            sum_cell{m+1, 1+c} = summary_mat(m, c);
        end
        sum_cell{m+1, 8} = N;
        sum_cell{m+1, 9} = P.ci_level;
    end

    pn_hdr  = {'idx','label','SE_type','SE_v1','SE_v2', ...
               'Op_mean','Op_std','Op_ci_low','Op_ci_high','IsLeaf','IsRoot'};
    pn_cell = [pn_hdr; cell(n, numel(pn_hdr))];
    for i = 1:n
        pn_cell{i+1, 1}  = i;
        pn_cell{i+1, 2}  = labels{i};
        pn_cell{i+1, 3}  = SE_t{i};
        pn_cell{i+1, 4}  = SE_a(i);
        pn_cell{i+1, 5}  = SE_b(i);
        pn_cell{i+1, 6}  = Op_mean(i);
        pn_cell{i+1, 7}  = Op_std(i);
        pn_cell{i+1, 8}  = Op_ci_low(i);
        pn_cell{i+1, 9}  = Op_ci_high(i);
        pn_cell{i+1, 10} = double(ismember(i, cfg.leaves));
        pn_cell{i+1, 11} = double(ismember(i, cfg.roots));
    end

    if ~isempty(jit_idx)
        jit_str = strjoin(labels(jit_idx), '|');
    else
        jit_str = '';
    end
    meta_cell = { ...
        'param',          'value'; ...
        'N',              N; ...
        'seed',           P.seed; ...
        'unif_jitter',    P.unif_jitter; ...
        'jitter_nodes',   jit_str; ...
        'env_jitter',     P.env_jitter; ...
        'ci_level',       P.ci_level; ...
        'SE_nD',          nD; ...
        'SE_nU',          nU; ...
        'SE_nB',          nB; ...
        'is_dag',         double(cfg.is_dag); ...
        'crew3',          cfg.toggles.crew3; ...
        'ltv_FA',         cfg.toggles.ltv_FA; ...
        'ltv_DS',         cfg.toggles.ltv_DS; ...
        'regolith',       cfg.toggles.regolith; ...
        'regolith_pct',   cfg.toggles.regolith_pct; ...
        'overrides_n',    numel(cfg.overrides); ...
        'timestamp',      datestr(now, 'yyyy-mm-dd HH:MM:SS')}; %#ok<DATST,TNOW1>

    write_xlsx_safe(xlsx_out, sum_cell,  'summary');
    write_xlsx_safe(xlsx_out, pn_cell,   'per_node');
    write_xlsx_safe(xlsx_out, meta_cell, 'meta');
    if P.save_samples
        samp_hdr  = [{'rep'}, labels(:).'];
        samp_cell = [samp_hdr; num2cell([(1:N).' Op_samples])];
        write_xlsx_safe(xlsx_out, samp_cell, 'samples');
    end
    if P.verbose; fprintf('\nSaved: %s\n', xlsx_out); end

    ci_path = [stem '_mc_ci_nodes.csv'];
    fid = fopen(ci_path, 'w');
    cleanup_ci = onCleanup(@() fclose_if_open(fid));
    fprintf(fid, 'Id,Label,Op_mean,Op_std,Op_ci_low,Op_ci_high\n');
    for i = 1:n
        fprintf(fid, '%d,%s,%.4f,%.4f,%.4f,%.4f\n', ...
            i, csv_escape(labels{i}), Op_mean(i), Op_std(i), ...
            Op_ci_low(i), Op_ci_high(i));
    end
    clear cleanup_ci;
    if P.verbose; fprintf('Saved: %s\n', ci_path); end

    if P.plot
        png_out = [stem '_mc.png'];
        plot_mc_diagnostics(png_out, Onet_vec, leaf_mean_vec, leaf_min_vec, ...
            Op_samples, Op_mean, Op_std, summary_mat, labels, n, P.ci_level);
        if P.verbose; fprintf('Saved: %s\n', png_out); end
    end
end

dist = struct('Onet', Onet_vec, 'leaf_mean', leaf_mean_vec, ...
              'leaf_min', leaf_min_vec, 'Op', Op_samples);

info = P;
info.n           = n;
info.labels      = {labels};
info.leaves      = leaves;
info.roots       = cfg.roots;
info.metric_names= {metric_names};
info.summary_mat = summary_mat;
info.runtime_s   = toc(t0);
info.timestamp   = datestr(now, 'yyyy-mm-dd HH:MM:SS'); %#ok<DATST,TNOW1>
end


% ======================================================================
function P = default_params()
P.N            = 2000;
P.seed         = 20260503;
P.unif_jitter  = 0;
P.jitter_nodes = {};
P.env_jitter   = 0;
P.ci_level     = 0.95;
P.plot         = true;
P.save_samples = false;
P.verbose      = true;
end

% ======================================================================
function se = draw_SE(SE_t, SE_a, SE_b)
n = numel(SE_t);
se = zeros(1, n);
for i = 1:n
    switch SE_t{i}
        case 'D'
            se(i) = SE_a(i);
        case 'U'
            lo = SE_a(i); hi = SE_b(i);
            se(i) = lo + (hi - lo) * rand();
        case 'B'
            a = SE_a(i); b = SE_b(i);
            if a <= 0 || b <= 0
                % degenerate Beta -> deterministic 0 (e.g. dormant Crew3)
                se(i) = 0;
            else
                se(i) = 100 * betarnd(a, b);
            end
        otherwise
            error('Unknown SE type %s at row %d', SE_t{i}, i);
    end
end
end

% ======================================================================
function v = clamp01_100(v)
v(v < 0)   = 0;
v(v > 100) = 100;
end

% ======================================================================
function idx = resolve_node_selector(sel, labels)
if isnumeric(sel)
    idx = sel(:).';
    assert(all(idx >= 1 & idx <= numel(labels)), 'index out of range');
    return;
end
if ischar(sel); sel = {sel}; end
if isstring(sel); sel = cellstr(sel); end
assert(iscell(sel), 'jitter_nodes must be numeric, char, string, or cellstr');
idx = [];
for k = 1:numel(sel)
    needle = sel{k};
    if isstring(needle); needle = char(needle); end
    hits = [];
    for i = 1:numel(labels)
        if contains(lower(labels{i}), lower(needle))
            hits(end+1) = i; %#ok<AGROW>
        end
    end
    if isempty(hits)
        error('jitter_nodes: no label matches "%s"', needle);
    end
    idx = [idx, hits]; %#ok<AGROW>
end
idx = unique(idx);
end

% ======================================================================
function plot_mc_diagnostics(png_out, Onet_v, leaf_mean_v, leaf_min_v, ...
    Op_samples, Op_mean, Op_std, summary_mat, labels, n, ci_level)
fig = figure('Position',[100 100 1200 900], 'Visible','off', 'Color','w');

subplot(2,2,1);
hist_with_ci(Onet_v, summary_mat(1,3), summary_mat(1,4), summary_mat(1,1));
xlabel('O_{net}'); ylabel('count');
title(sprintf('O_{net}  mean=%.2f  %d%% CI=[%.2f, %.2f]', ...
    summary_mat(1,1), round(ci_level*100), summary_mat(1,3), summary_mat(1,4)));

subplot(2,2,2);
hist_with_ci(leaf_mean_v, summary_mat(2,3), summary_mat(2,4), summary_mat(2,1));
xlabel('mean Op over leaves'); ylabel('count');
title(sprintf('leaf mean  mean=%.2f  CI=[%.2f, %.2f]', ...
    summary_mat(2,1), summary_mat(2,3), summary_mat(2,4)));

subplot(2,2,3);
if exist('boxplot','file') == 2 || exist('boxplot','builtin') == 5
    boxplot(Op_samples, 'Labels', labels, 'Symbol', '.');
else
    errorbar(1:n, Op_mean, Op_std, 'o'); xlim([0.5 n+0.5]);
    set(gca, 'XTick', 1:n, 'XTickLabel', labels);
end
xtickangle(45); ylabel('Op'); ylim([0 105]); grid on;
title('Per-node Op distribution');

subplot(2,2,4);
hist_with_ci(leaf_min_v, summary_mat(3,3), summary_mat(3,4), summary_mat(3,1));
xlabel('min Op over leaves'); ylabel('count');
title(sprintf('leaf min  mean=%.2f  CI=[%.2f, %.2f]', ...
    summary_mat(3,1), summary_mat(3,3), summary_mat(3,4)));

if exist('exportgraphics','file') == 2 || exist('exportgraphics','builtin') == 5
    exportgraphics(fig, png_out, 'Resolution', 150);
else
    print(fig, png_out, '-dpng', '-r150');
end
close(fig);
end

% ======================================================================
function hist_with_ci(v, ci_lo, ci_hi, mu)
nbins = max(15, min(60, round(sqrt(numel(v)))));
if all(v == v(1))
    bar(v(1), numel(v)); grid on;
    return;
end
histogram(v, nbins, 'FaceColor', [0.3 0.5 0.8], 'EdgeColor', 'none');
hold on; grid on;
yl = ylim;
patch([ci_lo ci_hi ci_hi ci_lo], [yl(1) yl(1) yl(2) yl(2)], ...
    [1 0.8 0.4], 'FaceAlpha', 0.25, 'EdgeColor', 'none');
xline(mu,    'k-',  'LineWidth', 1.4);
xline(ci_lo, 'r--', 'LineWidth', 1.0);
xline(ci_hi, 'r--', 'LineWidth', 1.0);
end

% ======================================================================
function s = csv_escape(s)
if isstring(s); s = char(s); end
if ~ischar(s); s = num2str(s); end
if any(s == ',' | s == '"' | s == newline | s == sprintf('\r'))
    s = ['"' strrep(s, '"', '""') '"'];
end
end

% ======================================================================
function fclose_if_open(fid)
if ~isempty(fid) && fid > 2
    try
        fclose(fid);
    catch
    end
end
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
