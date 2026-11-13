function report = run_extended_evaluation()
% Evaluate all saved benchmark outputs without fitting any EQ again.

rootDir = fileparts(mfilename('fullpath'));
resultFile = fullfile(rootDir, 'results', ...
    'batch_comparison', 'batch_results.csv');
outDir = fullfile(rootDir, 'results', 'extended_evaluation');
assert(isfile(resultFile), 'Batch results CSV is missing.');

opts = detectImportOptions(resultFile, 'TextType', 'string');
textVars = {'PairID','ClipID','PerformerID','Condition','Method', ...
    'Status','ReferencePath','InputPath','OutputPath'};
assert(all(ismember(textVars, opts.VariableNames)), ...
    'The batch results CSV has an incompatible schema.');
opts = setvartype(opts, textVars, 'string');
R = readtable(resultFile, opts);
assert(all(R.Status == "OK"), 'Resolve failed benchmark rows first.');

R = sortrows(R, {'PairID','Method'});
methods = ["Distorted"; "Centroid"; "Three-band"; "Differentiable"];
base = R(R.Method == methods(1), :);
nPairs = height(base);

assert(nPairs == 240 && numel(unique(base.PairID)) == nPairs, ...
    'Expected 240 unique benchmark pairs.');
assert(height(R) == 4*nPairs, 'Expected four methods per pair.');

for m = 1:4
    rows = R(R.Method == methods(m), :);
    assert(height(rows) == nPairs && ...
        numel(unique(rows.PairID)) == nPairs && ...
        all(ismember(base.PairID, rows.PairID)), ...
        'Methods do not contain identical unique test pairs.');
end

if ~isfolder(outDir)
    mkdir(outDir);
end

% Settings are fixed for every method and every test pair.
cfg.WindowLength = 2048;
cfg.OverlapLength = 1024;
cfg.FFTLength = 2048;
cfg.FrequencyRangeHz = [20 16000];
cfg.BandEdgesHz = [20 500 2000 16000];

cfg.MRFFTLengths = [512 2048 8192];
cfg.MROverlapFraction = 0.75;
cfg.MRFloorBelowPeakDB = 80;
cfg.ActiveFrameBelowPeakDB = 60;

cfg.BootstrapSamples = 2000;
cfg.Seed = 5305;
cfg.PlotFloor = 1e-8;
cfg.LevelMatching = 'Equal total Welch power from 20 to 16000 Hz';

names = {'RawRMSEdB','ShapeRMSEdB','MRLogRMSEdB', ...
    'LevelDifferenceDB','EvaluatedCentroidErrorHz', ...
    'ShapeLowDB','ShapeMidDB','ShapeHighDB'};

values = zeros(height(R), numel(names));
rawBands = zeros(height(R),3);
binCounts = zeros(height(R),1);
lastReference = "";

for k = 1:height(R)

    refPath = resolveAudio(rootDir, R.ReferencePath(k));

    if refPath ~= lastReference
        [ref, fs] = audioread(refPath);
        assert(iscolumn(ref) && all(isfinite(ref)), ...
            'Reference audio must be finite and mono.');

        C = referenceAnalysis(ref, fs, cfg);
        lastReference = refPath;
    end

    % Check that level matching removes a pure gain change.
    if k == 1
        identity = measureAudio(ref, C, cfg);
        gainOnly = measureAudio(ref*10^(6/20), C, cfg);

        assert(max(abs(identity(1:3))) < 1e-8, ...
            'Reference identity check failed.');

        assert(abs(gainOnly(1)-6) < 1e-8 && ...
            max(abs(gainOnly(2:3))) < 1e-8, ...
            'Pure-gain invariance check failed.');

        fprintf('Identity check: PASS\n');
        fprintf('Pure-gain shape check: PASS\n');
    end

    if R.Method(k) == "Distorted"
        audioPath = resolveAudio(rootDir, R.InputPath(k));
    else
        audioPath = resolveAudio(rootDir, R.OutputPath(k));
    end

    [y, fsY] = audioread(audioPath);

    assert(fsY == C.fs && iscolumn(y) && numel(y) == C.N && ...
        all(isfinite(y)), 'An output has invalid audio dimensions.');

    [values(k,:), rawBands(k,:)] = measureAudio(y, C, cfg);
    binCounts(k) = numel(C.f);

    if mod(k,40) == 0 || k == height(R)
        fprintf('Audio rows evaluated: %d/%d\n', k, height(R));
        drawnow;
    end
