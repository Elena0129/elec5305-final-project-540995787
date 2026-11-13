function allResults = run_batch_comparison(resume)
% Compare three EQ methods on every prepared test pair.
% Call again to resume. Use false to start a fresh evaluation.
% Optimization timings exclude audio file writing and final measurement.

if nargin < 1
    resume = true;
end

rootDir = fileparts(mfilename('fullpath'));
manifestPath = fullfile(rootDir, 'data', 'batch', 'manifest.csv');

options = detectImportOptions(manifestPath, 'TextType', 'string');
options = setvartype(options, ...
    {'PairID','ClipID','PerformerID','ReferenceFile','Condition'}, ...
    'string');
manifest = readtable(manifestPath, options);

loaded = load(fullfile(rootDir, 'data', 'batch', 'protocol.mat'));
protocol = loaded.protocol;

% Match the settings used by the differentiable EQ.
assert(isequal(protocol.FrequenciesHz(:), [250;1000;2500]) && ...
    protocol.MidBandwidthHz == 1000 && protocol.ShelfSlope == 1 && ...
    protocol.WindowLength == 2048 && ...
    protocol.OverlapLength == 1024 && protocol.FFTLength == 2048 && ...
    isequal(protocol.BandEdgesHz(:), [20;500;2000;16000]), ...
    'The batch protocol does not match the EQ settings.');

nPairs = height(manifest);

assert(numel(unique(manifest.PairID)) == nPairs, ...
    'Pair IDs must be unique.');

methods = ["Distorted"; "Centroid"; "Three-band"; "Differentiable"];
folderNames = ["centroid"; "three_band"];

outDir = fullfile(rootDir, 'results', 'batch_comparison');
inputDir = fullfile(rootDir, 'data', 'batch', 'distorted');

if ~isfolder(outDir), mkdir(outDir); end
if ~isfolder(inputDir), mkdir(inputDir); end

% Identify the code, protocol and reference files used by this run.
referenceNames = unique(manifest.ReferenceFile);
referenceMetadata = cell(numel(referenceNames), 1);

for k = 1:numel(referenceNames)
    info = dir(fullfile(rootDir, char(referenceNames(k))));
    assert(numel(info) == 1 && ~info.isdir, ...
        'A reference audio file is missing.');
    referenceMetadata{k} = ...
        {char(referenceNames(k)), info.bytes, info.datenum};
end

key = { ...
    fileread([mfilename('fullpath'), '.m']), ...
    fileread(fullfile(rootDir, 'run_differentiable_eq.m')), ...
    fileread(fullfile(rootDir, 'project_param_eq.m')), ...
    fileread(manifestPath), protocol, referenceMetadata, version};

checkpointPath = fullfile(outDir, 'checkpoint.mat');

if resume && isfile(checkpointPath)
    saved = load(checkpointPath);

    assert(isequaln(saved.key, key), ...
        ['Code or data changed. Use run_batch_comparison(false) ' ...
         'to start a fresh evaluation.']);

    allResults = saved.allResults;
    done = saved.done;
    fitHistory = saved.fitHistory;
else
    nRows = 4*nPairs;

    PairID = repelem(manifest.PairID, 4);
    ClipID = repelem(manifest.ClipID, 4);
    PerformerID = repelem(manifest.PerformerID, 4);
    Condition = repelem(manifest.Condition, 4);
    Method = repmat(methods, nPairs, 1);

    Status = repmat("PENDING", nRows, 1);
    ReferencePath = strings(nRows, 1);
    InputPath = strings(nRows, 1);
    OutputPath = strings(nRows, 1);
    ErrorID = strings(nRows, 1);

    allResults = table(PairID, ClipID, PerformerID, Condition, ...
        Method, Status, ReferencePath, InputPath, OutputPath, ErrorID);

    metricNames = {'CentroidErrorHz','LogPowerRMSEdB', ...
        'LowErrorDB','MidErrorDB','HighErrorDB', ...
        'OptimizationSeconds','LowGainDB','MidGainDB','HighGainDB','Peak'};

    allResults = [allResults, ...
        array2table(nan(nRows,10), 'VariableNames', metricNames)];

    allResults.GainBoundaryHit = false(nRows,1);
    done = false(nPairs,1);
    fitHistory = cell(nPairs,3);

    saveProgress(checkpointPath, allResults, done, ...
        fitHistory, key, protocol);
