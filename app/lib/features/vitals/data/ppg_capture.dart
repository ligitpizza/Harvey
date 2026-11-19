import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../domain/ppg.dart';
import '../domain/ppg_image.dart';

/// Why a camera measurement could not run at all (as opposed to a noisy signal).
enum PpgUnavailable { noCamera, permissionDenied, notSupported }

class PpgUnavailableException implements Exception {
  const PpgUnavailableException(this.reason);
  final PpgUnavailable reason;
}

/// Live progress while measuring (D-119, D-121): how far along, the recent green signal
/// for the trace, the live heart-rate reading so far (null until a clear pulse is found)
/// and frame statistics for the technical readout.
class PpgLive {
  const PpgLive({
    required this.progress,
    required this.signal,
    this.bpm,
    this.frames = 0,
    this.fps = 0,
    this.green,
  });

  /// 0..1 of the measurement window.
  final double progress;

  /// The most recent mean-green values (about 3 s), one per frame.
  final List<double> signal;
  final int? bpm;

  /// Frames recorded so far and the rate they arrive at.
  final int frames;
  final double fps;

  /// Mean green intensity of the latest frame (0..255).
  final double? green;
}

/// D-123: what the image stage sees in the latest frame, for the live hints.
class PpgFrameInfo {
  const PpgFrameInfo({this.coverage = 0, this.moving = false, this.pressingHard = false});

  /// Share of the picture classified as lit fingertip, 0..1.
  final double coverage;

  /// Frame differencing flagged movement.
  final bool moving;

  /// Many saturated pixels: the finger presses too hard.
  final bool pressingHard;
}

typedef PpgProgress = void Function(PpgLive live);

/// Camera PPG capture (FR-3.2, UC3.3). Two steps so the patient can see the lens
/// before measuring: [open] starts the camera + torch and a live preview,
/// [measure] then records for the measurement window. Behind an interface so
/// screens are tested without a camera.
abstract interface class PpgCapture {
  /// Starts the rear camera, torch and live preview. Throws [PpgUnavailableException].
  Future<void> open();

  /// Live camera view; only meaningful after [open].
  Widget preview();

  /// True while the lens looks covered by a fingertip (a hint, not a gate).
  ValueListenable<bool> get fingerDetected;

  /// D-123: coverage, motion and pressure of the latest frame.
  ValueListenable<PpgFrameInfo> get frameInfo;

  /// Records for [duration] and returns the estimate. Requires [open].
  Future<PpgResult> measure({required PpgProgress onProgress, Duration duration});

  /// Stops measuring, turns the torch off and releases the camera.
  Future<void> cancel();
}

/// Rear camera + torch. Each frame goes through the image stage (D-123, [analyzeFrame]);
/// the signal stage runs in an isolate.
class CameraPpgCapture implements PpgCapture {
  static const defaultDuration = Duration(seconds: 15);

  CameraController? _controller;
  final _finger = ValueNotifier<bool>(false);
  final _info = ValueNotifier<PpgFrameInfo>(const PpgFrameInfo());
  Float64List? _previousThumb;

  // Active measurement, if any.
  Completer<void>? _done;
  Stopwatch? _clock;
  Duration _duration = defaultDuration;
  PpgProgress? _onProgress;
  final _times = <double>[];
  final _values = <double>[];
  final _blocks = <List<double>>[];
  final _moving = <bool>[];

  // D-119 live reading: re-estimated about once a second from the frames so far.
  static const _liveEvery = Duration(seconds: 1);
  static const _liveAfter = Duration(milliseconds: 6500); // settle 1.5 s + 5 s
  int? _liveBpm;
  bool _liveBusy = false;
  Duration _lastLive = Duration.zero;

  @override
  ValueListenable<bool> get fingerDetected => _finger;

  @override
  ValueListenable<PpgFrameInfo> get frameInfo => _info;

