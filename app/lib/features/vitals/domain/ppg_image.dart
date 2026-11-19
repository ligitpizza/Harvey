import 'dart:math' as math;
import 'dart:typed_data';

/// D-123: the image-processing stage of camera PPG (FR-3.2, UC3.3; docs/06 §B).
///
/// Each camera frame is a YUV420 image of the torch-lit fingertip. Per frame:
/// 1. colour-space conversion: every sampled pixel YUV -> RGB (green is the PPG channel,
///    red is used to recognise skin)
/// 2. luma histogram -> pixel masking: too-dark (unlit) and saturated (blown-out) pixels
///    are left out; many saturated pixels usually means the finger presses too hard
/// 3. segmentation: a pixel is "fingertip" when it is lit and red-dominant; the share of
///    fingertip pixels is the finger coverage
/// 4. 4x4 grid: mean green of the usable fingertip pixels in each block, so the signal
///    stage can keep only the blocks with the strongest pulse (adaptive region of interest)
/// 5. frame differencing: a small luma thumbnail is compared with the previous frame's;
///    a large mean difference means the finger or phone moved
///
/// Pure Dart (no Flutter), so it is unit-tested with synthetic frames.

/// One YUV420 frame as raw planes (Android camera stream layout).
class YuvFrame {
  const YuvFrame({
    required this.width,
    required this.height,
    required this.y,
    required this.yRowStride,
    required this.u,
    required this.v,
    required this.uvRowStride,
    this.uvPixelStride = 1,
  });

  final int width;
  final int height;
  final Uint8List y;
  final int yRowStride;
  final Uint8List u;
  final Uint8List v;
  final int uvRowStride;
  final int uvPixelStride;
}

class PpgImageConfig {
  const PpgImageConfig({
    this.step = 4,
    this.grid = 4,
    this.darkLuma = 30,
    this.saturatedLuma = 245,
    this.minRedChroma = 20,
    this.minCoverage = 0.8,
    this.thumbCols = 8,
    this.thumbRows = 6,
    this.motionThreshold = 6,
  });

  /// Sample every [step]th pixel in each direction (a 320x240 frame gives 4,800 samples).
  final int step;

  /// The frame is split into [grid] x [grid] blocks.
  final int grid;

  /// Luma below this is unlit (no torch light through the finger): masked.
  final int darkLuma;

  /// Luma at or above this is saturated (clipped): masked.
  final int saturatedLuma;

  /// Minimum red chroma (Cr = V - 128) for a pixel to count as lit skin.
  final int minRedChroma;

  /// Coverage needed for "finger detected".
  final double minCoverage;

  /// Size of the luma thumbnail used for frame differencing.
  final int thumbCols;
  final int thumbRows;

  /// Mean absolute thumbnail difference (luma levels) above which a frame counts as moving.
  /// The pulse itself changes luma by only about 1-2 levels.
  final double motionThreshold;
}

class FrameAnalysis {
  const FrameAnalysis({
    required this.green,
    required this.blockGreen,
    required this.coverage,
    required this.darkFraction,
    required this.saturatedFraction,
    required this.thumb,
    required this.motion,
    required this.moving,
    required this.covered,
  });

  /// Mean green of all usable fingertip pixels (or of every pixel when none are usable).
  final double green;

  /// Mean green per grid block, row by row; NaN where a block has no usable pixel.
  final List<double> blockGreen;

  /// Share of sampled pixels classified as lit fingertip, 0..1.
  final double coverage;

  /// Shares of sampled pixels masked as too dark / saturated (from the luma histogram).
  final double darkFraction;
  final double saturatedFraction;

  /// Luma thumbnail for the next frame's differencing.
  final Float64List thumb;

  /// Mean absolute luma difference from the previous frame (0 for the first frame).
  final double motion;
  final bool moving;
  final bool covered;

  /// "Press more lightly" hint: a quarter of the picture is blown out.
  bool get pressingHard => saturatedFraction > 0.25;
}

