function [results, fitInfo] = run_differentiable_eq( ...
    refPath, inputPath, runID)
% Fit a three-section EQ using automatic differentiation.

assert(nargin == 0 || nargin == 2 || nargin == 3, ...
    'Provide no inputs, or provide reference and distorted audio paths.');

rootDir = fileparts(mfilename('fullpath'));
pilotDir = fullfile(rootDir, 'data', 'pilot');
resultsDir = fullfile(rootDir, 'results');

isPilotRun = nargin == 0;

if isPilotRun
    refPath = fullfile(pilotDir, 'reference_01.wav');
    inputPath = fullfile(pilotDir, 'distorted', ...
        'reference_01_peaking_-6dB.wav');
    runID = 'pilot_reference_01';
    runDir = resultsDir;
else
    if nargin < 3 || isempty(runID)
        [~, runID] = fileparts(inputPath);
    end

    runID = char(runID);
    runDir = fullfile(resultsDir, ...
        'batch_differentiable', runID);
end

if ~isfolder(runDir)
    mkdir(runDir);
end

baselinePath = fullfile(resultsDir, ...
    'step12_method_comparison.csv');

assert(isfile(refPath), 'Reference audio file is missing.');
assert(isfile(inputPath), 'Distorted audio file is missing.');

if isPilotRun
    assert(isfile(baselinePath), ...
        'Baseline results file is missing.');
end

[ref, fs] = audioread(refPath);
[input, fsInput] = audioread(inputPath);

assert(fs == fsInput && numel(ref) == numel(input), ...
    'Audio sample rates and lengths must match.');
assert(iscolumn(ref) && iscolumn(input), ...
    'This module expects mono audio.');

% Use the same spectral analysis settings as the other methods
win = hann(2048, 'periodic');
[PRef, fAll] = pwelch(ref, win, 1024, 2048, fs);
[PInput, ~] = pwelch(input, win, 1024, 2048, fs);

inBand = fAll >= 20 & fAll <= 16000;
f = fAll(inBand);
pRef = PRef(inBand);
pInput = PInput(inBand);

targetDB = 10*log10(max(pRef, realmin));
inputDB = 10*log10(max(pInput, realmin));

w = 2*pi*f/fs;
basis = [cos(w), cos(2*w), sin(w), sin(2*w)];

% Start all gains at zero and constrain them to +/-12 dB
theta = dlarray(zeros(3, 1));
averageGrad = [];
averageSqGrad = [];

maxIterations = 400;
learningRate = 0.03;
lossHistory = zeros(maxIterations, 1);
bestLoss = Inf;

fitClock = tic;

for iteration = 1:maxIterations

    [loss, grad] = dlfeval(@eqLoss, theta, ...
        inputDB, targetDB, basis, fs);

    value = double(extractdata(loss));

    assert(isfinite(value) && ...
        all(isfinite(extractdata(grad)), 'all'), ...
        'The optimization produced a non-finite value.');

    lossHistory(iteration) = value;

    if value < bestLoss
        bestLoss = value;
        bestGainsDB = double(extractdata(12*tanh(theta)));
    end

   if isPilotRun && mod(iteration, 100) == 0
        fprintf('Iteration %d, model RMSE: %.4f dB\n', ...
            iteration, sqrt(value));
    end

    if value < 1e-8
        break;
    end

    [theta, averageGrad, averageSqGrad] = adamupdate( ...
        theta, grad, averageGrad, averageSqGrad, ...
        iteration, learningRate);
end

optimizationSeconds = toc(fitClock);
lossHistory = lossHistory(1:iteration);

% Apply the best EQ to the original distorted input
corrected = input;

for section = 1:3
    [b, a] = eqCoefficients(bestGainsDB(section), section, fs);
    corrected = filter(b, a, corrected);
end

assert(all(isfinite(corrected)) && max(abs(corrected)) < 1, ...
    'The corrected audio contains invalid values or clipping.');

if isPilotRun
    correctedDir = fullfile(pilotDir, 'corrected');
    outputPath = fullfile(correctedDir, ...
        'reference_01_midcut_differentiable_corrected.wav');
else
    correctedDir = runDir;
    outputPath = fullfile(correctedDir, 'corrected.wav');
end

if ~isfolder(correctedDir)
    mkdir(correctedDir);
end

audiowrite(outputPath, corrected, fs, 'BitsPerSample', 24);

% Measure the saved WAV rather than the model prediction
[corrected, fsOutput] = audioread(outputPath);
[POutput, ~] = pwelch(corrected, win, 1024, 2048, fsOutput);
pOutput = POutput(inBand);

