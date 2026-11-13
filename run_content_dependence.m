function report = run_content_dependence(action)
% Test fixed-target centroid control on unmodified guitar excerpts.
% Use "run" for computation, "load" for saved results, and "plot" for figures.

if nargin == 0
    action = "run";
end

action = string(action);

assert(isscalar(action) && any(action == ["run","load","plot"]), ...
    'Action must be run, load, or plot.');

rootDir = fileparts(mfilename('fullpath'));
outDir = fullfile(rootDir,'results','content_dependence');
resultMAT = fullfile(outDir,'content_dependence_results.mat');

if action ~= "run"
    assert(isfile(resultMAT),'Run the content experiment first.');

    saved = load(resultMAT,'report');
    report = saved.report;

    if action == "plot"
        figureDir = fullfile(outDir,'figures');

        if ~isfolder(figureDir)
            mkdir(figureDir);
        end

        for q = 1:3
            plotOne(report,q,figureDir);
        end

        fprintf('Content-dependence figures completed.\n');
    else
        fprintf('Loaded saved content results: %d cases.\n', ...
            height(report.Cases));
    end

    return;
end

if ~isfolder(outDir)
    mkdir(outDir);
end

audioDir = fullfile(outDir,'audio');

if ~isfolder(audioDir)
    mkdir(audioDir);
end

settings = load( ...
    fullfile(rootDir,'results','extended_evaluation', ...
    'evaluation_settings.mat'),'cfg');

cfg = settings.cfg;
cfg.ShelfHz = 2500;
cfg.ShelfSlope = 1;
cfg.GainLimitDB = 12;
cfg.CoarseStepDB = 0.5;
cfg.FineStepDB = 0.01;
cfg.NontrivialGainDB = 0.5;

% Use the same 30 final-test references as the main benchmark.
batchFile = fullfile(rootDir,'results','batch_comparison', ...
    'batch_results.csv');

R = readTextTable(batchFile, ...
    {'ClipID','PerformerID','Method','Status','ReferencePath'});

R = R(R.Method == "Distorted",:);

assert(height(R) == 240 && all(R.Status == "OK"), ...
    'The completed 240-pair benchmark is required.');

[~,first] = unique(R.ClipID);

clips = R(first,{'ClipID','PerformerID','ReferencePath'});

assert(height(clips) == 30, ...
    'Expected 30 clean test excerpts.');

for k = 1:height(clips)
    selected = R.ClipID == clips.ClipID(k);

    assert(numel(unique(R.ReferencePath(selected))) == 1 && ...
        numel(unique(R.PerformerID(selected))) == 1, ...
        'A clip has inconsistent reference metadata.');
end

% Find source-recording metadata by its column names.
metadata = sourceMetadata(fullfile(rootDir,'data','batch'));

[found,order] = ismember(clips.ClipID,metadata.ClipID);

assert(all(found),'Test source metadata are incomplete.');

clips.SourceFile = metadata.SourceFile(order);

assert(numel(unique(clips.SourceFile)) == 30, ...
    'Test excerpts must come from 30 distinct source recordings.');

clips.PlayingMode = repmat("Unknown",height(clips),1);

clips.PlayingMode( ...
    contains(lower(clips.SourceFile),"_comp_")) = "Comp";

clips.PlayingMode( ...
    contains(lower(clips.SourceFile),"_solo_")) = "Solo";

% Determine one fixed target using development audio only.
pilotDir = fullfile(rootDir,'data','pilot');

D = readTextTable( ...
    fullfile(pilotDir,'source_manifest.csv'), ...
    {'referenceFile','sourceFile'});

assert(height(D) == 3, ...
    'Expected three pilot development excerpts.');

assert(isempty(intersect( ...
    lower(D.sourceFile),lower(clips.SourceFile))), ...
    'Development and final-test source recordings overlap.');

development = table( ...
    D.referenceFile,D.sourceFile,zeros(height(D),1), ...
    'VariableNames',{'ReferenceFile','SourceFile','CentroidHz'});

