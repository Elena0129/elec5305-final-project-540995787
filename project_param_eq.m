function [b, a] = project_param_eq(order, gain, centre, bandwidth, varargin)
% Preserve the second-order bandwidth specification across MATLAB releases.
% Frequencies are normalised to Nyquist, as in the original implementation.
% R2026a replaced positional inputs and removed the Orientation option.

assert(isscalar(order) && order == 2, 'ELEC5305:FilterOrder', ...
    'This project uses one second-order peaking section.');

if ~isempty(varargin)
    assert(numel(varargin) == 2 && ...
        strcmpi(string(varargin{1}), "Orientation") && ...
        strcmpi(string(varargin{2}), "row"), ...
        'ELEC5305:FilterOrientation', ...
        'Only row-oriented filter coefficients are supported.');
end

if verLessThan('matlab', '26.1')
    [b, a] = designParamEQ(order, gain, centre, bandwidth, ...
        'Orientation', 'row');
else
    [b, a] = designParamEQ('FilterOrder', order, 'Gain', gain, ...
        'CenterFrequency', centre, 'Bandwidth', bandwidth);
end

assert(numel(b) == 3 && numel(a) == 3, ...
    'ELEC5305:FilterShape', 'Expected one second-order filter section.');
b = reshape(b, 1, 3);
a = reshape(a, 1, 3);
end
