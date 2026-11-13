function report = run_capacity_ablation(action, resume)
% Compare two objectives with the same one-shelf EQ.
% Existing three-gain methods provide context.
% Use a second argument false to start fresh without a saved checkpoint.

if nargin == 0
    action = "run";
end

if nargin < 2, resume = true; end
assert(islogical(resume) && isscalar(resume), ...
    'ELEC5305:ResumeFlag', 'Resume must be true or false.');

action = string(action);

assert(isscalar(action) && any(action == ["run","load","plot"]), ...
    'Action must be run, load, or plot.');

rootDir = fileparts(mfilename('fullpath'));
outDir = fullfile(rootDir,'results','capacity_ablation');
resultMAT = fullfile(outDir,'capacity_ablation_results.mat');

if action ~= "run"
    assert(isfile(resultMAT),'Run the capacity ablation first.');

    saved = load(resultMAT,'report');
    report = saved.report;

    if action == "plot"
        figureDir = fullfile(outDir,'figures');

        if ~isfolder(figureDir)
            mkdir(figureDir);
        end

        for q = 1:3
            plotOne(report,q,rootDir,figureDir);
        end

        fprintf('Capacity-ablation figures completed.\n');
    else
        fprintf('Loaded saved capacity ablation: %d comparison rows.\n', ...
            height(report.Cases));
    end

    return;
end

if ~isfolder(outDir)
    mkdir(outDir);
end

audioDir = fullfile(outDir,'spectrum_shelf_audio');

if ~isfolder(audioDir)
    mkdir(audioDir);
end

evaluationDir = fullfile(rootDir,'results','extended_evaluation');

settings = load( ...
    fullfile(evaluationDir,'evaluation_settings.mat'),'cfg');

cfg = settings.cfg;
cfg.ShelfHz = 2500;
cfg.ShelfSlope = 1;
cfg.GainLimitDB = 12;
cfg.CoarseStepDB = 0.5;
cfg.FineStepDB = 0.01;
cfg.ShelfVerificationTolerance = 2e-6;

file = fullfile(evaluationDir,'extended_metrics.csv');

opts = detectImportOptions(file,'TextType','string');

opts = setvartype(opts, ...
    {'PairID','ClipID','PerformerID','Condition', ...
    'Method','Status','ReferencePath','InputPath','OutputPath'}, ...
    'string');

E = readtable(file,opts);

assert(height(E) == 960 && all(E.Status == "OK"), ...
    'The completed 960-row extended evaluation is required.');

base = sortrows(E(E.Method == "Distorted",:),'PairID');
centroid = E(E.Method == "Centroid",:);

[found,order] = ismember(base.PairID,centroid.PairID);

assert(height(base) == 240 && height(centroid) == 240 && ...
    numel(unique(base.PairID)) == 240 && ...
    numel(unique(centroid.PairID)) == 240 && all(found), ...
    'Expected 240 unique aligned test pairs.');

centroid = centroid(order,:);

assert(all(abs(centroid.LowGainDB) < 1e-9) && ...
    all(abs(centroid.MidGainDB) < 1e-9) && ...
    all(abs(centroid.HighGainDB) <= cfg.GainLimitDB+1e-9), ...
    'The centroid baseline must use one bounded high shelf.');

% Validate resumed work against code, settings, and audio files.
signature.Config = cfg;

signature.Pairs = base(:, ...
    {'PairID','ClipID','PerformerID','Condition', ...
    'ReferencePath','InputPath'});

signature.CentroidGains = centroid.HighGainDB;

signature.AudioFiles = fileState(rootDir, ...
    [base.ReferencePath;base.InputPath;centroid.OutputPath]);

signature.Code = {fileread([mfilename('fullpath') '.m']), ...
    fileread(fullfile(rootDir,'project_param_eq.m')), ...
    fileread(fullfile(rootDir,'project_audio_path.m'))};

checkpoint = fullfile(outDir,'checkpoint.mat');

