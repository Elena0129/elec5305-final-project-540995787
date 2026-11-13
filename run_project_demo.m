% ELEC5305: Is Spectral Centroid Enough?
% Same executable sections as Step01_prepare_audio.mlx.
% Default: compute the pilot demonstration and inspect saved formal results.
% Complete fresh fitting: reproduce_results(false).

clear; clc;
rootDir = fileparts(mfilename('fullpath'));
cd(rootDir);
rng(5305, 'twister');
playAudio = usejava('desktop');
% Run the pilot computations and display saved formal experiment results.
% A complete fresh refit is available separately with reproduce_results(false).
check_project("demo");

%% Find the source recordings

% Reuse the supplied excerpts. Raw GuitarSet is optional for reconstruction.
[manifest, fig] = prepare_pilot_audio();

%% Create output folders

outDir = fullfile(rootDir, 'data', 'pilot');
clipSeconds = 5;
nClips = height(manifest);

%% Prepare three reference clips

% The helper validates the prepared audio and retains its source provenance.
disp(manifest(:, {'referenceFile', 'sourceFile', 'sampleRate'}));

%% Save the source information and waveform figure

% prepare_pilot_audio also exports the waveform figure.
fprintf('Pilot excerpts: %d, %.1f seconds each.\n', nClips, clipSeconds);
fprintf('Preparation metadata: data/pilot/source_manifest.csv\n');

%% Step 02 - Create the first known EQ distortion

% Read the first reference clip
[x, fs] = audioread(fullfile('data', 'pilot', 'reference_01.wav'));

% Design a high-shelf EQ
gainDB = 6;
f0Hz = 2500;
shelfSlope = 1;

[b, a] = designShelvingEQ(gainDB, shelfSlope, ...
    f0Hz/(fs/2), 'hi', 'Orientation', 'row');

% Apply the known EQ
y = filter(b, a, x);
assert(all(isfinite(y)) && max(abs(y)) < 1, ...
    'Invalid audio or clipping detected.');

% Save the processed audio and its settings
distDir = fullfile('data', 'pilot', 'distorted');
if ~isfolder(distDir)
    mkdir(distDir);
end

audiowrite(fullfile(distDir, ...
    'reference_01_high_shelf_+6dB.wav'), y, fs, ...
    'BitsPerSample', 24);

save(fullfile(distDir, 'first_eq_settings.mat'), ...
    'gainDB', 'f0Hz', 'shelfSlope', 'b', 'a', 'fs');

% Display the EQ frequency response
[H, f] = freqz(b, a, 4096, fs);
figure('Color', 'w');
semilogx(f(2:end), 20*log10(abs(H(2:end))), ...
    'LineWidth', 1.5);
grid on;
xlim([30 16000]);
ylim([-1 7]);
xlabel('Frequency (Hz)');
ylabel('Gain (dB)');
title('High-shelf EQ: +6 dB, 2500 Hz');

disp('Created the first EQ-distorted audio clip.');

%% Step 03 - Listen to the reference and distorted audio

[ref, fsRef] = audioread(fullfile( ...
    'data', 'pilot', 'reference_01.wav'));

[dist, fsDist] = audioread(fullfile( ...
    'data', 'pilot', 'distorted', ...
    'reference_01_high_shelf_+6dB.wav'));

if playAudio
    disp('Playing reference audio');
    sound(ref, fsRef);
    pause(size(ref, 1)/fsRef + 1);
    
    disp('Playing high-frequency boosted audio');
    sound(dist, fsDist);
end

%% Step 04 - Compare spectra and power spectral centroids

% Read the audio pair
[ref, fsRef] = audioread(fullfile( ...
    'data', 'pilot', 'reference_01.wav'));

[dist, fsDist] = audioread(fullfile( ...
    'data', 'pilot', 'distorted', ...
    'reference_01_high_shelf_+6dB.wav'));

assert(fsRef == fsDist && numel(ref) == numel(dist), ...
    'Audio sample rates and lengths must match.');

% Estimate both power spectra using identical settings
win = hann(2048, 'periodic');
[PRef, f] = pwelch(ref, win, 1024, 2048, fsRef);
[PDist, ~] = pwelch(dist, win, 1024, 2048, fsDist);

% Use the same analysis range: 20 to 16000 Hz
inBand = f >= 20 & f <= 16000;
fBand = f(inBand);
pRef = PRef(inBand);
pDist = PDist(inBand);

% Calculate the power-weighted spectral centroids
centroidRef = sum(fBand .* pRef) / sum(pRef);
centroidDist = sum(fBand .* pDist) / sum(pDist);

% Plot the actual audio spectra
spectrumFig = figure('Color', 'w');
semilogx(fBand, 10*log10(max(pRef, realmin)), ...
    'LineWidth', 1.2);
hold on;
semilogx(fBand, 10*log10(max(pDist, realmin)), ...
    'LineWidth', 1.2);
grid on;
xlim([20 16000]);
xlabel('Frequency (Hz)');
ylabel('Power spectral density (dB/Hz)');
title('Reference and high-frequency boosted audio');
legend('Reference', 'EQ-distorted', 'Location', 'best');

% Display and save the results
centroidResults = table( ...
    ["Reference"; "EQ-distorted"], ...
    [centroidRef; centroidDist], ...
    'VariableNames', {'Audio', 'PowerCentroidHz'});

disp(centroidResults);
fprintf('Centroid change: %+.2f Hz\n', ...
    centroidDist - centroidRef);

writetable(centroidResults, ...
    fullfile('results', 'step04_centroid_comparison.csv'));

exportgraphics(spectrumFig, ...
    fullfile('results', 'step04_spectrum_comparison.png'), ...
    'Resolution', 150);

%% Step 05 - Find the correction gain using spectral centroid

% Try gains from -12 dB to +12 dB
gainCandidates = -12:0.5:12;
candidateCentroids = zeros(size(gainCandidates));
centroidErrors = zeros(size(gainCandidates));

