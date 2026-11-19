import 'dart:math' as math;

import 'ppg_image.dart';

/// Camera PPG heart-rate estimation (FR-3.2, UC3.3; docs/06 algorithm B, Yan et al. 2017).
///
/// 1. image stage (D-123, ppg_image.dart): per frame, YUV -> green, histogram masking,
///    fingertip segmentation, 4x4 grid block means and frame-differencing motion flags;
///    here the most pulse-like blocks are averaged (adaptive ROI) and frames flagged as
///    moving are bridged by interpolation
/// 2. resample to a uniform rate and remove the slow baseline
/// 3. band-pass 0.67-3.3 Hz (40-200 bpm), zero-phase
/// 4. peak detection
/// 5. bpm = beats per minute over the span of detected beats
/// 6. D-119 cross-check: an FFT of the same filtered signal gives a second, independent
///    estimate (strongest frequency in 40-200 bpm); the two must agree
/// 7. reject the capture if the signal quality is too low (UC3.3 E1 / UC14.2 E1)
///
/// [liveHeartRate] runs the same steps on the frames so far, for the live reading
/// shown while measuring (D-119).
///
/// Pure Dart with no Flutter imports, so it runs in an isolate via `compute`
/// and is unit-tested with synthetic signals.

enum PpgFailure { tooShort, noSignal, irregular, outOfRange, mismatch, motion }

class PpgInput {
  const PpgInput(this.timesSeconds, this.greenMeans, {this.blockGreens, this.moving});

  /// Frame timestamps in seconds (need not be evenly spaced).
  final List<double> timesSeconds;

  /// Mean green intensity of each frame.
  final List<double> greenMeans;

  /// D-123: per frame, the mean green of each grid block (NaN when unusable).
  final List<List<double>>? blockGreens;

  /// D-123: per frame, true when frame differencing flagged movement.
  final List<bool>? moving;
}

class PpgResult {
  const PpgResult.success(
    this.bpm,
    this.quality, {
    this.fftBpm,
    this.roiBlocks = const [],
    this.blockStrength = const [],
    this.motionFrames = 0,
  }) : failure = null;
  const PpgResult.failed(this.failure)
    : bpm = null,
      quality = 0,
      fftBpm = null,
      roiBlocks = const [],
      blockStrength = const [],
      motionFrames = 0;

  /// Heart rate from counting peaks (the reported value).
  final int? bpm;

  /// D-119: the frequency-spectrum (FFT) estimate it was checked against.
  final int? fftBpm;

  /// 0..1, higher is a cleaner, more regular pulse.
  final double quality;

  /// D-123: grid blocks averaged for the signal, and the pulse strength (0..1) of every
  /// block for the heat map. Empty when the input had no grid.
  final List<int> roiBlocks;
  final List<double> blockStrength;

  /// D-123: frames flagged as moving and bridged by interpolation.
  final int motionFrames;
  final PpgFailure? failure;

  bool get ok => bpm != null;
}

class PpgConfig {
  const PpgConfig({
    this.sampleRate = 30,
    this.lowHz = 0.67,
    this.highHz = 3.3,
    this.settleSeconds = 1.5,
    this.minSeconds = 8,
    this.maxIntervalCv = 0.25,
    this.maxMethodGapBpm = 8,
    this.maxMethodGapRatio = 0.1,
    this.maxMotionShare = 0.25,
  });

  final double sampleRate;
  final double lowHz;
  final double highHz;

  /// Ignore the first seconds while the finger and auto-exposure settle.
  final double settleSeconds;

  /// Minimum usable signal length after settling.
  final double minSeconds;

  /// Maximum coefficient of variation of beat intervals for a "regular" pulse.
  final double maxIntervalCv;

  /// D-119: the peak and FFT estimates agree when they differ by at most this many
  /// bpm, or this fraction of the peak estimate, whichever is larger.
  final double maxMethodGapBpm;
  final double maxMethodGapRatio;

  /// D-123: fail as `motion` when more than this share of frames (after settling) moved.
  final double maxMotionShare;
}

/// Shorter minimum for the live reading while measuring (D-119).
const livePpgConfig = PpgConfig(minSeconds: 5);

const minBpm = 40;
const maxBpm = 200;