newRows = cell(240,1);
waveErrors = zeros(240,1);
evaluations = zeros(240,1);
completed = 0;

if resume && isfile(checkpoint)
    saved = load(checkpoint);

    assert(isequaln(saved.signature,signature), ...
        'Checkpoint inputs or code changed. Use a new result folder.');

    newRows = saved.newRows;
    waveErrors = saved.waveErrors;
    evaluations = saved.evaluations;
    completed = saved.completed;

    assert(completed >= 0 && completed <= 240 && ...
        completed == fix(completed) && ...
        numel(newRows) == 240 && ...
        all(~cellfun(@isempty,newRows(1:completed))), ...
        'The ablation checkpoint is incomplete.');
end

fprintf('Ablation pairs: 240\n');
fprintf('Previously completed spectrum-shelf fits: %d\n',completed);

firstPath = resolvePath(rootDir,base.ReferencePath(1));
[xRef,fs] = audioread(firstPath);

C = referenceProfile(xRef,fs,cfg);
lastReference = firstPath;
nBins = numel(C.f);

for k = completed+1:240

    fprintf('Pair %d/240: %s\n',k,char(base.PairID(k)));

    refPath = resolvePath(rootDir,base.ReferencePath(k));

    if refPath ~= lastReference
        [xRef,fs] = audioread(refPath);
        C = referenceProfile(xRef,fs,cfg);
        lastReference = refPath;
    end

    inputPath = resolvePath(rootDir,base.InputPath(k));
    [x,fsInput] = audioread(inputPath);

    assert(fsInput == C.fs && iscolumn(x) && ...
        numel(x) == C.N && all(isfinite(x)), ...
        'Input audio dimensions are invalid.');

    % Reconstruct the original processor to verify matched capacity.
    [oldY,oldFs] = audioread( ...
        resolvePath(rootDir,centroid.OutputPath(k)));

    assert(oldFs == C.fs && iscolumn(oldY) && ...
        numel(oldY) == C.N && all(isfinite(oldY)), ...
        'The original centroid output has invalid dimensions.');

    reconstructed = applyShelf( ...
        x,C.fs,centroid.HighGainDB(k),cfg);

    waveErrors(k) = max(abs(reconstructed-oldY));

    assert(waveErrors(k) < cfg.ShelfVerificationTolerance, ...
        'The original centroid processor does not match this shelf.');

    clockFit = tic;

    [gainDB,evaluations(k)] = fitSpectrumShelf(x,C,cfg);

    seconds = toc(clockFit);

    y = applyShelf(x,C.fs,gainDB,cfg);

    assert(all(isfinite(y)) && max(abs(y)) < 1, ...
        'A spectrum-shelf output is invalid or clipped.');

    outputPath = fullfile(audioDir,char(base.PairID(k)+".wav"));

    audiowrite(outputPath,y,C.fs,'BitsPerSample',24);

    [y,fsOutput] = audioread(outputPath);

    assert(fsOutput == C.fs && numel(y) == C.N, ...
        'Saved output dimensions do not match.');

    [rawRMSE,shapeRMSE,centroidError] = ...
        measuredErrors(y,C,cfg);

    newRows{k} = table( ...
        base.PairID(k),base.ClipID(k), ...
        base.PerformerID(k),base.Condition(k), ...
        "Spectrum-shelf", ...
        string(refPath),string(inputPath),string(outputPath), ...
        centroidError,rawRMSE,shapeRMSE,seconds,0,0,gainDB,1, ...
        'VariableNames',caseColumns());

    completed = k;

    pendingFile = [checkpoint '.pending.mat'];

    save(pendingFile,'signature','newRows','completed', ...
        'waveErrors','evaluations');

    [ok,message] = movefile(pendingFile,checkpoint,'f');

    assert(ok,'Checkpoint update failed: %s',message);

    fprintf('Spectrum-shelf fits completed: %d/240\n',completed);
end

% Reuse previously measured outputs of the original three methods.
columns = caseColumns();