for k = 1:numel(gainCandidates)

    [bTry, aTry] = designShelvingEQ( ...
        gainCandidates(k), 1, 2500/(fsRef/2), ...
        'hi', 'Orientation', 'row');

    % Apply each candidate EQ to the distorted audio
    candidate = filter(bTry, aTry, dist);

    % Use the same analysis settings as Step 04
    [PTry, ~] = pwelch(candidate, win, 1024, 2048, fsRef);
    pTry = PTry(inBand);

    candidateCentroids(k) = sum(fBand .* pTry) / sum(pTry);
    centroidErrors(k) = abs(candidateCentroids(k) - centroidRef);
end

% Select the gain with the smallest centroid error
[bestError, bestIndex] = min(centroidErrors);
bestGainDB = gainCandidates(bestIndex);
bestCentroid = candidateCentroids(bestIndex);

fprintf('Selected correction gain: %+.2f dB\n', bestGainDB);
fprintf('Reference centroid: %.2f Hz\n', centroidRef);
fprintf('Corrected centroid: %.2f Hz\n', bestCentroid);
fprintf('Remaining centroid error: %.4f Hz\n', bestError);

figure('Color', 'w');
plot(gainCandidates, centroidErrors, 'LineWidth', 1.5);
hold on;
plot(bestGainDB, bestError, 'ro', 'MarkerFaceColor', 'r');
grid on;
xlabel('Correction gain (dB)');
ylabel('Absolute centroid error (Hz)');
title('Selecting EQ gain by spectral centroid matching');

%% Step 06 - Apply and verify the selected correction

% Apply the gain selected automatically in Step 05
[bFix, aFix] = designShelvingEQ( ...
    bestGainDB, 1, 2500/(fsRef/2), ...
    'hi', 'Orientation', 'row');

corrected = filter(bFix, aFix, dist);

assert(all(isfinite(corrected)) && max(abs(corrected)) < 1, ...
    'Invalid audio or clipping detected.');

% Save the corrected audio
correctedDir = fullfile('data', 'pilot', 'corrected');
if ~isfolder(correctedDir)
    mkdir(correctedDir);
end

correctedPath = fullfile(correctedDir, ...
    'reference_01_centroid_corrected.wav');

audiowrite(correctedPath, corrected, fsRef, ...
    'BitsPerSample', 24);

% Analyse the saved audio
[corrected, fsCorrected] = audioread(correctedPath);
[PCorrected, ~] = pwelch( ...
    corrected, win, 1024, 2048, fsCorrected);

pCorrected = PCorrected(inBand);
centroidCorrected = sum(fBand .* pCorrected) / sum(pCorrected);

% Compare all three spectra
comparisonFig = figure('Color', 'w');

semilogx(fBand, 10*log10(max(pRef, realmin)), ...
    'LineWidth', 1.5);
hold on;

semilogx(fBand, 10*log10(max(pDist, realmin)), ...
    'LineWidth', 1);

semilogx(fBand, 10*log10(max(pCorrected, realmin)), ...
    '--', 'Color', [0 0.5 0.2], 'LineWidth', 1.5);

grid on;
xlim([20 16000]);
xlabel('Frequency (Hz)');
ylabel('Power spectral density (dB/Hz)');
title('Reference, distorted and corrected audio');
legend('Reference', 'EQ-distorted', 'Corrected', ...
    'Location', 'best');

% Save the comparison results
comparisonResults = table( ...
    ["Reference"; "EQ-distorted"; "Corrected"], ...
    [centroidRef; centroidDist; centroidCorrected], ...
    'VariableNames', {'Audio', 'PowerCentroidHz'});

disp(comparisonResults);

writetable(comparisonResults, ...
    fullfile('results', 'step06_correction_comparison.csv'));

exportgraphics(comparisonFig, ...
    fullfile('results', 'step06_corrected_spectrum.png'), ...
    'Resolution', 150);

save(fullfile(correctedDir, 'correction_settings.mat'), ...
    'bestGainDB', 'bFix', 'aFix', 'fsRef');

%% Step 07 - Create a mid-frequency cut

% Define a controlled peaking-EQ distortion
peakGainDB = -6;
peakF0Hz = 1000;
peakBandwidthHz = 1000;

[bPeak, aPeak] = project_param_eq( ...
    2, peakGainDB, peakF0Hz/(fsRef/2), ...
    peakBandwidthHz/(fsRef/2), ...
    'Orientation', 'row');

peakDist = filter(bPeak, aPeak, ref);

assert(all(isfinite(peakDist)) && max(abs(peakDist)) < 1, ...
    'Invalid audio or clipping detected.');

% Save the new distorted audio and its settings
peakDistPath = fullfile('data', 'pilot', 'distorted', ...
    'reference_01_peaking_-6dB.wav');

audiowrite(peakDistPath, peakDist, fsRef, ...
    'BitsPerSample', 24);

save(fullfile('data', 'pilot', 'distorted', ...
    'peaking_settings.mat'), ...
    'peakGainDB', 'peakF0Hz', 'peakBandwidthHz', ...
    'bPeak', 'aPeak', 'fsRef');

% Analyse the saved audio using the same settings
[peakDist, fsPeak] = audioread(peakDistPath);
[PPeak, ~] = pwelch(peakDist, win, 1024, 2048, fsPeak);
pPeak = PPeak(inBand);

centroidPeak = sum(fBand .* pPeak) / sum(pPeak);

midcutResults = table( ...
    ["Reference"; "Mid-frequency cut"], ...
    [centroidRef; centroidPeak], ...
    'VariableNames', {'Audio', 'PowerCentroidHz'});

disp(midcutResults);

% Compare the original and mid-frequency-cut spectra
midcutFig = figure('Color', 'w');
semilogx(fBand, 10*log10(max(pRef, realmin)), ...
    'LineWidth', 1.2);
hold on;
semilogx(fBand, 10*log10(max(pPeak, realmin)), ...
    'LineWidth', 1.2);

grid on;
xlim([20 16000]);
xlabel('Frequency (Hz)');
ylabel('Power spectral density (dB/Hz)');
title('Reference and mid-frequency cut audio');
legend('Reference', 'Mid-frequency cut', 'Location', 'best');

writetable(midcutResults, ...
    fullfile('results', 'step07_midcut_centroids.csv'));