for k = 1:height(D)
    [x,fs] = audioread( ...
        resolvePath(pilotDir,D.referenceFile(k)));

    A = analyseAudio(x,fs,cfg);
    development.CentroidHz(k) = A.centroid;
end

cfg.FixedTargetHz = median(development.CentroidHz);
cfg.TargetDefinition = ...
    'Median power centroid of three development clips';

writetable(development, ...
    fullfile(outDir,'development_target.csv'));

save(fullfile(outDir,'content_settings.mat'), ...
    'cfg','development');

fprintf('Development excerpts: %d\n',height(development));
fprintf('Clean test excerpts: %d\n',height(clips));
fprintf('Development/test source overlap: 0\n');
fprintf('Fixed development target: %.6f Hz\n',cfg.FixedTargetHz);

scenarios = ["Self-reference";"Fixed-target"];

caseRows = cell(2*height(clips),1);
clips.CleanCentroidHz = zeros(height(clips),1);
rowCount = 0;

for k = 1:height(clips)
    inputPath = resolvePath(rootDir,clips.ReferencePath(k));

    [x,fs] = audioread(inputPath);
    A = analyseAudio(x,fs,cfg);

    clips.CleanCentroidHz(k) = A.centroid;
    targets = [A.centroid;cfg.FixedTargetHz];

    for s = 1:2
        fprintf('Clip %d/%d | %s: fitting...\n', ...
            k,height(clips),char(scenarios(s)));

        clockFit = tic;

        [gainDB,nEvaluations] = ...
            fitShelfGain(x,A,targets(s),cfg);

        optimizationSeconds = toc(clockFit);
        y = applyShelf(x,fs,gainDB,cfg);

        assert(all(isfinite(y)) && max(abs(y)) < 1, ...
            'A content-test output is invalid or clipped.');

        suffixes = ["self";"fixed"];

        outputPath = fullfile(audioDir, ...
            char(clips.ClipID(k)+"_"+suffixes(s)+".wav"));

        audiowrite(outputPath,y,fs,'BitsPerSample',24);

        % Measure the saved WAV against its own clean input.
        [y,fsY] = audioread(outputPath);

        assert(fsY == fs && numel(y) == numel(x), ...
            'Saved output dimensions do not match.');

        O = analyseAudio(y,fsY,cfg);

        delta = O.logPower-A.logPower;
        levelDB = 10*log10(sum(O.power)/sum(A.power));

        rawRMSE = sqrt(mean(delta.^2));
        shapeRMSE = sqrt(mean((delta-levelDB).^2));

        rowCount = rowCount+1;

        caseRows{rowCount} = table( ...
            clips.ClipID(k),clips.PerformerID(k), ...
            clips.SourceFile(k),clips.PlayingMode(k),scenarios(s), ...
            string(inputPath),string(outputPath), ...
            targets(s),A.centroid,O.centroid, ...
            abs(A.centroid-targets(s)), ...
            abs(O.centroid-targets(s)), ...
            abs(O.centroid-A.centroid), ...
            gainDB,abs(gainDB) >= 11.99, ...
            rawRMSE,shapeRMSE,optimizationSeconds,nEvaluations,fs, ...
            'VariableNames', ...
            {'ClipID','PerformerID','SourceFile','PlayingMode', ...
            'Scenario','InputPath','OutputPath','TargetCentroidHz', ...
            'CleanCentroidHz','OutputCentroidHz', ...
            'InitialTargetErrorHz','FinalTargetErrorHz', ...
            'OwnCentroidErrorHz','GainDB','BoundaryHit', ...
            'RawRMSEdB','ShapeRMSEdB','OptimizationSeconds', ...
            'CandidateEvaluations','SampleRate'});
    end

    partial = vertcat(caseRows{1:rowCount});

    writetable(partial, ...
        fullfile(outDir,'content_cases_partial.csv'));

    fprintf('Clean clips completed: %d/%d\n',k,height(clips));