old = E(E.Method ~= "Distorted",columns(1:end-1));

old.GainParameters = 3*ones(height(old),1);

selected = old.Method == "Centroid";
old.GainParameters(selected) = 1;
old.Method(selected) = "Centroid-shelf";

new = vertcat(newRows{:});

cases = sortrows([old;new],{'PairID','Method'});

methods = ["Centroid-shelf";"Spectrum-shelf"; ...
    "Three-band";"Differentiable"];

[S,P] = pairedStatistics(cases,methods,cfg);

conditions = unique(base.Condition,'stable');
conditionRows = cell(numel(conditions)*4,1);
r = 0;

for c = 1:numel(conditions)
    for m = 1:4
        selected = cases.Condition == conditions(c) & ...
            cases.Method == methods(m);

        r = r+1;

        conditionRows{r} = table( ...
            conditions(c),methods(m),nnz(selected), ...
            mean(cases.RawRMSEdB(selected)), ...
            mean(cases.ShapeRMSEdB(selected)), ...
            'VariableNames', ...
            {'Condition','Method','Cases', ...
            'MeanRawRMSEdB','MeanShapeRMSEdB'});
    end
end

byCondition = vertcat(conditionRows{:});

complexity = table(methods,[1;1;3;3],[1;nBins;3;nBins], ...
    'VariableNames', ...
    {'Method','GainParameters','TargetValueCount'});

verification = table(base.PairID,waveErrors,evaluations, ...
    'VariableNames', ...
    {'PairID','ShelfWaveformDifference', ...
    'SpectrumCandidateEvaluations'});

report = struct( ...
    'Cases',cases, ...
    'Summary',S, ...
    'Paired',P, ...
    'ByCondition',byCondition, ...
    'Complexity',complexity, ...
    'Verification',verification, ...
    'Distorted',base, ...
    'Settings',cfg);

writetable(cases,fullfile(outDir,'ablation_cases.csv'));

writetable(S,fullfile(outDir,'ablation_summary.csv'));

writetable(P, ...
    fullfile(outDir,'paired_objective_comparison.csv'));

writetable(byCondition, ...
    fullfile(outDir,'condition_summary.csv'));

writetable(complexity, ...
    fullfile(outDir,'complexity_summary.csv'));

writetable(verification, ...
    fullfile(outDir,'shelf_verification.csv'));

save(resultMAT,'report');

fprintf('\nCapacity ablation complete: 240 pairs | 960 comparison rows.\n');

for m = 1:4
    fprintf('\n%s | gain parameters: %d\n', ...
        char(methods(m)),complexity.GainParameters(m));

    selected = find(S.Method == methods(m));

    for j = selected.'
        fprintf('%s: %.6f dB | CI [%.6f, %.6f]\n', ...
            char(S.Metric(j)),S.MeanDB(j), ...
            S.Lower95DB(j),S.Upper95DB(j));
    end
end

fprintf('\nMatched one-shelf comparison: spectrum minus centroid\n');

for j = 1:height(P)
    fprintf('%s: %+.6f dB | CI [%+.6f, %+.6f]\n', ...
        char(P.Metric(j)),P.MeanDifferenceDB(j), ...
        P.Lower95DB(j),P.Upper95DB(j));

    fprintf('Lower error: %.2f%% | Ties: %.2f%%\n', ...
        P.WinPercent(j),P.TiePercent(j));
end

fprintf('\nSaved results: %s\n',outDir);
end


function columns = caseColumns()

columns = {'PairID','ClipID','PerformerID','Condition','Method', ...
    'ReferencePath','InputPath','OutputPath','CentroidErrorHz', ...
    'RawRMSEdB','ShapeRMSEdB','OptimizationSeconds', ...
    'LowGainDB','MidGainDB','HighGainDB','GainParameters'};
end


function C = referenceProfile(x,fs,cfg)

assert(iscolumn(x) && all(isfinite(x)) && ...
    numel(x) >= cfg.WindowLength && ...
    fs/2 >= cfg.FrequencyRangeHz(2), ...
    'Reference audio is invalid.');

