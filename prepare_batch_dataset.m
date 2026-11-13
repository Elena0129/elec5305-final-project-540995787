function manifest = prepare_batch_dataset()
% Prepare a reproducible evaluation dataset.
% Save reference clips and a manifest of controlled EQ conditions.

rootDir = fileparts(mfilename('fullpath'));
rawDir = fullfile(rootDir, 'data', 'raw');
batchDir = fullfile(rootDir, 'data', 'batch');
referenceDir = fullfile(batchDir, 'reference');

protocol.Seed = 5305;
protocol.NumClips = 30;
protocol.ClipSeconds = 5;
protocol.ReferencePeak = 0.1;
protocol.MinimumRMS = 1e-5;
protocol.FrequenciesHz = [250 1000 2500];
protocol.MidBandwidthHz = 1000;
protocol.ShelfSlope = 1;
protocol.BandEdgesHz = [20 500 2000 16000];
protocol.WindowLength = 2048;
protocol.OverlapLength = 1024;
protocol.FFTLength = 2048;

conditionNames = [
    "low_cut"
    "low_boost"
    "mid_cut"
    "mid_boost"
    "high_cut"
    "high_boost"
    "mixed_A"
    "mixed_B"
];

% Columns: low-shelf, peaking, high-shelf gain in dB
knownGainsDB = [
    -6   0   0
     6   0   0
     0  -6   0
     0   6   0
     0   0  -6
     0   0   6
     6  -6   6
    -6   6  -6
];

assert(isfolder(rawDir), 'The raw audio folder is missing.');

pilotManifestPath = fullfile( ...
    rootDir, 'data', 'pilot', 'source_manifest.csv');

assert(isfile(pilotManifestPath), ...
    'The pilot source manifest is missing.');

pilot = readtable(pilotManifestPath, 'TextType', 'string');

% Find recordings and exclude the pilot source files
files = dir(fullfile(rawDir, '**', '*.wav'));
names = string({files.name})';

keep = ~startsWith(names, "._") & ...
    ~ismember(names, pilot.sourceFile);

files = files(keep);

[~, sortOrder] = sort(string({files.name}));
files = files(sortOrder);
names = string({files.name})';

assert(numel(files) >= protocol.NumClips, ...
    'There are not enough eligible source recordings.');

playerIDs = extractBefore(names, "_");

assert(all(~ismissing(playerIDs)), ...
    'Source filenames must contain a performer prefix.');

players = unique(playerIDs);
rng(protocol.Seed, 'twister');

% Shuffle within each performer, then select in round-robin order
queues = cell(numel(players), 1);

for p = 1:numel(players)
    indices = find(playerIDs == players(p));
    queues{p} = indices(randperm(numel(indices)));
end

candidateOrder = [];
queueLengths = cellfun(@numel, queues);

for roundIndex = 1:max(queueLengths)
    for p = 1:numel(players)
        if roundIndex <= numel(queues{p})
            candidateOrder(end+1) = queues{p}(roundIndex);
        end
    end
end

if ~isfolder(referenceDir)
    mkdir(referenceDir);
end

referenceRows = struct([]);
pairRows = struct([]);
clipCount = 0;
pairCount = 0;

