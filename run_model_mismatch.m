function report = run_model_mismatch(action, resume)
% Evaluate fixed EQ models under frequency and bandwidth mismatch.
% Use a second argument false to start fresh without a saved checkpoint.
% Numerical evaluation and figure capture are separate actions.
% Compatible with the filter-design interface used in MATLAB R2025b.

if nargin == 0
    action = "run";
end

if nargin < 2, resume = true; end
assert(islogical(resume) && isscalar(resume), ...
    'ELEC5305:ResumeFlag', 'Resume must be true or false.');

action = lower(string(action));

assert(isscalar(action) && any(action == ["run","load","plot"]), ...
    'Action must be run, load, or plot.');

rootDir = fileparts(mfilename('fullpath'));
outDir = fullfile(rootDir, 'results', 'model_mismatch');
resultFile = fullfile(outDir, 'model_mismatch_results.mat');

if action == "load" || action == "plot"

    assert(isfile(resultFile), ...
        'Saved model-mismatch results are missing.');

    saved = load(resultFile, 'report');
    report = saved.report;

    if action == "plot"
        plotResults(report, outDir);
    else
        printResults(report);
    end

    return;
end

%% Experiment settings

cfg.NFFT = 2048;
cfg.Overlap = 1024;
cfg.FrequencyRange = [20 16000];
cfg.BandEdges = [20 500 2000 16000];

cfg.FixedFrequencies = [250 1000 2500];
cfg.FixedBandwidth = 1000;
cfg.GainLimit = 12;

cfg.CoarseStep = 0.5;
cfg.FineStep = 0.01;

cfg.ControllerIterations = 30;
cfg.ControllerStep = 0.7;
cfg.ControllerTolerance = 0.02;

cfg.AdamIterations = 400;
cfg.AdamLearningRate = 0.03;
cfg.AdamLossTolerance = 1e-8;

cfg.BootstrapSamples = 2000;
cfg.Seed = 5305;

cfg.Scenarios = ["matched";"frequency";"bandwidth";"joint"];

cfg.CorruptionFrequencies = [1000;1600;1000;1600];
cfg.CorruptionBandwidths = [1000;1000;300;300];
cfg.CorruptionGains = [-6 6];

cfg.Methods = ["Distorted";"Centroid";"Three-band"; ...
    "Differentiable";"Oracle"];

cfg.Version = 1;

assert(exist('designParamEQ','file') ~= 0 && ...
    exist('designShelvingEQ','file') ~= 0 && ...
    exist('dlarray','file') ~= 0, ...
    'Required MATLAB toolboxes are missing.');

if ~isfolder(outDir)
    mkdir(outDir);
end

inputDir = fullfile(outDir, 'inputs');
audioDir = fullfile(outDir, 'corrected');

if ~isfolder(inputDir)
    mkdir(inputDir);
end

if ~isfolder(audioDir)
    mkdir(audioDir);
end

%% Read the existing formal reference list

batchFile = fullfile(rootDir, 'results', ...
    'batch_comparison', 'batch_results.csv');

assert(isfile(batchFile), ...
    'The formal batch results CSV is missing.');

opts = detectImportOptions(batchFile, 'TextType', 'string');

textVars = {'ClipID','PerformerID','Method', ...
    'Status','ReferencePath'};

assert(all(ismember(textVars,opts.VariableNames)), ...
    'The batch results CSV has incompatible columns.');

opts = setvartype(opts, textVars, 'string');
R = readtable(batchFile, opts);

base = R(R.Method == "Distorted", :);

assert(height(base) == 240 && all(base.Status == "OK"), ...
    'The original 240 distorted-input rows must be valid.');

[~, first] = unique(base.ClipID, 'sorted');

refs = base(first, ...
    {'ClipID','PerformerID','ReferencePath'});

assert(height(refs) == 30 && ...
    numel(unique(refs.PerformerID)) == 6, ...
    'This design expects 30 clips from six performers.');

fileBytes = zeros(height(refs),1);
fileDates = zeros(height(refs),1);