/// Runs steps 1-5 on one frame. [previousThumb] is the last frame's [FrameAnalysis.thumb].
FrameAnalysis analyzeFrame(
  YuvFrame f, {
  Float64List? previousThumb,
  PpgImageConfig config = const PpgImageConfig(),
}) {
  final g = config.grid;
  final blockSum = List<double>.filled(g * g, 0);
  final blockN = List<int>.filled(g * g, 0);
  final histogram = List<int>.filled(256, 0);
  final thumbSum = Float64List(config.thumbCols * config.thumbRows);
  final thumbN = List<int>.filled(config.thumbCols * config.thumbRows, 0);
  var allGreen = 0.0;
  var usableGreen = 0.0;
  var usable = 0;
  var finger = 0;
  var n = 0;

  for (var row = 0; row < f.height; row += config.step) {
    final by = row * g ~/ f.height;
    final ty = row * config.thumbRows ~/ f.height;
    for (var col = 0; col < f.width; col += config.step) {
      final yi = row * f.yRowStride + col;
      final uvi = (row ~/ 2) * f.uvRowStride + (col ~/ 2) * f.uvPixelStride;
      if (yi >= f.y.length || uvi >= f.u.length || uvi >= f.v.length) continue;
      final luma = f.y[yi];
      final cb = f.u[uvi] - 128;
      final cr = f.v[uvi] - 128;
      // 1. Colour-space conversion (BT.601): G = Y - 0.344 Cb - 0.714 Cr.
      final green = (luma - 0.344 * cb - 0.714 * cr).clamp(0.0, 255.0);
      n++;
      allGreen += green;
      histogram[luma]++;
      final t = ty * config.thumbCols + col * config.thumbCols ~/ f.width;
      thumbSum[t] += luma;
      thumbN[t]++;
      // 2. Masking and 3. segmentation.
      final masked = luma < config.darkLuma || luma >= config.saturatedLuma;
      final skin = luma >= config.darkLuma && cr > config.minRedChroma;
      if (skin) finger++;
      if (masked || !skin) continue;
      usable++;
      usableGreen += green;
      // 4. Grid block.
      final b = by * g + col * g ~/ f.width;
      blockSum[b] += green;
      blockN[b]++;
    }
  }
  if (n == 0) {
    return FrameAnalysis(
      green: 0,
      blockGreen: List<double>.filled(g * g, double.nan),
      coverage: 0,
      darkFraction: 0,
      saturatedFraction: 0,
      thumb: thumbSum,
      motion: 0,
      moving: false,
      covered: false,
    );
  }

  var dark = 0;
  for (var i = 0; i < config.darkLuma; i++) {
    dark += histogram[i];
  }
  var saturated = 0;
  for (var i = config.saturatedLuma; i < 256; i++) {
    saturated += histogram[i];
  }

  for (var i = 0; i < thumbSum.length; i++) {
    if (thumbN[i] > 0) thumbSum[i] /= thumbN[i];
  }
  // 5. Frame differencing.
  var motion = 0.0;
  if (previousThumb != null && previousThumb.length == thumbSum.length) {
    for (var i = 0; i < thumbSum.length; i++) {
      motion += (thumbSum[i] - previousThumb[i]).abs();
    }
    motion /= thumbSum.length;
  }
  final coverage = finger / n;
  return FrameAnalysis(
    green: usable > 0 ? usableGreen / usable : allGreen / n,
    blockGreen: [
      for (var b = 0; b < g * g; b++) blockN[b] > 0 ? blockSum[b] / blockN[b] : double.nan,
    ],
    coverage: coverage,
    darkFraction: dark / n,
    saturatedFraction: saturated / n,
    thumb: thumbSum,
    motion: motion,
    moving: motion > config.motionThreshold,
    covered: coverage >= config.minCoverage,
  );
}

/// D-123 adaptive ROI result: which grid blocks were averaged and how strong the pulse
/// was in each (for the heat map).
class RoiSelection {
  const RoiSelection(this.series, this.strength, this.selected);

  /// The averaged green series of the selected blocks, one value per frame.
  final List<double> series;

  /// Pulse strength per block, 0..1 (0 for unusable blocks).
  final List<double> strength;

  /// Indices of the blocks used.
  final List<int> selected;
}

/// Picks the blocks whose signal is most pulse-like. [blocks] is per frame, per block;
/// [strengthOf] scores one block's series (0..1). A block missing in more than 10% of
/// frames is not used. Blocks within [keepRatio] of the best score are averaged.
RoiSelection selectRoi(
  List<List<double>> blocks,
  double Function(List<double> series) strengthOf, {
  double keepRatio = 0.6,
}) {
  final frames = blocks.length;
  final count = frames == 0 ? 0 : blocks.first.length;
  final strength = List<double>.filled(count, 0);
  final seriesOf = <int, List<double>>{};
  for (var b = 0; b < count; b++) {
    final raw = [for (final f in blocks) f[b]];
    final missing = raw.where((v) => v.isNaN).length;
    if (frames == 0 || missing > 0.1 * frames) continue;
    final filled = _fillGaps(raw);
    seriesOf[b] = filled;
    strength[b] = strengthOf(filled);
  }
  if (seriesOf.isEmpty) return RoiSelection(const [], strength, const []);
  final best = strength.reduce(math.max);
  final selected = [
    for (final b in seriesOf.keys)
      if (best > 0 && strength[b] >= keepRatio * best) b,
  ]..sort();
  final use = selected.isEmpty ? seriesOf.keys.toList() : selected;
  final series = [
    for (var i = 0; i < frames; i++)
      use.map((b) => seriesOf[b]![i]).reduce((a, c) => a + c) / use.length,
  ];
  return RoiSelection(series, strength, use);
}

/// Replaces flagged values by straight lines between the nearest good neighbours
/// (D-123 motion repair). Leading/trailing flagged values copy the nearest good one.
List<double> repairFlagged(List<double> y, List<bool> flagged) {
  final out = List<double>.of(y);
  for (var i = 0; i < out.length; i++) {
    if (flagged[i]) out[i] = double.nan;
  }
  return _fillGaps(out);
}

List<double> _fillGaps(List<double> y) {
  final out = List<double>.of(y);
  final good = [
    for (var i = 0; i < out.length; i++)
      if (!out[i].isNaN) i,
  ];
  if (good.isEmpty) return List<double>.filled(out.length, 0);
  for (var i = 0; i < good.first; i++) {
    out[i] = out[good.first];
  }
  for (var i = good.last + 1; i < out.length; i++) {
    out[i] = out[good.last];
  }
  for (var k = 1; k < good.length; k++) {
    final a = good[k - 1], b = good[k];
    for (var i = a + 1; i < b; i++) {
      out[i] = out[a] + (out[b] - out[a]) * (i - a) / (b - a);
    }
  }
  return out;
}