/// Entry point used with `compute(estimateHeartRate, input)`.
PpgResult estimateHeartRate(PpgInput input, {PpgConfig config = const PpgConfig()}) {
  final t = input.timesSeconds;
  var y = input.greenMeans;
  if (t.length != y.length || t.length < 2) return const PpgResult.failed(PpgFailure.tooShort);
  final fs = config.sampleRate;

  // D-123 motion: frames flagged by frame differencing are bridged; too many -> retry.
  final moving = input.moving != null && input.moving!.length == t.length ? input.moving : null;
  var motionFrames = 0;
  if (moving != null) {
    final settled = t.first + config.settleSeconds;
    var counted = 0;
    for (var i = 0; i < t.length; i++) {
      if (t[i] < settled) continue;
      counted++;
      if (moving[i]) motionFrames++;
    }
    if (counted > 0 && motionFrames > config.maxMotionShare * counted) {
      return const PpgResult.failed(PpgFailure.motion);
    }
  }

  // D-123 adaptive ROI: average only the grid blocks with the strongest pulse.
  RoiSelection? roi;
  final blocks = input.blockGreens;
  if (blocks != null && blocks.length == t.length) {
    roi = selectRoi(
      blocks,
      (series) => pulseStrength(t, moving == null ? series : repairFlagged(series, moving), config),
    );
    if (roi.series.isNotEmpty) y = roi.series;
  }
  if (moving != null) y = repairFlagged(y, moving);

  final uniform = resample(t, y, fs);
  final skip = (config.settleSeconds * fs).round();
  if (uniform.length - skip < config.minSeconds * fs) {
    return const PpgResult.failed(PpgFailure.tooShort);
  }
  final signal = uniform.sublist(skip);

  // A covered lens with the torch on gives a small but clear pulsatile variation.
  // A flat signal means no finger, a dead camera or a frozen frame.
  if (_std(signal) < 1e-3) return const PpgResult.failed(PpgFailure.noSignal);

  final filtered = bandPass(signal, fs, config.lowHz, config.highHz);
  // Drop filter edges, where the forward-backward pass is least reliable.
  final edge = fs.round();
  if (filtered.length <= 3 * edge) return const PpgResult.failed(PpgFailure.tooShort);
  final core = filtered.sublist(edge, filtered.length - edge);

  // The dicrotic wave of each beat is also in band, so first estimate the beat
  // period (autocorrelation) and only accept peaks spaced like real beats.
  final period = dominantPeriodSamples(core, fs);
  if (period == null) return const PpgResult.failed(PpgFailure.noSignal);
  final peaks = detectPeaks(core, fs, minDistance: (0.6 * period).floor());
  if (peaks.length < 4) return const PpgResult.failed(PpgFailure.noSignal);

  final intervals = [for (var i = 1; i < peaks.length; i++) (peaks[i] - peaks[i - 1]) / fs];
  final meanInterval = intervals.reduce((a, b) => a + b) / intervals.length;
  final cv = _std(intervals) / meanInterval;
  if (cv > config.maxIntervalCv) return const PpgResult.failed(PpgFailure.irregular);

  final spanSeconds = (peaks.last - peaks.first) / fs;
  final bpm = ((peaks.length - 1) / spanSeconds * 60).round();
  if (bpm < minBpm || bpm > maxBpm) return const PpgResult.failed(PpgFailure.outOfRange);

  // D-119: independent check in the frequency domain. Counting peaks can be fooled by
  // a missed or extra beat; the spectrum looks at the whole window at once.
  final fft = spectralBpm(core, fs);
  if (fft == null || !methodsAgree(bpm, fft, config)) {
    return const PpgResult.failed(PpgFailure.mismatch);
  }

  return PpgResult.success(
    bpm,
    (1 - cv / config.maxIntervalCv).clamp(0.0, 1.0),
    fftBpm: fft.round(),
    roiBlocks: roi?.selected ?? const [],
    blockStrength: roi?.strength ?? const [],
    motionFrames: motionFrames,
  );
}

/// D-123: how pulse-like one series is, 0..1: the share of in-band (40-200 bpm) spectral
/// power within 6 bpm of the strongest frequency. A clean pulse is near 1, noise is low.
double pulseStrength(List<double> t, List<double> y, [PpgConfig config = const PpgConfig()]) {
  final fs = config.sampleRate;
  final uniform = resample(t, y, fs);
  final skip = (config.settleSeconds * fs).round();
  if (uniform.length - skip < 4 * fs) return 0;
  final signal = uniform.sublist(skip);
  if (_std(signal) < 1e-6) return 0;
  final power = _powerSpectrum(bandPass(signal, fs, config.lowHz, config.highHz), 1024);
  final n = (power.length - 1) * 2;
  final lo = math.max(1, (minBpm / 60 * n / fs).ceil());
  final hi = math.min(power.length - 1, (maxBpm / 60 * n / fs).floor());
  var total = 0.0;
  var best = lo;
  for (var k = lo; k <= hi; k++) {
    total += power[k];
    if (power[k] > power[best]) best = k;
  }
  if (total == 0) return 0;
  final width = (6 / 60 * n / fs).ceil();
  var near = 0.0;
  for (var k = math.max(lo, best - width); k <= math.min(hi, best + width); k++) {
    near += power[k];
  }
  return near / total;
}