end

% Check agreement with the original benchmark metrics.
rawDifference = max(abs(values(:,1)-R.LogPowerRMSEdB));
centroidDifference = max(abs(values(:,5)-R.CentroidErrorHz));

assert(rawDifference < 1e-4 && centroidDifference < 1e-4, ...
    'Recomputed metrics disagree with the original benchmark.');

assert(all(binCounts == binCounts(1)), ...
    'Feature counts require a common analysis frequency grid.');

assert(all(isfinite(values), 'all'), ...
    'A new evaluation metric is not finite.');

E = [R, array2table(values, 'VariableNames', names)];
E.LowErrorDB = rawBands(:,1);
E.MidErrorDB = rawBands(:,2);
E.HighErrorDB = rawBands(:,3);

[S, P] = clusterStatistics(E, methods, cfg);

% Report signed errors and absolute errors separately.
bandNames = ["Low"; "Mid"; "High"];
rawMAE = zeros(4,3);
shapeMAE = zeros(4,3);
rawSigned = zeros(4,3);
shapeSigned = zeros(4,3);
times = zeros(4,1);

for m = 1:4
    selected = E.Method == methods(m);

    a = E{selected, ...
        {'LowErrorDB','MidErrorDB','HighErrorDB'}};

    b = E{selected, ...
        {'ShapeLowDB','ShapeMidDB','ShapeHighDB'}};

    rawMAE(m,:) = mean(abs(a),1);
    shapeMAE(m,:) = mean(abs(b),1);
    rawSigned(m,:) = mean(a,1);
    shapeSigned(m,:) = mean(b,1);

    times(m) = median(E.OptimizationSeconds(selected));
end

B = table(repelem(methods,3), repmat(bandNames,4,1), ...
    reshape(rawSigned.',[],1), reshape(rawMAE.',[],1), ...
    reshape(shapeSigned.',[],1), reshape(shapeMAE.',[],1), ...
    'VariableNames', {'Method','Band','MeanSignedRawDB', ...
    'MeanAbsRawDB','MeanSignedShapeDB','MeanAbsShapeDB'});

complexity = table(methods, [0;1;3;binCounts(1)], [0;1;3;3], ...
    times, 'VariableNames', {'Method','TargetValueCount', ...
    'OptimizedGainCount','MedianOptimizationSeconds'});

% Save new analysis without replacing the original benchmark.
writetable(E, fullfile(outDir, 'extended_metrics.csv'));
writetable(S, fullfile(outDir, 'metric_summary.csv'));
writetable(P, fullfile(outDir, 'paired_comparisons.csv'));
writetable(B, fullfile(outDir, 'bandwise_summary.csv'));
writetable(complexity, fullfile(outDir, 'complexity_summary.csv'));

save(fullfile(outDir, 'evaluation_settings.mat'), ...
    'cfg','resultFile','rawDifference','centroidDifference');

% Export each plot as a separate figure.
colors = lines(4);

metricFields = ["ShapeRMSEdB"; "MRLogRMSEdB"];
captions = ["Level-matched spectral error"; ...
    "Multi-resolution spectral error"];
files = ["shape_error.png"; "multi_resolution_error.png"];

for q = 1:2
    [fig, ax] = newPlot(captions(q));

    for m = 1:4
        row = S.Method == methods(m) & ...
            S.Metric == metricFields(q);

        mu = S.MeanDB(row);
        lo = S.Lower95DB(row);
        hi = S.Upper95DB(row);

        errorbar(ax, m, max(mu,cfg.PlotFloor), ...
            max(0,mu-lo), max(0,hi-mu), 'o', ...
            'Color', colors(m,:), 'LineWidth', 1.5);

        hold(ax,'on');
    end

    set(ax,'YScale','log','XTick',1:4, ...
        'XTickLabel',cellstr(methods));

    xlim(ax,[0.5 4.5]);
    ylabel(ax,'Mean error (dB)');
    xlabel(ax,'Method');

    exportgraphics(fig, fullfile(outDir,files(q)), ...
        'Resolution',200);