exportgraphics(midcutFig, ...
    fullfile('results', 'step07_midcut_spectrum.png'), ...
    'Resolution', 150);

%% Step 08 - Match the centroid of the mid-frequency-cut audio

% First search broadly, then refine around the best gain
for pass = 1:2

    if pass == 1
        midGains = -12:0.5:12;
    else
        lowerGain = max(-12, midBestGainDB - 0.5);
        upperGain = min(12, midBestGainDB + 0.5);
        midGains = lowerGain:0.01:upperGain;
    end

    midCentroids = zeros(size(midGains));
    midErrors = zeros(size(midGains));

    for j = 1:numel(midGains)

        % Use the same high-shelf correction as before
        [bMidTry, aMidTry] = designShelvingEQ( ...
            midGains(j), 1, 2500/(fsRef/2), ...
            'hi', 'Orientation', 'row');

        midCandidate = filter(bMidTry, aMidTry, peakDist);

        [PMidTry, ~] = pwelch( ...
            midCandidate, win, 1024, 2048, fsRef);

        pMidTry = PMidTry(inBand);

        midCentroids(j) = ...
            sum(fBand .* pMidTry) / sum(pMidTry);

        midErrors(j) = abs(midCentroids(j) - centroidRef);
    end

    [midBestError, midBestIndex] = min(midErrors);
    midBestGainDB = midGains(midBestIndex);
    midBestCentroid = midCentroids(midBestIndex);
end

fprintf('Selected correction gain: %+.2f dB\n', midBestGainDB);
fprintf('Reference centroid: %.2f Hz\n', centroidRef);
fprintf('Corrected centroid: %.2f Hz\n', midBestCentroid);
fprintf('Remaining centroid error: %.4f Hz\n', midBestError);

midSearchFig = figure('Color', 'w');
plot(midGains, midErrors, 'LineWidth', 1.5);
hold on;
plot(midBestGainDB, midBestError, ...
    'ro', 'MarkerFaceColor', 'r');
grid on;
xlabel('High-shelf correction gain (dB)');
ylabel('Absolute centroid error (Hz)');
title('Fine gain search for the mid-frequency cut');

save(fullfile('results', 'step08_midcut_gain_search.mat'), ...
    'midBestGainDB', 'midBestCentroid', 'midBestError', ...
    'midGains', 'midCentroids', 'midErrors');

exportgraphics(midSearchFig, ...
    fullfile('results', 'step08_midcut_gain_search.png'), ...
    'Resolution', 150);

%% Step 09 - Check the remaining spectral error

% Apply the gain selected in Step 08
[bMidFix, aMidFix] = designShelvingEQ( ...
    midBestGainDB, 1, 2500/(fsRef/2), ...
    'hi', 'Orientation', 'row');

midCorrected = filter(bMidFix, aMidFix, peakDist);

assert(all(isfinite(midCorrected)) && max(abs(midCorrected)) < 1, ...
    'Invalid audio or clipping detected.');

% Save and reload the corrected audio
midCorrectedPath = fullfile('data', 'pilot', 'corrected', ...
    'reference_01_midcut_centroid_corrected.wav');

audiowrite(midCorrectedPath, midCorrected, fsRef, ...
    'BitsPerSample', 24);

[midCorrected, fsMidCorrected] = audioread(midCorrectedPath);

% Analyse the saved audio
[PMidCorrected, ~] = pwelch( ...
    midCorrected, win, 1024, 2048, fsMidCorrected);

pMidCorrected = PMidCorrected(inBand);

centroidMidCorrected = ...
    sum(fBand .* pMidCorrected) / sum(pMidCorrected);

% Calculate spectral differences relative to the reference
refDB = 10*log10(max(pRef, realmin));
beforeDiffDB = 10*log10(max(pPeak, realmin)) - refDB;
afterDiffDB = 10*log10(max(pMidCorrected, realmin)) - refDB;

% Plot the remaining error across frequency
midResidualFig = figure('Color', 'w');

semilogx(fBand, beforeDiffDB, ...
    'Color', [0.85 0.33 0.10], 'LineWidth', 1.2);
hold on;

semilogx(fBand, afterDiffDB, '--', ...
    'Color', [0 0.5 0.2], 'LineWidth', 1.5);

yline(0, 'k:', 'HandleVisibility', 'off');
grid on;
xlim([20 16000]);
xlabel('Frequency (Hz)');
ylabel('Power-spectrum difference (dB)');
title('Remaining spectral error: mid-frequency cut');
legend('Before correction', 'After centroid correction', ...
    'Location', 'best');

% Report the centroid and the error near 1000 Hz
[~, midBin] = min(abs(fBand - 1000));

fprintf('Corrected centroid: %.2f Hz\n', centroidMidCorrected);
fprintf('Centroid error: %.4f Hz\n', ...
    abs(centroidMidCorrected - centroidRef));
fprintf('Spectral difference at %.1f Hz: %+.2f dB\n', ...
    fBand(midBin), afterDiffDB(midBin));

% Save the evidence
midResidualResults = table(fBand, beforeDiffDB, afterDiffDB, ...
    'VariableNames', {'FrequencyHz', ...
    'BeforeDifferenceDB', 'AfterDifferenceDB'});

writetable(midResidualResults, ...
    fullfile('results', 'step09_midcut_residual_spectrum.csv'));

exportgraphics(midResidualFig, ...
    fullfile('results', 'step09_midcut_residual_spectrum.png'), ...
    'Resolution', 150);

%% Step 10 - Measure errors in three frequency bands

bandEdgesHz = [20 500 2000 16000];
bandNames = ["Low"; "Mid"; "High"];

beforeBandDB = zeros(3, 1);
afterBandDB = zeros(3, 1);

for b = 1:3

    bandMask = fBand >= bandEdgesHz(b) & ...
        fBand < bandEdgesHz(b+1);

    if b == 3
        bandMask = fBand >= bandEdgesHz(b) & ...
            fBand <= bandEdgesHz(b+1);
    end

    % Sum the spectral power within each band
    refPower = sum(pRef(bandMask));
    beforePower = sum(pPeak(bandMask));
    afterPower = sum(pMidCorrected(bandMask));

    % Express the differences relative to the reference
    beforeBandDB(b) = 10*log10( ...
        max(beforePower, realmin) / max(refPower, realmin));

    afterBandDB(b) = 10*log10( ...
        max(afterPower, realmin) / max(refPower, realmin));
