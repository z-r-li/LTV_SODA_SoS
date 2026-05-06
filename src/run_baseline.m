function [Op, info] = run_baseline(cfg, out_prefix, opts)
%RUN_BASELINE  Deterministic SODA run for a single cfg (from load_SODA_config).
%
%   [Op, info] = run_baseline(cfg, out_prefix, opts)
%
% Inputs
% ------
%   cfg        : struct from load_SODA_config(...). Must have fields
%                n / labels / SOD / COD / IOD / SE / SE_type / SE_v1 / SE_v2 /
%                roots / leaves / is_dag.
%   out_prefix : string. Outputs are written next to it as
%                  <out_prefix>_results.xlsx
%                  <out_prefix>_nodes.csv
%                  <out_prefix>_edges.csv
%                Pass '' to skip writing files (returns Op + info only).
%   opts       : struct (all optional)
%                  .verbose   true (default) or false
%                  .write     true (default) or false  -- overrides empty out_prefix
%
% Output
% ------
%   Op   : 1 x n  deterministic operability vector returned by SODA / SODAcycle
%   info : struct with Onet, leaf_mean, leaf_min, sanity_err, runtime_s
%
% Notes
% -----
% - Uses cfg.SE (the deterministic point: D -> v1; B -> 100*v1/(v1+v2) mean).
%   For stochastic runs use run_mc(cfg, ...).
% - Picks SODA() vs SODAcycle() based on cfg.is_dag.
% - Outputs match run_SODA_baseline.m's schema so the existing Gephi import
%   workflow keeps working.

t0 = tic;

if nargin < 2; out_prefix = ''; end
if nargin < 3 || isempty(opts); opts = struct(); end
if ~isfield(opts, 'verbose'); opts.verbose = true; end
if ~isfield(opts, 'write');   opts.write = ~isempty(out_prefix); end

n      = cfg.n;
labels = cfg.labels;
SOD    = cfg.SOD;
COD    = cfg.COD;
IOD    = cfg.IOD;
SE     = cfg.SE(:).';

if cfg.is_dag
    Op = SODA(SE, SOD, COD, IOD);
    solver = 'SODA';
else
    Op = SODAcycle(SE, SOD, COD, IOD);
    solver = 'SODAcycle';
end
Op = Op(:).';

if any(~isfinite(Op))
    bad = find(~isfinite(Op));
    error(['Non-finite Op for node(s) %s. Likely cause: IOD = 0 on an ', ...
           'active edge.'], mat2str(bad));
end

Onet      = mean(Op);
leaf_op   = Op(cfg.leaves);
leaf_mean = mean(leaf_op);
leaf_min  = min(leaf_op);

% SE=100 sanity check
SE_perf       = 100 * ones(1, n);
if cfg.is_dag
    Op_perf = SODA(SE_perf, SOD, COD, IOD);
else
    Op_perf = SODAcycle(SE_perf, SOD, COD, IOD);
end
sanity_err = max(abs(Op_perf - 100));

if opts.verbose
    fprintf('\nrun_baseline (solver: %s)\n', solver);
    fprintf('  %3s  %-14s  %3s  %6s  %6s  %6s\n', ...
        'idx', 'label', 'typ', 'SE', 'Op', 'delta');
    for i = 1:n
        fprintf('  %3d  %-14s  %3s  %6.2f  %6.2f  %+6.2f\n', ...
            i, labels{i}, cfg.SE_type{i}, SE(i), Op(i), Op(i) - SE(i));
    end
    fprintf('\n  Onet (mean Op)    = %.2f\n', Onet);
    fprintf('  Mean leaf Op      = %.2f\n', leaf_mean);
    fprintf('  Min  leaf Op      = %.2f\n', leaf_min);
    for k = 1:numel(cfg.leaves)
        i = cfg.leaves(k);
        fprintf('    leaf %-14s  Op = %.2f\n', labels{i}, Op(i));
    end
    fprintf('\n  Sanity (SE=100 -> Op=100) max|err| = %.2e\n', sanity_err);
end

if opts.write && ~isempty(out_prefix)
    [out_dir, out_base, out_ext] = fileparts(out_prefix);
    if isempty(out_dir); out_dir = pwd; end
    stem = fullfile(out_dir, [out_base out_ext]);    % preserve any user suffix

    results_path = [stem '_results.xlsx'];
    label_col = labels(:);
    SE_col    = num2cell(SE(:));
    Op_col    = num2cell(Op(:));
    type_col  = cfg.SE_type(:);
    results_cell = [{'idx','label','SE_type','SE','Op'}; ...
        num2cell((1:n).'), label_col, type_col, SE_col, Op_col];
    write_xlsx_safe(results_path, results_cell, 'results');
    if opts.verbose; fprintf('  Saved: %s\n', results_path); end

    % Gephi node table
    nodes_path = [stem '_nodes.csv'];
    fid = fopen(nodes_path, 'w');
    cleanup_nodes = onCleanup(@() fclose_if_open(fid));
    fprintf(fid, 'Id,Label,SE_type,SE,Op,IsLeaf,IsRoot\n');
    for i = 1:n
        is_leaf = ismember(i, cfg.leaves);
        is_root = ismember(i, cfg.roots);
        fprintf(fid, '%d,%s,%s,%.2f,%.2f,%d,%d\n', ...
            i, csv_escape(labels{i}), cfg.SE_type{i}, SE(i), Op(i), ...
            is_leaf, is_root);
    end
    clear cleanup_nodes;
    if opts.verbose; fprintf('  Saved: %s\n', nodes_path); end

    % Gephi edge table: one row per non-zero SOD entry
    edges_path = [stem '_edges.csv'];
    fid = fopen(edges_path, 'w');
    cleanup_edges = onCleanup(@() fclose_if_open(fid));
    fprintf(fid, 'Source,Target,Type,Weight,SOD,COD,IOD\n');
    for i = 1:n
        for j = 1:n
            if SOD(i, j) > 0
                w = SOD(i, j) * COD(i, j) / 100;
                fprintf(fid, '%d,%d,Directed,%.4f,%.3f,%.1f,%.1f\n', ...
                    i, j, w, SOD(i, j), COD(i, j), IOD(i, j));
            end
        end
    end
    clear cleanup_edges;
    if opts.verbose; fprintf('  Saved: %s\n', edges_path); end
end

info = struct();
info.Op          = Op;
info.Onet        = Onet;
info.leaf_mean   = leaf_mean;
info.leaf_min    = leaf_min;
info.sanity_err  = sanity_err;
info.solver      = solver;
info.runtime_s   = toc(t0);
info.events_log  = cfg.events_log;
info.toggles     = cfg.toggles;
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