end

bandData = {rawMAE, shapeMAE};
bandTitles = ["Bandwise error before level matching"; ...
    "Bandwise error after level matching"];
bandFiles = ["band_error_raw.png"; "band_error_shape.png"];

for q = 1:2
    [fig, ax] = newPlot(bandTitles(q));

    for m = 1:4
        semilogy(ax,1:3, ...
            max(bandData{q}(m,:),cfg.PlotFloor), ...
            '-o','Color',colors(m,:),'LineWidth',1.5);

        hold(ax,'on');
    end

    xticks(ax,1:3);
    xticklabels(ax,bandNames);
    xlim(ax,[0.8 3.2]);

    ylabel(ax,'Mean absolute band-power error (dB)');
    xlabel(ax,'Frequency band');
    addLegend(ax,methods);

    exportgraphics(fig, fullfile(outDir,bandFiles(q)), ...
        'Resolution',200);
end

[fig, ax] = newPlot("Centroid matching versus spectral matching");

for m = 2:4
    selected = E.Method == methods(m);

    loglog(ax, ...
        max(E.CentroidErrorHz(selected),cfg.PlotFloor), ...
        max(E.RawRMSEdB(selected),cfg.PlotFloor), ...
        'o','Color',colors(m,:),'MarkerSize',5);

    hold(ax,'on');
end

xlabel(ax,'Absolute centroid error (Hz)');
ylabel(ax,'Raw log-power RMSE (dB)');
addLegend(ax,methods(2:4));

exportgraphics(fig, ...
    fullfile(outDir,'centroid_vs_spectrum.png'), ...
    'Resolution',200);

plotRecoveryExample(E,rootDir,outDir,cfg,methods,colors);

fprintf('\nEvaluation complete: %d rows | %d pairs | 4 methods.\n', ...
    height(E),nPairs);

for m = 1:4
    fprintf('\n%s\n',char(methods(m)));
    rows = find(S.Method == methods(m));

    for j = rows.'
        fprintf('  %s: %.6f dB | CI [%.6f, %.6f]\n', ...
            char(S.Metric(j)),S.MeanDB(j), ...
            S.Lower95DB(j),S.Upper95DB(j));
    end
end

fprintf('\nSaved results: %s\n',outDir);

report = struct('Rows',E,'Summary',S,'Paired',P, ...
    'Bands',B,'Complexity',complexity,'Settings',cfg);
end


function C = referenceAnalysis(ref,fs,cfg)

assert(fs/2 >= cfg.FrequencyRangeHz(2) && ...
    numel(ref) >= max(cfg.MRFFTLengths), ...
    'Reference sample rate or length is too small.');

C.fs = fs;
C.N = numel(ref);
C.window = hann(cfg.WindowLength,'periodic');

[p,f] = pwelch(ref,C.window, ...
    cfg.OverlapLength,cfg.FFTLength,fs);

C.mask = f >= cfg.FrequencyRangeHz(1) & ...
    f <= cfg.FrequencyRangeHz(2);

C.f = f(C.mask);
C.p = p(C.mask);

assert(sum(C.p) > 0, ...
    'Reference has no analysis-band energy.');

C.logPower = 10*log10(max(C.p,realmin));
C.centroid = sum(C.f.*C.p)/sum(C.p);
C.MR = cell(numel(cfg.MRFFTLengths),1);

for r = 1:numel(C.MR)
    n = cfg.MRFFTLengths(r);

    [s,f] = spectrogram(ref,hann(n,'periodic'), ...
        round(cfg.MROverlapFraction*n),n,fs);

    keep = f >= cfg.FrequencyRangeHz(1) & ...
        f <= cfg.FrequencyRangeHz(2);

    mag = abs(s(keep,:));
    energy = sum(mag.^2,1);

    active = energy > max(energy)* ...
        10^(-cfg.ActiveFrameBelowPeakDB/10);

    assert(any(active), ...
        'No active reference frames were found.');

    mag = mag(:,active);

    floorValue = max(max(mag,[],'all')* ...
        10^(-cfg.MRFloorBelowPeakDB/20),realmin);

    C.MR{r} = struct('Keep',keep,'Active',active, ...
        'Floor',floorValue,'LogReference', ...
        20*log10(max(mag,floorValue)));