  @override
  Future<void> open() async {
    if (kIsWeb) throw const PpgUnavailableException(PpgUnavailable.notSupported);
    if (_controller != null) return;
    final List<CameraDescription> cameras;
    try {
      cameras = await availableCameras();
    } on CameraException {
      throw const PpgUnavailableException(PpgUnavailable.noCamera);
    }
    final back = cameras.where((c) => c.lensDirection == CameraLensDirection.back).firstOrNull;
    if (back == null) throw const PpgUnavailableException(PpgUnavailable.noCamera);

    final controller = CameraController(
      back,
      ResolutionPreset.low,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.yuv420,
    );
    _controller = controller;
    try {
      await controller.initialize();
      await controller.setFlashMode(FlashMode.torch);
      await controller.startImageStream(_onFrame);
    } on CameraException catch (e) {
      await _release();
      throw PpgUnavailableException(
        e.code.contains('Denied') ? PpgUnavailable.permissionDenied : PpgUnavailable.noCamera,
      );
    }
  }

  @override
  Widget preview() {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return const SizedBox.shrink();
    return CameraPreview(c);
  }

  void _onFrame(CameraImage image) {
    if (image.planes.length < 3) return;
    final y = image.planes[0];
    final u = image.planes[1];
    final v = image.planes[2];
    final frame = analyzeFrame(
      YuvFrame(
        width: image.width,
        height: image.height,
        y: y.bytes,
        yRowStride: y.bytesPerRow,
        u: u.bytes,
        v: v.bytes,
        uvRowStride: u.bytesPerRow,
        uvPixelStride: u.bytesPerPixel ?? 1,
      ),
      previousThumb: _previousThumb,
    );
    _previousThumb = frame.thumb;
    _finger.value = frame.covered;
    _info.value = PpgFrameInfo(
      coverage: frame.coverage,
      moving: frame.moving,
      pressingHard: frame.pressingHard,
    );

    final done = _done;
    final clock = _clock;
    if (done == null || clock == null || done.isCompleted) return;
    _times.add(clock.elapsedMicroseconds / 1e6);
    _values.add(frame.green);
    _blocks.add(frame.blockGreen);
    _moving.add(frame.moving);
    final p = (clock.elapsed.inMilliseconds / _duration.inMilliseconds).clamp(0.0, 1.0);
    final start = _values.length > 90 ? _values.length - 90 : 0;
    final secs = clock.elapsedMicroseconds / 1e6;
    _onProgress?.call(
      PpgLive(
        progress: p,
        signal: _values.sublist(start),
        bpm: _liveBpm,
        frames: _values.length,
        fps: secs > 0 ? _values.length / secs : 0,
        green: frame.green,
      ),
    );
    _maybeUpdateLive(clock.elapsed);
    if (clock.elapsed >= _duration) done.complete();
  }

  void _maybeUpdateLive(Duration elapsed) {
    if (_liveBusy || elapsed < _liveAfter || elapsed - _lastLive < _liveEvery) return;
    _liveBusy = true;
    _lastLive = elapsed;
    compute(liveHeartRate, _input())
        .then((bpm) {
          // Keep the last good value through a noisy second rather than flicker.
          if (bpm != null && _done != null) _liveBpm = bpm;
        })
        .whenComplete(() => _liveBusy = false);
  }

  @override
  Future<PpgResult> measure({
    required PpgProgress onProgress,
    Duration duration = defaultDuration,
  }) async {
    await open();
    _times.clear();
    _values.clear();
    _blocks.clear();
    _moving.clear();
    _liveBpm = null;
    _lastLive = Duration.zero;
    _duration = duration;
    _onProgress = onProgress;
    _clock = Stopwatch()..start();
    final done = Completer<void>();
    _done = done;
    await done.future;
    _done = null;
    _clock = null;
    _onProgress = null;
    if (_values.length < 2) return const PpgResult.failed(PpgFailure.tooShort);
    return compute(estimateHeartRate, _input());
  }

  PpgInput _input() => PpgInput(
    List.of(_times),
    List.of(_values),
    blockGreens: List.of(_blocks),
    moving: List.of(_moving),
  );

  @override
  Future<void> cancel() async {
    final done = _done;
    if (done != null && !done.isCompleted) done.complete();
    await _release();
  }

  Future<void> _release() async {
    final c = _controller;
    _controller = null;
    _finger.value = false;
    _info.value = const PpgFrameInfo();
    _previousThumb = null;
    if (c == null) return;
    try {
      if (c.value.isStreamingImages) await c.stopImageStream();
      await c.setFlashMode(FlashMode.off);
    } catch (_) {
      // Already stopped or disposed.
    }
    await c.dispose();
  }
}
