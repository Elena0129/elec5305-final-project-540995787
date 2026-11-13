function [manifest, fig] = prepare_pilot_audio(regenerate)
% Reuse the three supplied pilot excerpts, or prepare them from raw GuitarSet.
% prepare_pilot_audio(true) explicitly regenerates the pilot data from data/raw.
% The original centre-crop, mono, DC-removal and 0.2-peak rules are retained.

if nargin < 1, regenerate = false; end
assert(islogical(regenerate) && isscalar(regenerate), ...
    'ELEC5305:RegenerateFlag', 'Regenerate must be true or false.');
rootDir = fileparts(mfilename('fullpath'));
outDir = fullfile(rootDir, 'data', 'pilot');
resultDir = fullfile(rootDir, 'results');
manifestPath = fullfile(outDir, 'source_manifest.csv');
if ~isfolder(outDir), mkdir(outDir); end
if ~isfolder(resultDir), mkdir(resultDir); end

nClips = 3;
clipSeconds = 5;
paths = strings(nClips, 1);
for k = 1:nClips
    paths(k) = fullfile(outDir, sprintf('reference_%02d.wav', k));
end
reuse = ~regenerate && isfile(manifestPath) && all(isfile(paths));
fig = figure('Name', 'Reference audio clips', 'Color', 'w');

if reuse
    manifest = readtable(manifestPath, 'TextType', 'string');
    assert(height(manifest) == nClips, 'ELEC5305:PilotManifest', ...
        'Expected three pilot source records.');
    for k = 1:nClips
        [x, fs] = audioread(paths(k));
        assert(iscolumn(x) && all(isfinite(x)) && ...
            numel(x) == round(clipSeconds*fs), 'ELEC5305:PilotAudio', ...
            'A supplied pilot clip is invalid.');
        drawClip(fig, x, fs, k, nClips, clipSeconds, ...
            sprintf('reference_%02d.wav', k));
    end
    fprintf('Using the three supplied pilot excerpts; raw audio is not needed.\n');
else
    audioFiles = dir(fullfile(rootDir, 'data', 'raw', '**', '*.wav'));
    audioFiles = audioFiles(~startsWith(string({audioFiles.name}), "._"));
    assert(numel(audioFiles) >= nClips, 'ELEC5305:RawAudio', ...
        'Provide the prepared pilot data or extract GuitarSet into data/raw.');
    [~, order] = sort({audioFiles.name});
    audioFiles = audioFiles(order);
    stream = RandStream('mt19937ar', 'Seed', 5305);
    selected = randperm(stream, numel(audioFiles), nClips);
    referenceFile = strings(nClips, 1);
    sourceFile = strings(nClips, 1);
    sampleRate = zeros(nClips, 1);
    startSample = zeros(nClips, 1);
    numSamples = zeros(nClips, 1);
    scaleGain = zeros(nClips, 1);
    for k = 1:nClips
        file = audioFiles(selected(k));
        sourcePath = fullfile(file.folder, file.name);
        info = audioinfo(sourcePath);
        fs = info.SampleRate;
        N = round(clipSeconds*fs);
        assert(info.TotalSamples >= N, 'ELEC5305:ShortSource', ...
            'Source recording is too short.');
        firstSample = floor((info.TotalSamples-N)/2)+1;
        x = audioread(sourcePath, [firstSample, firstSample+N-1]);
        x = mean(x, 2);
        x = x-mean(x);
        peak = max(abs(x));
        assert(peak > 1e-6 && all(isfinite(x)), 'ELEC5305:SilentSource', ...
            'Selected source is invalid or nearly silent.');
        gain = 0.2/peak;
        x = gain*x;
        outputName = sprintf('reference_%02d.wav', k);
        audiowrite(paths(k), x, fs, 'BitsPerSample', 24);
        referenceFile(k) = string(outputName);
        sourceFile(k) = string(file.name);
        sampleRate(k) = fs;
        startSample(k) = firstSample;
        numSamples(k) = N;
        scaleGain(k) = gain;
        drawClip(fig, x, fs, k, nClips, clipSeconds, outputName);
    end
    manifest = table(referenceFile, sourceFile, sampleRate, ...
        startSample, numSamples, scaleGain);
    writetable(manifest, manifestPath);
    fprintf('Prepared three pilot excerpts from raw GuitarSet audio.\n');
end

exportgraphics(fig, fullfile(resultDir, 'step01_reference_waveforms.png'), ...
    'Resolution', 150);
end


function drawClip(fig, x, fs, k, nClips, seconds, name)
subplot(nClips, 1, k, 'Parent', fig);
plot((0:numel(x)-1)'/fs, x);
xlabel('Time (s)');
ylabel('Amplitude');
title(name, 'Interpreter', 'none');
xlim([0 seconds]);
ylim([-0.22 0.22]);
grid on;
end