for c = 1:height(refs)

    sameClip = base.ClipID == refs.ClipID(c);

    assert(numel(unique(base.ReferencePath(sameClip))) == 1 && ...
        numel(unique(base.PerformerID(sameClip))) == 1, ...
        'A clip has inconsistent reference metadata.');

    refs.ReferencePath(c) = resolvePath( ...
        rootDir,refs.ReferencePath(c));

    info = dir(char(refs.ReferencePath(c)));

    fileBytes(c) = info.bytes;
    fileDates(c) = info.datenum;
end

%% Build the 240-case experiment manifest

plan = cell(240,1);
p = 0;

signNames = ["cut","boost"];

for c = 1:height(refs)
    for s = 1:4
        for g = 1:2

            p = p + 1;

            entry = refs(c,:);

            entry.CaseID = string(sprintf( ...
                'clip_%03d_%s_%s', ...
                c,char(cfg.Scenarios(s)),char(signNames(g))));

            entry.Scenario = cfg.Scenarios(s);
            entry.GainSign = signNames(g);

            entry.CorruptionGainDB = cfg.CorruptionGains(g);

            entry.CorruptionF0Hz = ...
                cfg.CorruptionFrequencies(s);

            entry.CorruptionBandwidthHz = ...
                cfg.CorruptionBandwidths(s);

            plan{p} = entry;
        end
    end
end

manifest = vertcat(plan{:});

%% Load or create the checkpoint

signature.Settings = cfg;
signature.References = refs;
signature.ReferenceBytes = fileBytes;
signature.ReferenceDates = fileDates;
signature.Source = {fileread([mfilename('fullpath') '.m']), ...
    fileread(fullfile(rootDir,'project_param_eq.m')), ...
    fileread(fullfile(rootDir,'project_audio_path.m'))};
signature.MATLABVersion = version;

checkpointFile = fullfile(outDir, 'checkpoint.mat');

if resume && isfile(checkpointFile)

    saved = load(checkpointFile, 'state');
    state = saved.state;

    assert(isequaln(state.Signature,signature), ...
        ['The checkpoint does not match the current code or data. ' ...
         'Preserve the existing folder before starting a changed study.']);

else

    state.Signature = signature;
    state.Completed = 0;
    state.PairRows = cell(height(manifest),1);

end

writetable(manifest, ...
    fullfile(outDir,'mismatch_manifest.csv'));

save(fullfile(outDir,'mismatch_settings.mat'), 'cfg');

fprintf('Model-mismatch pairs: %d\n',height(manifest));

fprintf('Previously completed pairs: %d\n', ...
    state.Completed);

fprintf(['Methods: Distorted, Centroid, Three-band, ' ...
    'Differentiable, Oracle\n']);

%% Generate distortions and evaluate all methods

previousReference = "";