for candidateIndex = 1:numel(candidateOrder)

    sourceIndex = candidateOrder(candidateIndex);
    file = files(sourceIndex);
    sourcePath = fullfile(file.folder, file.name);
    info = audioinfo(sourcePath);

    fs = info.SampleRate;
    N = round(protocol.ClipSeconds * fs);

    if info.TotalSamples < N || fs < 32000
        continue;
    end

    % Extract a centred five-second excerpt
    firstSample = floor((info.TotalSamples - N)/2) + 1;
    [x, fs] = audioread(sourcePath, ...
        [firstSample firstSample + N - 1]);

    x = mean(x, 2);
    dcOffset = mean(x);
    x = x - dcOffset;

    if ~all(isfinite(x)) || ...
            sqrt(mean(x.^2)) < protocol.MinimumRMS
        continue;
    end

    peak = max(abs(x));
    scaleGain = protocol.ReferencePeak / peak;
    x = scaleGain * x;

    clipCount = clipCount + 1;
    clipID = sprintf('clip_%03d', clipCount);

    relativeReference = fullfile( ...
        'data', 'batch', 'reference', [clipID '.wav']);

    referencePath = fullfile(rootDir, relativeReference);

    audiowrite(referencePath, x, fs, 'BitsPerSample', 24);
    [x, fs] = audioread(referencePath);

    referenceRows(clipCount).ClipID = string(clipID);
    referenceRows(clipCount).SourceFile = string(file.name);
    referenceRows(clipCount).SourcePath = string( ...
        strrep(sourcePath, [rootDir filesep], ''));
    referenceRows(clipCount).PerformerID = playerIDs(sourceIndex);
    referenceRows(clipCount).ReferenceFile = string(relativeReference);
    referenceRows(clipCount).StartSample = firstSample;
    referenceRows(clipCount).NumSamples = N;
    referenceRows(clipCount).SampleRate = fs;
    referenceRows(clipCount).DCOffset = dcOffset;
    referenceRows(clipCount).ScaleGain = scaleGain;

    % Validate every controlled input without saving duplicate audio
    for c = 1:numel(conditionNames)

        y = applyKnownEQ(x, fs, knownGainsDB(c, :), protocol);
        inputPeak = max(abs(y));

        assert(all(isfinite(y)) && inputPeak < 1, ...
            'Invalid values or clipping in %s, condition %s.', ...
            clipID, char(conditionNames(c)));

        pairCount = pairCount + 1;

        pairRows(pairCount).PairID = ...
            string(clipID) + "_" + conditionNames(c);
        pairRows(pairCount).ClipID = string(clipID);
        pairRows(pairCount).PerformerID = playerIDs(sourceIndex);
        pairRows(pairCount).ReferenceFile = string(relativeReference);
        pairRows(pairCount).Condition = conditionNames(c);
        pairRows(pairCount).SampleRate = fs;
        pairRows(pairCount).LowGainDB = knownGainsDB(c, 1);
        pairRows(pairCount).MidGainDB = knownGainsDB(c, 2);
        pairRows(pairCount).HighGainDB = knownGainsDB(c, 3);
        pairRows(pairCount).InputPeak = inputPeak;
    end

    if clipCount == protocol.NumClips
        break;
    end
end

assert(clipCount == protocol.NumClips, ...
    'Could not prepare the requested number of valid clips.');

referenceManifest = struct2table(referenceRows);
manifest = struct2table(pairRows);

conditions = table(conditionNames, ...
    knownGainsDB(:, 1), knownGainsDB(:, 2), knownGainsDB(:, 3), ...
    'VariableNames', ...
    {'Condition', 'LowGainDB', 'MidGainDB', 'HighGainDB'});

writetable(referenceManifest, ...
    fullfile(batchDir, 'references.csv'));
writetable(manifest, ...
    fullfile(batchDir, 'manifest.csv'));
writetable(conditions, ...
    fullfile(batchDir, 'conditions.csv'));

save(fullfile(batchDir, 'protocol.mat'), ...
    'protocol', 'conditionNames', 'knownGainsDB');

fprintf('Reference clips: %d\n', height(referenceManifest));
fprintf('Duration per clip: %.1f seconds\n', protocol.ClipSeconds);
fprintf('Conditions per clip: %d\n', numel(conditionNames));
fprintf('Total test conditions: %d\n', height(manifest));

summary = table(conditionNames, ...
    repmat(clipCount, numel(conditionNames), 1), ...
    'VariableNames', {'Condition', 'Pairs'});
disp(summary);

for p = 1:numel(players)
    count = sum(referenceManifest.PerformerID == players(p));
    fprintf('Performer %s: %d clips\n', char(players(p)), count);
end

fprintf('Dataset saved in data/batch.\n');
end


function y = applyKnownEQ(x, fs, gainsDB, protocol)
% Generate a controlled distortion using the recorded parameters.

y = x;
frequencies = protocol.FrequenciesHz;

if gainsDB(1) ~= 0
    [b, a] = designShelvingEQ( ...
        gainsDB(1), protocol.ShelfSlope, ...
        frequencies(1)/(fs/2), 'lo', 'Orientation', 'row');
    y = filter(b, a, y);
end

if gainsDB(2) ~= 0
    [b, a] = designParamEQ( ...
        2, gainsDB(2), frequencies(2)/(fs/2), ...
        protocol.MidBandwidthHz/(fs/2), ...
        'Orientation', 'row');
    y = filter(b, a, y);
end

if gainsDB(3) ~= 0
    [b, a] = designShelvingEQ( ...
        gainsDB(3), protocol.ShelfSlope, ...
        frequencies(3)/(fs/2), 'hi', 'Orientation', 'row');
    y = filter(b, a, y);
end
end