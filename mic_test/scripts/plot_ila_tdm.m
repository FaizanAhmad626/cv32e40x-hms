% plot_ila_tdm.m
% Reads a tdm_ila capture and plots each microphone slot, with level,
% spectral peak and tone-above-noise-floor for every slot.
%
% Input: either
%   - a CSV from Vivado (ILA window: File > Export > Export ILA Data, CSV), or
%   - an .ila file (write_hw_ila_data or the saved capture); it is a zip
%     that contains waveform.csv.
%
% Capture with capture control on and condition sample_valid == 1, so every
% stored entry is a sample.

clc; clear; close all;

scriptDir = fileparts(mfilename('fullpath'));          % folder this script is in
dataDir = fullfile(scriptDir, '..', 'data');            % captures in, images out
inFile = fullfile(dataDir, 'iladata.csv');   % .csv export, or an .ila file
fs     = 100e6 / 16 / 256;   % 24,414 Hz per slot (100 MHz clock, BCLK = clk/16, 256 BCLK per frame)
FS24   = 2^23;               % 24-bit full scale

% ---------- read the CSV ----------
[~, ~, ext] = fileparts(inFile);
if strcmpi(ext, '.ila')
    tmpDir = tempname; mkdir(tmpDir);
    zipCopy = fullfile(tmpDir, 'capture.zip');      % unzip() only accepts .zip names
    copyfile(inFile, zipCopy);
    unzip(zipCopy, tmpDir);
    csvFile = fullfile(tmpDir, 'waveform.csv');
else
    csvFile = inFile;
end
fid = fopen(csvFile);
if fid < 0
    error('Cannot open %s. Check that inFile points to the exported file.', csvFile);
end
hdr = strtrim(strsplit(fgetl(fid), ','));   % line 1: signal names
fgetl(fid);                                  % line 2: radix, skip
C = textscan(fid, repmat('%s', 1, numel(hdr)), 'Delimiter', ',');
fclose(fid);

col = @(pat) find(~cellfun(@isempty, regexp(hdr, pat)), 1);
iSample = col('sample\[23:0\]');
iSlot   = col('slot\[2:0\]');
iValid  = col('sample_valid');

raw   = hex2dec(C{iSample});
raw(raw >= 2^23) = raw(raw >= 2^23) - 2^24;     % 24-bit two's complement to signed
slot  = hex2dec(C{iSlot});
valid = hex2dec(C{iValid}) == 1;

% ---------- per-slot analysis ----------
fprintf('slot  samples  level(dBFS)  peak(Hz)  above noise(dB)\n');
figT = figure('Name', 'Time');     tlT = tiledlayout(figT, 2, 4);
figF = figure('Name', 'Spectrum'); tlF = tiledlayout(figF, 2, 4);
for k = 0:7
    x = raw(valid & slot == k);
    N = numel(x);
    if N < 256                                         % need fs/N < 100 Hz for the 950-1050 Hz band
        fprintf('%4d  skipped, only %d samples\n', k, N);
        continue;
    end
    x = x - mean(x);                                   % 1. remove DC

    levelDb = 20*log10(sqrt(mean(x.^2)) / FS24);       % 2-3. RMS, then dBFS

    w = 0.5 - 0.5*cos(2*pi*(0:N-1)'/(N-1));            % Hann window
    X = abs(fft(x .* w));
    X = X(1:floor(N/2)+1);
    f = (0:numel(X)-1)' * fs / N;                      % bin width = fs/N
    [~, kPk] = max(X(4:end)); kPk = kPk + 3;           % skip the DC bins
    band  = f > 950 & f < 1050;
    snrDb = 20*log10(max(X(band)) / median(X(2:end))); % tone vs median noise floor

    fprintf('%4d  %7d  %11.1f  %8.1f  %15.1f\n', k, N, levelDb, f(kPk), snrDb);

    nexttile(tlT); t = (0:N-1)'/fs*1e3;
    plot(t, x); xlim([0 3]); grid on;
    title(sprintf('slot %d', k)); xlabel('time (ms)'); ylabel('LSB');

    nexttile(tlF);
    plot(f, 20*log10(X / max(X))); xlim([0 fs/2]); ylim([-100 5]); grid on;
    title(sprintf('slot %d: %.0f Hz', k, f(kPk))); xlabel('Hz'); ylabel('dB');
end

% ---------- save the figures as PNG in the data folder ----------
exportgraphics(figT, fullfile(dataDir, 'time.png'),     'Resolution', 200);
exportgraphics(figF, fullfile(dataDir, 'spectrum.png'), 'Resolution', 200);