for p = state.Completed+1:height(manifest)

    entry = manifest(p,:);

    if entry.ReferencePath ~= previousReference

        [ref,fs] = audioread(entry.ReferencePath);

        assert(iscolumn(ref) && all(isfinite(ref)) && ...
            fs/2 >= cfg.FrequencyRange(2) && ...
            numel(ref) >= cfg.NFFT, ...
            ['Reference audio must be finite mono audio ' ...
             'at a suitable rate.']);

        target = spectrum(ref,fs,cfg);
        previousReference = entry.ReferencePath;

    end

    fprintf('\nPair %d/%d | %s | %s\n', ...
        p,height(manifest), ...
        char(entry.Scenario),char(entry.GainSign));

    % Generate corruption using its true center and bandwidth.
    [b,a] = project_param_eq(2,entry.CorruptionGainDB, ...
        entry.CorruptionF0Hz/(fs/2), ...
        entry.CorruptionBandwidthHz/(fs/2), ...
        'Orientation','row');

    inputPath = fullfile(inputDir, ...
        char(entry.CaseID + ".wav"));

    input = writeAndRead( ...
        inputPath,filter(b,a,ref),fs);

    inputSpectrum = spectrum(input,fs,cfg);
    inputMetrics = measure(inputSpectrum,target);

    assert(inputMetrics.RawRMSEdB > 1e-8, ...
        ['The generated corruption is too small ' ...
         'for a relative comparison.']);

    rows = cell(5,1);

    rows{1} = resultRow(entry,"Distorted", ...
        inputPath,inputPath,inputMetrics,zeros(3,1), ...
        0,inputMetrics.RawRMSEdB,cfg);

    % Automatic methods receive the reference and distorted signals.
    % Their correction frequencies and bandwidth remain fixed.
    for m = 2:4

        method = cfg.Methods(m);

        fprintf('  Fitting %s...\n',char(method));

        if method == "Centroid"

            [gains,seconds] = fitCentroid( ...
                input,fs,target,cfg);

            output = applyFixedEQ( ...
                input,gains,fs,cfg,false);

        elseif method == "Three-band"

            [gains,seconds] = fitThreeBand( ...
                input,fs,target,cfg);

            output = applyFixedEQ( ...
                input,gains,fs,cfg,false);

        else

            [gains,seconds] = fitDifferentiable( ...
                inputSpectrum,target,fs,cfg);

            output = applyFixedEQ( ...
                input,gains,fs,cfg,true);

        end

        outputPath = fullfile(audioDir, ...
            char(entry.CaseID + "_" + method + ".wav"));

        output = writeAndRead(outputPath,output,fs);

        metrics = measure( ...
            spectrum(output,fs,cfg),target);

        rows{m} = resultRow(entry,method, ...
            inputPath,outputPath,metrics,gains,seconds, ...
            inputMetrics.RawRMSEdB,cfg);

    end

    % The oracle uses true corruption parameters.
    % It is a diagnostic control, not an automatic estimator.
    [b,a] = project_param_eq(2,-entry.CorruptionGainDB, ...
        entry.CorruptionF0Hz/(fs/2), ...
        entry.CorruptionBandwidthHz/(fs/2), ...
        'Orientation','row');

    outputPath = fullfile(audioDir, ...
        char(entry.CaseID + "_Oracle.wav"));

    output = writeAndRead( ...
        outputPath,filter(b,a,input),fs);

    metrics = measure( ...
        spectrum(output,fs,cfg),target);

    rows{5} = resultRow(entry,"Oracle", ...
        inputPath,outputPath,metrics, ...
        [0;-entry.CorruptionGainDB;0], ...
        0,inputMetrics.RawRMSEdB,cfg);

    % Save only after the complete five-row case is available.
    state.PairRows{p} = vertcat(rows{:});
    state.Completed = p;

    temporaryFile = fullfile(outDir, ...
        'checkpoint_pending.mat');

    save(temporaryFile,'state','-v7');
    movefile(temporaryFile,checkpointFile,'f');

    fprintf('Mismatch pairs completed: %d/%d\n', ...
        p,height(manifest));

end

%% Summarise and save numerical results

cases = vertcat(state.PairRows{:});

assert(height(cases) == 1200 && ...
    all(isfinite(cases.RawRMSEdB)) && ...
    all(isfinite(cases.ShapeRMSEdB)), ...
    'Model-mismatch results are incomplete.');

fprintf('\nComputing performer-cluster confidence intervals...\n');

rng(cfg.Seed,'twister');

summary = summarise(cases,cfg);
paired = pairedEffects(cases,cfg);

report.Cases = cases;
report.Manifest = manifest;
report.Summary = summary;
report.Paired = paired;
report.Settings = cfg;

writetable(cases, ...
    fullfile(outDir,'mismatch_cases.csv'));

writetable(summary, ...
    fullfile(outDir,'mismatch_summary.csv'));

writetable(paired, ...
    fullfile(outDir,'paired_mismatch_effects.csv'));

save(resultFile,'report','-v7');

printResults(report);

fprintf('\nModel mismatch complete: 240 pairs | 1200 rows.\n');
fprintf('Saved results: %s\n',outDir);

end


function s = spectrum(x,fs,cfg)

win = hann(cfg.NFFT,'periodic');