end
end


function [v,rawBand] = measureAudio(y,C,cfg)

[p,~] = pwelch(y,C.window, ...
    cfg.OverlapLength,cfg.FFTLength,C.fs);

p = p(C.mask);
assert(sum(p) > 0,'Output has no analysis-band energy.');

d = 10*log10(max(p,realmin))-C.logPower;

% Remove one global level difference, retaining spectral shape.
levelDB = 10*log10(sum(p)/sum(C.p));
shape = d-levelDB;

centroid = sum(C.f.*p)/sum(p);
rawBand = zeros(1,3);

for b = 1:3
    keep = C.f >= cfg.BandEdgesHz(b) & ...
        C.f < cfg.BandEdgesHz(b+1);

    if b == 3
        keep = C.f >= cfg.BandEdgesHz(b) & ...
            C.f <= cfg.BandEdgesHz(b+1);
    end

    rawBand(b) = 10*log10( ...
        max(sum(p(keep)),realmin)/ ...
        max(sum(C.p(keep)),realmin));
end

% Average log-magnitude RMSE across three STFT resolutions.
mr = zeros(numel(C.MR),1);
levelGain = 10^(-levelDB/20);

for r = 1:numel(mr)
    n = cfg.MRFFTLengths(r);

    s = spectrogram(y,hann(n,'periodic'), ...
        round(cfg.MROverlapFraction*n),n,C.fs);

    item = C.MR{r};

    mag = abs(s(item.Keep,item.Active))*levelGain;

    delta = 20*log10(max(mag,item.Floor)) - ...
        item.LogReference;

    mr(r) = sqrt(mean(delta.^2,'all'));
end

v = [sqrt(mean(d.^2)),sqrt(mean(shape.^2)),mean(mr), ...
    levelDB,abs(centroid-C.centroid),rawBand-levelDB];
end


function [S,P] = clusterStatistics(E,methods,cfg)

base = E(E.Method == methods(1),:);
metrics = ["RawRMSEdB";"ShapeRMSEdB";"MRLogRMSEdB"];
nPairs = height(base);
values = zeros(nPairs,4,3);

for m = 1:4
    rows = E(E.Method == methods(m),:);
    [found,order] = ismember(base.PairID,rows.PairID);

    assert(all(found) && ...
        all(rows.PerformerID(order) == base.PerformerID) && ...
        all(rows.ClipID(order) == base.ClipID) && ...
        all(rows.Condition(order) == base.Condition), ...
        'Pair metadata are inconsistent across methods.');

    values(:,m,:) = reshape( ...
        rows{order,cellstr(metrics)},nPairs,1,3);
end

flat = reshape(values,nPairs,12);
players = unique(base.PerformerID);
nPlayers = numel(players);

assert(nPlayers >= 2, ...
    'At least two performer clusters are required.');

sums = zeros(nPlayers,12);
counts = zeros(nPlayers,1);

for p = 1:nPlayers
    keep = base.PerformerID == players(p);
    sums(p,:) = sum(flat(keep,:),1);
    counts(p) = nnz(keep);
end

stream = RandStream('mt19937ar','Seed',cfg.Seed);
draws = randi(stream,nPlayers,nPlayers,cfg.BootstrapSamples);
boot = zeros(cfg.BootstrapSamples,12);

for b = 1:cfg.BootstrapSamples
    selected = draws(:,b);

    boot(b,:) = sum(sums(selected,:),1) / ...
        sum(counts(selected));
end

lo = max(1,ceil(0.025*cfg.BootstrapSamples));
hi = min(cfg.BootstrapSamples,ceil(0.975*cfg.BootstrapSamples));
sorted = sort(boot,1);

S = table(repmat(methods,3,1),repelem(metrics,4), ...
    repmat(nPairs,12,1),repmat(nPlayers,12,1), ...
    mean(flat,1).',median(flat,1).', ...
    sorted(lo,:).',sorted(hi,:).', ...
    'VariableNames',{'Method','Metric','Pairs','PerformerClusters', ...
    'MeanDB','MedianDB','Lower95DB','Upper95DB'});