end

bandResults = table( ...
    bandNames, bandEdgesHz(1:3)', bandEdgesHz(2:4)', ...
    beforeBandDB, afterBandDB, ...
    'VariableNames', ...
    {'Band', 'LowerHz', 'UpperHz', 'BeforeDB', 'AfterDB'});

disp(bandResults(:, {'Band', 'BeforeDB', 'AfterDB'}));

% Compare errors before and after centroid correction
bandFig = figure('Color', 'w');
bars = bar([beforeBandDB afterBandDB]);

bars(1).FaceColor = [0.85 0.33 0.10];
bars(2).FaceColor = [0 0.5 0.2];

xticks(1:3);
xticklabels(bandNames);
yline(0, 'k:', 'HandleVisibility', 'off');
grid on;
xlabel('Frequency band');
ylabel('Band power difference (dB)');
title('Bandwise errors after centroid matching');
legend('Before correction', 'After centroid correction', ...
    'Location', 'best');

writetable(bandResults, ...
    fullfile('results', 'step10_bandwise_errors.csv'));

exportgraphics(bandFig, ...
    fullfile('results', 'step10_bandwise_errors.png'), ...
    'Resolution', 150);

%% Step 11 - Find gains using a three-band controller

% Map spectral bins into the same three analysis bands
bandSumMatrix = zeros(3, numel(fBand));

for b = 1:3
    mask = fBand >= bandEdgesHz(b) & ...
        fBand < bandEdgesHz(b+1);

    if b == 3
        mask = fBand >= bandEdgesHz(b) & ...
            fBand <= bandEdgesHz(b+1);
    end

    bandSumMatrix(b, mask) = 1;
end

targetBandPower = bandSumMatrix * pRef;

% Start with no correction
multiGainsDB = zeros(3, 1);
multiMaxIterations = 30;
multiToleranceDB = 0.02;
multiBestScore = Inf;
multiHistory = zeros(multiMaxIterations, 3);

for it = 1:multiMaxIterations

    % Fixed EQ positions; only the three gains are adjusted
    [bLow, aLow] = designShelvingEQ( ...
        multiGainsDB(1), 1, 250/(fsRef/2), ...
        'lo', 'Orientation', 'row');

    [bMid, aMid] = project_param_eq( ...
        2, multiGainsDB(2), 1000/(fsRef/2), ...
        1000/(fsRef/2), 'Orientation', 'row');

    [bHigh, aHigh] = designShelvingEQ( ...
        multiGainsDB(3), 1, 2500/(fsRef/2), ...
        'hi', 'Orientation', 'row');

    % Every trial starts from the same distorted input
    multiTrial = filter(bLow, aLow, peakDist);
    multiTrial = filter(bMid, aMid, multiTrial);
    multiTrial = filter(bHigh, aHigh, multiTrial);

    [PTrial, ~] = pwelch( ...
        multiTrial, win, 1024, 2048, fsRef);

    trialBandPower = bandSumMatrix * PTrial(inBand);

    multiErrorsDB = 10*log10( ...
        max(trialBandPower, realmin) ./ ...
        max(targetBandPower, realmin));

    multiHistory(it, :) = multiErrorsDB';

    % Keep the best evaluated settings
    score = sum(multiErrorsDB.^2);

    if score < multiBestScore
        multiBestScore = score;
        multiBestGainsDB = multiGainsDB;
        multiBestErrorsDB = multiErrorsDB;
    end

    if max(abs(multiErrorsDB)) < multiToleranceDB
        break;
    end

    % Move each gain opposite to its measured band error
    multiGainsDB = min(12, max(-12, ...
        multiGainsDB - 0.7 * multiErrorsDB));
end

multiHistory = multiHistory(1:it, :);

multiGainResults = table( ...
    bandNames, multiBestGainsDB, multiBestErrorsDB, ...
    'VariableNames', {'Band', 'GainDB', 'ErrorDB'});

disp(multiGainResults);
fprintf('Evaluated settings: %d\n', it);

% Display how the three band errors change
multiSearchFig = figure('Color', 'w');
plot(0:it-1, multiHistory, 'LineWidth', 1.4);
yline(0, 'k:', 'HandleVisibility', 'off');
grid on;
xlabel('Update number');
ylabel('Band power error (dB)');
title('Three-band controller convergence');
legend('Low', 'Mid', 'High', 'Location', 'best');

% Save the gain settings and evidence
writetable(multiGainResults, ...
    fullfile('results', 'step11_multiband_gains.csv'));

save(fullfile('results', 'step11_multiband_search.mat'), ...
    'multiBestGainsDB', 'multiBestErrorsDB', ...
    'multiHistory', 'bandEdgesHz', 'fsRef');

exportgraphics(multiSearchFig, ...
    fullfile('results', 'step11_multiband_convergence.png'), ...
    'Resolution', 150);

%% Step 12 - Compare centroid and three-band correction

% Rebuild the EQ using the best three-band gains
[bML, aML] = designShelvingEQ( ...
    multiBestGainsDB(1), 1, 250/(fsRef/2), ...
    'lo', 'Orientation', 'row');

[bMM, aMM] = project_param_eq( ...
    2, multiBestGainsDB(2), 1000/(fsRef/2), ...
    1000/(fsRef/2), 'Orientation', 'row');

[bMH, aMH] = designShelvingEQ( ...
    multiBestGainsDB(3), 1, 2500/(fsRef/2), ...
    'hi', 'Orientation', 'row');

% Process the same distorted input
multiCorrected = filter(bML, aML, peakDist);
multiCorrected = filter(bMM, aMM, multiCorrected);
multiCorrected = filter(bMH, aMH, multiCorrected);

assert(all(isfinite(multiCorrected)) && max(abs(multiCorrected)) < 1, ...
    'Invalid audio or clipping detected.');