/// Power at bins 0..n/2 of a Hann-windowed, zero-padded FFT.
List<double> _powerSpectrum(List<double> x, int minSize) {
  var n = 1;
  while (n < math.max(x.length, minSize)) {
    n <<= 1;
  }
  final mean = x.reduce((a, b) => a + b) / x.length;
  final re = List<double>.filled(n, 0);
  final im = List<double>.filled(n, 0);
  for (var i = 0; i < x.length; i++) {
    final w = 0.5 - 0.5 * math.cos(2 * math.pi * i / (x.length - 1));
    re[i] = (x[i] - mean) * w;
  }
  fft(re, im);
  return [for (var k = 0; k <= n ~/ 2; k++) re[k] * re[k] + im[k] * im[k]];
}

/// Live reading from the frames captured so far (D-119), or null while there is
/// not yet a clear, cross-checked pulse. Top-level so it can run with `compute`.
int? liveHeartRate(PpgInput input) => estimateHeartRate(input, config: livePpgConfig).bpm;

/// D-119: true when the peak-count and FFT estimates are close enough.
bool methodsAgree(int peakBpm, double fftBpm, [PpgConfig config = const PpgConfig()]) {
  final allowed = math.max(config.maxMethodGapBpm, config.maxMethodGapRatio * peakBpm);
  return (peakBpm - fftBpm).abs() <= allowed;
}

/// Heart rate from the frequency spectrum (D-119): Hann window, zero-padded radix-2
/// FFT, strongest bin between 40 and 200 bpm, refined by parabolic interpolation.
/// Null when the signal has no energy.
double? spectralBpm(List<double> x, double fs, {int minSize = 2048}) {
  if (x.length < 8) return null;
  var n = 1;
  while (n < math.max(x.length, minSize)) {
    n <<= 1;
  }
  final mean = x.reduce((a, b) => a + b) / x.length;
  final re = List<double>.filled(n, 0);
  final im = List<double>.filled(n, 0);
  for (var i = 0; i < x.length; i++) {
    final w = 0.5 - 0.5 * math.cos(2 * math.pi * i / (x.length - 1)); // Hann
    re[i] = (x[i] - mean) * w;
  }
  fft(re, im);
  final lo = math.max(1, (minBpm / 60 * n / fs).ceil());
  final hi = math.min(n ~/ 2 - 2, (maxBpm / 60 * n / fs).floor());
  double mag(int k) => math.sqrt(re[k] * re[k] + im[k] * im[k]);
  var best = lo;
  for (var k = lo + 1; k <= hi; k++) {
    if (mag(k) > mag(best)) best = k;
  }
  if (mag(best) == 0) return null;
  final a = mag(best - 1), b = mag(best), c = mag(best + 1);
  final denom = a - 2 * b + c;
  final delta = denom == 0 ? 0.0 : (0.5 * (a - c) / denom).clamp(-0.5, 0.5);
  return (best + delta) * fs / n * 60;
}

/// In-place iterative radix-2 Cooley-Tukey FFT. [re] and [im] must have the same
/// power-of-two length.
void fft(List<double> re, List<double> im) {
  final n = re.length;
  assert(n == im.length && n & (n - 1) == 0, 'length must be a power of two');
  // Bit-reversal permutation.
  for (var i = 1, j = 0; i < n; i++) {
    var bit = n >> 1;
    for (; j & bit != 0; bit >>= 1) {
      j ^= bit;
    }
    j ^= bit;
    if (i < j) {
      final tr = re[i];
      re[i] = re[j];
      re[j] = tr;
      final ti = im[i];
      im[i] = im[j];
      im[j] = ti;
    }
  }
  // Butterflies.
  for (var len = 2; len <= n; len <<= 1) {
    final half = len >> 1;
    final ang = -2 * math.pi / len;
    final wr = math.cos(ang), wi = math.sin(ang);
    for (var i = 0; i < n; i += len) {
      var cr = 1.0, ci = 0.0;
      for (var k = 0; k < half; k++) {
        final a = i + k, b = a + half;
        final vr = re[b] * cr - im[b] * ci;
        final vi = re[b] * ci + im[b] * cr;
        re[b] = re[a] - vr;
        im[b] = im[a] - vi;
        re[a] += vr;
        im[a] += vi;
        final next = cr * wr - ci * wi;
        ci = cr * wi + ci * wr;
        cr = next;
      }
    }
  }
}

/// Linear interpolation onto an even grid at [fs] Hz.
List<double> resample(List<double> t, List<double> y, double fs) {
  final start = t.first;
  final end = t.last;
  final n = ((end - start) * fs).floor() + 1;
  final out = List<double>.filled(n, 0);
  var j = 0;
  for (var i = 0; i < n; i++) {
    final ti = start + i / fs;
    while (j < t.length - 2 && t[j + 1] < ti) {
      j++;
    }
    final span = t[j + 1] - t[j];
    final w = span <= 0 ? 0.0 : ((ti - t[j]) / span).clamp(0.0, 1.0);
    out[i] = y[j] + (y[j + 1] - y[j]) * w;
  }
  return out;
}