[P,f] = pwelch( ...
    x,win,cfg.Overlap,cfg.NFFT,fs);

selected = f >= cfg.FrequencyRange(1) & ...
    f <= cfg.FrequencyRange(2);

s.P = P(selected);
s.F = f(selected);
s.DB = 10*log10(max(s.P,realmin));

assert(sum(s.P) > 0 && all(isfinite(s.DB)), ...
    'The analysis band has no valid spectral energy.');

s.Centroid = sum(s.F.*s.P)/sum(s.P);

s.Bands = zeros(3,1);

for k = 1:3

    selected = s.F >= cfg.BandEdges(k) & ...
        s.F < cfg.BandEdges(k+1);

    if k == 3
        selected = s.F >= cfg.BandEdges(k) & ...
            s.F <= cfg.BandEdges(k+1);
    end

    s.Bands(k) = sum(s.P(selected));

end

end


function metrics = measure(output,target)

assert(isequal(output.F,target.F), ...
    'Spectral frequency grids differ.');

difference = output.DB-target.DB;

levelDifference = 10*log10( ...
    sum(output.P)/sum(target.P));

metrics.RawRMSEdB = sqrt(mean(difference.^2));

metrics.ShapeRMSEdB = sqrt( ...
    mean((difference-levelDifference).^2));

metrics.CentroidErrorHz = abs( ...
    output.Centroid-target.Centroid);

end


function row = resultRow(entry,method,inputPath,outputPath, ...
    metrics,gains,seconds,inputError,cfg)

row = entry;

row.Method = method;
row.InputPath = string(inputPath);
row.OutputPath = string(outputPath);

row.RawRMSEdB = metrics.RawRMSEdB;
row.ShapeRMSEdB = metrics.ShapeRMSEdB;
row.CentroidErrorHz = metrics.CentroidErrorHz;

row.InputRawRMSEdB = inputError;

row.ImprovementPercent = ...
    100*(1-metrics.RawRMSEdB/inputError);

row.OptimizationSeconds = seconds;

row.LowGainDB = gains(1);
row.MidGainDB = gains(2);
row.HighGainDB = gains(3);

row.UsesKnownInverse = method == "Oracle";

if row.UsesKnownInverse
    row.ModelMidF0Hz = entry.CorruptionF0Hz;
    row.ModelMidBandwidthHz = entry.CorruptionBandwidthHz;
else
    row.ModelMidF0Hz = cfg.FixedFrequencies(2);
    row.ModelMidBandwidthHz = cfg.FixedBandwidth;
end

row.GainBoundaryHit = ...
    any(abs(gains) >= cfg.GainLimit-0.01) && ...
    any(method == ["Centroid","Three-band","Differentiable"]);

row.Status = "OK";

end


function [gains,seconds] = fitCentroid(input,fs,target,cfg)

clock = tic;

bestError = Inf;
bestGain = 0;

coarse = -cfg.GainLimit:cfg.CoarseStep:cfg.GainLimit;

for gain = coarse

    output = applyFixedEQ( ...
        input,[0;0;gain],fs,cfg,false);

    s = spectrum(output,fs,cfg);

    value = abs(s.Centroid-target.Centroid);

    if value < bestError
        bestError = value;
        bestGain = gain;
    end

end

lower = max( ...
    -cfg.GainLimit,bestGain-cfg.CoarseStep);

upper = min( ...
    cfg.GainLimit,bestGain+cfg.CoarseStep);

for gain = lower:cfg.FineStep:upper

    output = applyFixedEQ( ...
        input,[0;0;gain],fs,cfg,false);

    s = spectrum(output,fs,cfg);

    value = abs(s.Centroid-target.Centroid);

    if value < bestError
        bestError = value;
        bestGain = gain;
    end

end

gains = [0;0;bestGain];

seconds = toc(clock);

end


function [bestGains,seconds] = fitThreeBand(input,fs,target,cfg)

clock = tic;

gains = zeros(3,1);
bestGains = gains;
bestScore = Inf;

