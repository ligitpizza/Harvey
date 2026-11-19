import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:hypertension/features/vitals/domain/ppg.dart';

/// Synthetic PPG: pulse at [bpm] plus slow baseline drift, Gaussian noise and
/// optional frame-timing jitter, like a phone camera at ~30 fps.
PpgInput synth(
  double bpm, {
  double seconds = 15,
  double fps = 30,
  double noise = 0.15,
  double jitter = 0.004,
  int seed = 1,
}) {
  final rnd = math.Random(seed);
  double gauss() {
    final u1 = rnd.nextDouble().clamp(1e-12, 1.0);
    final u2 = rnd.nextDouble();
    return math.sqrt(-2 * math.log(u1)) * math.cos(2 * math.pi * u2);
  }

  final t = <double>[];
  final y = <double>[];
  final f = bpm / 60;
  for (var i = 0; i < seconds * fps; i++) {
    final ti = i / fps + (i == 0 ? 0 : jitter * (rnd.nextDouble() - 0.5));
    // Sharp systolic upstroke + smaller dicrotic wave, like a real PPG.
    final pulse = math.sin(2 * math.pi * f * ti) + 0.35 * math.sin(4 * math.pi * f * ti + 0.8);
    final drift = 3 * math.sin(2 * math.pi * 0.05 * ti) + 0.4 * ti;
    t.add(ti);
    y.add(120 + pulse + drift + noise * gauss());
  }
  return PpgInput(t, y);
}

void main() {
  group('FR-3.2 PPG estimates known heart rates (Objective 1, unit verified)', () {
    for (final bpm in [50.0, 60.0, 72.0, 90.0, 120.0, 150.0]) {
      for (final seed in [1, 2, 3]) {
        test('UC3.3 $bpm bpm, noise seed $seed within ±3 bpm', () {
          final r = estimateHeartRate(synth(bpm, seed: seed));
          expect(r.ok, isTrue, reason: 'failure: ${r.failure}');
          expect((r.bpm! - bpm).abs(), lessThanOrEqualTo(3));
          expect(r.quality, greaterThan(0.5));
        });
      }
    }

    test('works at a lower, uneven frame rate (24 fps with jitter)', () {
      final r = estimateHeartRate(synth(80, fps: 24, jitter: 0.01));
      expect(r.ok, isTrue);
      expect((r.bpm! - 80).abs(), lessThanOrEqualTo(3));
    });
  });

  group('UC3.3 E1 poor signal is rejected (retry or skip)', () {
    test('pure noise fails', () {
      final rnd = math.Random(7);
      final t = [for (var i = 0; i < 450; i++) i / 30.0];
      final y = [for (var i = 0; i < 450; i++) 120 + rnd.nextDouble() * 4];
      final r = estimateHeartRate(PpgInput(t, y));
      expect(r.ok, isFalse);
    });

    test('flat signal (no finger / frozen frames) fails with noSignal', () {
      final t = [for (var i = 0; i < 450; i++) i / 30.0];
      final r = estimateHeartRate(PpgInput(t, List.filled(450, 128.0)));
      expect(r.failure, PpgFailure.noSignal);
    });

    test('too short a capture fails with tooShort', () {
      expect(estimateHeartRate(synth(70, seconds: 5)).failure, PpgFailure.tooShort);
      expect(estimateHeartRate(const PpgInput([0], [1])).failure, PpgFailure.tooShort);
    });

    test('very noisy signal does not produce a confident wrong answer', () {
      final r = estimateHeartRate(synth(75, noise: 3));
      if (r.ok) expect((r.bpm! - 75).abs(), lessThanOrEqualTo(5));
    });
  });

  group('D-119 FFT cross-check', () {
    test('FFT of a pure sine finds its frequency', () {
      for (final bpm in [45.0, 72.0, 110.0, 180.0]) {
        final x = [for (var i = 0; i < 360; i++) math.sin(2 * math.pi * bpm / 60 * i / 30)];
        expect(spectralBpm(x, 30)!, closeTo(bpm, 1.5));
      }
    });

    test('fft matches a direct DFT', () {
      final x = [for (var i = 0; i < 16; i++) math.cos(i * 0.7) + 0.3 * i];
      final re = List.of(x), im = List<double>.filled(16, 0);
      fft(re, im);
      for (var k = 0; k < 16; k++) {
        var r = 0.0, m = 0.0;
        for (var i = 0; i < 16; i++) {
          r += x[i] * math.cos(-2 * math.pi * k * i / 16);
          m += x[i] * math.sin(-2 * math.pi * k * i / 16);
        }
        expect(re[k], closeTo(r, 1e-9));
        expect(im[k], closeTo(m, 1e-9));
      }
    });

    test('a flat signal has no spectral peak', () {
      expect(spectralBpm(List.filled(300, 5.0), 30), isNull);
    });

    test('accepted results carry an FFT estimate that agrees', () {
      for (final bpm in [60.0, 90.0, 150.0]) {
        final r = estimateHeartRate(synth(bpm));
        expect(r.ok, isTrue);
        expect(methodsAgree(r.bpm!, r.fftBpm!.toDouble()), isTrue);
        expect((r.fftBpm! - bpm).abs(), lessThanOrEqualTo(3));
      }
    });

    test('agreement allows 8 bpm or 10%, whichever is larger', () {
      expect(methodsAgree(70, 77.9), isTrue);
      expect(methodsAgree(70, 78.5), isFalse);
      expect(methodsAgree(150, 164), isTrue);
      expect(methodsAgree(150, 166), isFalse);
    });
  });

  group('D-119 live reading', () {
    test('appears once there is enough signal', () {
      expect(liveHeartRate(synth(72, seconds: 4)), isNull);
      expect((liveHeartRate(synth(72, seconds: 8))! - 72).abs(), lessThanOrEqualTo(3));
    });
  });

  group('signal helpers', () {
    test('resample produces an even grid at the requested rate', () {
      final out = resample([0, 0.5, 1.0], [0, 5, 10], 10);
      expect(out.length, 11);
      expect(out[5], closeTo(5, 1e-9));
      expect(out.last, closeTo(10, 1e-9));
    });

    test('band-pass removes a constant offset and slow drift', () {
      final x = [for (var i = 0; i < 600; i++) 100 + 0.5 * i / 30];
      final y = bandPass(x, 30, 0.67, 3.3);
      final mid = y.sublist(60, 540);
      expect(mid.map((v) => v.abs()).reduce(math.max), lessThan(0.05));
    });

    test('peaks are at least one shortest beat apart', () {
      final x = [for (var i = 0; i < 300; i++) math.sin(2 * math.pi * 1.5 * i / 30)];
      final peaks = detectPeaks(x, 30);
      for (var i = 1; i < peaks.length; i++) {
        expect(peaks[i] - peaks[i - 1], greaterThanOrEqualTo((30 * 60 / maxBpm).floor()));
      }
      expect(peaks.length, closeTo(15, 1));
    });
  });
}