end

cases = vertcat(caseRows{:});
self = cases(cases.Scenario == "Self-reference",:);

assert(all(abs(self.GainDB) < 1e-6) && ...
    all(self.ShapeRMSEdB < 1e-6), ...
    'The self-reference negative control failed.');

summaryRows = cell(2,1);

for s = 1:2
    T = cases(cases.Scenario == scenarios(s),:);

    [lo,hi] = clusterCI( ...
        [abs(T.GainDB),T.ShapeRMSEdB],T.PerformerID,cfg);

    summaryRows{s} = table( ...
        scenarios(s),height(T), ...
        mean(abs(T.GainDB)),lo(1),hi(1), ...
        100*mean(abs(T.GainDB) >= cfg.NontrivialGainDB), ...
        100*mean(T.BoundaryHit), ...
        mean(T.InitialTargetErrorHz), ...
        mean(T.FinalTargetErrorHz), ...
        mean(T.OwnCentroidErrorHz), ...
        mean(T.RawRMSEdB),mean(T.ShapeRMSEdB),lo(2),hi(2), ...
        'VariableNames', ...
        {'Scenario','Clips','MeanAbsGainDB', ...
        'GainLower95DB','GainUpper95DB','AdjustedPercent', ...
        'BoundaryHitPercent','MeanInitialTargetErrorHz', ...
        'MeanFinalTargetErrorHz','MeanOwnCentroidErrorHz', ...
        'MeanRawRMSEdB','MeanShapeRMSEdB', ...
        'ShapeLower95DB','ShapeUpper95DB'});
end

summary = vertcat(summaryRows{:});

report = struct( ...
    'Cases',cases, ...
    'Clips',clips, ...
    'Development',development, ...
    'Summary',summary, ...
    'Settings',cfg);

writetable(cases,fullfile(outDir,'content_cases.csv'));
writetable(clips,fullfile(outDir,'clean_clip_features.csv'));
writetable(summary,fullfile(outDir,'content_summary.csv'));

save(resultMAT,'report');

fprintf('\nContent experiment complete: 30 clips | 60 cases.\n');

fprintf('Clean centroid range: %.3f to %.3f Hz\n', ...
    min(clips.CleanCentroidHz),max(clips.CleanCentroidHz));

for s = 1:2
    fprintf('\n%s\n',char(summary.Scenario(s)));

    fprintf('Mean absolute gain: %.6f dB\n', ...
        summary.MeanAbsGainDB(s));

    fprintf('Clean inputs adjusted (|gain| >= %.1f dB): %.2f%%\n', ...
        cfg.NontrivialGainDB,summary.AdjustedPercent(s));

    fprintf('Gain boundary hits: %.2f%%\n', ...
        summary.BoundaryHitPercent(s));

    fprintf('Mean target error before: %.6f Hz\n', ...
        summary.MeanInitialTargetErrorHz(s));

    fprintf('Mean target error after: %.6f Hz\n', ...
        summary.MeanFinalTargetErrorHz(s));

    fprintf('Mean centroid shift from clean input: %.6f Hz\n', ...
        summary.MeanOwnCentroidErrorHz(s));

    fprintf('Mean shape RMSE: %.6f dB | CI [%.6f, %.6f]\n', ...
        summary.MeanShapeRMSEdB(s), ...
        summary.ShapeLower95DB(s),summary.ShapeUpper95DB(s));
end

fprintf('\nSaved results: %s\n',outDir);
end


function A = analyseAudio(x,fs,cfg)

assert(iscolumn(x) && all(isfinite(x)) && ...
    numel(x) >= cfg.WindowLength && ...
    fs/2 >= cfg.FrequencyRangeHz(2), ...
    'Audio must be finite, mono, and long enough.');

[p,f] = pwelch(x,hann(cfg.WindowLength,'periodic'), ...
    cfg.OverlapLength,cfg.FFTLength,fs);

