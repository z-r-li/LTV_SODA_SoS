function [results, info] = run_robustness_cfg(cfg, out_prefix, params)
%RUN_ROBUSTNESS_CFG  Single-node knockout robustness sweep on a cfg struct.
% Companion to run_robustness.m, but takes a cfg from load_SODA_config so
% any toggle / override combination flows through the same machinery used
% by run_baseline / run_centrality_cfg / run_mc.
%
%   [results, info] = run_robustness_cfg(cfg, out_prefix, params)
%
% For every non-leaf node, force its SE to zero and re-run SODA(cycle).
% Records per-knockout dR_mean, dR_leaf, and "resilience" (defined here as
% Onet_disrupted / Onet_nominal in [0,1]). Picks the worst node by dR_leaf
% and stashes it in info.worst_*.
%
% Inputs
% ------
%   cfg        : struct from load_SODA_config(...).
%   out_prefix : string. Outputs (when non-empty) are written as
%                  <out_prefix>_robustness.xlsx
%                  <out_prefix>_robustness.png
%                Pass '' to skip files (return only).
%   params (struct, all optional)
%     .nodes_to_test  vector of node indices to knock out.
%                     Default: every non-leaf node.
%     .SE_failed      scalar SE value to force on the knocked-out node.
%                     Default 0.
%     .plot           true to write _robustness.png   default true
%     .verbose        true to log to console          default true
%
% Outputs
% -------
%   results : struct array (one per knockout) with fields
%               name, idx, mode, Onet_nom, Onet_dis, dR_mean,
%               leaf_nom, leaf_dis, dR_leaf, dR_min_leaf,
%               resilience, per_node_delta, Op_dis.
%   info    : struct with Onet_nom, leaf_nom, min_leaf_nom, Op_nom,
%             worst_idx, worst_label, worst_dR_leaf, runtime_s.
%
% Usage
% -----
%   cfg = load_SODA_config('SODA_configurations_input.xlsx');
%   [r, info] = run_robustness_cfg(cfg, 'SODA_configurations_baseline');

t0 = tic;
if nargin < 2; out_prefix = ''; end
if nargin < 3 || isempty(params); params = struct(); end
if ~isfield(params, 'nodes_to_test'); params.nodes_to_test = []; end
if ~isfield(params, 'SE_failed');     params.SE_failed     = 0; end
if ~isfield(params, 'plot');          params.plot          = true; end
if ~isfield(params, 'verbose');       params.verbose       = true; end

n      = cfg.n;
labels = cfg.labels;
SOD    = cfg.SOD;
COD    = cfg.COD;
IOD    = cfg.IOD;
SE_nom = cfg.SE(:).';
leaves = cfg.leaves(:).';

assert(~isempty(leaves), 'cfg has no leaf nodes -- robustness undefined.');

if cfg.is_dag
    sodaFun = @(se) SODA(se, SOD, COD, IOD);
else
    sodaFun = @(se) SODAcycle(se, SOD, COD, IOD);
end

% Nominal run
Op_nom       = sodaFun(SE_nom);
Op_nom       = Op_nom(:).';
Onet_nom     = mean(Op_nom);
leaf_nom     = mean(Op_nom(leaves));
min_leaf_nom = min(Op_nom(leaves));

% Default test set: every non-leaf node
if isempty(params.nodes_to_test)
    test_idx = setdiff(1:n, leaves);
else
    test_idx = params.nodes_to_test(:).';
end

if params.verbose
    fprintf('\nrun_robustness_cfg: knocking out %d non-leaf nodes\n', ...
        numel(test_idx));
    fprintf('  Nominal: Onet=%.2f, leaf_mean=%.2f, leaf_min=%.2f\n', ...
        Onet_nom, leaf_nom, min_leaf_nom);
end

results = repmat(struct( ...
    'name', '', 'idx', 0, 'mode', '', ...
    'Onet_nom', Onet_nom, 'Onet_dis', NaN, 'dR_mean', NaN, ...
    'leaf_nom', leaf_nom, 'leaf_dis', NaN, 'dR_leaf', NaN, ...
    'dR_min_leaf', NaN, 'resilience', NaN, ...
    'per_node_delta', zeros(1, n), 'Op_dis', zeros(1, n)), ...
    1, numel(test_idx));

mode_str = sprintf('SE_failed=%.1f', params.SE_failed);

for k = 1:numel(test_idx)
    i = test_idx(k);
    SE_dis = SE_nom;
    SE_dis(i) = params.SE_failed;
    Op_dis = sodaFun(SE_dis);
    Op_dis = Op_dis(:).';

    if any(~isfinite(Op_dis))
        warning('run_robustness_cfg:nonFinite', ...
            'Non-finite Op when knocking out %s -- recording NaN.', labels{i});
    end

    Onet_dis = mean(Op_dis);
    leaf_dis = mean(Op_dis(leaves));

    results(k).name           = sprintf('Knockout_%s', safe_name(labels{i}));
    results(k).idx            = i;
    results(k).mode           = mode_str;
    results(k).Onet_dis       = Onet_dis;
    results(k).dR_mean        = Onet_nom - Onet_dis;
    results(k).leaf_dis       = leaf_dis;
    results(k).dR_leaf        = leaf_nom - leaf_dis;
    results(k).dR_min_leaf    = min_leaf_nom - min(Op_dis(leaves));
    if Onet_nom > 0
        results(k).resilience = Onet_dis / Onet_nom;
    else
        results(k).resilience = NaN;
    end
    results(k).per_node_delta = Op_nom - Op_dis;
    results(k).Op_dis         = Op_dis;

    if params.verbose
        fprintf('  [%2d/%2d] knock %-14s  dR_mean=%6.2f  dR_leaf=%6.2f  res=%.3f\n', ...
            k, numel(test_idx), labels{i}, ...
            results(k).dR_mean, results(k).dR_leaf, results(k).resilience);
    end
