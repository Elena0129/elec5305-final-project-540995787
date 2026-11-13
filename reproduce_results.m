function report = reproduce_results(resume)
% Refit every formal experiment using the supplied prepared audio.
% reproduce_results(false) starts fresh, ignoring distributed checkpoints.
% reproduce_results(true) resumes only an unchanged run in this checkout.
% Result tables, derived WAVs and figures are updated in results/.

if nargin < 1, resume = false; end
assert(islogical(resume) && isscalar(resume), ...
    'ELEC5305:ResumeFlag', 'Resume must be true or false.');
check_project("compute");

fprintf('\nStage 1/5: formal EQ benchmark\n');
report.Batch = run_batch_comparison(resume);
assert(all(report.Batch.Status == "OK"), 'ELEC5305:BenchmarkFailed', ...
    'Inspect results/batch_comparison/failed_results.csv before continuing.');

fprintf('\nStage 2/5: remeasure saved audio\n');
report.Extended = run_extended_evaluation();
for plotID = 1:6
    replot_extended_evaluation(plotID);
end

fprintf('\nStage 3/5: content dependence\n');
report.Content = run_content_dependence("run");
run_content_dependence("plot");

fprintf('\nStage 4/5: matched-capacity ablation\n');
report.Ablation = run_capacity_ablation("run", resume);
run_capacity_ablation("plot");

fprintf('\nStage 5/5: model mismatch\n');
report.Mismatch = run_model_mismatch("run", resume);
run_model_mismatch("plot");

report.Verification = check_project("saved");
fprintf('\nAll five experiment modules completed.\n');
end