keep = f >= cfg.FrequencyRangeHz(1) & ...
    f <= cfg.FrequencyRangeHz(2);

A.power = p(keep);
A.f = f(keep);

assert(sum(A.power) > 0, ...
    'Audio has no analysis-band energy.');

A.logPower = 10*log10(max(A.power,realmin));
A.centroid = sum(A.f.*A.power)/sum(A.power);
A.fs = fs;
end


function [bestGain,evaluations] = fitShelfGain(x,A,target,cfg)

bestGain = 0;

probe = analyseAudio( ...
    applyShelf(x,A.fs,0,cfg),A.fs,cfg);

bestError = abs(probe.centroid-target);
evaluations = 1;

if bestError < 1e-9
    return;
end

for pass = 1:2
    if pass == 1
        gains = -cfg.GainLimitDB:cfg.CoarseStepDB:cfg.GainLimitDB;
    else
        lowerGain = max( ...
            -cfg.GainLimitDB,bestGain-cfg.CoarseStepDB);

        upperGain = min( ...
            cfg.GainLimitDB,bestGain+cfg.CoarseStepDB);

        gains = lowerGain:cfg.FineStepDB:upperGain;
    end

    for gain = gains
        probe = analyseAudio( ...
            applyShelf(x,A.fs,gain,cfg),A.fs,cfg);

        currentError = abs(probe.centroid-target);
        evaluations = evaluations+1;

        if currentError < bestError
            bestError = currentError;
            bestGain = gain;
        end
    end
end
end


function y = applyShelf(x,fs,gainDB,cfg)

[b,a] = designShelvingEQ(gainDB,cfg.ShelfSlope, ...
    cfg.ShelfHz/(fs/2),'hi','Orientation','row');

y = filter(b,a,x);
end


function [lo,hi] = clusterCI(values,playerIDs,cfg)

players = unique(playerIDs);

assert(numel(players) >= 2, ...
    'At least two performer clusters are required.');

sums = zeros(numel(players),size(values,2));
counts = zeros(numel(players),1);

for p = 1:numel(players)
    keep = playerIDs == players(p);
    sums(p,:) = sum(values(keep,:),1);
    counts(p) = nnz(keep);
end

stream = RandStream('mt19937ar','Seed',cfg.Seed);

draws = randi(stream,numel(players), ...
    numel(players),cfg.BootstrapSamples);

boot = zeros(cfg.BootstrapSamples,size(values,2));

for b = 1:cfg.BootstrapSamples
    selected = draws(:,b);

    boot(b,:) = sum(sums(selected,:),1) / ...
        sum(counts(selected));
end

boot = sort(boot,1);

lo = boot(max(1,ceil(0.025*cfg.BootstrapSamples)),:);

hi = boot(min(cfg.BootstrapSamples, ...
    ceil(0.975*cfg.BootstrapSamples)),:);
end


function T = readTextTable(path,variables)

assert(isfile(path), ...
    'Required CSV is missing: %s',char(path));

opts = detectImportOptions(path,'TextType','string');

assert(all(ismember(variables,opts.VariableNames)), ...
    'CSV columns are incompatible: %s',char(path));

opts = setvartype(opts,variables,'string');
T = readtable(path,opts);
end


function T = sourceMetadata(batchDir)

files = dir(fullfile(batchDir,'*.csv'));
matches = {};

for k = 1:numel(files)
    path = fullfile(files(k).folder,files(k).name);
    opts = detectImportOptions(path,'TextType','string');

    if all(ismember({'ClipID','SourceFile'},opts.VariableNames))
        opts = setvartype(opts, ...
            {'ClipID','SourceFile'},'string');

        candidate = readtable(path,opts);

        if numel(unique(candidate.ClipID)) == height(candidate)
            matches{end+1} = candidate;
        end
    end
end

assert(numel(matches) == 1, ...
    'Expected one batch CSV with unique ClipID and SourceFile columns.');

T = matches{1};
end


function p = resolvePath(rootDir,value)

p = string(value);

