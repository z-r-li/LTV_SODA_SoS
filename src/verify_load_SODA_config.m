function verify_load_SODA_config(xlsx_path)
%VERIFY_LOAD_SODA_CONFIG  Smoke-test load_SODA_config.m against several
% toggle states. Prints DAG status, edge counts, root/leaf labels, and the
% deterministic operability vector returned by SODA() for each scenario.
%
%   >> addpath('SODA_2.2_pcode')   % so SODA.p is on the path
%   >> verify_load_SODA_config('SODA_configurations_input.xlsx')

if nargin < 1 || isempty(xlsx_path)
    xlsx_path = 'SODA_configurations_input.xlsx';
end

% ----------------------------------------------------- Scenario A: Default
fprintf('\n===== A. Default (Decision-Approval LTV, no Crew3, no Regolith) =====\n');
cfg = load_SODA_config(xlsx_path);
report(cfg);

% ----------------------------------------------------- Scenario B: Crew3 ON
fprintf('\n===== B. Crew3 ON =====\n');
cfg = load_SODA_config(xlsx_path, struct('crew3', 1));
report(cfg);

% ----------------------------------------------------- Scenario C: LTV Decision Support
fprintf('\n===== C. LTV Decision Support =====\n');
cfg = load_SODA_config(xlsx_path, struct('ltv_DS', 1));
report(cfg);

% ----------------------------------------------------- Scenario D: LTV Fully Autonomous
fprintf('\n===== D. LTV Fully Autonomous =====\n');
cfg = load_SODA_config(xlsx_path, struct('ltv_FA', 1));
report(cfg);

% ----------------------------------------------------- Scenario E: Regolith @ 100%
fprintf('\n===== E. Regolith ON @ 100%% =====\n');
cfg = load_SODA_config(xlsx_path, ...
    struct('regolith', 1, 'regolith_pct', 100));
report(cfg);

% ----------------------------------------------------- Scenario F: Set 1 / S1 (Crew1 SE drop)
fprintf('\n===== F. Set 1 / Scenario 1: Crew1 SE -> 15 deterministic =====\n');
ovr = make_se_drop_overrides({'Crew1_Obs','Crew1_Ori','Crew1_Dec','Crew1_Act'}, 15);
cfg = load_SODA_config(xlsx_path, struct(), ovr);
report(cfg);

% ----------------------------------------------------- Scenario G: Set 2 / Increased
fprintf('\n===== G. Set 2 / Increased dependency on LTV route plan =====\n');
ovr = make_dep_overrides('LTV_Ori','Crew1_Dec', 0.9, 75, 75);
cfg = load_SODA_config(xlsx_path, struct(), ovr);
report(cfg);

fprintf('\nAll 7 scenarios loaded without error.\n');
end


% ======================================================================
function ovr = make_se_drop_overrides(node_names, value)
% Build an override list that pins each named SE to a deterministic value.
ovr = repmat(struct('target','','feeder','','receiver','','value',NaN), 0, 0);
for k = 1:numel(node_names)
    ovr(end+1) = struct('target','SE_type','feeder',node_names{k}, ...
                        'receiver','','value','D'); %#ok<AGROW>
    ovr(end+1) = struct('target','SE_value','feeder',node_names{k}, ...
                        'receiver','','value', value); %#ok<AGROW>
end
end


% ======================================================================
function ovr = make_dep_overrides(feeder, receiver, sod, cod, iod)
ovr = struct('target',{},'feeder',{},'receiver',{},'value',{});
ovr(end+1) = struct('target','SOD','feeder',feeder,'receiver',receiver,'value',sod);
ovr(end+1) = struct('target','COD','feeder',feeder,'receiver',receiver,'value',cod);
ovr(end+1) = struct('target','IOD','feeder',feeder,'receiver',receiver,'value',iod);
end


% ======================================================================
function report(cfg)
fprintf('  is_dag: %d\n', cfg.is_dag);
fprintf('  edges:  SOD=%d  COD=%d  IOD=%d\n', ...
    nnz(cfg.SOD), nnz(cfg.COD), nnz(cfg.IOD));
fprintf('  roots:  ');  print_lab(cfg.labels, cfg.roots);
fprintf('  leaves: ');  print_lab(cfg.labels, cfg.leaves);

% Run SODA on the deterministic SE point and print Op
try
    if cfg.is_dag
        Op = SODA(cfg.SE(:)', cfg.SOD, cfg.COD, cfg.IOD);
    else
        Op = SODAcycle(cfg.SE(:)', cfg.SOD, cfg.COD, cfg.IOD);
    end
    fprintf('  Op (mean, leaves):  Onet=%.2f, ', mean(Op));
    leaf_op = Op(cfg.leaves);
    fprintf('leaf_min=%.2f, leaf_mean=%.2f\n', min(leaf_op), mean(leaf_op));
    fprintf('  Per-leaf:\n');
    for k = 1:numel(cfg.leaves)
        i = cfg.leaves(k);
        fprintf('    %-14s  SE=%-7.2f  Op=%6.2f\n', cfg.labels{i}, cfg.SE(i), Op(i));
    end
catch ME
    fprintf('  SODA call FAILED: %s\n', ME.message);
end

if ~isempty(cfg.events_log)
    fprintf('  events_log (%d):\n', numel(cfg.events_log));
    for k = 1:numel(cfg.events_log)
        fprintf('    %s\n', cfg.events_log{k});
    end
end
end


% ======================================================================
function print_lab(labels, idx_list)
if isempty(idx_list)
    fprintf('(none)\n');
    return;
end
parts = cell(1, numel(idx_list));
for k = 1:numel(idx_list)
    parts{k} = labels{idx_list(k)};
end
fprintf('%s\n', strjoin(parts, ', '));
end