end

metricNames = {'CentroidErrorHz','LogPowerRMSEdB', ...
    'LowErrorDB','MidErrorDB','HighErrorDB', ...
    'OptimizationSeconds','LowGainDB','MidGainDB','HighGainDB','Peak'};

fprintf('Test pairs: %d\n', nPairs);
fprintf('Previously completed pairs: %d\n', nnz(done));

firstPending = find(~done, 1);

for i = 1:nPairs
    if done(i), continue; end

    rows = (i-1)*4 + (1:4);
    runID = char(manifest.PairID(i));

    refPath = fullfile(rootDir, char(manifest.ReferenceFile(i)));
    inputPath = fullfile(inputDir, [runID, '.wav']);

    allResults.ReferencePath(rows) = string(refPath);
    allResults.InputPath(rows) = string(inputPath);

    try
        [ref, fs] = audioread(refPath);

        assert(iscolumn(ref) && all(isfinite(ref)), ...
            'Reference audio must be finite and mono.');
        assert(fs == manifest.SampleRate(i), ...
            'The reference sample rate does not match the manifest.');

        % Known gains create the input only. Fitters do not receive them.
        knownGains = manifest{i, ...
            {'LowGainDB','MidGainDB','HighGainDB'}}';

        input = applyEQ(ref, knownGains, fs, protocol);
        writeAudio(inputPath, input, fs);

        % Every method receives exactly the same saved input.
        [input, fsInput] = audioread(inputPath);
        assert(fsInput == fs, 'Input sample rate mismatch.');

        context = makeContext(ref, fs, protocol);

        % Exclude one warm-up attempt from the recorded fitting times.
        if i == firstPending
            try
                fitSimple("Centroid", input, context, fs, protocol);
                fitSimple("Three-band", input, context, fs, protocol);
                run_differentiable_eq( ...
                    refPath, inputPath, 'batch_warmup');
                fprintf('Warm-up completed.\n');
            catch warmError
                fprintf('Warm-up warning: %s\n', warmError.identifier);
            end
        end

        for m = 1:4
            row = rows(m);

            try
                if m == 1
                    output = input;
                    outputPath = inputPath;
                    gains = zeros(3,1);
                    seconds = 0;

                elseif m == 4
                    [~, fit] = run_differentiable_eq( ...
                        refPath, inputPath, runID);

                    gains = fit.GainsDB;
                    seconds = fit.OptimizationSeconds;
                    outputPath = char(fit.OutputPath);

                    [output, fsOutput] = audioread(outputPath);
                    assert(fsOutput == fs, 'Output sample rate mismatch.');

                    fitHistory{i,3} = fit;

                else
                    fitClock = tic;
                    [gains, history] = fitSimple( ...
                        methods(m), input, context, fs, protocol);
                    seconds = toc(fitClock);

                    output = applyEQ(input, gains, fs, protocol);

                    outputPath = fullfile(outDir, 'corrected', ...
                        char(folderNames(m-1)), [runID, '.wav']);

                    writeAudio(outputPath, output, fs);
                    [output, fsOutput] = audioread(outputPath);
                    assert(fsOutput == fs, 'Output sample rate mismatch.');

                    fitHistory{i,m-1} = struct( ...
                        'GainsDB', gains, 'History', history, ...
                        'OptimizationSeconds', seconds);
                end

                [centroidError, spectrumError, bandErrors] = ...
                    measureOutput(output, context, fs, protocol);

                values = [centroidError, spectrumError, bandErrors', ...
                    seconds, gains', max(abs(output))];

                assert(all(isfinite(values)), ...
                    'A measured result is non-finite.');

                allResults{row,metricNames} = values;
                allResults.OutputPath(row) = string(outputPath);
                allResults.GainBoundaryHit(row) = ...
                    any(abs(gains) >= 11.99);
                allResults.Status(row) = "OK";

            catch methodError
                allResults.Status(row) = "FAILED";
                allResults.ErrorID(row) = string(methodError.identifier);
            end
        end

    catch pairError
        allResults.Status(rows) = "FAILED";
        allResults.ErrorID(rows) = string(pairError.identifier);
    end

    done(i) = true;

    saveProgress(checkpointPath, allResults, done, ...
        fitHistory, key, protocol);

    attempted = allResults.Status ~= "PENDING";
    writetable(allResults(attempted,:), ...
        fullfile(outDir, 'batch_results_partial.csv'));

    if mod(i,10) == 0 || i == nPairs || ...
            any(allResults.Status(rows) == "FAILED")
        fprintf('Pairs completed: %d/%d | Failed rows so far: %d\n', ...
            nnz(done), nPairs, nnz(allResults.Status == "FAILED"));
    end
end

summary = summarizeRows(allResults, methods);

conditions = unique(manifest.Condition, 'stable');
conditionTables = cell(numel(conditions),1);

for k = 1:numel(conditions)
    selected = allResults.Condition == conditions(k);
    part = summarizeRows(allResults(selected,:), methods);
    part.Condition = repmat(conditions(k), height(part), 1);
    conditionTables{k} = part;
end

conditionSummary = vertcat(conditionTables{:});

writetable(allResults, fullfile(outDir, 'batch_results.csv'));
writetable(summary, fullfile(outDir, 'summary_by_method.csv'));
writetable(conditionSummary, ...
    fullfile(outDir, 'summary_by_condition.csv'));

writetable(allResults(allResults.Status == "FAILED",:), ...
    fullfile(outDir, 'failed_results.csv'));

fprintf('\nAll %d pairs have been attempted.\n', nPairs);

for k = 1:height(summary)
    fprintf('\n%s: valid %d/%d, failed %d\n', ...
        char(summary.Method(k)), summary.Valid(k), ...
        summary.Expected(k), summary.Failed(k));
    fprintf('Mean centroid error: %.6f Hz\n', ...
        summary.MeanCentroidErrorHz(k));
    fprintf('Mean log-power RMSE: %.6f dB\n', ...
        summary.MeanLogPowerRMSEdB(k));
    fprintf('Median optimization time: %.4f s\n', ...
        summary.MedianOptimizationSeconds(k));
end

fig = figure('Color','w');
tiledlayout(2,1,'TileSpacing','compact');

nexttile;
bar(summary.MeanLogPowerRMSEdB);
xticks(1:4);
xticklabels(methods);
ylabel('Mean log-power RMSE (dB)');
title('Measured spectral error');
grid on;

nexttile;
bar(summary.MedianOptimizationSeconds(2:4));
xticks(1:3);
xticklabels(methods(2:4));
ylabel('Median optimization time (s)');
title('Fitting time excluding audio file I/O');
grid on;

exportgraphics(fig, fullfile(outDir, ...
    'batch_method_comparison.png'), 'Resolution', 200);
end


function context = makeContext(ref, fs, protocol)
context.Window = hann(protocol.WindowLength, 'periodic');

[power, frequency] = pwelch(ref, context.Window, ...
    protocol.OverlapLength, protocol.FFTLength, fs);

context.InBand = frequency >= 20 & frequency <= 16000;
context.Frequency = frequency(context.InBand);
context.RefPower = power(context.InBand);
context.RefDB = 10*log10(max(context.RefPower, realmin));

context.Centroid = sum(context.Frequency.*context.RefPower) / ...
    sum(context.RefPower);

edges = protocol.BandEdgesHz;
context.BandMatrix = zeros(3, numel(context.Frequency));

for k = 1:3
    mask = context.Frequency >= edges(k) & ...
        context.Frequency < edges(k+1);

    if k == 3
        mask = context.Frequency >= edges(k) & ...
            context.Frequency <= edges(k+1);
    end

    context.BandMatrix(k,:) = double(mask)';
end

context.RefBandPower = context.BandMatrix*context.RefPower;

assert(all(context.RefBandPower > 0), ...
    'A reference frequency band has no power.');
end


function [gains, history] = fitSimple(method, input, context, fs, protocol)
if method == "Centroid"
    bestError = Inf;
    bestGain = 0;
    history = zeros(0,2);

    for pass = 1:2
        if pass == 1
            candidates = -12:0.5:12;
        else
            lower = max(-12, bestGain-0.5);
            upper = min(12, bestGain+0.5);
            candidates = lower:0.01:upper;
        end

        for gain = candidates
            output = applyEQ(input, [0;0;gain], fs, protocol);
            power = getPower(output, context, fs, protocol);

            centroid = sum(context.Frequency.*power)/sum(power);
            value = abs(centroid-context.Centroid);

            history(end+1,:) = [gain,value]; %#ok<AGROW>

            if value < bestError
                bestError = value;
                bestGain = gain;
            end
        end
    end

    gains = [0;0;bestGain];

else
    currentGains = zeros(3,1);
    gains = currentGains;
    bestScore = Inf;
    history = zeros(30,7);

    for iteration = 1:30
        output = applyEQ(input, currentGains, fs, protocol);
        power = getPower(output, context, fs, protocol);

        errors = 10*log10(max(context.BandMatrix*power, realmin) ...
            ./ context.RefBandPower);

        score = sum(errors.^2);
        history(iteration,:) = [currentGains', errors', score];

        if score < bestScore
            bestScore = score;
            gains = currentGains;
        end

        if max(abs(errors)) <= 0.02
            break;
        end

        currentGains = min(12, max(-12, currentGains-0.7*errors));
    end

    history = history(1:iteration,:);
end
end


function output = applyEQ(input, gains, fs, protocol)
output = input;

for section = 1:3
    if gains(section) == 0, continue; end

    if section == 2
        [b,a] = project_param_eq(2, gains(section), ...
            protocol.FrequenciesHz(2)/(fs/2), ...
            protocol.MidBandwidthHz/(fs/2), ...
            'Orientation','row');
    else
        if section == 1, type = 'lo'; else, type = 'hi'; end

        [b,a] = designShelvingEQ(gains(section), ...
            protocol.ShelfSlope, ...
            protocol.FrequenciesHz(section)/(fs/2), ...
            type, 'Orientation','row');
    end

    output = filter(b,a,output);
end
end


function power = getPower(output, context, fs, protocol)
assert(all(isfinite(output)), 'Audio contains non-finite values.');

power = pwelch(output, context.Window, ...
    protocol.OverlapLength, protocol.FFTLength, fs);

power = power(context.InBand);
end


function [centroidError, spectrumError, bandErrors] = ...
    measureOutput(output, context, fs, protocol)

power = getPower(output, context, fs, protocol);

centroid = sum(context.Frequency.*power)/sum(power);
centroidError = abs(centroid-context.Centroid);

difference = 10*log10(max(power,realmin))-context.RefDB;
spectrumError = sqrt(mean(difference.^2));

bandErrors = 10*log10(max(context.BandMatrix*power, realmin) ...
    ./ context.RefBandPower);
end


function writeAudio(path, audio, fs)
assert(all(isfinite(audio)) && max(abs(audio)) < 1, ...
    'Audio contains invalid values or clipping.');

folder = fileparts(path);
if ~isfolder(folder), mkdir(folder); end

audiowrite(path, audio, fs, 'BitsPerSample',24);
end


function summary = summarizeRows(results, methods)
rows = cell(numel(methods),1);

for k = 1:numel(methods)
    selected = results.Method == methods(k);
    valid = selected & results.Status == "OK";

    rows{k} = table(methods(k), nnz(selected), nnz(valid), ...
        nnz(selected & results.Status == "FAILED"), ...
        mean(results.CentroidErrorHz(valid)), ...
        mean(results.LogPowerRMSEdB(valid)), ...
        median(results.OptimizationSeconds(valid)), ...
        'VariableNames', {'Method','Expected','Valid','Failed', ...
        'MeanCentroidErrorHz','MeanLogPowerRMSEdB', ...
        'MedianOptimizationSeconds'});
end

summary = vertcat(rows{:});
end


function saveProgress(path, allResults, done, fitHistory, key, protocol)
temporaryPath = [path,'.tmp.mat'];

save(temporaryPath, 'allResults','done','fitHistory', ...
    'key','protocol','-v7');

[ok,~] = movefile(temporaryPath,path,'f');
assert(ok, 'Could not save the batch checkpoint.');
end