assert(~ismissing(p) && strlength(p) > 0, ...
    'An audio path is empty.');

if ~isfile(p)
    p = string(fullfile(rootDir,char(p)));
end

assert(isfile(p), ...
    'Audio file is missing: %s',char(p));
end


function plotOne(report,plotID,outDir)

cfg = report.Settings;
C = report.Clips;
R = report.Cases;

scenarios = ["Self-reference";"Fixed-target"];
colors = [0.45 0.45 0.45;0 0.45 0.74];

screen = get(groot,'ScreenSize');

fig = figure('WindowStyle','normal','Color','w', ...
    'Units','pixels', ...
    'Position',[60 80 min(1100,screen(3)-120) ...
    min(740,screen(4)-180)], ...
    'MenuBar','none','ToolBar','none','NumberTitle','off');

cleanup = onCleanup(@() close(fig));

ax = axes('Parent',fig);
hold(ax,'on');

fprintf('Content figure %d: drawing...\n',plotID);

switch plotID

    case 1
        plot(ax,1:height(C),C.CleanCentroidHz,'-o', ...
            'LineWidth',1.3,'MarkerSize',6);

        yline(ax,cfg.FixedTargetHz,'k--','LineWidth',1.5);

        xticks(ax,1:2:height(C));
        xlim(ax,[0.5 height(C)+0.5]);

        labels = ["Clean excerpt";"Fixed development target"];

        caption = 'Natural centroid variation without added EQ';
        xLabel = 'Clean excerpt index';
        yLabel = 'Power spectral centroid (Hz)';
        fileName = 'natural_centroid_variation.png';

    case 2
        for s = 1:2
            keep = R.Scenario == scenarios(s);

            plot(ax,R.CleanCentroidHz(keep), ...
                R.GainDB(keep),'o', ...
                'Color',colors(s,:),'MarkerSize',7);
        end

        yline(ax,0,'k:','HandleVisibility','off');

        xline(ax,cfg.FixedTargetHz,'k--', ...
            'HandleVisibility','off');

        ylim(ax,[-13 13]);

        labels = scenarios;

        caption = 'EQ gain assigned to unmodified clean excerpts';
        xLabel = 'Clean-input centroid (Hz)';
        yLabel = 'Selected high-shelf gain (dB)';
        fileName = 'content_dependent_gains.png';

    case 3
        for s = 1:2
            keep = R.Scenario == scenarios(s);

            plot(ax, ...
                max(R.FinalTargetErrorHz(keep),cfg.PlotFloor), ...
                max(R.ShapeRMSEdB(keep),cfg.PlotFloor),'o', ...
                'Color',colors(s,:),'MarkerSize',7);
        end

        ax.XScale = 'log';
        ax.YScale = 'log';

        labels = scenarios;

        caption = 'Target matching versus alteration of clean input';
        xLabel = 'Centroid error to assigned target (Hz)';
        yLabel = 'Shape change from clean input (dB)';
        fileName = 'target_match_vs_clean_change.png';
end

set(ax,'FontSize',13,'Color','w','XColor','k','YColor','k');

xlabel(ax,xLabel,'Color','k');
ylabel(ax,yLabel,'Color','k');

title(ax,caption,'Color','k', ...
    'Interpreter','none','FontSize',15);

grid(ax,'on');
box(ax,'on');

lgd = legend(ax,labels,'NumColumns',2, ...
    'Interpreter','none','FontSize',12, ...
    'TextColor','k','Color','w');

lgd.Units = 'normalized';
lgd.Position = [0.15 0.02 0.80 0.10];

ax.Position = [0.13 0.24 0.83 0.65];

drawnow nocallbacks;

fprintf('Content figure %d: capturing window...\n',plotID);
frame = getframe(fig);

path = fullfile(outDir,fileName);
imwrite(frame.cdata,path);

info = imfinfo(path);

fprintf('Saved: %s\nImage size: %d x %d pixels\n', ...
    path,info.Width,info.Height);
end