% Save and reload the corrected audio
multiCorrectedPath = fullfile('data', 'pilot', 'corrected', ...
    'reference_01_midcut_multiband_corrected.wav');

audiowrite(multiCorrectedPath, multiCorrected, fsRef, ...
    'BitsPerSample', 24);

[multiCorrected, fsMulti] = audioread(multiCorrectedPath);

% Analyse the saved audio
[PMulti, ~] = pwelch( ...
    multiCorrected, win, 1024, 2048, fsMulti);

pMulti = PMulti(inBand);
centroidMulti = sum(fBand .* pMulti) / sum(pMulti);
multiDiffDB = 10*log10(max(pMulti, realmin)) - refDB;

% Compare centroid errors and whole-spectrum errors
methodNames = ["Distorted"; "Centroid"; "Three-band"];

methodCentroids = [centroidPeak; ...
    centroidMidCorrected; centroidMulti];

centroidErrorHz = abs(methodCentroids - centroidRef);

logPowerRMSEdB = sqrt(mean( ...
    [beforeDiffDB afterDiffDB multiDiffDB].^2, 1))';

methodResults = table( ...
    methodNames, centroidErrorHz, logPowerRMSEdB, ...
    'VariableNames', ...
    {'Method', 'CentroidErrorHz', 'LogPowerRMSEdB'});

disp(methodResults);

% Compare residual spectra
methodFig = figure('Color', 'w');

semilogx(fBand, beforeDiffDB, ...
    'Color', [0.85 0.33 0.10], 'LineWidth', 1.1);
hold on;

semilogx(fBand, afterDiffDB, '--', ...
    'Color', [0 0.5 0.2], 'LineWidth', 1.3);

semilogx(fBand, multiDiffDB, ...
    'Color', [0 0.45 0.74], 'LineWidth', 1.6);

yline(0, 'k:', 'HandleVisibility', 'off');
grid on;
xlim([20 16000]);
xlabel('Frequency (Hz)');
ylabel('Power-spectrum difference (dB)');
title('Mid-frequency cut: correction methods compared');
legend('Distorted', 'Centroid correction', ...
    'Three-band correction', 'Location', 'best');

writetable(methodResults, ...
    fullfile('results', 'step12_method_comparison.csv'));

exportgraphics(methodFig, ...
    fullfile('results', 'step12_method_comparison.png'), ...
    'Resolution', 150);

%% Step 13 - Show complete results and check automatic differentiation

% Print each metric on a separate line
methodResults = readtable( ...
    fullfile('results', 'step12_method_comparison.csv'), ...
    'TextType', 'string');
for m = 1:height(methodResults)
    fprintf('\n%s\n', char(methodResults.Method(m)));

    fprintf('  Centroid error: %.6f Hz\n', ...
        methodResults.CentroidErrorHz(m));

    fprintf('  Log-power RMSE: %.6f dB\n', ...
        methodResults.LogPowerRMSEdB(m));
end

% Check the tools needed for differentiable EQ
fprintf('\nAutomatic differentiation check:\n');
autodiffReady = false;

try
    dlProbe = dlarray(3);

    % The derivative of x^2 at x = 3 should be 6
    probeGradient = dlfeval( ...
        @(v) dlgradient(v.^2, v), dlProbe);

    probeGradientValue = double(extractdata(probeGradient));

    assert(abs(probeGradientValue - 6) < 1e-8, ...
        'Automatic gradient check failed.');

    % Check that an Adam parameter update also works
    dlProbeUpdated = adamupdate( ...
        dlProbe, probeGradient, [], [], 1, 0.01);

    autodiffReady = true;
    fprintf('Gradient check: PASS\n');
    fprintf('Adam update: PASS\n');
    fprintf('Tools: READY\n');

catch ME
    autodiffReady = false
    fprintf('Tools: NOT READY\n');
    fprintf('Error ID: %s\n', ME.identifier);
end

%% Differentiable correction and four-method comparison

% Fit method C on the same mid-cut pilot pair and show all four rows.
[differentiableResults, differentiableFit] = run_differentiable_eq();

%% Batch dataset preparation

% The published repository includes the frozen preparation metadata.
manifestFile = fullfile('data', 'batch', 'manifest.csv');
options = detectImportOptions(manifestFile, 'TextType', 'string');
options = setvartype(options, ...
    {'PairID','ClipID','PerformerID','ReferenceFile','Condition'}, 'string');
batchManifest = readtable(manifestFile, options);
fprintf('Using the supplied dataset: %d pairs.\n', height(batchManifest));

%% Batch method comparison

% Display the recorded benchmark; do not resume a checkpoint from another PC.
resultFile = fullfile('results', 'batch_comparison', 'batch_results.csv');
options = detectImportOptions(resultFile, 'TextType', 'string');
options = setvartype(options, ...
    {'PairID','ClipID','PerformerID','Condition','Method','Status'}, 'string');
batchResults = readtable(resultFile, options);
assert(height(batchResults) == 960 && all(batchResults.Status == "OK"), ...
    'The supplied benchmark results are incomplete.');
disp(readtable(fullfile('results', 'batch_comparison', ...
    'summary_by_method.csv'), 'TextType', 'string'));
fprintf('Loaded %d recorded benchmark rows.\n', height(batchResults));

%% Condition-wise analysis

resultDir = fullfile('results', 'batch_comparison');

S = readtable(fullfile(resultDir, ...
    'summary_by_condition.csv'), 'TextType', 'string');

conditions = unique(S.Condition, 'stable');
methods = ["Distorted", "Centroid", ...
    "Three-band", "Differentiable"];

nConditions = numel(conditions);

spectralErrors = nan(nConditions, 4);
centroidErrors = nan(nConditions, 4);

for c = 1:nConditions
    for m = 1:4
        selected = S.Condition == conditions(c) & ...
            S.Method == methods(m);

        assert(nnz(selected) == 1, ...
            'A condition-method summary is missing or duplicated.');

        spectralErrors(c,m) = S.MeanLogPowerRMSEdB(selected);
        centroidErrors(c,m) = S.MeanCentroidErrorHz(selected);
    end