C.fs = fs;
C.N = numel(x);
C.window = hann(cfg.WindowLength,'periodic');

[p,f] = pwelch(x,C.window, ...
    cfg.OverlapLength,cfg.FFTLength,fs);

C.keep = f >= cfg.FrequencyRangeHz(1) & ...
    f <= cfg.FrequencyRangeHz(2);

C.f = f(C.keep);
C.power = p(C.keep);

assert(sum(C.power) > 0, ...
    'Reference has no analysis-band energy.');

C.logPower = 10*log10(max(C.power,realmin));
C.centroid = sum(C.f.*C.power)/sum(C.power);
end


function [gainDB,evaluations] = fitSpectrumShelf(x,C,cfg)

gainDB = 0;
bestLoss = Inf;
evaluations = 0;

for pass = 1:2
    if pass == 1
        gains = -cfg.GainLimitDB:cfg.CoarseStepDB:cfg.GainLimitDB;
    else
        lowerGain = max( ...
            -cfg.GainLimitDB,gainDB-cfg.CoarseStepDB);

        upperGain = min( ...
            cfg.GainLimitDB,gainDB+cfg.CoarseStepDB);

        gains = lowerGain:cfg.FineStepDB:upperGain;
    end

    for candidateGain = gains
        y = applyShelf(x,C.fs,candidateGain,cfg);

        p = pwelch(y,C.window, ...
            cfg.OverlapLength,cfg.FFTLength,C.fs);

        delta = 10*log10(max(p(C.keep),realmin))-C.logPower;
        loss = mean(delta.^2);

        assert(isfinite(loss), ...
            'A spectrum-search loss is not finite.');

        evaluations = evaluations+1;

        if loss < bestLoss
            bestLoss = loss;
            gainDB = candidateGain;
        end
    end
end
end


function y = applyShelf(x,fs,gainDB,cfg)

[b,a] = designShelvingEQ(gainDB,cfg.ShelfSlope, ...
    cfg.ShelfHz/(fs/2),'hi','Orientation','row');

y = filter(b,a,x);
end


function [raw,shape,centroidError] = measuredErrors(y,C,cfg)

p = pwelch(y,C.window, ...
    cfg.OverlapLength,cfg.FFTLength,C.fs);

p = p(C.keep);

assert(sum(p) > 0, ...
    'Output has no analysis-band energy.');

delta = 10*log10(max(p,realmin))-C.logPower;
level = 10*log10(sum(p)/sum(C.power));

raw = sqrt(mean(delta.^2));
shape = sqrt(mean((delta-level).^2));

centroidError = abs( ...
    sum(C.f.*p)/sum(p)-C.centroid);

assert(all(isfinite([raw,shape,centroidError])), ...
    'A saved-output metric is not finite.');
end


function [S,P] = pairedStatistics(cases,methods,cfg)

base = cases(cases.Method == methods(1),:);
metrics = ["RawRMSEdB";"ShapeRMSEdB"];
values = zeros(height(base),4,2);

for m = 1:4
    rows = cases(cases.Method == methods(m),:);

    [found,order] = ismember(base.PairID,rows.PairID);

    assert(height(rows) == 240 && ...
        numel(unique(rows.PairID)) == 240 && all(found), ...
        'A comparison method is missing test pairs.');

    assert(all(rows.PerformerID(order) == base.PerformerID), ...
        'Performer labels do not match across methods.');

    values(:,m,:) = reshape( ...
        rows{order,cellstr(metrics)},240,1,2);
end

flat = reshape(values,240,8);
players = unique(base.PerformerID);

assert(numel(players) >= 2, ...
    'At least two performer clusters are required.');

sums = zeros(numel(players),8);
counts = zeros(numel(players),1);

for p = 1:numel(players)
    selected = base.PerformerID == players(p);
    sums(p,:) = sum(flat(selected,:),1);
    counts(p) = nnz(selected);