pairs = [2 3;2 4;3 4];
a = zeros(9,4);

for q = 1:3
    for p = 1:3
        i = pairs(p,1)+4*(q-1);
        j = pairs(p,2)+4*(q-1);

        delta = flat(:,j)-flat(:,i);
        sampled = sort(boot(:,j)-boot(:,i));

        a(p+3*(q-1),:) = [mean(delta),sampled(lo),sampled(hi), ...
            100*mean(delta < -1e-9)];
    end
end

P = table(repelem(metrics,3), ...
    repmat(methods(pairs(:,1)),3,1), ...
    repmat(methods(pairs(:,2)),3,1), ...
    a(:,1),a(:,2),a(:,3),a(:,4), ...
    'VariableNames',{'Metric','Baseline','Contender', ...
    'MeanDifferenceDB','Lower95DB','Upper95DB','WinPercent'});
end


function plotRecoveryExample(E,rootDir,outDir,cfg,methods,colors)
% Choose the median centroid-method RMSE among mid-cut cases.

candidates = E(E.Method == "Centroid" & ...
    E.Condition == "mid_cut",:);

assert(~isempty(candidates),'No mid-cut example was found.');

[~,order] = sort(candidates.RawRMSEdB);
chosen = candidates(order(ceil(height(candidates)/2)),:);

[ref,fs] = audioread( ...
    resolveAudio(rootDir,chosen.ReferencePath));

win = hann(cfg.WindowLength,'periodic');
[p,f] = pwelch(ref,win,cfg.OverlapLength,cfg.FFTLength,fs);

keep = f >= cfg.FrequencyRangeHz(1) & ...
    f <= cfg.FrequencyRangeHz(2);

f = f(keep);
spectra = zeros(numel(f),5);
spectra(:,1) = 10*log10(max(p(keep),realmin));

[fig,ax] = newPlot("Reference recovery: "+chosen.PairID);
semilogx(ax,f,spectra(:,1),'k-','LineWidth',2);
hold(ax,'on');

for m = 1:4
    row = E(E.PairID == chosen.PairID & ...
        E.Method == methods(m),:);

    if m == 1
        path = resolveAudio(rootDir,row.InputPath);
    else
        path = resolveAudio(rootDir,row.OutputPath);
    end

    y = audioread(path);
    p = pwelch(y,win,cfg.OverlapLength,cfg.FFTLength,fs);

    spectra(:,m+1) = 10*log10(max(p(keep),realmin));

    semilogx(ax,f,spectra(:,m+1), ...
        'Color',colors(m,:),'LineWidth',1.2);
end

xlim(ax,cfg.FrequencyRangeHz);
xlabel(ax,'Frequency (Hz)');
ylabel(ax,'Power spectral density (dB/Hz)');
addLegend(ax,["Reference";methods]);

exportgraphics(fig, ...
    fullfile(outDir,'five_signal_spectra.png'), ...
    'Resolution',200);

T = array2table([f,spectra],'VariableNames', ...
    {'FrequencyHz','ReferenceDB','DistortedDB', ...
    'CentroidDB','ThreeBandDB','DifferentiableDB'});

writetable(T,fullfile(outDir,'example_spectra.csv'));

examplePairID = chosen.PairID;
save(fullfile(outDir,'example_selection.mat'),'examplePairID');
end


function p = resolveAudio(rootDir,value)

assert(~ismissing(value) && strlength(string(value)) > 0, ...
    'An audio path is empty.');

p = string(value);

if ~isfile(p)
    p = string(fullfile(rootDir,char(p)));
end

assert(isfile(p),'Audio file is missing: %s',char(p));
end


function [fig,ax] = newPlot(caption)

fig = figure('Color','w','Units','pixels', ...
    'Position',[100 100 1050 700],'Name',char(caption));

layout = tiledlayout(fig,1,1,'Padding','loose');
ax = nexttile(layout);

ax.FontSize = 12;
grid(ax,'on');
title(ax,caption,'Interpreter','none');
end


function addLegend(ax,labels)

lgd = legend(ax,labels,'Interpreter','none','NumColumns',2);
lgd.Layout.Tile = 'south';
end