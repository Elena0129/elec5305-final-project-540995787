function path = project_audio_path(rootDir, value, mustExist)
% Resolve audio in this checkout, including paths saved on another machine.
% Historical /data/ and /results/ paths are always mapped to rootDir first.
% Use false only when resolving an output file that will be created.

if nargin < 3
    mustExist = true;
end

value = string(value);
assert(isscalar(value) && ~ismissing(value) && strlength(value) > 0, ...
    'ELEC5305:InvalidPath', 'An audio path must be one nonempty string.');

normalised = strrep(char(value), '\', '/');
anchor = regexp(normalised, '(^|/)(data|results)/', 'start', 'once');

if ~isempty(anchor)
    if normalised(anchor) == '/'
        anchor = anchor + 1;
    end
    relative = normalised(anchor:end);
    parts = strsplit(relative, '/');
    assert(~any(strcmp(parts, '..')), 'ELEC5305:InvalidPath', ...
        'Project audio paths must not contain parent-directory traversal.');
    path = string(fullfile(char(rootDir), relative));
elseif startsWith(normalised, '/') || ...
        ~isempty(regexp(normalised, '^[A-Za-z]:/', 'once'))
    % An explicit external path without a project data/results component.
    path = string(normalised);
else
    parts = strsplit(normalised, '/');
    assert(~any(strcmp(parts, '..')), 'ELEC5305:InvalidPath', ...
        'Relative audio paths must stay inside the selected folder.');
    path = string(fullfile(char(rootDir), normalised));
end

if mustExist && ~isfile(path)
    error('ELEC5305:MissingAudio', ...
        ['Audio is missing from this checkout: %s\n' ...
         'Check the supplied data, or restore saved benchmark outputs ' ...
         'with restore_benchmark_audio.'], char(path));
end
end