for iteration = 1:cfg.ControllerIterations

    output = applyFixedEQ( ...
        input,gains,fs,cfg,false);

    s = spectrum(output,fs,cfg);

    errorDB = 10*log10( ...
        max(s.Bands,realmin)./max(target.Bands,realmin));

    score = sum(errorDB.^2);

    if score < bestScore
        bestScore = score;
        bestGains = gains;
    end

    if max(abs(errorDB)) <= cfg.ControllerTolerance
        break;
    end

    gains = min(cfg.GainLimit,max(-cfg.GainLimit, ...
        gains-cfg.ControllerStep*errorDB));

end

seconds = toc(clock);

end


function [bestGains,seconds] = fitDifferentiable( ...
    input,target,fs,cfg)

w = 2*pi*input.F/fs;

basis = [cos(w),cos(2*w),sin(w),sin(2*w)];

theta = dlarray(zeros(3,1));

averageGrad = [];
averageSqGrad = [];

bestLoss = Inf;
bestGains = zeros(3,1);

clock = tic;

for iteration = 1:cfg.AdamIterations

    [loss,grad] = dlfeval(@modelLoss,theta, ...
        input.DB,target.DB,basis,fs,cfg);

    value = double(extractdata(loss));

    assert(isfinite(value) && ...
        all(isfinite(extractdata(grad)),'all'), ...
        ['Differentiable optimization produced ' ...
         'a non-finite value.']);

    if value < bestLoss

        bestLoss = value;

        bestGains = double(extractdata( ...
            cfg.GainLimit*tanh(theta)));

    end

    if value < cfg.AdamLossTolerance
        break;
    end

    [theta,averageGrad,averageSqGrad] = adamupdate( ...
        theta,grad,averageGrad,averageSqGrad, ...
        iteration,cfg.AdamLearningRate);

end

seconds = toc(clock);

end


function [loss,grad] = modelLoss( ...
    theta,inputDB,targetDB,basis,fs,cfg)

gains = cfg.GainLimit*tanh(theta);

responseDB = zeros(size(inputDB));

for section = 1:3

    [b,a] = differentiableCoefficients( ...
        gains(section),section,fs,cfg);

    br = b(1)+b(2).*basis(:,1)+b(3).*basis(:,2);
    bi = b(2).*basis(:,3)+b(3).*basis(:,4);

    ar = a(1)+a(2).*basis(:,1)+a(3).*basis(:,2);
    ai = a(2).*basis(:,3)+a(3).*basis(:,4);

    ratio = (br.^2+bi.^2+1e-24)./ ...
        (ar.^2+ai.^2+1e-24);

    responseDB = responseDB+(10/log(10))*log(ratio);

end

loss = mean( ...
    (inputDB+responseDB-targetDB).^2,'all');

grad = dlgradient(loss,theta);

end


function y = applyFixedEQ( ...
    x,gains,fs,cfg,useDifferentiable)

y = x;

for section = 1:3

    if abs(gains(section)) < 1e-12
        continue;
    end

    if useDifferentiable

        [b,a] = differentiableCoefficients( ...
            gains(section),section,fs,cfg);

    elseif section == 2

        [b,a] = project_param_eq(2,gains(section), ...
            cfg.FixedFrequencies(section)/(fs/2), ...
            cfg.FixedBandwidth/(fs/2), ...
            'Orientation','row');

    else

        types = ["lo","hi"];
        type = types(1+(section == 3));

        [b,a] = designShelvingEQ(gains(section),1, ...
            cfg.FixedFrequencies(section)/(fs/2), ...
            char(type),'Orientation','row');

    end

    y = filter(b,a,y);

end

end


function [b,a] = differentiableCoefficients( ...
    gain,section,fs,cfg)

w0 = 2*pi*cfg.FixedFrequencies(section)/fs;

c = cos(w0);
A = exp(log(10)*gain/40);

if section == 2

    alpha = tan(pi*cfg.FixedBandwidth/fs);

    b = [1+alpha*A,-2*c,1-alpha*A];
    a = [1+alpha/A,-2*c,1-alpha/A];

