function tests = test_project_portability
% Regression checks for moved checkouts and the MATLAB filter-design API.
tests = functiontests(localfunctions);
end


function setupOnce(testCase)
project = fileparts(fileparts(mfilename('fullpath')));
addpath(project);
fixture = tempname;
mkdir(fixture);
testCase.TestData.Fixture = fixture;
testCase.TestData.Checkout = fullfile(fixture, 'checkout');
testCase.TestData.Old = fullfile(fixture, 'old_project');
end


function teardownOnce(testCase)
rmdir(testCase.TestData.Fixture, 's');
end


function testRelativeDataPath(testCase)
root = testCase.TestData.Checkout;
relative = fullfile('data', 'batch', 'reference', 'relative.wav');
createFile(fullfile(root, relative));
actual = project_audio_path(root, string(relative));
verifyEqual(testCase, actual, string(fullfile(root, relative)));
end


function testCurrentCheckoutWinsOverExistingOldCopy(testCase)
root = testCase.TestData.Checkout;
relative = fullfile('data', 'batch', 'reference', 'priority.wav');
old = fullfile(testCase.TestData.Old, relative);
local = fullfile(root, relative);
createFile(old);
createFile(local);
verifyEqual(testCase, project_audio_path(root, old), string(local));
end


function testHistoricalWindowsPath(testCase)
root = testCase.TestData.Checkout;
relative = fullfile('data', 'batch', 'reference', 'windows.wav');
createFile(fullfile(root, relative));
historical = 'C:\Users\student\ELEC5305\data\batch\reference\windows.wav';
verifyEqual(testCase, project_audio_path(root, historical), ...
    string(fullfile(root, relative)));
end


function testMissingCurrentCopyDoesNotUseOldAudio(testCase)
root = testCase.TestData.Checkout;
old = fullfile(testCase.TestData.Old, 'results', 'derived', 'missing.wav');
createFile(old);
verifyError(testCase, @() project_audio_path(root, old), 'ELEC5305:MissingAudio');
end


function testPilotBasename(testCase)
root = fullfile(testCase.TestData.Checkout, 'data', 'pilot');
createFile(fullfile(root, 'reference_01.wav'));
verifyEqual(testCase, project_audio_path(root, 'reference_01.wav'), ...
    string(fullfile(root, 'reference_01.wav')));
end


function testOutputCanBeResolvedBeforeCreation(testCase)
root = testCase.TestData.Checkout;
historical = '/Users/student/old/results/new_audio/output.wav';
verifyEqual(testCase, project_audio_path(root, historical, false), ...
    string(fullfile(root, 'results', 'new_audio', 'output.wav')));
end


function testParentTraversalRejected(testCase)
verifyError(testCase, @() project_audio_path( ...
    testCase.TestData.Checkout, 'data/../outside.wav', false), ...
    'ELEC5305:InvalidPath');
end


function testInvalidEmptyPath(testCase)
verifyError(testCase, @() project_audio_path( ...
    testCase.TestData.Checkout, ""), 'ELEC5305:InvalidPath');
end


function testPeakingFilterAcrossReleases(testCase)
fs = 44100;
omega = 2*pi*1000/fs;
for gain = [-6, 0, 6]
    [b, a] = project_param_eq(2, gain, 1000/(fs/2), 1000/(fs/2), ...
        'Orientation', 'row');
    verifySize(testCase, b, [1, 3]);
    verifySize(testCase, a, [1, 3]);
    h = freqz(b, a, [omega; omega]);
    verifyEqual(testCase, 20*log10(abs(h(1))), gain, 'AbsTol', 1e-7);
    verifyLessThan(testCase, max(abs(roots(a))), 1);
end
end


function createFile(path)
folder = fileparts(path);
if ~isfolder(folder), mkdir(folder); end
file = fopen(path, 'w');
assert(file ~= -1, 'Could not create a temporary regression fixture.');
fclose(file);
end