end

overall = readtable(fullfile(resultDir, ...
    'summary_by_method.csv'), 'TextType', 'string');

plotMethods = ["Distorted", "Centroid", ...
    "Three-band", "Differentiable"];

[found, order] = ismember(plotMethods, overall.Method);
assert(all(found), 'A method summary is missing.');
overall = overall(order,:);

plotData = { ...
    overall.MeanLogPowerRMSEdB, ...
    overall.MedianOptimizationSeconds(2:4), ...
    spectralErrors, ...
    centroidErrors};

conditionLabels = strrep(conditions, 'low_', 'L ');
conditionLabels = strrep(conditionLabels, 'mid_', 'M ');
conditionLabels = strrep(conditionLabels, 'high_', 'H ');
conditionLabels = strrep(conditionLabels, 'mixed_', 'Mix ');

tickLabels = { ...
    plotMethods, ...
    plotMethods(2:4), ...
    conditionLabels, ...
    conditionLabels};

plotTitles = [ ...
    "Overall spectral error"; ...
    "Optimization time"; ...
    "Spectral error by EQ condition"; ...
    "Centroid error by EQ condition"];

yLabels = [ ...
    "Mean RMSE (dB)"; ...
    "Median fitting time (s)"; ...
    "Mean RMSE (dB)"; ...
    "Mean centroid error (Hz)"];

fileNames = [ ...
    "overall_spectral_error.png"; ...
    "optimization_time.png"; ...
    "condition_spectral_error.png"; ...
    "condition_centroid_error.png"];

for k = 1:4
    fig = figure('Color', 'w');
    layout = tiledlayout(fig, 1, 1, 'Padding', 'loose');
    ax = nexttile(layout);

    if k == 1
        semilogy(ax, 1:4, plotData{k}, ...
            'o', 'MarkerSize', 7, 'LineWidth', 1.5);
    elseif k == 2
        bar(ax, plotData{k});
    else
        semilogy(ax, 1:nConditions, max(plotData{k}, 1e-6), ...
            '-o', 'LineWidth', 1.3, 'MarkerSize', 5);
    end

    xticks(ax, 1:numel(tickLabels{k}));
    xticklabels(ax, tickLabels{k});
    xtickangle(ax, 25);

    ylabel(ax, yLabels(k));
    title(ax, plotTitles(k));
    set(ax, 'FontSize', 11, 'TickLabelInterpreter', 'none');
    grid(ax, 'on');

    if k <= 2
        xlabel(ax, 'Method');
    else
        xlabel(ax, 'EQ condition');

        lgd = legend(ax, plotMethods, ...
            'NumColumns', 2, 'Box', 'off', ...
            'Interpreter', 'none');
        lgd.Layout.Tile = 'south';
    end

    exportgraphics(fig, fullfile(resultDir, ...
        char(fileNames(k))), 'Resolution', 300);
end

%% Statistical summary

resultDir = fullfile('results', 'batch_comparison');
resultFile = fullfile(resultDir, 'batch_results.csv');

options = detectImportOptions(resultFile, 'TextType', 'string');
options = setvartype(options, ...
    {'PairID','PerformerID','Method','Status'}, 'string');

R = readtable(resultFile, options);

assert(all(R.Status == "OK"), ...
    'Resolve failed rows before statistical analysis.');

base = R(R.Method == "Distorted", :);

assert(numel(unique(base.PairID)) == height(base), ...
    'Baseline pair IDs must be unique.');

statMethods = ["Centroid"; "Three-band"; "Differentiable"];
nPairs = height(base);

errors = nan(nPairs,3);
boundaryHits = false(nPairs,3);

% Align every method with the same baseline test pairs.
for m = 1:3
    current = R(R.Method == statMethods(m), :);
    [found, order] = ismember(base.PairID, current.PairID);

    assert(all(found) && height(current) == nPairs, ...
        'The methods do not contain the same test pairs.');

    current = current(order,:);

    errors(:,m) = current.LogPowerRMSEdB;

    gains = current{:, ...
        {'LowGainDB','MidGainDB','HighGainDB'}};
    boundaryHits(:,m) = any(abs(gains) >= 11.99, 2);
end

% Resample whole performers, retaining their clips and conditions.
performers = unique(base.PerformerID);
nPerformers = numel(performers);

assert(nPerformers >= 2, ...
    'At least two performer clusters are required.');

playerSums = zeros(nPerformers,3);
playerCounts = zeros(nPerformers,1);

for p = 1:nPerformers
    selected = base.PerformerID == performers(p);
    playerSums(p,:) = sum(errors(selected,:),1);
    playerCounts(p) = nnz(selected);
end

nBootstrap = 2000;
stream = RandStream('mt19937ar', 'Seed', 5305);
draws = randi(stream, nPerformers, nPerformers, nBootstrap);

bootstrapMeans = zeros(nBootstrap,3);

for b = 1:nBootstrap
    selectedPlayers = draws(:,b);

    bootstrapMeans(b,:) = ...
        sum(playerSums(selectedPlayers,:),1) / ...
        sum(playerCounts(selectedPlayers));
end

% Percentile confidence intervals using sorted bootstrap estimates.
lowIndex = max(1, ceil(0.025*nBootstrap));
highIndex = min(nBootstrap, ceil(0.975*nBootstrap));
sortedMeans = sort(bootstrapMeans,1);

meanError = mean(errors,1)';
medianError = median(errors,1)';
lower95 = sortedMeans(lowIndex,:)';
upper95 = sortedMeans(highIndex,:)';

improvedPercent = 100*mean( ...
    errors < base.LogPowerRMSEdB-1e-9, 1)';

boundaryPercent = 100*mean(boundaryHits,1)';

statisticalSummary = table( ...
    statMethods, repmat(nPairs,3,1), ...
    repmat(nPerformers,3,1), ...
    meanError, medianError, lower95, upper95, ...
    improvedPercent, boundaryPercent, ...
    'VariableNames', {'Method','Pairs','PerformerClusters', ...
    'MeanRMSEdB','MedianRMSEdB','Lower95DB','Upper95DB', ...
    'ImprovedPercent','BoundaryHitPercent'});