elseif section == 1

    u = sin(w0)*sqrt(2*A);

    b = A.*[(A+1)-(A-1)*c+u, ...
        2*((A-1)-(A+1)*c), ...
        (A+1)-(A-1)*c-u];

    a = [(A+1)+(A-1)*c+u, ...
        -2*((A-1)+(A+1)*c), ...
        (A+1)+(A-1)*c-u];

else

    u = sin(w0)*sqrt(2*A);

    b = A.*[(A+1)+(A-1)*c+u, ...
        -2*((A-1)+(A+1)*c), ...
        (A+1)+(A-1)*c-u];

    a = [(A+1)-(A-1)*c+u, ...
        2*((A-1)-(A+1)*c), ...
        (A+1)-(A-1)*c-u];

end

a0 = a(1);

b = b./a0;
a = a./a0;

end


function y = writeAndRead(path,x,fs)

assert(iscolumn(x) && all(isfinite(x)) && ...
    max(abs(x)) < 1, ...
    'An output contains invalid samples or would clip.');

audiowrite(path,x,fs,'BitsPerSample',24);

[y,fsRead] = audioread(path);

assert(fsRead == fs && isequal(size(y),size(x)), ...
    'Saved audio has an unexpected rate or size.');

end


function path = resolvePath(rootDir,value)
% Resolve historical paths against this checkout, never an old copy.
path = project_audio_path(rootDir,value);
end


function S = summarise(R,cfg)

rows = cell(20,1);
k = 0;

for s = 1:4
    for m = 1:5

        selected = R.Scenario == cfg.Scenarios(s) & ...
            R.Method == cfg.Methods(m);

        T = R(selected,:);

        assert(height(T) == 60, ...
            'A scenario-method group is incomplete.');

        values = [T.RawRMSEdB, ...
            T.ShapeRMSEdB,T.ImprovementPercent];

        [lower,upper] = clusterInterval( ...
            values,T.PerformerID,cfg);

        means = mean(values,1);

        k = k+1;

        rows{k} = table( ...
            cfg.Scenarios(s),cfg.Methods(m),height(T), ...
            means(1),lower(1),upper(1), ...
            means(2),lower(2),upper(2), ...
            means(3),lower(3),upper(3), ...
            100*mean(T.RawRMSEdB < T.InputRawRMSEdB-1e-6), ...
            'VariableNames', ...
            {'Scenario','Method','Pairs', ...
            'MeanRawRMSEdB','RawLower95DB','RawUpper95DB', ...
            'MeanShapeRMSEdB','ShapeLower95DB','ShapeUpper95DB', ...
            'MeanImprovementPercent', ...
            'ImprovementLower95Percent', ...
            'ImprovementUpper95Percent','ImprovedCasePercent'});

    end
end

S = vertcat(rows{:});

end


function P = pairedEffects(R,cfg)

rows = cell(15,1);
k = 0;

for m = 1:5

    A = R(R.Method == cfg.Methods(m) & ...
        R.Scenario == "matched",:);

    keysA = A.ClipID+"|"+A.GainSign;

    assert(numel(unique(keysA)) == 60, ...
        'Matched cases are not unique.');

    for s = 2:4

        B = R(R.Method == cfg.Methods(m) & ...
            R.Scenario == cfg.Scenarios(s),:);

        keysB = B.ClipID+"|"+B.GainSign;

        [found,index] = ismember(keysA,keysB);

        assert(height(B) == 60 && all(found) && ...
            numel(unique(keysB)) == 60, ...
            'Paired cases are incomplete.');

        B = B(index,:);

        assert(all(A.PerformerID == B.PerformerID), ...
            'Performer IDs differ.');

        values = [ ...
            B.RawRMSEdB-A.RawRMSEdB, ...
            B.ShapeRMSEdB-A.ShapeRMSEdB, ...
            B.ImprovementPercent-A.ImprovementPercent];

        [lower,upper] = clusterInterval( ...
            values,A.PerformerID,cfg);

        means = mean(values,1);

        k = k+1;

        rows{k} = table( ...
            cfg.Methods(m),cfg.Scenarios(s),height(A), ...
            means(1),lower(1),upper(1), ...
            means(2),lower(2),upper(2), ...
            means(3),lower(3),upper(3), ...
            'VariableNames', ...
            {'Method','Scenario','Pairs', ...
            'MeanRawDifferenceDB','RawLower95DB','RawUpper95DB', ...
            'MeanShapeDifferenceDB', ...
            'ShapeLower95DB','ShapeUpper95DB', ...
            'MeanImprovementDifferencePP', ...
            'ImprovementLower95PP','ImprovementUpper95PP'});

    end
