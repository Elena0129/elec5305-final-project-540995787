clear; clc;
rng(5305, 'twister');

%% Find the source recordings
audioFiles = dir(fullfile('data', 'raw', '**', '*.wav'));
assert(numel(audioFiles) >= 3, 'Cannot find enough WAV files.');

% Sort first so that selection is reproducible
[~, order] = sort({audioFiles.name});
audioFiles = audioFiles(order);
selected = randperm(numel(audioFiles), 3);

%% Create output folders
outDir = fullfile('data', 'pilot');
if ~isfolder(outDir)
    mkdir(outDir);
end
if ~isfolder('results')
    mkdir('results');
end

clipSeconds = 5;
nClips = 3;

referenceFile = strings(nClips, 1);
sourceFile = strings(nClips, 1);
sampleRate = zeros(nClips, 1);
startSample = zeros(nClips, 1);
numSamples = zeros(nClips, 1);
scaleGain = zeros(nClips, 1);

fig = figure('Name', 'Reference audio clips', 'Color', 'w');

%% Prepare three reference clips
for k = 1:nClips
    file = audioFiles(selected(k));
    sourcePath = fullfile(file.folder, file.name);
    info = audioinfo(sourcePath);

    fs = info.SampleRate;
    N = round(clipSeconds * fs);
    assert(info.TotalSamples >= N, 'Source recording is too short.');

    % Take five seconds from the middle of the recording
    firstSample = floor((info.TotalSamples - N) / 2) + 1;
    [x, fs] = audioread(sourcePath, ...
        [firstSample, firstSample + N - 1]);

    % Convert to mono and remove DC offset
    x = mean(x, 2);
    x = x - mean(x);

    % Leave headroom for the EQ boosts used later
    peak = max(abs(x));
    assert(peak > 1e-6, 'Selected clip is nearly silent.');
    gain = 0.2 / peak;
    x = gain * x;

    outputName = sprintf('reference_%02d.wav', k);
    audiowrite(fullfile(outDir, outputName), x, fs, ...
        'BitsPerSample', 24);

    referenceFile(k) = string(outputName);
    sourceFile(k) = string(file.name);
    sampleRate(k) = fs;
    startSample(k) = firstSample;
    numSamples(k) = N;
    scaleGain(k) = gain;

    subplot(nClips, 1, k);
    plot((0:N-1)' / fs, x);
    xlabel('Time (s)');
    ylabel('Amplitude');
    title(outputName, 'Interpreter', 'none');
    xlim([0 clipSeconds]);
    ylim([-0.22 0.22]);
    grid on;
end

%% Save the source information and waveform figure
manifest = table(referenceFile, sourceFile, sampleRate, ...
    startSample, numSamples, scaleGain);

writetable(manifest, fullfile(outDir, 'source_manifest.csv'));

exportgraphics(fig, ...
    fullfile('results', 'step01_reference_waveforms.png'), ...
    'Resolution', 150);

disp(manifest(:, 1:3));
fprintf('\nPrepared %d reference clips, %.1f seconds each.\n', ...
    nClips, clipSeconds);