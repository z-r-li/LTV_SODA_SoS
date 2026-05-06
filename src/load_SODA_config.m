function cfg = load_SODA_config(xlsx_path, toggles, overrides)
%LOAD_SODA_CONFIG  Load the AAE 560 SoS network from SODA_configurations_input.xlsx,
% apply Event-Register toggles and any per-edge / per-node sweep overrides,
% and return SODA-ready inputs.
%
%   cfg = load_SODA_config(xlsx_path, toggles, overrides)
%
% Inputs
% ------
%   xlsx_path : path to SODA_configurations_input.xlsx (24-node SoS).
%
%   toggles   : struct with the 4 Event-Register switches. Missing fields
%               default to the "off" state (Decision-Approval LTV, no Crew3,
%               no Regolith). Field names mirror the Event Register cells:
%
%                 .crew3        (0/1)        B2   - add Crewmember #3
%                 .crew3_pct    (0..100)    C2
%                 .ltv_FA       (0/1)        B37  - LTV Fully Autonomous
%                 .ltv_FA_pct   (0..100)    C37
%                 .ltv_DS       (0/1)        B50  - LTV Decision Support
%                 .ltv_DS_pct   (0..100)    C50
%                 .regolith     (0/1)        B66  - Regolith build-up
%                 .regolith_pct (0..100)    C66
%
%               Mus's rule: pick AT MOST ONE of {ltv_FA, ltv_DS}; default
%               (both 0) is Decision-Approval LTV.
%
%   overrides : optional 0x0 / Nx1 struct array for parametric sweeps
%               (Set 1 SE drop, Set 2 dependency sweep, Set 3 environment
%               stress). Each element has fields:
%
%                 .target  one of:
%                            'SE_value'  (deterministic value, type = 'D')
%                            'SE_alpha'  (Beta alpha)
%                            'SE_beta'   (Beta beta)
%                            'SE_type'   ('D' or 'B')
%                            'SOD' / 'COD' / 'IOD'  (edge param)
%                 .feeder   node label (must match labels sheet)
%                 .receiver node label (omit / '' for SE_*)
%                 .value    numeric (for SE_*, SOD/COD/IOD) or char ('D'/'B')
%                           for SE_type
%
% Output
% ------
%   cfg : struct with fields
%           .n          24
%           .labels     n x 1 cellstr
%           .SOD        n x n
%           .COD        n x n
%           .IOD        n x n
%           .SE_type    n x 1 cellstr ('D' or 'B')
%           .SE_v1      n x 1 numeric (D->value, B->alpha)
%           .SE_v2      n x 1 numeric (D->ignored, B->beta)
%           .SE         n x 1 numeric  (deterministic point value:
%                                       D: v1; B: 100*v1/(v1+v2)  [mean])
%           .roots      indices with no incoming edges
%           .leaves     indices with no outgoing edges
%           .toggles    echo of the (defaulted) toggle struct
%           .overrides  echo of the override struct (after defaulting)
%           .events_log Nx1 cell describing every modification applied
%
% Usage
% -----
%   % Default network (Decision-Approval LTV, no Crew3, no Regolith)
%   cfg = load_SODA_config('SODA_configurations_input.xlsx');
%
%   % Set 1 / Scenario 1: Crew1 SE drop to 15 (repeat for Obs/Ori/Dec/Act)
%   ovr(1) = struct('target','SE_type', 'feeder','Crew1_Obs', 'receiver','', 'value','D');
%   ovr(2) = struct('target','SE_value','feeder','Crew1_Obs', 'receiver','', 'value', 15);
%   cfg = load_SODA_config('SODA_configurations_input.xlsx', struct(), ovr);
%
%   % Set 2 / Increased dependency on LTV route planning
%   ovr(1) = struct('target','SOD','feeder','LTV_Ori','receiver','Crew1_Dec','value',0.9);
%   ovr(2) = struct('target','COD','feeder','LTV_Ori','receiver','Crew1_Dec','value',75);
%   ovr(3) = struct('target','IOD','feeder','LTV_Ori','receiver','Crew1_Dec','value',75);
%   cfg = load_SODA_config('SODA_configurations_input.xlsx', struct(), ovr);