end

stream = RandStream('mt19937ar','Seed',cfg.Seed);

draws = randi(stream,numel(players), ...
    numel(players),cfg.BootstrapSamples);

boot = zeros(cfg.BootstrapSamples,8);

for b = 1:cfg.BootstrapSamples
    selected = draws(:,b);

    boot(b,:) = sum(sums(selected,:),1) / ...
        sum(counts(selected));
end

lo = max(1,ceil(0.025*cfg.BootstrapSamples));

hi = min(cfg.BootstrapSamples, ...
    ceil(0.975*cfg.BootstrapSamples));

sorted = sort(boot,1);

S = table( ...
    repmat(methods,2,1),repelem(metrics,4), ...
    mean(flat,1).',median(flat,1).', ...
    sorted(lo,:).',sorted(hi,:).', ...
    'VariableNames', ...
    {'Method','Metric','MeanDB','MedianDB', ...
    'Lower95DB','Upper95DB'});

comparison = zeros(2,5);

for q = 1:2
    a = 1+4*(q-1);
    b = 2+4*(q-1);

    delta = flat(:,b)-flat(:,a);
    sampled = sort(boot(:,b)-boot(:,a));

    comparison(q,:) = ...
        [mean(delta),sampled(lo),sampled(hi), ...
        100*mean(delta < -1e-6), ...
        100*mean(abs(delta) <= 1e-6)];
end

P = table( ...
    metrics,repmat(methods(1),2,1),repmat(methods(2),2,1), ...
    comparison(:,1),comparison(:,2),comparison(:,3), ...
    comparison(:,4),comparison(:,5), ...
    'VariableNames', ...
    {'Metric','Baseline','Contender','MeanDifferenceDB', ...
    'Lower95DB','Upper95DB','WinPercent','TiePercent'});
end


function T = fileState(rootDir,paths)

paths = unique(paths,'stable');

bytes = zeros(numel(paths),1);
modified = zeros(numel(paths),1);
resolved = strings(numel(paths),1);

for k = 1:numel(paths)
    resolved(k) = resolvePath(rootDir,paths(k));

    info = dir(resolved(k));

    bytes(k) = info.bytes;
    modified(k) = info.datenum;
end

T = table(resolved,bytes,modified);
end


function p = resolvePath(rootDir,value)
% Resolve historical paths against this checkout, never an old copy.
p = project_audio_path(rootDir,value);
end


function plotOne(report,plotID,rootDir,outDir)

methods = ["Centroid-shelf";"Spectrum-shelf"; ...
    "Three-band";"Differentiable"];

colors = lines(4);
cfg = report.Settings;

screen = get(groot,'ScreenSize');

fig = figure('WindowStyle','normal','Color','w', ...
    'Units','pixels', ...
    'Position',[60 80 min(1100,screen(3)-120) ...
    min(740,screen(4)-180)], ...
    'MenuBar','none','ToolBar','none','NumberTitle','off');

cleanup = onCleanup(@() close(fig));

ax = axes('Parent',fig);
hold(ax,'on');

fprintf('Ablation figure %d: drawing...\n',plotID);

labels = strings(0,1);

