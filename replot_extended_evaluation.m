function outPath = replot_extended_evaluation(plotID)
% Recreate one figure from saved evaluation data.
% No EQ fitting and no exportgraphics or print calls.

if nargin == 0
    plotID = 1;
end

validateattributes(plotID,{'numeric'}, ...
    {'scalar','integer','>=',1,'<=',6});

rootDir = fileparts(mfilename('fullpath'));
dataDir = fullfile(rootDir,'results','extended_evaluation');
outDir = fullfile(dataDir,'figures');

if ~isfolder(outDir)
    mkdir(outDir);
end

S = readtable(fullfile(dataDir,'metric_summary.csv'), ...
    'TextType','string');

methods = ["Distorted";"Centroid";"Three-band";"Differentiable"];
colors = lines(4);
floorValue = 1e-8;

screen = get(groot,'ScreenSize');
figureWidth = min(1100,screen(3)-120);
figureHeight = min(740,screen(4)-180);

fig = figure('WindowStyle','normal','Color','w', ...
    'Units','pixels', ...
    'Position',[60 80 figureWidth figureHeight], ...
    'MenuBar','none','ToolBar','none','NumberTitle','off', ...
    'Name',sprintf('Extended evaluation - figure %d',plotID));

cleanup = onCleanup(@() close(fig));
ax = axes('Parent',fig,'Units','normalized');
hold(ax,'on');

labels = strings(0,1);
logX = false;
logY = true;

fprintf('Figure %d: drawing...\n',plotID);

