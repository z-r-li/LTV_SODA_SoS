function [scores, info] = run_centrality_cfg(cfg, out_prefix, params)
%RUN_CENTRALITY_CFG  Eigenvector-family centralities for a SODA architecture
% loaded via load_SODA_config. Returns the same centrality measures as the
% original run_centrality.m (eig_out/in via power iteration + SVD fallback,
% Katz out/in, PageRank, Hubs, Authorities) but operates on a cfg struct
% so any toggle/override combination flows through the same machinery.
%
%   [scores, info] = run_centrality_cfg(cfg, out_prefix, params)
%
% Inputs
% ------
%   cfg        : struct from load_SODA_config(...)
%   out_prefix : output stem; '' to skip writing files
%   params (struct, all optional)
%     .weight    'unit' | 'sod' | 'sod_cod'   default 'sod_cod'
%     .direction 'out' | 'in' | 'both'        default 'both'
%     .tol        power-iter / Katz tolerance default 1e-10
%     .max_iter   max iterations              default 1000
%     .damping    PageRank follow-prob        default 0.85
%     .plot       write _centrality.png       default true
%     .verbose    log to console              default true
%
% Outputs
% -------
%   scores : MATLAB table of scores (idx, label, eig_out/in, katz_out/in,
%            pagerank, hubs, authorities)
%   info   : convergence diagnostics for power iter (iters, residual, fallback)
%
% Files written when out_prefix is non-empty:
%   <out_prefix>_centrality.xlsx     scores / ranks / top10
%   <out_prefix>_centrality_nodes.csv  Gephi-ready (Id,Label,PageRank,Hubs,...)
%   <out_prefix>_centrality.png      bar chart grid

if nargin < 2; out_prefix = ''; end
if nargin < 3 || isempty(params); params = struct(); end
params = set_default(params, 'weight',    'sod_cod');
params = set_default(params, 'direction', 'both');
params = set_default(params, 'tol',       1e-10);
params = set_default(params, 'max_iter',  1000);
params = set_default(params, 'damping',   0.85);
params = set_default(params, 'plot',      true);
params = set_default(params, 'verbose',   true);

n      = cfg.n;
labels = cfg.labels;
SOD    = cfg.SOD;
COD    = cfg.COD;

A = double(abs(SOD) > 0);
switch lower(params.weight)
    case 'unit'
        W = A;
    case 'sod'
        W = abs(SOD);
    case 'sod_cod'
        W = abs(SOD) .* (COD / 100);
    otherwise
        error('Unknown weight "%s" (use unit | sod | sod_cod)', params.weight);
end
W(~A) = 0;

G = digraph(A);
E = G.Edges.EndNodes;
m = size(E, 1);
if m == 0
    warning('run_centrality_cfg:emptyGraph', ...
        'SOD has no edges - all centralities trivially zero.');
end
lin_edge = sub2ind([n n], E(:,1), E(:,2));
w_edge   = W(lin_edge);

if params.verbose
    fprintf('\nrun_centrality_cfg: n=%d, weight=%s, direction=%s, edges=%d\n', ...
        n, params.weight, params.direction, m);
    if cfg.is_dag
        fprintf('  Graph is a DAG - power iteration on W will hit SVD fallback.\n');
    end
end

% 1. eigenvector (power iter)
want_out = any(strcmpi(params.direction, {'out','both'}));
want_in  = any(strcmpi(params.direction, {'in', 'both'}));

eig_out = zeros(n, 1);
eig_in  = zeros(n, 1);
info = struct( ...
    'eig_out',  empty_diag(), ...
    'eig_in',   empty_diag(), ...
    'katz_out', empty_diag(), ...
    'katz_in',  empty_diag());

