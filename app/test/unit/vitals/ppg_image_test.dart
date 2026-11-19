import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hypertension/features/vitals/domain/ppg.dart';
import 'package:hypertension/features/vitals/domain/ppg_image.dart';

// D-123: the image-processing stage of camera PPG, tested with synthetic YUV frames.

const w = 64, h = 48;

/// A frame where [pixel] gives (Y, Cb, Cr) for each (x, y). Chroma is sampled at the
/// top-left pixel of each 2x2 block, as in YUV420.
YuvFrame frame((int, int, int) Function(int x, int y) pixel) {
  final y = Uint8List(w * h);
  final u = Uint8List((w ~/ 2) * (h ~/ 2));
  final v = Uint8List((w ~/ 2) * (h ~/ 2));
  for (var r = 0; r < h; r++) {
    for (var c = 0; c < w; c++) {
      final (luma, cb, cr) = pixel(c, r);
      y[r * w + c] = luma.clamp(0, 255);
      if (r.isEven && c.isEven) {
        u[(r ~/ 2) * (w ~/ 2) + c ~/ 2] = (cb + 128).clamp(0, 255);
        v[(r ~/ 2) * (w ~/ 2) + c ~/ 2] = (cr + 128).clamp(0, 255);
      }
    }
  }
  return YuvFrame(width: w, height: h, y: y, yRowStride: w, u: u, v: v, uvRowStride: w ~/ 2);
}

/// Torch-lit fingertip: bright and strongly red.
(int, int, int) finger(int x, int y) => (120, -10, 60);

void main() {
  const config = PpgImageConfig(step: 2);

  group('colour conversion and segmentation', () {
    test('a fingertip frame is fully covered and gives G = Y - 0.344Cb - 0.714Cr', () {
      final a = analyzeFrame(frame(finger), config: config);
      expect(a.coverage, 1);
      expect(a.covered, isTrue);
      expect(a.green, closeTo(120 + 0.344 * 10 - 0.714 * 60, 1e-6));
      expect(a.blockGreen.every((g) => !g.isNaN), isTrue);
      expect(a.darkFraction, 0);
      expect(a.saturatedFraction, 0);
    });

    test('a half-covered lens is about 50% and not "detected"', () {
      final a = analyzeFrame(
        frame((x, y) => x < w ~/ 2 ? finger(x, y) : (10, 0, 0)),
        config: config,
      );
      expect(a.coverage, closeTo(0.5, 0.05));
      expect(a.covered, isFalse);
      expect(a.darkFraction, closeTo(0.5, 0.05)); // the unlit half is masked as dark
      // Right-hand blocks have no usable pixels.
      expect(a.blockGreen[3].isNaN, isTrue);
      expect(a.blockGreen[0].isNaN, isFalse);
    });

    test('an uncovered room scene (grey, not red) has no coverage', () {
      final a = analyzeFrame(frame((x, y) => (140, 0, 0)), config: config);
      expect(a.coverage, 0);
    });
  });

  group('histogram masking', () {
    test('saturated pixels are left out of the average and flag pressing too hard', () {
      final a = analyzeFrame(
        frame((x, y) => y < h ~/ 2 ? (250, -10, 60) : finger(x, y)),
        config: config,
      );
      expect(a.saturatedFraction, closeTo(0.5, 0.05));
      expect(a.pressingHard, isTrue);
      // Only the unsaturated half contributes.
      expect(a.green, closeTo(120 + 0.344 * 10 - 0.714 * 60, 1e-6));
      expect(a.blockGreen[0].isNaN, isTrue); // top-left block: all saturated
    });
  });

  group('frame differencing', () {
    test('a steady finger is not moving; a shifted picture is', () {
      final first = analyzeFrame(frame(finger), config: config);
      final same = analyzeFrame(frame(finger), previousThumb: first.thumb, config: config);
      expect(same.motion, 0);
      expect(same.moving, isFalse);
      // A pulse-sized change (1-2 luma levels) is not motion.
      final pulse = analyzeFrame(
        frame((x, y) => (122, -10, 60)),
        previousThumb: first.thumb,
        config: config,
      );
      expect(pulse.moving, isFalse);
      // The finger slides: half the picture changes a lot.
      final slid = analyzeFrame(
        frame((x, y) => x < w ~/ 2 ? (60, -10, 60) : finger(x, y)),
        previousThumb: first.thumb,
        config: config,
      );
      expect(slid.moving, isTrue);
    });
  });

  group('signal stage with the image features', () {
    // 15 s at 30 fps; blocks 0-3 (top row) carry a clean 72 bpm pulse, the rest noise.
    PpgInput gridInput({List<bool>? moving, int seed = 3}) {
      final rnd = math.Random(seed);
      final t = <double>[];
      final blocks = <List<double>>[];
      for (var i = 0; i < 450; i++) {
        final ti = i / 30;
        t.add(ti);
        final pulse = math.sin(2 * math.pi * 1.2 * ti);
        blocks.add([
          for (var b = 0; b < 16; b++)
            b < 4 ? 100 + pulse + 0.1 * rnd.nextDouble() : 100 + 3 * (rnd.nextDouble() - 0.5),
        ]);
      }
      final mean = [for (final f in blocks) f.reduce((a, b) => a + b) / f.length];
      return PpgInput(t, mean, blockGreens: blocks, moving: moving);
    }

    test('adaptive ROI keeps the pulsing blocks', () {
      final r = estimateHeartRate(gridInput());
      expect(r.ok, isTrue, reason: '${r.failure}');
      expect((r.bpm! - 72).abs(), lessThanOrEqualTo(3));
      expect(r.roiBlocks, [0, 1, 2, 3]);
      expect(r.blockStrength[0], greaterThan(r.blockStrength[10]));
    });

    test('a few moving frames are bridged; too many fail as motion', () {
      final some = List<bool>.generate(450, (i) => i >= 200 && i < 215);
      final input = gridInput(moving: some);
      // Corrupt the flagged frames like a jolt would.
      for (var i = 200; i < 215; i++) {
        input.blockGreens![i] = List<double>.filled(16, 160);
      }
      final ok = estimateHeartRate(input);
      expect(ok.ok, isTrue, reason: '${ok.failure}');
      expect((ok.bpm! - 72).abs(), lessThanOrEqualTo(3));
      expect(ok.motionFrames, 15);

      final many = List<bool>.generate(450, (i) => i % 3 == 0);
      expect(estimateHeartRate(gridInput(moving: many)).failure, PpgFailure.motion);
    });

    test('repairFlagged draws straight lines over flagged values', () {
      expect(repairFlagged([1, 99, 99, 4], [false, true, true, false]), [1, 2, 3, 4]);
      expect(repairFlagged([99, 2, 99], [true, false, true]), [2, 2, 2]);
    });

    test('pulse strength is high for a sine and low for noise', () {
      final t = [for (var i = 0; i < 450; i++) i / 30.0];
      final rnd = math.Random(5);
      expect(
        pulseStrength(t, [for (final x in t) math.sin(2 * math.pi * 1.2 * x)]),
        greaterThan(0.8),
      );
      expect(pulseStrength(t, [for (final _ in t) rnd.nextDouble()]), lessThan(0.4));
    });
  });
}