switch plotID

    case {1,2}
        metricNames = ["ShapeRMSEdB";"MRLogRMSEdB"];

        captions = ["Level-matched spectral error"; ...
            "Multi-resolution spectral error"];

        fileNames = ["shape_error.png"; ...
            "multi_resolution_error.png"];

        metric = metricNames(plotID);
        caption = captions(plotID);
        fileName = fileNames(plotID);

        for m = 1:4
            row = S.Method == methods(m) & S.Metric == metric;
            assert(nnz(row) == 1,'A metric summary is missing.');

            mu = S.MeanDB(row);

            errorbar(ax,m,max(mu,floorValue), ...
                max(0,mu-S.Lower95DB(row)), ...
                max(0,S.Upper95DB(row)-mu),'o', ...
                'Color',colors(m,:),'LineWidth',1.5, ...
                'MarkerSize',8);
        end

        xticks(ax,1:4);
        xticklabels(ax,methods);
        xlim(ax,[0.5 4.5]);

        xLabel = 'Method';
        yLabel = 'Mean error (dB)';

    case {3,4}
        B = readtable(fullfile(dataDir,'bandwise_summary.csv'), ...
            'TextType','string');

        bands = ["Low";"Mid";"High"];

        if plotID == 3
            field = 'MeanAbsRawDB';
            caption = "Bandwise error before level matching";
            fileName = "band_error_raw.png";
        else
            field = 'MeanAbsShapeDB';
            caption = "Bandwise error after level matching";
            fileName = "band_error_shape.png";
        end

        for m = 1:4
            values = zeros(1,3);

            for b = 1:3
                row = B.Method == methods(m) & B.Band == bands(b);
                assert(nnz(row) == 1,'A band summary is missing.');
                values(b) = B.(field)(row);
            end

            plot(ax,1:3,max(values,floorValue),'-o', ...
                'Color',colors(m,:),'LineWidth',1.6, ...
                'MarkerSize',7);
        end

        xticks(ax,1:3);
        xticklabels(ax,bands);
        xlim(ax,[0.8 3.2]);

        xLabel = 'Frequency band';
        yLabel = 'Mean absolute band-power error (dB)';
        labels = methods;

    case 5
        E = readtable(fullfile(dataDir,'extended_metrics.csv'), ...
            'TextType','string');

        for m = 2:4
            row = E.Method == methods(m);

            plot(ax,max(E.CentroidErrorHz(row),floorValue), ...
                max(E.RawRMSEdB(row),floorValue),'o', ...
                'Color',colors(m,:),'MarkerSize',5);
        end

        caption = "Centroid matching versus spectral matching";
        fileName = "centroid_vs_spectrum.png";

        xLabel = 'Absolute centroid error (Hz)';
        yLabel = 'Raw log-power RMSE (dB)';

        labels = methods(2:4);
        logX = true;

    case 6
        resultFile = fullfile(dataDir,'extended_metrics.csv');

        opts = detectImportOptions(resultFile,'TextType','string');
        opts = setvartype(opts, ...
            {'PairID','Condition','Method', ...
            'ReferencePath','InputPath','OutputPath'},'string');

        E = readtable(resultFile,opts);

        candidates = E(E.Method == "Centroid" & ...
            E.Condition == "mid_cut",:);

        assert(~isempty(candidates),'No mid-cut cases were found.');

        [~,order] = sort(candidates.RawRMSEdB);
        chosen = candidates(order(ceil(size(candidates,1)/2)),:);

        settings = load( ...
            fullfile(dataDir,'evaluation_settings.mat'),'cfg');
        cfg = settings.cfg;

        restore_benchmark_audio(chosen.PairID);

        [ref,fs] = audioread( ...
            resolvePath(rootDir,chosen.ReferencePath));

        win = hann(cfg.WindowLength,'periodic');

        [p,f] = pwelch(ref,win, ...
            cfg.OverlapLength,cfg.FFTLength,fs);

        keep = f >= cfg.FrequencyRangeHz(1) & ...
            f <= cfg.FrequencyRangeHz(2);

        f = f(keep);

        spectra = zeros(numel(f),5);
        spectra(:,1) = 10*log10(max(p(keep),realmin));

        plot(ax,f,spectra(:,1),'k--','LineWidth',2);

        for m = 1:4
            row = E(E.PairID == chosen.PairID & ...
                E.Method == methods(m),:);

            assert(size(row,1) == 1, ...
                'An example output is missing.');

            if m == 1
                audioPath = row.InputPath;
            else
                audioPath = row.OutputPath;
            end

            [y,fsY] = audioread( ...
                resolvePath(rootDir,audioPath));

            assert(fsY == fs && numel(y) == numel(ref), ...
                'Example audio dimensions do not match.');

            p = pwelch(y,win, ...
                cfg.OverlapLength,cfg.FFTLength,fs);

            spectra(:,m+1) = 10*log10(max(p(keep),realmin));

            plot(ax,f,spectra(:,m+1), ...
                'Color',colors(m,:),'LineWidth',1.3);
        end

        caption = "Reference recovery: "+chosen.PairID;
        fileName = "five_signal_spectra.png";

        xLabel = 'Frequency (Hz)';
        yLabel = 'Power spectral density (dB/Hz)';

        labels = ["Reference";methods];
        logX = true;
        logY = false;

        xlim(ax,cfg.FrequencyRangeHz);

        T = array2table([f,spectra],'VariableNames', ...
            {'FrequencyHz','ReferenceDB','DistortedDB', ...
            'CentroidDB','ThreeBandDB','DifferentiableDB'});

        writetable(T,fullfile(dataDir,'example_spectra.csv'));

        examplePairID = chosen.PairID;
        save(fullfile(dataDir,'example_selection.mat'), ...
            'examplePairID');
end

% Apply formatting after plotting.
set(ax,'FontSize',13,'Color','w','XColor','k','YColor','k');

if logX
    ax.XScale = 'log';
end

if logY
    ax.YScale = 'log';
end

grid(ax,'on');
box(ax,'on');

xlabel(ax,xLabel,'Color','k');
ylabel(ax,yLabel,'Color','k');

title(ax,caption,'Interpreter','none', ...
    'Color','k','FontSize',15);

if ~isempty(labels)
    lgd = legend(ax,labels,'NumColumns',2, ...
        'Interpreter','none','FontSize',12, ...
        'TextColor','k','Color','w');

    lgd.Units = 'normalized';
    lgd.Position = [0.18 0.02 0.76 0.10];
end

ax.Position = [0.13 0.24 0.83 0.65];

drawnow nocallbacks;

fprintf('Figure %d: exporting figure...\n',plotID);


outPath = fullfile(outDir,char(fileName));

fprintf('Figure %d: saving PNG...\n',plotID);
exportgraphics(fig,outPath,'Resolution',150);

info = imfinfo(outPath);

fprintf('Saved: %s\nImage size: %d x %d pixels\n', ...
    outPath,info.Width,info.Height);
end


function p = resolvePath(rootDir,value)
% Resolve historical paths against this checkout, never an old copy.
p = project_audio_path(rootDir,value);
end