if want_out; [eig_out, info.eig_out] = power_iter_eig(W,    params.tol, params.max_iter); end
if want_in;  [eig_in,  info.eig_in]  = power_iter_eig(W.',  params.tol, params.max_iter); end

% 2. Katz centrality
rho = spectral_radius(W);
if rho <= 0 || ~isfinite(rho)
    if params.verbose
        fprintf('  spectral_radius(W) = %.4g - Katz alpha defaulted to 0.1.\n', rho);
    end
    alpha = 0.1;
else
    alpha = 0.9 / rho;
end
if params.verbose
    fprintf('  spectral_radius(W) = %.4g, Katz alpha = %.4g\n', rho, alpha);
end

katz_out = zeros(n, 1);
katz_in  = zeros(n, 1);
if want_out; [katz_out, info.katz_out] = katz_solve(W,    alpha); end
if want_in;  [katz_in,  info.katz_in]  = katz_solve(W.',  alpha); end

% 3. PageRank, Hubs, Authorities
if m > 0
    pr  = centrality(G, 'pagerank',    'Importance', w_edge, ...
        'FollowProbability', params.damping, ...
        'MaxIterations', params.max_iter, 'Tolerance', params.tol);
    hubs= centrality(G, 'hubs',        'Importance', w_edge, ...
        'MaxIterations', params.max_iter, 'Tolerance', params.tol);
    auth= centrality(G, 'authorities', 'Importance', w_edge, ...
        'MaxIterations', params.max_iter, 'Tolerance', params.tol);
else
    pr   = ones(n, 1) / n;
    hubs = zeros(n, 1);
    auth = zeros(n, 1);
end

idx = (1:n)';
scores = table(idx, string(labels(:)), eig_out, eig_in, ...
    katz_out, katz_in, pr, hubs, auth, ...
    'VariableNames', {'idx','label','eig_out','eig_in', ...
                      'katz_out','katz_in','pagerank','hubs','authorities'});
ranks = table(idx, string(labels(:)), ...
    tiedrank_desc(eig_out),  tiedrank_desc(eig_in), ...
    tiedrank_desc(katz_out), tiedrank_desc(katz_in), ...
    tiedrank_desc(pr),       tiedrank_desc(hubs),    tiedrank_desc(auth), ...
    'VariableNames', scores.Properties.VariableNames);

if params.verbose
    fprintf('\nScores:\n');
    fprintf('  %3s  %-14s  %9s %9s  %9s %9s  %9s  %9s %9s\n', ...
        'idx','label','eig_out','eig_in','katz_out','katz_in','pagerank','hubs','auth');
    for i = 1:n
        fprintf('  %3d  %-14s  %9.4f %9.4f  %9.4f %9.4f  %9.4f  %9.4f %9.4f\n', ...
            i, labels{i}, eig_out(i), eig_in(i), katz_out(i), katz_in(i), ...
            pr(i), hubs(i), auth(i));
    end
    print_top('PageRank',    pr,   labels, 10);
    print_top('Authorities', auth, labels, 10);
    print_top('Hubs',        hubs, labels, 10);
end

if ~isempty(out_prefix)
    [out_dir, out_base, out_ext] = fileparts(out_prefix);
    if isempty(out_dir); out_dir = pwd; end
    stem = fullfile(out_dir, [out_base out_ext]);

    xlsx_out = [stem '_centrality.xlsx'];
    write_xlsx_safe(xlsx_out, ...
        [scores.Properties.VariableNames; table2cell(scores)], 'scores');
    write_xlsx_safe(xlsx_out, ...
        [ranks.Properties.VariableNames;  table2cell(ranks)],  'ranks');
    write_xlsx_safe(xlsx_out, build_top10_cell(scores, labels, 10), 'top10');
    if params.verbose; fprintf('\nSaved: %s\n', xlsx_out); end

    nodes_out = [stem '_centrality_nodes.csv'];
    fid = fopen(nodes_out, 'w');
    cleanup = onCleanup(@() fclose_if_open(fid));
    fprintf(fid, ['Id,Label,PageRank,Hubs,Authorities,KatzOut,KatzIn,' ...
                  'EigOut,EigIn\n']);
    for i = 1:n
        fprintf(fid, '%d,%s,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f\n', ...
            i, csv_escape(labels{i}), pr(i), hubs(i), auth(i), ...
            katz_out(i), katz_in(i), eig_out(i), eig_in(i));
    end
    clear cleanup;
    if params.verbose; fprintf('Saved: %s\n', nodes_out); end

    if params.plot
        png_out = [stem '_centrality.png'];
        plot_centrality_bars(png_out, labels, ...
            {'EigOut','EigIn','PageRank','Katz Out','Hubs','Authorities'}, ...
            {eig_out, eig_in, pr, katz_out, hubs, auth}, 15);
        if params.verbose; fprintf('Saved: %s\n', png_out); end
    end
end

end


% ======================================================================
function [v, diag] = power_iter_eig(M, tol, max_iter)
n = size(M, 1);
v = ones(n, 1) / sqrt(n);
prev = v;
residual = Inf;
iters = 0;
fallback = false;
for k = 1:max_iter
    w = M * v;
    nw = norm(w, 2);
    if nw < eps
        fallback = true;
        break;
    end
    w = w / nw;
    residual = norm(w - prev, 2);
    iters = k;
    prev = w;
    v = w;
    if residual < tol; break; end
end
if fallback
    try
        [~, ~, V] = svds(M, 1);
        v = V(:, 1);
    catch
        [~, ~, V] = svd(full(M));
        v = V(:, 1);
    end
    residual = NaN;
end
% sign gauge: largest |entry| positive
[~, im] = max(abs(v));
if v(im) < 0; v = -v; end
diag = struct('iters', iters, 'residual', residual, 'fallback', fallback);
end

% ======================================================================
function [v, diag] = katz_solve(M, alpha)
n = size(M, 1);
b = ones(n, 1);
A = (eye(n) - alpha * M);
try
    v = A \ b;
catch
    v = pinv(full(A)) * b;
end
res = norm(A * v - b);
diag = struct('iters', 1, 'residual', res, 'fallback', false);
end

% ======================================================================
function rho = spectral_radius(W)
try
    e = eigs(W, 1, 'largestabs');
    rho = abs(e);
catch
    e = eig(full(W));
    rho = max(abs(e));
end
end

% ======================================================================
function r = tiedrank_desc(x)
[~, ord] = sort(x, 'descend');
r = zeros(numel(x), 1);
r(ord) = 1:numel(x);
end

% ======================================================================
function P = set_default(P, name, val)
if ~isfield(P, name) || isempty(P.(name))
    P.(name) = val;
end
end

% ======================================================================
function d = empty_diag()
d = struct('iters', 0, 'residual', NaN, 'fallback', false);
end

% ======================================================================
function print_top(title_str, scores, labels, k)
[~, ord] = sort(scores, 'descend');
k = min(k, numel(ord));
fprintf('\nTop %d by %s:\n', k, title_str);
for r = 1:k
    i = ord(r);
    fprintf('  %2d  %-14s  %.4f\n', r, labels{i}, scores(i));
end
end

% ======================================================================
function C = build_top10_cell(scores, labels, k)
n = height(scores);
k = min(k, n);
metrics = {'eig_out','eig_in','katz_out','katz_in','pagerank','hubs','authorities'};
hdr = {'metric','rank','idx','label','score'};
C = hdr;
for mi = 1:numel(metrics)
    mn = metrics{mi};
    [~, ord] = sort(scores.(mn), 'descend');
    for r = 1:k
        i = ord(r);
        C(end+1, :) = {mn, r, i, labels{i}, scores.(mn)(i)}; %#ok<AGROW>
    end
end
end

% ======================================================================
function plot_centrality_bars(png_out, labels, titles, vals, top_k)
n = numel(labels);
top_k = min(top_k, n);
fig = figure('Position',[100 100 1500 900], 'Visible','off', 'Color','w');
for k = 1:numel(vals)
    subplot(2, 3, k);
    [s, ord] = sort(vals{k}, 'descend');
    s = s(1:top_k); ord = ord(1:top_k);
    barh(flipud(s), 'FaceColor', [0.4 0.6 0.85], 'EdgeColor', 'none');
    set(gca, 'YTick', 1:top_k, 'YTickLabel', flipud(labels(ord)));
    title(titles{k}); grid on;
end
if exist('exportgraphics','file') == 2 || exist('exportgraphics','builtin') == 5
    exportgraphics(fig, png_out, 'Resolution', 150);
else
    print(fig, png_out, '-dpng', '-r150');
end
close(fig);
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
    try; fclose(fid); catch; end
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
