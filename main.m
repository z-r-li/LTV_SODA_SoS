function summary = main(varargin)
%MAIN  Top-level entry point for the AAE 560 LTV-SODA-SoS pipeline.
%   Adds src/ and third_party/SODA_2.2_pcode/ to the MATLAB path, then
%   runs the four-scenario poster pipeline against
%   data/SODA_configurations_input.xlsx.
%
%   >> summary = main();              % full run, defaults
%   >> opts.N = 200; opts.plot = false;
%   >> summary = main(opts);          % quick smoke test
%
% Returns the comparative summary table written by run_poster.m.

here = fileparts(mfilename('fullpath'));

addpath(fullfile(here, 'src'));
addpath(fullfile(here, 'third_party', 'SODA_2.2_pcode'));

xlsx = fullfile(here, 'data', 'SODA_configurations_input.xlsx');
out_dir = fullfile(here, 'results');
if exist(out_dir, 'dir') ~= 7
    mkdir(out_dir);
end

if nargin == 0
    opts = struct();
else
    opts = varargin{1};
end
if ~isfield(opts, 'out_dir')
    opts.out_dir = out_dir;
end

summary = run_poster(xlsx, opts);
end