% ---------------------------------------------------------------- inputs
if nargin < 1 || isempty(xlsx_path)
    xlsx_path = 'SODA_configurations_input.xlsx';
end
assert(exist(xlsx_path, 'file') == 2, 'XLSX not found: %s', xlsx_path);

if nargin < 2 || isempty(toggles); toggles = struct(); end
toggles = default_toggles(toggles);

if nargin < 3; overrides = struct([]); end

% ----------------------------------- read labels and Default Network Metrics
labels = read_labels(xlsx_path);
n      = numel(labels);
assert(n == 24, 'Expected 24 nodes in labels sheet, got %d', n);

[SOD, COD, IOD, SE_type, SE_v1, SE_v2] = read_defaults(xlsx_path, n);

events_log = {};

% ------------------------------------------- apply Event-Register toggles
% Mutual exclusion (per Mus's Further Notes):
%   pick one of {LTV default, LTV Decision Support, LTV Fully Autonomous}.
if toggles.ltv_FA == 1 && toggles.ltv_DS == 1
    error(['load_SODA_config: ltv_FA and ltv_DS cannot both be 1. ', ...
           'Pick exactly one of {default (both 0), Decision Support, Fully Autonomous}.']);
end

% --- Group 1: Add Crew #3 (B2 / C2) -----------------------------------
if toggles.crew3 == 1
    pct = toggles.crew3_pct / 100;
    crew3_nodes = {'Crew3_Obs','Crew3_Ori','Crew3_Dec','Crew3_Act'};
    % SE: blend from default (B 0 0) toward (B 5 2) by pct
    for k = 1:numel(crew3_nodes)
        i = idx(labels, crew3_nodes{k});
        SE_v1(i) = SE_v1(i) + pct * (5 - SE_v1(i));
        SE_v2(i) = SE_v2(i) + pct * (2 - SE_v2(i));
        SE_type{i} = 'B';
        events_log{end+1,1} = sprintf('B2/C2 Crew3 ON %.0f%%: %s SE=B(%.2f,%.2f)', ...
            toggles.crew3_pct, crew3_nodes{k}, SE_v1(i), SE_v2(i));
    end
    % Crew3 internal OODA chain + outputs (J-targets from Event Register rows 10-36)
    crew3_edges = {
        'SOD','Crew3_Obs','Crew3_Ori', 0.9;
        'COD','Crew3_Obs','Crew3_Ori', 100;
        'IOD','Crew3_Obs','Crew3_Ori',  90;
        'SOD','Crew3_Ori','Crew3_Dec', 0.9;
        'COD','Crew3_Ori','Crew3_Dec', 100;
        'IOD','Crew3_Ori','Crew3_Dec',  90;
        'SOD','Crew3_Dec','Crew3_Act', 0.9;
        'COD','Crew3_Dec','Crew3_Act', 100;
        'IOD','Crew3_Dec','Crew3_Act',  90;
        'SOD','Crew3_Obs','HLS_Obs',   1.0;   % SOD>1 verbatim from registry
        'COD','Crew3_Obs','HLS_Obs',   100;
        'IOD','Crew3_Obs','HLS_Obs',    10;
        'SOD','Crew3_Dec','SciEq_Act', 0.5;
        'COD','Crew3_Dec','SciEq_Act',  50;
        'IOD','Crew3_Dec','SciEq_Act',  50;
        'SOD','Crew3_Act','SciEq_Act', 0.9;
        'COD','Crew3_Act','SciEq_Act', 100;
        'IOD','Crew3_Act','SciEq_Act', 100;
        % Inbound edges to Crew3_Obs (from LTV / HLS) - must mirror Crew1/Crew2
        'SOD','LTV_Act','Crew3_Obs',   0.8;
        'COD','LTV_Act','Crew3_Obs',    90;
        'IOD','LTV_Act','Crew3_Obs',    90;
        'SOD','HLS_Ori','Crew3_Obs',   0.5;
        'COD','HLS_Ori','Crew3_Obs',    80;
        'IOD','HLS_Ori','Crew3_Obs',    50;
        'SOD','HLS_Act','Crew3_Obs',   0.2;
        'COD','HLS_Act','Crew3_Obs',    50;
        'IOD','HLS_Act','Crew3_Obs',    50;
    };
    [SOD, COD, IOD, events_log] = blend_edges(SOD, COD, IOD, crew3_edges, ...
        pct, labels, events_log, 'B2/C2 Crew3');
end

% --- Group 2: LTV Fully Autonomous (B37 / C37) ------------------------
% J-targets from Event Register rows 37-49.
%   - SE LTV_Dec lights up to D 80
%   - LTV_Ori -> LTV_Dec edge enabled
%   - LTV_Dec -> LTV_Act edge enabled
%   - Crew1_Act -> LTV_Act edge zeroed (manual driving link removed)
%   - Crew1_Act -> SciEq_Act edge enabled (frees Crew1 to assist science)
if toggles.ltv_FA == 1
    pct = toggles.ltv_FA_pct / 100;
    i = idx(labels, 'LTV_Dec');
    SE_v1(i) = SE_v1(i) + pct * (80 - SE_v1(i));
    SE_type{i} = 'D';
    events_log{end+1,1} = sprintf('B37/C37 LTV_FA %.0f%%: LTV_Dec SE=D %.1f', ...
        toggles.ltv_FA_pct, SE_v1(i));
    fa_edges = {
        'SOD','LTV_Ori','LTV_Dec',   0.9;
        'COD','LTV_Ori','LTV_Dec',   100;
        'IOD','LTV_Ori','LTV_Dec',    90;
        'SOD','LTV_Dec','LTV_Act',   0.9;
        'COD','LTV_Dec','LTV_Act',   100;
        'IOD','LTV_Dec','LTV_Act',    90;
        'SOD','Crew1_Act','LTV_Act',   0;     % zero out manual driving
        'COD','Crew1_Act','LTV_Act',   0;
        'IOD','Crew1_Act','LTV_Act',   0;
        'SOD','Crew1_Act','SciEq_Act',0.9;
        'COD','Crew1_Act','SciEq_Act',100;
        'IOD','Crew1_Act','SciEq_Act',100;
    };
    [SOD, COD, IOD, events_log] = blend_edges(SOD, COD, IOD, fa_edges, ...
        pct, labels, events_log, 'B37/C37 LTV_FA');
end

% --- Group 3: LTV Decision Support (B50 / C50) ------------------------
% J-targets from Event Register rows 50-65.
%   - SE LTV_Dec -> D 80
%   - LTV_Ori -> LTV_Dec edge enabled
%   - LTV_Dec -> LTV_Act REDUCED (J: 0/20/20) - smaller weight than FA
%   - LTV_Ori -> Crew1_Dec edge zeroed (Crew1 no longer leans on raw plan)
%   - LTV_Dec -> Crew1_Dec edge enabled (0.5/50/50)  -- ADVISORY support
%   - Crew1_Act -> LTV_Act REDUCED (0.5/50/70) - shared driving
if toggles.ltv_DS == 1
    pct = toggles.ltv_DS_pct / 100;
    i = idx(labels, 'LTV_Dec');
    SE_v1(i) = SE_v1(i) + pct * (80 - SE_v1(i));
    SE_type{i} = 'D';
    events_log{end+1,1} = sprintf('B50/C50 LTV_DS %.0f%%: LTV_Dec SE=D %.1f', ...
        toggles.ltv_DS_pct, SE_v1(i));
    ds_edges = {
        'SOD','LTV_Ori','LTV_Dec',   0.9;
        'COD','LTV_Ori','LTV_Dec',   100;
        'IOD','LTV_Ori','LTV_Dec',    90;
        'SOD','LTV_Dec','LTV_Act',     0;     % Mus's J-target = 0 here
        'COD','LTV_Dec','LTV_Act',    20;
        'IOD','LTV_Dec','LTV_Act',    20;
        'SOD','LTV_Ori','Crew1_Dec',   0;
        'COD','LTV_Ori','Crew1_Dec',   0;
        'IOD','LTV_Ori','Crew1_Dec',   0;
        'SOD','LTV_Dec','Crew1_Dec', 0.5;
        'COD','LTV_Dec','Crew1_Dec',  50;
        'IOD','LTV_Dec','Crew1_Dec',  50;
        'SOD','Crew1_Act','LTV_Act', 0.5;
        'COD','Crew1_Act','LTV_Act',  50;
        'IOD','Crew1_Act','LTV_Act',  70;
    };
    [SOD, COD, IOD, events_log] = blend_edges(SOD, COD, IOD, ds_edges, ...
        pct, labels, events_log, 'B50/C50 LTV_DS');
end

% --- Group 4: Regolith build-up (B66 / C66) ---------------------------
% Interpretation per Mus's Further Notes: regolith degrades the deterministic
% SE of LTV_Obs/LTV_Act/SciEq_Act by flipping their type to Beta(5,2)*scale,
% and worsens the Beta(5,2) Crew SE (still Beta, but moved toward the same).
% Implementation: at full-on (pct=1) those three nodes become B(5,2);
% partial blends linearly between D 80 and B(5,2). Crew SE Beta is unchanged
% in shape (already B 5 2) but flagged in the events_log.
if toggles.regolith == 1
    pct = toggles.regolith_pct / 100;
    rego_nodes = {'LTV_Obs','LTV_Act','SciEq_Act'};
    for k = 1:numel(rego_nodes)
        i = idx(labels, rego_nodes{k});
        if pct >= 1
            SE_type{i} = 'B';
            SE_v1(i) = 5;
            SE_v2(i) = 2;
        elseif pct > 0
            % Treat default D=80 as Beta(80,20) (mean 80) and linearly blend
            % alpha,beta toward regolith B(5,2).
            SE_type{i} = 'B';
            alpha0 = 80; beta0 = 20;
            SE_v1(i) = alpha0 + pct * (5  - alpha0);
            SE_v2(i) = beta0  + pct * (2  - beta0);
        end
        events_log{end+1,1} = sprintf('B66/C66 Regolith %.0f%%: %s SE=%s(%.2f,%.2f)', ...
            toggles.regolith_pct, rego_nodes{k}, SE_type{i}, SE_v1(i), SE_v2(i));
    end
end

% --------------------------------------------------- per-call sweep overrides
% Applied LAST so they win over toggle effects.
n_ovr = numel(overrides);
for k = 1:n_ovr
    o = overrides(k);
    [SOD, COD, IOD, SE_type, SE_v1, SE_v2, msg] = ...
        apply_override(SOD, COD, IOD, SE_type, SE_v1, SE_v2, labels, o);
    events_log{end+1,1} = sprintf('OVERRIDE: %s', msg);
end

% --------------------------------------------------- deterministic SE point
SE = zeros(n, 1);
for i = 1:n
    switch upper(SE_type{i})
        case 'D'
            SE(i) = SE_v1(i);
        case 'B'
            % Beta mean on 0-100 scale: 100 * a / (a + b)
            denom = SE_v1(i) + SE_v2(i);
            if denom <= 0
                SE(i) = 0;
            else
                SE(i) = 100 * SE_v1(i) / denom;
            end
        case 'U'
            SE(i) = 50;          % uniform midpoint stand-in
        otherwise
            error('SE row %d: unknown type %s', i, SE_type{i});
    end
end

% --------------------------------------------------- topology flags
roots  = find(all(SOD == 0, 1)); roots  = roots(:);
leaves = find(all(SOD == 0, 2)); leaves = leaves(:);

% --------------------------------------------------- assemble cfg
cfg.n          = n;
cfg.labels     = labels;
cfg.SOD        = SOD;
cfg.COD        = COD;
cfg.IOD        = IOD;
cfg.SE_type    = SE_type;
cfg.SE_v1      = SE_v1;
cfg.SE_v2      = SE_v2;
cfg.SE         = SE;
cfg.roots      = roots;
cfg.leaves     = leaves;
cfg.toggles    = toggles;
cfg.overrides  = overrides;
cfg.events_log = events_log;

% ---------------------------------------------------- DAG sanity
gr = digraph(SOD ~= 0);
cfg.is_dag = isdag(gr);
end


% ======================================================================
function t = default_toggles(t)
% Fill missing toggle fields with the default-OFF state.
defaults = struct( ...
    'crew3', 0, 'crew3_pct', 100, ...
    'ltv_FA', 0, 'ltv_FA_pct', 100, ...
    'ltv_DS', 0, 'ltv_DS_pct', 100, ...
    'regolith', 0, 'regolith_pct', 0);
fns = fieldnames(defaults);
for k = 1:numel(fns)
    if ~isfield(t, fns{k}) || isempty(t.(fns{k}))
        t.(fns{k}) = defaults.(fns{k});
    end
end
end

% ======================================================================
function labels = read_labels(xlsx_path)
% Read the labels sheet (column A, n rows).
C = read_sheet_cell(xlsx_path, 'labels');
labels = C(:, 1);
mask = false(numel(labels), 1);
for k = 1:numel(labels)
    v = labels{k};
    if isstring(v); v = char(v); labels{k} = v; end
    mask(k) = ischar(v) && ~isempty(strtrim(v));
end
labels = labels(mask);
end

% ======================================================================
function [SOD, COD, IOD, SE_type, SE_v1, SE_v2] = read_defaults(xlsx_path, n)
% Read the Default Network Metrics tab into per-block matrices and SE arrays.
% Layout (1-based, matches the .xlsx):
%   SOD : rows 3-26,  cols B-Y       (B=2..Y=25)  -> 24 x 24
%   COD : rows 31-54, cols B-Y
%   IOD : rows 59-82, cols B-Y
%   SE  : rows 3-26,  cols AC,AD,AE  (AC=29 type, AD=30 v1, AE=31 v2)
C = read_sheet_cell(xlsx_path, 'Default Network Metrics');
[nr, nc] = size(C);
need_r = 82; need_c = 31;
assert(nr >= need_r && nc >= need_c, ...
    'Default Network Metrics: expected at least %d x %d, got %d x %d', ...
    need_r, need_c, nr, nc);

SOD = block_numeric(C,  3, 26, 2, 25);
COD = block_numeric(C, 31, 54, 2, 25);
IOD = block_numeric(C, 59, 82, 2, 25);
assert(isequal(size(SOD), [n n]), 'SOD block size mismatch');
assert(isequal(size(COD), [n n]), 'COD block size mismatch');
assert(isequal(size(IOD), [n n]), 'IOD block size mismatch');

SE_type = cell(n, 1);
SE_v1   = zeros(n, 1);
SE_v2   = zeros(n, 1);
for r = 1:n
    t = C{r + 2, 29};                      % col AC
    if isstring(t); t = char(t); end
    if isa(t, 'missing') || (isnumeric(t) && all(isnan(t)))
        t = 'D';
    end
    SE_type{r} = upper(t);
    v1 = C{r + 2, 30};
    v2 = C{r + 2, 31};
    SE_v1(r) = to_num(v1, 0);
    SE_v2(r) = to_num(v2, 0);
end
end

% ======================================================================
function M = block_numeric(C, r0, r1, c0, c1)
% Pull a rectangular numeric block out of a cell array; missing/blank -> 0.
nr = r1 - r0 + 1; nc = c1 - c0 + 1;
M  = zeros(nr, nc);
for ii = 1:nr
    for jj = 1:nc
        v = C{r0 + ii - 1, c0 + jj - 1};
        M(ii, jj) = to_num(v, 0);
    end
end
end

% ======================================================================
function x = to_num(v, default_val)
if isnumeric(v) && isscalar(v) && ~isnan(v)
    x = double(v);
elseif islogical(v) && isscalar(v)
    x = double(v);
elseif (ischar(v) || isstring(v))
    s = strtrim(char(v));
    if isempty(s)
        x = default_val;
    else
        n = sscanf(s, '%f');
        if isempty(n); x = default_val; else; x = n(1); end
    end
else
    x = default_val;
end
end

% ======================================================================
function i = idx(labels, name)
i = find(strcmp(labels, name), 1);
assert(~isempty(i), 'label not found: %s', name);
end

% ======================================================================
function [SOD, COD, IOD, log] = blend_edges(SOD, COD, IOD, edges, pct, ...
                                            labels, log, tag)
% Apply a list of edge transforms with linear blend by pct (0..1).
%   newval = old + pct * (J - old)
% edges is an Nx4 cell: {target, feeder, receiver, J}
for r = 1:size(edges, 1)
    tgt  = edges{r, 1};
    fi   = idx(labels, edges{r, 2});
    ri   = idx(labels, edges{r, 3});
    Jval = edges{r, 4};
    switch upper(tgt)
        case 'SOD'
            old = SOD(fi, ri);
            SOD(fi, ri) = old + pct * (Jval - old);
            new = SOD(fi, ri);
        case 'COD'
            old = COD(fi, ri);
            COD(fi, ri) = old + pct * (Jval - old);
            new = COD(fi, ri);
        case 'IOD'
            old = IOD(fi, ri);
            IOD(fi, ri) = old + pct * (Jval - old);
            new = IOD(fi, ri);
        otherwise
            error('blend_edges: unknown target %s', tgt);
    end
    log{end+1,1} = sprintf('%s %.0f%%: %s %s->%s  %.3f -> %.3f', ...
        tag, 100*pct, tgt, edges{r,2}, edges{r,3}, old, new);
end
end

% ======================================================================
function [SOD, COD, IOD, SE_type, SE_v1, SE_v2, msg] = ...
    apply_override(SOD, COD, IOD, SE_type, SE_v1, SE_v2, labels, o)
% Apply one override struct (parametric sweep slot).
fi = idx(labels, o.feeder);
switch upper(o.target)
    case 'SE_VALUE'
        SE_v1(fi) = double(o.value);
        msg = sprintf('SE value %s = %.3f', o.feeder, SE_v1(fi));
    case 'SE_ALPHA'
        SE_v1(fi) = double(o.value);
        msg = sprintf('SE alpha %s = %.3f', o.feeder, SE_v1(fi));
    case 'SE_BETA'
        SE_v2(fi) = double(o.value);
        msg = sprintf('SE beta  %s = %.3f', o.feeder, SE_v2(fi));
    case 'SE_TYPE'
        c = char(o.value);
        SE_type{fi} = upper(c(1));
        msg = sprintf('SE type  %s = %s', o.feeder, SE_type{fi});
    case {'SOD','COD','IOD'}
        ri = idx(labels, o.receiver);
        switch upper(o.target)
            case 'SOD'; SOD(fi, ri) = double(o.value);
            case 'COD'; COD(fi, ri) = double(o.value);
            case 'IOD'; IOD(fi, ri) = double(o.value);
        end
        msg = sprintf('%s %s->%s = %.3f', o.target, o.feeder, o.receiver, double(o.value));
    otherwise
        error('apply_override: unknown target %s', o.target);
end
end

% ======================================================================
function C = read_sheet_cell(path, sheet)
% Read a worksheet by name into a cell array, with consistent types across
% platforms. readcell (R2019a+) handles mixed text/numeric cleanly; xlsread
% basic mode (Mac/Linux without Excel) garbles text in the raw output.
if exist('readcell', 'file') == 2 || exist('readcell', 'builtin') == 5
    C = readcell(path, 'Sheet', sheet);
    for k = 1:numel(C)
        if isa(C{k}, 'missing'); C{k} = NaN; end
    end
else
    [~, ~, C] = xlsread(path, sheet);
end
end