switch plotID

    case 1
        S = report.Summary;

        for m = 1:4
            row = S.Method == methods(m) & ...
                S.Metric == "RawRMSEdB";

            mu = S.MeanDB(row);

            errorbar(ax,m,max(mu,cfg.PlotFloor), ...
                max(0,mu-S.Lower95DB(row)), ...
                max(0,S.Upper95DB(row)-mu),'o', ...
                'Color',colors(m,:),'MarkerSize',8, ...
                'LineWidth',1.5);
        end

        ax.YScale = 'log';

        xticks(ax,1:4);
        xticklabels(ax,methods);
        xlim(ax,[0.5 4.5]);

        caption = ...
            'Objective ablation with processor-capacity context';

        xLabel = 'Method';
        yLabel = 'Mean raw log-power RMSE (dB)';
        fileName = 'objective_ablation_overview.png';

    case 2
        T = report.ByCondition;
        conditions = unique(T.Condition,'stable');

        for m = 1:2
            values = zeros(numel(conditions),1);

            for c = 1:numel(conditions)
                row = T.Method == methods(m) & ...
                    T.Condition == conditions(c);

                values(c) = T.MeanRawRMSEdB(row);
            end

            plot(ax,1:numel(conditions), ...
                max(values,cfg.PlotFloor),'-o', ...
                'Color',colors(m,:),'LineWidth',1.5);
        end

        ax.YScale = 'log';
        xticks(ax,1:numel(conditions));

        tickLabels = replace(conditions, ...
            ["low_","mid_","high_","mixed_"], ...
            ["L ","M ","H ","Mix "]);

        xticklabels(ax,tickLabels);
        xtickangle(ax,25);
        xlim(ax,[0.7 numel(conditions)+0.3]);

        labels = methods(1:2);
        caption = 'Same high shelf, different fitting objective';
        xLabel = 'EQ distortion condition';
        yLabel = 'Mean raw log-power RMSE (dB)';
        fileName = 'matched_shelf_by_condition.png';

    case 3
        candidates = report.Distorted( ...
            report.Distorted.Condition == "mid_cut",:);

        [~,order] = sort(candidates.RawRMSEdB);

        chosen = candidates( ...
            order(ceil(height(candidates)/2)),:);

        [ref,fs] = audioread( ...
            resolvePath(rootDir,chosen.ReferencePath));

        C = referenceProfile(ref,fs,cfg);

        [xInput,fsInput] = audioread( ...
            resolvePath(rootDir,chosen.InputPath));

        assert(fsInput == fs, ...
            'Example sample rates do not match.');

        p = pwelch(xInput,C.window, ...
            cfg.OverlapLength,cfg.FFTLength,fs);

        plot(ax,C.f, ...
            10*log10(max(p(C.keep),realmin))-C.logPower, ...
            'k:','LineWidth',1.4);

        for m = 1:4
            row = report.Cases( ...
                report.Cases.PairID == chosen.PairID & ...
                report.Cases.Method == methods(m),:);

            y = audioread( ...
                resolvePath(rootDir,row.OutputPath));

            p = pwelch(y,C.window, ...
                cfg.OverlapLength,cfg.FFTLength,fs);

            plot(ax,C.f, ...
                10*log10(max(p(C.keep),realmin))-C.logPower, ...
                'Color',colors(m,:),'LineWidth',1.5);
        end

        ax.XScale = 'log';

        xlim(ax,cfg.FrequencyRangeHz);

        yline(ax,0,'k--','HandleVisibility','off');

        labels = ["Distorted";methods];

        caption = "Mid-cut residual spectrum: "+chosen.PairID;
        xLabel = 'Frequency (Hz)';
        yLabel = 'Difference from clean reference (dB)';
        fileName = 'matched_shelf_midcut_residual.png';
end

set(ax,'FontSize',13,'Color','w','XColor','k','YColor','k');

xlabel(ax,xLabel,'Color','k');
ylabel(ax,yLabel,'Color','k');

title(ax,caption,'Interpreter','none', ...
    'FontSize',15,'Color','k');

grid(ax,'on');
box(ax,'on');

if ~isempty(labels)
    lgd = legend(ax,labels,'Interpreter','none', ...
        'NumColumns',2,'FontSize',12, ...
        'TextColor','k','Color','w');

    lgd.Units = 'normalized';
    lgd.Position = [0.15 0.02 0.80 0.11];
end

ax.Position = [0.13 0.26 0.83 0.63];

drawnow nocallbacks;

fprintf('Ablation figure %d: exporting figure...\n',plotID);


path = fullfile(outDir,fileName);

exportgraphics(fig,path,'Resolution',150);
info = imfinfo(path);

fprintf('Saved: %s\nImage size: %d x %d pixels\n', ...
    path,info.Width,info.Height);
end