end

% Worst-case
[~, worst_k] = max([results.dR_leaf]);
worst_idx    = results(worst_k).idx;

info = struct( ...
    'Onet_nom',     Onet_nom, ...
    'leaf_nom',     leaf_nom, ...
    'min_leaf_nom', min_leaf_nom, ...
    'Op_nom',       Op_nom, ...
    'worst_idx',    worst_idx, ...
    'worst_label',  labels{worst_idx}, ...
    'worst_dR_leaf',results(worst_k).dR_leaf, ...
    'worst_resilience', results(worst_k).resilience, ...
    'runtime_s',    toc(t0));

if params.verbose
    fprintf('  Worst single-node knockout: %s  (dR_leaf=%.2f, resilience=%.3f)\n', ...
        info.worst_label, info.worst_dR_leaf, info.worst_resilience);
end

% --------------------------------------------------------- write outputs
if ~isempty(out_prefix)
    [out_dir, out_base, out_ext] = fileparts(out_prefix);
    if isempty(out_dir); out_dir = pwd; end
    stem = fullfile(out_dir, [out_base out_ext]);

    xlsx_out = [stem '_robustness.xlsx'];
    hdr = {'name','idx','label','mode', ...
           'Onet_nom','Onet_dis','dR_mean', ...
           'leaf_nom','leaf_dis','dR_leaf','dR_min_leaf','resilience'};
    cell_out = cell(numel(results) + 1, numel(hdr));
    cell_out(1, :) = hdr;
    for k = 1:numel(results)
        cell_out(k+1, :) = { ...
            results(k).name, results(k).idx, labels{results(k).idx}, ...
            results(k).mode, ...
            results(k).Onet_nom, results(k).Onet_dis, results(k).dR_mean, ...
            results(k).leaf_nom, results(k).leaf_dis, results(k).dR_leaf, ...
            results(k).dR_min_leaf, results(k).resilience};
    end
    write_xlsx_safe(xlsx_out, cell_out, 'summary');

    % per_node_delta sheet (rows = nodes, cols = each knockout's Op_dis)
    pnd_hdr = [{'idx','label','Op_nom'}, ...
               cellfun(@(s) s, {results.name}, 'UniformOutput', false)];
    pnd = cell(n + 1, numel(pnd_hdr));
    pnd(1, :) = pnd_hdr;
    for i = 1:n
        pnd{i+1, 1} = i;
        pnd{i+1, 2} = labels{i};
        pnd{i+1, 3} = Op_nom(i);
        for k = 1:numel(results)
            pnd{i+1, 3+k} = results(k).Op_dis(i);
        end
    end
    write_xlsx_safe(xlsx_out, pnd, 'per_node_delta');

    if params.verbose; fprintf('  Saved: %s\n', xlsx_out); end

    % Bar chart of dR_leaf per knockout (descending)
    if params.plot
        png_out = [stem '_robustness.png'];
        [dR_sorted, order] = sort([results.dR_leaf], 'descend');
        names_sorted = arrayfun(@(k) labels{results(k).idx}, order, ...
            'UniformOutput', false);
        nb = numel(dR_sorted);
        fig_h = max(300, 28 * nb + 120);
        fig = figure('Position', [100 100 900 fig_h], ...
            'Visible', 'off', 'Color', 'w');
        ax = axes(fig); %#ok<LAXES>
        barh(ax, nb:-1:1, dR_sorted, 'FaceColor', [0.80 0.22 0.22], ...
            'EdgeColor', 'none');
        set(ax, 'YTick', 1:nb, 'YTickLabel', fliplr(names_sorted), ...
            'TickLabelInterpreter', 'none');
        xlabel(ax, '\Delta R_{leaf} = leaf\_mean_{nom} - leaf\_mean_{dis}');
        title(ax, 'Single-node knockout: scenarios by \Delta R_{leaf}');
        grid(ax, 'on');
        if exist('exportgraphics', 'file') == 2 || ...
           exist('exportgraphics', 'builtin') == 5
            exportgraphics(fig, png_out, 'Resolution', 150);
        else
            print(fig, png_out, '-dpng', '-r150');
        end
        close(fig);
        if params.verbose; fprintf('  Saved: %s\n', png_out); end
    end
end

end


% ======================================================================
function s = safe_name(s)
if isstring(s); s = char(s); end
if ~ischar(s); s = num2str(s); end
s = regexprep(s, '[^A-Za-z0-9]+', '_');
s = regexprep(s, '^_+|_+$', '');
if isempty(s); s = 'node'; end
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
