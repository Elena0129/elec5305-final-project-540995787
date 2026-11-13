function restored = restore_benchmark_audio(pairIDs, methods)
% Rebuild omitted output WAVs from the published gains, without refitting EQ.
% Examples:
%   restore_benchmark_audio("clip_005_mid_boost", "Centroid")
%   restore_benchmark_audio("clip_001_mid_cut")
%   restore_benchmark_audio("all")
% This reproduces saved processors; it is not a fresh optimisation run.

if nargin < 1
    pairIDs = "all";
end
if nargin < 2
    methods = ["Centroid", "Three-band", "Differentiable"];
end

rootDir = fileparts(mfilename('fullpath'));
file = fullfile(rootDir, 'results', 'batch_comparison', 'batch_results.csv');
opts = detectImportOptions(file, 'TextType', 'string');
textVars = {'PairID', 'Method', 'Status', ...
    'ReferencePath', 'InputPath', 'OutputPath'};
opts = setvartype(opts, textVars, 'string');
R = readtable(file, opts);

pairIDs = string(pairIDs);
methods = string(methods);
assert(all(ismember(methods, ...
    ["Distorted", "Centroid", "Three-band", "Differentiable"])), ...
    'ELEC5305:UnknownMethod', 'An unrecognised benchmark method was requested.');

if isscalar(pairIDs) && pairIDs == "all"
    selected = ismember(R.Method, methods);
else
    assert(~isempty(pairIDs) && all(ismember(pairIDs, R.PairID)), ...
        'ELEC5305:UnknownPair', 'A requested PairID is absent from the results.');
    selected = ismember(R.PairID, pairIDs) & ismember(R.Method, methods);
end

R = R(selected, :);
assert(~isempty(R) && all(R.Status == "OK"), ...
    'ELEC5305:InvalidResults', 'Valid saved benchmark rows are required.');

created = false(height(R), 1);
paths = strings(height(R), 1);
loaded = load(fullfile(rootDir, 'data', 'batch', 'protocol.mat'), 'protocol');
protocol = loaded.protocol;

for k = 1:height(R)
    inputPath = project_audio_path(rootDir, R.InputPath(k));
    outputPath = project_audio_path(rootDir, R.OutputPath(k), false);
    paths(k) = outputPath;
    if isfile(outputPath)
        continue;
    end

    [input, fs] = audioread(inputPath);
    gains = R{k, {'LowGainDB', 'MidGainDB', 'HighGainDB'}}';
    assert(all(isfinite(gains)) && iscolumn(input), ...
        'ELEC5305:InvalidAudio', 'Saved gains and mono input must be valid.');

    output = input;
    if R.Method(k) == "Differentiable"
        % Use exactly the final numeric coefficients from run_differentiable_eq.
        for section = 1:3
            [b, a] = eqCoefficients(gains(section), section, fs);
            output = filter(b, a, output);
        end
    elseif R.Method(k) ~= "Distorted"
        for section = 1:3
            if gains(section) == 0, continue; end
            if section == 2
                [b, a] = project_param_eq(2, gains(section), ...
                    protocol.FrequenciesHz(2)/(fs/2), ...
                    protocol.MidBandwidthHz/(fs/2), 'Orientation', 'row');
            else
                if section == 1, type = 'lo'; else, type = 'hi'; end
                [b, a] = designShelvingEQ(gains(section), ...
                    protocol.ShelfSlope, protocol.FrequenciesHz(section)/(fs/2), ...
                    type, 'Orientation', 'row');
            end
            output = filter(b, a, output);
        end
    end

    assert(all(isfinite(output)) && max(abs(output)) < 1, ...
        'ELEC5305:InvalidAudio', 'Reconstructed output is invalid or clipped.');
    folder = fileparts(char(outputPath));
    if ~isfolder(folder), mkdir(folder); end
    audiowrite(outputPath, output, fs, 'BitsPerSample', 24);

    % Remeasure the saved WAV using the original benchmark definitions.
    [output, fsOut] = audioread(outputPath);
    [reference, fsRef] = audioread( ...
        project_audio_path(rootDir, R.ReferencePath(k)));
    assert(fsOut == fs && fsRef == fs && ...
        isequal(size(output), size(reference)), ...
        'ELEC5305:AudioDimensions', 'Restored audio dimensions do not match.');
    window = hann(protocol.WindowLength, 'periodic');
    [pRef, f] = pwelch(reference, window, ...
        protocol.OverlapLength, protocol.FFTLength, fs);
    pOut = pwelch(output, window, ...
        protocol.OverlapLength, protocol.FFTLength, fs);
    keep = f >= 20 & f <= 16000;
    pRef = pRef(keep);
    pOut = pOut(keep);
    f = f(keep);
    raw = sqrt(mean((10*log10(max(pOut, realmin)) - ...
        10*log10(max(pRef, realmin))).^2));
    centroid = abs(sum(f.*pOut)/sum(pOut) - sum(f.*pRef)/sum(pRef));
    assert(abs(raw - R.LogPowerRMSEdB(k)) < 1e-4 && ...
        abs(centroid - R.CentroidErrorHz(k)) < 1e-4, ...
        'ELEC5305:RestoreMismatch', ...
        'Restored audio disagrees with the recorded metrics for %s (%s).', ...
        char(R.PairID(k)), char(R.Method(k)));
    created(k) = true;
end

restored = table(R.PairID, R.Method, paths, created, ...
    'VariableNames', {'PairID', 'Method', 'OutputPath', 'Created'});
fprintf('Saved-gain audio: %d created, %d already present.\n', ...
    nnz(created), nnz(~created));
end


function [b, a] = eqCoefficients(gainDB, section, fs)
% Same numeric processor as the original differentiable EQ; no dlarray needed.
frequencies = [250 1000 2500];
w0 = 2*pi*frequencies(section)/fs;
c = cos(w0);
A = exp(log(10)*gainDB/40);
if section == 2
    alpha = tan(pi*1000/fs);
    b = [1 + alpha*A, -2*c, 1 - alpha*A];
    a = [1 + alpha/A, -2*c, 1 - alpha/A];
elseif section == 1
    u = sin(w0)*sqrt(2*A);
    b = A.*[(A+1)-(A-1)*c+u, ...
        2*((A-1)-(A+1)*c), (A+1)-(A-1)*c-u];
    a = [(A+1)+(A-1)*c+u, ...
        -2*((A-1)+(A+1)*c), (A+1)+(A-1)*c-u];
else
    u = sin(w0)*sqrt(2*A);
    b = A.*[(A+1)+(A-1)*c+u, ...
        -2*((A-1)+(A+1)*c), (A+1)+(A-1)*c-u];
    a = [(A+1)-(A-1)*c+u, ...
        2*((A-1)-(A+1)*c), (A+1)-(A-1)*c-u];
end
a0 = a(1);
b = b./a0;
a = a./a0;
end