/// Zero-phase band-pass: 2nd-order Butterworth high-pass then low-pass, each run
/// forward and backward (filtfilt) so peaks are not shifted in time.
List<double> bandPass(List<double> x, double fs, double lowHz, double highHz) {
  final mean = x.reduce((a, b) => a + b) / x.length;
  var s = [for (final v in x) v - mean];
  s = _filtfilt(s, _Biquad.highPass(fs, lowHz));
  s = _filtfilt(s, _Biquad.lowPass(fs, highHz));
  return s;
}

/// Beat period in samples from the autocorrelation peak within 40-200 bpm, or
/// null when there is no clear periodicity.
int? dominantPeriodSamples(List<double> x, double fs) {
  final minLag = (fs * 60 / maxBpm).floor();
  final maxLag = (fs * 60 / minBpm).ceil();
  if (x.length < 2 * maxLag) return null;
  var energy = 0.0;
  for (final v in x) {
    energy += v * v;
  }
  if (energy == 0) return null;
  final r = List<double>.filled(maxLag + 1, 0);
  for (var lag = minLag; lag <= maxLag; lag++) {
    var acc = 0.0;
    for (var i = 0; i + lag < x.length; i++) {
      acc += x[i] * x[i + lag];
    }
    r[lag] = acc / energy;
  }
  // First local maximum that is close to the global maximum: avoids picking a
  // multiple of the true period.
  final best = r.sublist(minLag).reduce(math.max);
  // Weak periodicity means noise dominates: reject rather than guess (UC3.3 E1).
  if (best < 0.45) return null;
  for (var lag = minLag + 1; lag < maxLag; lag++) {
    if (r[lag] >= r[lag - 1] && r[lag] >= r[lag + 1] && r[lag] >= 0.8 * best) return lag;
  }
  return null;
}

/// Local maxima above an adaptive threshold, at least [minDistance] samples apart
/// (default: one shortest beat).
List<int> detectPeaks(List<double> x, double fs, {int? minDistance}) {
  minDistance ??= (fs * 60 / maxBpm).floor();
  final threshold = 0.3 * _std(x);
  final peaks = <int>[];
  for (var i = 1; i < x.length - 1; i++) {
    if (x[i] <= threshold || x[i] < x[i - 1] || x[i] < x[i + 1]) continue;
    if (peaks.isNotEmpty && i - peaks.last < minDistance) {
      if (x[i] > x[peaks.last]) peaks[peaks.length - 1] = i; // keep the taller one
      continue;
    }
    peaks.add(i);
  }
  return peaks;
}

double _std(List<double> v) {
  if (v.length < 2) return 0;
  final m = v.reduce((a, b) => a + b) / v.length;
  var acc = 0.0;
  for (final e in v) {
    acc += (e - m) * (e - m);
  }
  return math.sqrt(acc / (v.length - 1));
}

List<double> _filtfilt(List<double> x, _Biquad f) {
  final forward = f.run(x);
  final backward = f.run(forward.reversed.toList());
  return backward.reversed.toList();
}

/// RBJ audio-EQ-cookbook biquad, Q = 1/sqrt(2) (Butterworth).
class _Biquad {
  _Biquad(this.b0, this.b1, this.b2, this.a1, this.a2);

  factory _Biquad.lowPass(double fs, double fc) {
    final w = 2 * math.pi * fc / fs;
    final alpha = math.sin(w) / (2 * math.sqrt1_2);
    final cosw = math.cos(w);
    final a0 = 1 + alpha;
    return _Biquad(
      (1 - cosw) / 2 / a0,
      (1 - cosw) / a0,
      (1 - cosw) / 2 / a0,
      -2 * cosw / a0,
      (1 - alpha) / a0,
    );
  }

  factory _Biquad.highPass(double fs, double fc) {
    final w = 2 * math.pi * fc / fs;
    final alpha = math.sin(w) / (2 * math.sqrt1_2);
    final cosw = math.cos(w);
    final a0 = 1 + alpha;
    return _Biquad(
      (1 + cosw) / 2 / a0,
      -(1 + cosw) / a0,
      (1 + cosw) / 2 / a0,
      -2 * cosw / a0,
      (1 - alpha) / a0,
    );
  }

  final double b0, b1, b2, a1, a2;

  List<double> run(List<double> x) {
    final y = List<double>.filled(x.length, 0);
    var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0;
    for (var i = 0; i < x.length; i++) {
      final v = b0 * x[i] + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2;
      x2 = x1;
      x1 = x[i];
      y2 = y1;
      y1 = v;
      y[i] = v;
    }
    return y;
  }
}
