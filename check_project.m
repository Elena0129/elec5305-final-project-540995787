function verification = check_project(mode)
% Check the files required by the published demo or a fresh experiment run.
% "demo" (default): data, toolboxes and saved formal results.
% "compute": data and toolboxes; saved experiment outputs are not required.
% "saved": data and saved formal result tables, without toolbox probes.
% This checks prerequisites; it does not refit the benchmark.

if nargin < 1, mode = "demo"; end
mode = string(mode);
assert(isscalar(mode) && any(mode == ["demo", "compute", "saved"]), ...
    'ELEC5305:CheckMode', 'Mode must be demo, compute, or saved.');
rootDir = fileparts(mfilename('fullpath'));
fprintf('Project folder: %s\nMATLAB release: %s\n', rootDir, version('-release'));

required = {
    'data/batch/manifest.csv'
    'data/batch/references.csv'
    'data/batch/conditions.csv'
    'data/batch/protocol.mat'
    'data/pilot/source_manifest.csv'
    'data/pilot/reference_01.wav'
    'data/pilot/reference_02.wav'
    'data/pilot/reference_03.wav'
};
for k = 1:numel(required)
    assert(isfile(fullfile(rootDir, required{k})), ...
        'ELEC5305:MissingFile', 'Required file is missing: %s', required{k});
end

file = fullfile(rootDir, 'data', 'batch', 'manifest.csv');
opts = detectImportOptions(file, 'TextType', 'string');
opts = setvartype(opts, ...
    {'PairID', 'ClipID', 'PerformerID', 'ReferenceFile', 'Condition'}, 'string');
M = readtable(file, opts);
assert(height(M) == 240 && numel(unique(M.PairID)) == 240 && ...
    numel(unique(M.ClipID)) == 30 && numel(unique(M.PerformerID)) == 6, ...
    'ELEC5305:Manifest', 'Expected 240 pairs, 30 clips and six performers.');
refs = unique(M.ReferenceFile);
for k = 1:numel(refs)
    path = project_audio_path(rootDir, refs(k));
    info = audioinfo(path);
    assert(info.SampleRate == 44100 && info.NumChannels == 1 && ...
        info.TotalSamples == 220500, 'ELEC5305:ReferenceAudio', ...
        'Expected a five-second mono 44.1 kHz reference: %s', char(path));
end
if mode ~= "compute"
    for k = 1:height(M)
        project_audio_path(rootDir, ...
            "data/batch/distorted/" + M.PairID(k) + ".wav");
    end
end
P = readtable(fullfile(rootDir, 'data', 'pilot', 'source_manifest.csv'), ...
    'TextType', 'string');
Q = readtable(fullfile(rootDir, 'data', 'batch', 'references.csv'), ...
    'TextType', 'string');
assert(height(P) == 3 && height(Q) == 30 && ...
    numel(unique(string(Q.SourceFile))) == 30 && ...
    isempty(intersect(lower(string(P.sourceFile)), lower(string(Q.SourceFile)))), ...
    'ELEC5305:SourceSplit', 'Pilot and test source recordings must be distinct.');
fprintf('Prepared metadata: 3 pilot references, 30 test references, 240 pairs.\n');
if mode ~= "compute", fprintf('Supplied distorted inputs: 240 found.\n'); end
fprintf('Pilot/test source-recording overlap: 0.\n');

if mode ~= "saved"
    requiredFunctions = {'pwelch', 'hann', 'freqz', 'spectrogram', ...
        'designParamEQ', 'designShelvingEQ', ...
        'dlarray', 'dlfeval', 'dlgradient', 'adamupdate'};
    missing = requiredFunctions(cellfun(@(x) isempty(which(x)), requiredFunctions));
    assert(isempty(missing), 'ELEC5305:Toolboxes', ...
        'Missing MATLAB functions: %s. See README requirements.', strjoin(missing, ', '));
    [b, a] = project_param_eq(2, -6, 1000/22050, 1000/22050, ...
        'Orientation', 'row');
    omega = 2*pi*1000/44100;
    response = freqz(b, a, [omega; omega]);
    centreGain = 20*log10(abs(response(1)));
    assert(abs(centreGain + 6) < 1e-7, 'ELEC5305:FilterProbe', ...
        'The peaking-EQ interface did not preserve its centre gain.');
    x = dlarray(3);
    gradient = dlfeval(@squareGradient, x);
    assert(abs(double(extractdata(gradient)) - 6) < 1e-8, ...
        'ELEC5305:AutodiffProbe', 'Automatic differentiation failed.');
    adamupdate(x, gradient, [], [], 1, 0.01);
    fprintf('Filter design, automatic differentiation and Adam: PASS.\n');
end

moduleNames = ["Batch comparison"; "Extended evaluation"; ...
    "Content dependence"; "Matched-capacity ablation"; "Model mismatch"];
expected = [960; 960; 60; 960; 1200];
actual = nan(5, 1);

if mode ~= "compute"
    csvFiles = {
        'results/batch_comparison/batch_results.csv'
        'results/extended_evaluation/extended_metrics.csv'
        'results/content_dependence/content_cases.csv'
        'results/capacity_ablation/ablation_cases.csv'
        'results/model_mismatch/mismatch_cases.csv'
    };
    for k = 1:numel(csvFiles)
        path = fullfile(rootDir, csvFiles{k});
        assert(isfile(path), 'ELEC5305:MissingResults', ...
            'Saved results are missing: %s', csvFiles{k});
        T = readtable(path, 'TextType', 'string');
        actual(k) = height(T);
        assert(actual(k) == expected(k), 'ELEC5305:ResultRows', ...
            'Unexpected number of result rows in %s.', csvFiles{k});
        if ismember('Status', T.Properties.VariableNames)
            assert(all(string(T.Status) == "OK"), 'ELEC5305:FailedResults', ...
                'A saved result row has failed status.');
        end
        metrics = intersect({'LogPowerRMSEdB', 'RawRMSEdB', ...
            'ShapeRMSEdB', 'MRLogRMSEdB'}, T.Properties.VariableNames, 'stable');
        assert(~isempty(metrics) && all(isfinite(T{:, metrics}), 'all'), ...
            'ELEC5305:ResultMetrics', 'Saved metrics must be finite.');
    end
    matFiles = {
        'results/extended_evaluation/evaluation_settings.mat'
        'results/content_dependence/content_dependence_results.mat'
        'results/capacity_ablation/capacity_ablation_results.mat'
        'results/model_mismatch/model_mismatch_results.mat'
    };
    for k = 1:numel(matFiles)
        path = fullfile(rootDir, matFiles{k});
        assert(isfile(path), 'ELEC5305:MissingResults', ...
            'Required saved MAT file is missing: %s', matFiles{k});
        vars = whos('-file', path);
        if k == 1, variable = 'cfg'; else, variable = 'report'; end
        assert(ismember(variable, {vars.name}), 'ELEC5305:SavedMAT', ...
            'A required variable is missing from %s.', matFiles{k});
    end
end

verification = table(moduleNames, expected, actual, ...
    'VariableNames', {'Module', 'ExpectedRows', 'SavedRows'});
if mode ~= "compute", disp(verification); end
fprintf('Project prerequisite check passed (%s).\n', char(mode));
fprintf('Omitted batch output WAVs can be restored from saved gains or refitted.\n');
end


function gradient = squareGradient(x)
gradient = dlgradient(x.^2, x);
end
