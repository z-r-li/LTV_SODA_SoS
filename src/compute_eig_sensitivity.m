function [sens, info] = compute_eig_sensitivity(cfg, params)
%COMPUTE_EIG_SENSITIVITY  Per-node sensitivity of eigenvector centrality to
% perturbations of that node's incident edges.
%
%   [sens, info] = compute_eig_sensitivity(cfg, params)
%
% Method (finite-difference, edge-incident perturbation):
%   1. Build W = |SOD| .* (COD/100) and compute baseline eigenvector
%      centrality v0 by power iteration (SVD fallback for DAGs).
%   2. For each node i, scale every edge incident to i (row i and column i
%      of W) by (1 + eps_pct) and (1 - eps_pct) in two separate copies.
%      Recompute the eigenvector for each.
%   3. Sign-align both perturbed eigenvectors to v0 via dot product, then
%      report sens(i) = mean(||v_plus - v0||_2, ||v_minus - v0||_2).
%
% High sens(i) means: small wobbles in node i's edges noticeably reorder
% the centrality landscape -- the network's "importance map" depends on
% this node's exact connection strengths.
%
% Inputs
% ------
%   cfg     : struct from load_SODA_config(...). Needs .n, .SOD, .COD.
%   params  : struct (all optional)
%       .eps_pct  perturbation magnitude (fraction). Default 0.10 (= +/-10%).
%       .tol      power-iter tolerance.            Default 1e-10.
%       .max_iter power-iter cap.                  Default 1000.
%       .verbose  log to console.                  Default false.
%
% Outputs
% -------
%   sens : n x 1 column of per-node sensitivity scores (L2 units, same
%          scale as the eigenvector itself, which is unit-norm).
%   info : struct with .eps_pct, .v0 (baseline eigenvector), .runtime_s.
%
% Usage
% -----
%   cfg = load_SODA_config('SODA_configurations_input.xlsx');
%   sens = compute_eig_sensitivity(cfg);
%   [~, top] = max(sens);
%   fprintf('most centrality-sensitive node: %s\n', cfg.labels{top});

t0 = tic;
if nargin < 2 || isempty(params); params = struct(); end
if ~isfield(params, 'eps_pct');  params.eps_pct  = 0.10;  end
if ~isfield(params, 'tol');      params.tol      = 1e-10; end
if ~isfield(params, 'max_iter'); params.max_iter = 1000;  end
if ~isfield(params, 'verbose');  params.verbose  = false; end

n   = cfg.n;
SOD = cfg.SOD;
COD = cfg.COD;
W0  = abs(SOD) .* (COD / 100);

v0 = eig_via_power(W0, params.tol, params.max_iter);

sens = zeros(n, 1);
for i = 1:n
    W_plus  = W0;
    W_minus = W0;
    s_plus  = 1 + params.eps_pct;
    s_minus = 1 - params.eps_pct;
    W_plus(i, :)  = W_plus(i, :)  * s_plus;
    W_plus(:, i)  = W_plus(:, i)  * s_plus;
    W_minus(i, :) = W_minus(i, :) * s_minus;
    W_minus(:, i) = W_minus(:, i) * s_minus;

    v_plus  = sign_align(eig_via_power(W_plus,  params.tol, params.max_iter), v0);
    v_minus = sign_align(eig_via_power(W_minus, params.tol, params.max_iter), v0);

    d_plus  = norm(v_plus  - v0, 2);
    d_minus = norm(v_minus - v0, 2);
    sens(i) = (d_plus + d_minus) / 2;

    if params.verbose
        fprintf('  sens %-14s = %.5f  (+: %.5f, -: %.5f)\n', ...
            cfg.labels{i}, sens(i), d_plus, d_minus);
    end
end

info.eps_pct   = params.eps_pct;
info.v0        = v0;
info.runtime_s = toc(t0);
end

% ======================================================================
function v = eig_via_power(M, tol, max_iter)
% Outgoing eigenvector centrality via power iteration on M (NOT M').
% SVD fallback for matrices with zero spectral radius (e.g., a DAG).
n = size(M, 1);
v = ones(n, 1) / sqrt(n);
prev = v;
fallback = false;
for k = 1:max_iter
    w = M * v;
    nw = norm(w, 2);
    if nw < eps
        fallback = true;
        break;
    end
    w = w / nw;
    if norm(w - prev, 2) < tol; v = w; break; end
    prev = w;
    v = w;
end
if fallback
    try
        [~, ~, V] = svds(M, 1);
        v = V(:, 1);
    catch
        [~, ~, V] = svd(full(M));
        v = V(:, 1);
    end
end
% Initial sign gauge: largest |entry| positive
[~, im] = max(abs(v));
if v(im) < 0; v = -v; end
end

% ======================================================================
function v = sign_align(v, v_ref)
% Flip v so it points the same way as v_ref (eigenvectors are sign-ambiguous).
if dot(v, v_ref) < 0
    v = -v;
end
end