end

P = vertcat(rows{:});

end


function [lower,upper] = clusterInterval( ...
    values,performer,cfg)

[~,~,group] = unique(string(performer));

nGroups = max(group);

assert(nGroups == 6 && all(isfinite(values),'all'), ...
    'Six valid performer clusters are required.');

counts = accumarray(group,1,[nGroups 1]);

totals = zeros(nGroups,size(values,2));

for k = 1:size(values,2)

    totals(:,k) = accumarray( ...
        group,values(:,k),[nGroups 1]);

end

draws = randi( ...
    nGroups,nGroups,cfg.BootstrapSamples);

numerator = zeros( ...
    cfg.BootstrapSamples,size(values,2));

denominator = zeros(cfg.BootstrapSamples,1);

for k = 1:nGroups

    selected = draws(k,:);

    numerator = numerator+totals(selected,:);
    denominator = denominator+counts(selected);

end

bootstrapMeans = sort( ...
    numerator./denominator,1);

lower = bootstrapMeans( ...
    max(1,ceil(0.025*cfg.BootstrapSamples)),:);

upper = bootstrapMeans( ...
    min(cfg.BootstrapSamples, ...
    ceil(0.975*cfg.BootstrapSamples)),:);

end


function printResults(report)

S = report.Summary;

for s = 1:4

    fprintf('\nScenario: %s\n', ...
        char(report.Settings.Scenarios(s)));

    T = S(S.Scenario == report.Settings.Scenarios(s),:);

    for k = 1:height(T)

        fprintf( ...
            '%s | Raw: %.6f dB | Shape: %.6f dB | Recovery: %.2f%%\n', ...
            char(T.Method(k)),T.MeanRawRMSEdB(k), ...
            T.MeanShapeRMSEdB(k), ...
            T.MeanImprovementPercent(k));

    end

end

fprintf(['\nPaired changes: mismatch minus matched, ' ...
    'same clip and gain sign\n']);

P = report.Paired;

for k = 1:height(P)

    if P.Method(k) == "Differentiable"

        fprintf( ...
            '%s | Raw change: %+.6f dB | CI [%+.6f, %+.6f]\n', ...
            char(P.Scenario(k)),P.MeanRawDifferenceDB(k), ...
            P.RawLower95DB(k),P.RawUpper95DB(k));

    end

end

fprintf(['\nOracle uses known corruption parameters; ' ...
    'it is a diagnostic control.\n']);

end


function plotResults(report,outDir)

figureDir = fullfile(outDir,'figures');

if ~isfolder(figureDir)
    mkdir(figureDir);
end

cfg = report.Settings;

colors = lines(5);

labels = ["Distorted","Centroid","Three-band", ...
    "Differentiable","Oracle (known inverse)"];

scenarioLabels = ...
    {'Matched','Frequency','Bandwidth','Both'};

names = { ...
    'mismatch_spectral_error.png', ...
    'mismatch_relative_recovery.png', ...
    'paired_mismatch_effect.png'};