residualDB = 10*log10(max(pOutput, realmin)) - targetDB;

referenceCentroid = sum(f .* pRef) / sum(pRef);
outputCentroid = sum(f .* pOutput) / sum(pOutput);

centroidErrorHz = abs(outputCentroid - referenceCentroid);
logPowerRMSEdB = sqrt(mean(residualDB.^2));

newRow = table("Differentiable", centroidErrorHz, ...
    logPowerRMSEdB, 'VariableNames', ...
    {'Method', 'CentroidErrorHz', 'LogPowerRMSEdB'});

if isPilotRun
    baseline = readtable(baselinePath, 'TextType', 'string');
    results = [baseline; newRow];
else
    results = newRow;
end

gainResults = table(["Low"; "Mid"; "High"], bestGainsDB, ...
    'VariableNames', {'Band', 'GainDB'});

fitInfo = struct( ...
    'RunID', string(runID), ...
    'GainsDB', bestGainsDB, ...
    'Iterations', iteration, ...
    'BestModelMSE', bestLoss, ...
    'OptimizationSeconds', optimizationSeconds, ...
    'GainBoundaryHit', any(abs(bestGainsDB) >= 11.99), ...
    'ReferencePath', string(refPath), ...
    'InputPath', string(inputPath), ...
    'OutputPath', string(outputPath));

writetable(results, ...
    fullfile(runDir, 'differentiable_eq_comparison.csv'));

writetable(gainResults, ...
    fullfile(runDir, 'differentiable_eq_gains.csv'));

save(fullfile(runDir, 'differentiable_eq_fit.mat'), ...
    'bestGainsDB', 'bestLoss', 'lossHistory', ...
    'optimizationSeconds', 'learningRate', 'fs', 'fitInfo');

% Display detailed output only for the original pilot call.
if isPilotRun
    disp(gainResults);

    for k = 1:height(results)
        fprintf('\n%s\n', char(results.Method(k)));
        fprintf('  Centroid error: %.6f Hz\n', ...
            results.CentroidErrorHz(k));
        fprintf('  Log-power RMSE: %.6f dB\n', ...
            results.LogPowerRMSEdB(k));
    end

    fprintf('\nOptimization time: %.2f s\n', ...
        optimizationSeconds);

    resultFig = figure('Color', 'w');

    subplot(2, 1, 1);
    semilogy(1:numel(lossHistory), ...
        max(lossHistory, realmin), 'LineWidth', 1.4);
    grid on;
    xlabel('Iteration');
    ylabel('Predicted MSE (dB^2)');
    title('Differentiable EQ model-fitting loss');

    subplot(2, 1, 2);
    semilogx(f, inputDB - targetDB, 'LineWidth', 1.1);
    hold on;
    semilogx(f, residualDB, 'LineWidth', 1.5);
    yline(0, 'k:', 'HandleVisibility', 'off');
    grid on;
    xlim([20 16000]);
    xlabel('Frequency (Hz)');
    ylabel('Difference from reference (dB)');
    title('Measured residual spectrum');
    legend('Distorted', 'Differentiable EQ', ...
        'Location', 'best');

    exportgraphics(resultFig, ...
        fullfile(runDir, 'differentiable_eq_results.png'), ...
        'Resolution', 150);
end
end


function [loss, grad] = eqLoss(theta, inputDB, targetDB, basis, fs)
% Predict the log-power change of the EQ cascade.

gainsDB = 12*tanh(theta);
responseDB = zeros(size(inputDB));

for section = 1:3
    [b, a] = eqCoefficients(gainsDB(section), section, fs);

    br = b(1) + b(2).*basis(:, 1) + b(3).*basis(:, 2);
    bi = b(2).*basis(:, 3) + b(3).*basis(:, 4);

    ar = a(1) + a(2).*basis(:, 1) + a(3).*basis(:, 2);
    ai = a(2).*basis(:, 3) + a(3).*basis(:, 4);

    powerRatio = (br.^2 + bi.^2 + 1e-24) ./ ...
        (ar.^2 + ai.^2 + 1e-24);

    responseDB = responseDB + (10/log(10))*log(powerRatio);
end

residual = inputDB + responseDB - targetDB;
loss = mean(residual.^2, 'all');
grad = dlgradient(loss, theta);
end


function [b, a] = eqCoefficients(gainDB, section, fs)
% Differentiable biquad coefficients.
% Shelves use slope = 1; the peaking section uses 1000 Hz bandwidth.

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