writetable(statisticalSummary, ...
    fullfile(resultDir, 'statistical_summary.csv'));

% Paired comparisons: contender minus baseline.
pairIndex = [1 2; 1 3; 2 3];

pairMean = zeros(3,1);
pairLower = zeros(3,1);
pairUpper = zeros(3,1);
winPercent = zeros(3,1);

for p = 1:3
    a = pairIndex(p,1);
    b = pairIndex(p,2);

    difference = errors(:,b)-errors(:,a);
    bootstrapDifference = sort( ...
        bootstrapMeans(:,b)-bootstrapMeans(:,a));

    pairMean(p) = mean(difference);
    pairLower(p) = bootstrapDifference(lowIndex);
    pairUpper(p) = bootstrapDifference(highIndex);
    winPercent(p) = 100*mean(difference < -1e-9);
end

pairedSummary = table( ...
    statMethods(pairIndex(:,1)), ...
    statMethods(pairIndex(:,2)), ...
    pairMean, pairLower, pairUpper, winPercent, ...
    'VariableNames', {'Baseline','Contender', ...
    'MeanRMSEDifferenceDB','Lower95DB','Upper95DB','WinPercent'});

writetable(pairedSummary, ...
    fullfile(resultDir, 'paired_method_comparisons.csv'));

fprintf('Pairs: %d | Performer clusters: %d\n', ...
    nPairs, nPerformers);

for m = 1:3
    fprintf('\n%s\n', char(statMethods(m)));
    fprintf('Mean RMSE: %.6f dB\n', meanError(m));
    fprintf('Median RMSE: %.6f dB\n', medianError(m));
    fprintf('Mean RMSE 95%% CI: [%.6f, %.6f] dB\n', ...
        lower95(m), upper95(m));
    fprintf('Improved over distorted input: %.2f%%\n', ...
        improvedPercent(m));
    fprintf('Gain boundary hits: %.2f%%\n', boundaryPercent(m));
end

fprintf('\nPaired RMSE differences: contender minus baseline\n');

for p = 1:3
    fprintf('%s versus %s: %+.6f dB, CI [%+.6f, %+.6f]\n', ...
        char(pairedSummary.Contender(p)), ...
        char(pairedSummary.Baseline(p)), ...
        pairMean(p), pairLower(p), pairUpper(p));
end

%% Extended evaluation

evaluationDir = fullfile(pwd, 'results', 'extended_evaluation');
rowsFile = fullfile(evaluationDir, 'extended_metrics.csv');

assert(isfile(rowsFile), 'Saved evaluation data are missing.');

options = detectImportOptions(rowsFile, 'TextType', 'string');
options = setvartype(options, ...
    {'PairID','ClipID','PerformerID','Condition','Method', ...
    'Status','ReferencePath','InputPath','OutputPath'}, 'string');

extendedResults = struct;
extendedResults.Rows = readtable(rowsFile, options);

extendedResults.Summary = readtable( ...
    fullfile(evaluationDir, 'metric_summary.csv'), ...
    'TextType', 'string');

extendedResults.Paired = readtable( ...
    fullfile(evaluationDir, 'paired_comparisons.csv'), ...
    'TextType', 'string');

extendedResults.Bands = readtable( ...
    fullfile(evaluationDir, 'bandwise_summary.csv'), ...
    'TextType', 'string');

extendedResults.Complexity = readtable( ...
    fullfile(evaluationDir, 'complexity_summary.csv'), ...
    'TextType', 'string');

savedSettings = load( ...
    fullfile(evaluationDir, 'evaluation_settings.mat'), 'cfg');
extendedResults.Settings = savedSettings.cfg;

assert(height(extendedResults.Rows) == 960 && ...
    height(extendedResults.Summary) == 12, ...
    'Saved evaluation results are incomplete.');

fprintf('Loaded saved evaluation: %d audio rows.\n', ...
    height(extendedResults.Rows));

%% Content dependence

contentResults = run_content_dependence("load");

%% Matched-capacity ablation

ablationResults = run_capacity_ablation("load");

%% Model mismatch

mismatchResults = run_model_mismatch("load");

%% Final experiment verification

% Final experiment verification

rootDir = pwd;

csvFiles = {
    fullfile('results','batch_comparison','batch_results.csv')
    fullfile('results','extended_evaluation','extended_metrics.csv')
    fullfile('results','content_dependence','content_cases.csv')
    fullfile('results','capacity_ablation','ablation_cases.csv')
    fullfile('results','model_mismatch','mismatch_cases.csv')
};

moduleNames = ["Batch comparison";"Extended evaluation"; ...
    "Content dependence";"Matched-capacity ablation";"Model mismatch"];

expectedRows = [960;960;60;960;1200];
actualRows = zeros(5,1);
savedTables = cell(5,1);

for k = 1:5

    csvPath = fullfile(rootDir,csvFiles{k});

    assert(isfile(csvPath), ...
        'Missing result file: %s',csvPath);

    T = readtable(csvPath,'TextType','string');
    actualRows(k) = height(T);

    assert(actualRows(k) == expectedRows(k), ...
        'Unexpected row count in %s.',char(moduleNames(k)));

    if ismember('Status',T.Properties.VariableNames)

        assert(all(string(T.Status) == "OK"), ...
            'A result file contains an unsuccessful row.');

    end

    metricNames = intersect( ...
        {'LogPowerRMSEdB','RawRMSEdB','ShapeRMSEdB','MRLogRMSEdB'}, ...
        T.Properties.VariableNames,'stable');

    if ~isempty(metricNames)

        assert(all(isfinite(T{:,metricNames}),'all'), ...
            'A result file contains non-finite metrics.');

    end

    savedTables{k} = T;

end

verificationTable = table( ...
    moduleNames,expectedRows,actualRows, ...
    'VariableNames',{'Module','ExpectedRows','SavedRows'});

disp(verificationTable);

% These are result rows, including method repetitions.
% They are not independent recordings.

figureFolders = { ...
    'extended_evaluation', ...
    'content_dependence', ...
    'capacity_ablation', ...
    'model_mismatch'};