for plotID = 1:3

    screen = get(groot,'ScreenSize');

    width = max(800,min(1100,floor(0.85*screen(3))));
    heightPixels = max(600,min(740,floor(0.80*screen(4))));

    fig = figure( ...
        'Color','w', ...
        'WindowStyle','normal', ...
        'Units','pixels', ...
        'Position',[30 50 width heightPixels], ...
        'MenuBar','none', ...
        'ToolBar','none', ...
        'Name',sprintf('Model mismatch %d',plotID), ...
        'NumberTitle','off');

    cleanup = onCleanup(@() close(fig));

    ax = axes( ...
        'Parent',fig, ...
        'Position',[0.13 0.23 0.83 0.66]);

    hold(ax,'on');

    handles = gobjects(0);
    legendLabels = strings(0);

    if plotID <= 2

        for m = 1:5

            values = zeros(4,1);

            for s = 1:4

                selected = ...
                    report.Summary.Method == cfg.Methods(m) & ...
                    report.Summary.Scenario == cfg.Scenarios(s);

                assert(nnz(selected) == 1, ...
                    'A plotted summary is missing.');

                if plotID == 1

                    values(s) = ...
                        report.Summary.MeanRawRMSEdB(selected);

                else

                    values(s) = ...
                        report.Summary.MeanImprovementPercent(selected);

                end

            end

            if plotID == 1
                values = max(values,1e-8);
            end

            handles(end+1) = plot(ax,1:4,values,'-o', ...
                'Color',colors(m,:), ...
                'LineWidth',1.5,'MarkerSize',6);

            legendLabels(end+1) = labels(m);

        end

        xticks(ax,1:4);
        xticklabels(ax,scenarioLabels);
        xlim(ax,[0.75 4.25]);

        xlabel(ax,'Corruption scenario');

        if plotID == 1

            set(ax,'YScale','log');

            ylabel(ax,'Mean log-power RMSE (dB)');

            title(ax, ...
                'Fixed-model error under EQ mismatch');

        else

            yline(ax,0,'k:', ...
                'HandleVisibility','off');

            ylabel(ax, ...
                'Mean RMSE reduction relative to input (%)');

            title(ax, ...
                'Recovery relative to each distorted input');

        end

    else

        for m = 2:4

            values = zeros(3,1);
            lower = values;
            upper = values;

            for s = 2:4

                selected = ...
                    report.Paired.Method == cfg.Methods(m) & ...
                    report.Paired.Scenario == cfg.Scenarios(s);

                assert(nnz(selected) == 1, ...
                    'A paired summary is missing.');

                values(s-1) = ...
                    report.Paired.MeanRawDifferenceDB(selected);

                lower(s-1) = ...
                    report.Paired.RawLower95DB(selected);

                upper(s-1) = ...
                    report.Paired.RawUpper95DB(selected);

            end

            x = (1:3)'+0.13*(m-3);

            midpoint = (lower+upper)/2;

            errorbar(ax,x,midpoint, ...
                midpoint-lower,upper-midpoint, ...
                'LineStyle','none', ...
                'Marker','none', ...
                'Color',colors(m,:), ...
                'LineWidth',1.5, ...
                'HandleVisibility','off');

            handles(end+1) = plot(ax,x,values,'o', ...
                'Color',colors(m,:), ...
                'LineWidth',1.5,'MarkerSize',6);

            legendLabels(end+1) = labels(m);

        end

        yline(ax,0,'k:', ...
            'HandleVisibility','off');

        xticks(ax,1:3);
        xticklabels(ax,scenarioLabels(2:4));
        xlim(ax,[0.65 3.35]);

        xlabel(ax,'Mismatch scenario');

        ylabel(ax, ...
            'RMSE change from matched case (dB)');

        title(ax, ...
            'Paired changes with performer-cluster 95% intervals');

    end

    set(ax,'FontSize',12);

    grid(ax,'on');
    box(ax,'on');

    legend(ax,handles,cellstr(legendLabels), ...
        'Location','southoutside', ...
        'NumColumns',2, ...
        'Interpreter','none');

    fprintf('Mismatch figure %d: drawing...\n',plotID);

    drawnow nocallbacks;

    

    path = fullfile(figureDir,names{plotID});

    exportgraphics(fig,path,'Resolution',150);

    info = imfinfo(path);

    fprintf('Saved: %s\nImage size: %d x %d pixels\n', ...
        path,info.Width,info.Height);

    clear cleanup;

end

fprintf('Model-mismatch figures completed.\n');

end