expectedFigures = [6 3 3 3];

for k = 1:numel(figureFolders)

    folder = fullfile( ...
        rootDir,'results',figureFolders{k},'figures');

    images = dir(fullfile(folder,'*.png'));

    assert(numel(images) >= expectedFigures(k), ...
        'Expected figures are missing from %s.',folder);

    fprintf('%s: %d PNG files found.\n', ...
        figureFolders{k},numel(images));

end

% Select a measured centroid counterexample.

E = savedTables{2};

requiredNames = { ...
    'Method','PairID','Condition','ReferencePath', ...
    'OutputPath','EvaluatedCentroidErrorHz','ShapeRMSEdB'};

assert(all(ismember(requiredNames,E.Properties.VariableNames)), ...
    'The extended results have incompatible columns.');

candidates = find( ...
    string(E.Method) == "Centroid" & ...
    E.EvaluatedCentroidErrorHz < 1 & ...
    E.ShapeRMSEdB > 1);

assert(~isempty(candidates), ...
    ['No example meets centroid error < 1 Hz ' ...
     'and shape RMSE > 1 dB.']);

% Select the smallest centroid error among qualifying examples.
% This is an illustrative counterexample, not an average result.

[~,position] = min( ...
    E.EvaluatedCentroidErrorHz(candidates));

counterexample = E(candidates(position),:);

disp(counterexample(:,{ ...
    'PairID','Condition', ...
    'EvaluatedCentroidErrorHz','ShapeRMSEdB'}));

% Output WAVs are recreated only for this measured example, using saved gains.
restore_benchmark_audio(string(counterexample.PairID), "Centroid");
referencePath = project_audio_path(rootDir,counterexample.ReferencePath);
outputPath = project_audio_path(rootDir,counterexample.OutputPath);

[referenceAudio,fsReference] = audioread(referencePath);
[centroidAudio,fsOutput] = audioread(outputPath);

assert(fsReference == fsOutput && ...
    isequal(size(referenceAudio),size(centroidAudio)) && ...
    iscolumn(referenceAudio), ...
    'The example audio rates, lengths, or channels do not match.');

win = hann(2048,'periodic');

[PReference,f] = pwelch( ...
    referenceAudio,win,1024,2048,fsReference);

[POutput,~] = pwelch( ...
    centroidAudio,win,1024,2048,fsOutput);

inBand = f >= 20 & f <= 16000;

f = f(inBand);
PReference = PReference(inBand);
POutput = POutput(inBand);

referenceCentroid = ...
    sum(f.*PReference)/sum(PReference);

outputCentroid = ...
    sum(f.*POutput)/sum(POutput);

rawResidual = ...
    10*log10(max(POutput,realmin)) - ...
    10*log10(max(PReference,realmin));

levelDifference = ...
    10*log10(sum(POutput)/sum(PReference));

shapeError = sqrt( ...
    mean((rawResidual-levelDifference).^2));

centroidError = abs( ...
    outputCentroid-referenceCentroid);

assert( ...
    abs(shapeError-counterexample.ShapeRMSEdB) < 1e-5 && ...
    abs(centroidError- ...
    counterexample.EvaluatedCentroidErrorHz) < 1e-4, ...
    'The saved metrics do not agree with the selected WAV files.');

df = f(2)-f(1);

referenceDB = ...
    10*log10(max(PReference,realmin)) - ...
    10*log10(sum(PReference)*df);

outputDB = ...
    10*log10(max(POutput,realmin)) - ...
    10*log10(sum(POutput)*df);

% Draw and capture a standalone figure.

screenSize = get(groot,'ScreenSize');

figureWidth = max(800,min(1100,floor(0.85*screenSize(3))));
figureHeight = max(600,min(740,floor(0.80*screenSize(4))));

counterexampleFig = figure( ...
    'Color','w', ...
    'WindowStyle','normal', ...
    'Units','pixels', ...
    'Position',[30 50 figureWidth figureHeight], ...
    'MenuBar','none', ...
    'ToolBar','none', ...
    'Name','Centroid counterexample', ...
    'NumberTitle','off');

ax = axes( ...
    'Parent',counterexampleFig, ...
    'Position',[0.13 0.24 0.83 0.63]);

hold(ax,'on');

hReference = plot(ax,f,referenceDB, ...
    'Color',[0 0.4470 0.7410], ...
    'LineWidth',1.3);

hOutput = plot(ax,f,outputDB, ...
    'Color',[0.8500 0.3250 0.0980], ...
    'LineWidth',1.3);

xline(ax,referenceCentroid,'--', ...
    'Color',[0 0.4470 0.7410], ...
    'HandleVisibility','off');

xline(ax,outputCentroid,':', ...
    'Color',[0.8500 0.3250 0.0980], ...
    'HandleVisibility','off');

set(ax,'XScale','log','FontSize',12);

xlim(ax,[20 16000]);
grid(ax,'on');
box(ax,'on');

xlabel(ax,'Frequency (Hz)');
ylabel(ax,'Power-normalised PSD (dB/Hz)');

title(ax,{ ...
    'Similar centroids, different spectral shapes'; ...
    sprintf( ...
    'Centroid error: %.6f Hz | Shape RMSE: %.6f dB', ...
    centroidError,shapeError)}, ...
    'FontSize',13);

legend(ax,[hReference hOutput], ...
    {sprintf( ...
    'Reference: centroid = %.6f Hz',referenceCentroid), ...
    sprintf( ...
    'Centroid EQ: centroid = %.6f Hz',outputCentroid)}, ...
    'Location','southoutside', ...
    'Interpreter','none');

verificationDir = fullfile( ...
    rootDir,'results','verification');

if ~isfolder(verificationDir)
    mkdir(verificationDir);
end

drawnow nocallbacks;

imagePath = fullfile( ...
    verificationDir,'centroid_counterexample.png');

exportgraphics(counterexampleFig,imagePath,'Resolution',150);

close(counterexampleFig);

fprintf('\nSaved counterexample: %s\n',imagePath);
fprintf('Experiment verification complete.\n');
