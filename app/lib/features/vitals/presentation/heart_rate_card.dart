import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/enums.dart';
import '../../../core/utils/bp_classifier.dart';
import '../data/ppg_capture.dart';
import '../domain/ppg.dart';
import '../state/vitals_providers.dart';
import 'ppg_guide.dart';

/// "Measure Heart Rate" card (Fig 4.3.3.2, UC3.3). Shows a live camera preview so the
/// patient can place the fingertip, then measures. D-119: measuring starts by itself
/// once a fingertip has covered the lens for [autoStartDelay], shows a live reading
/// while it records, and the result shows the FFT cross-check. D-121: shorter copy with
/// a placement guide, the green channel the algorithm reads shown beside the camera,
/// live frame statistics and a technical summary of the result. Reports the measured or
/// manually entered heart rate through [onChanged]; null means none.
/// D-122: the heart rate and where it came from; both null when cleared.
typedef HeartRateChanged = void Function(int? bpm, HeartRateSource? source);

class HeartRateCard extends ConsumerStatefulWidget {
  const HeartRateCard({super.key, required this.onChanged, this.allowSkip = true});

  final HeartRateChanged onChanged;

  /// False in the symptom checker, where heart rate is compulsory (D-38): no Skip button;
  /// the camera or a typed pulse must provide it.
  final bool allowSkip;

  /// How long the fingertip must stay on the lens before measuring starts by itself.
  static const autoStartDelay = Duration(seconds: 1);

  @override
  ConsumerState<HeartRateCard> createState() => _HeartRateCardState();
}

enum _Phase { idle, opening, positioning, measuring, done, failed, unavailable, manual }

class _HeartRateCardState extends ConsumerState<HeartRateCard> {
  _Phase _phase = _Phase.idle;
  PpgLive _live = const PpgLive(progress: 0, signal: []);
  PpgResult? _result;
  Timer? _autoStart;
  String _message = '';
  final _manual = TextEditingController();
  // Kept so dispose() can stop the camera without touching ref.
  late final PpgCapture _capture;

  @override
  void initState() {
    super.initState();
    _capture = ref.read(ppgCaptureProvider);
    _capture.fingerDetected.addListener(_onFinger);
  }

  @override
  void dispose() {
    _autoStart?.cancel();
    _capture.fingerDetected.removeListener(_onFinger);
    _manual.dispose();
    _capture.cancel();
    super.dispose();
  }

  /// Step 1: camera + torch + live preview, so the patient can find the lens.
  Future<void> _openCamera() async {
    setState(() => _phase = _Phase.opening);
    try {
      await _capture.open();
      if (!mounted) return;
      setState(() => _phase = _Phase.positioning);
      _onFinger(); // the finger may already be on the lens
    } on PpgUnavailableException catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = _Phase.unavailable;
        _message = switch (e.reason) {
          PpgUnavailable.permissionDenied =>
            'Camera access was denied. Allow it in your phone settings, or enter your heart rate.',
          _ => 'The camera is not available on this device. You can enter your heart rate instead.',
        };
      });
    }
  }

  /// D-119: start measuring by itself once the fingertip has stayed on the lens.
  void _onFinger() {
    if (_phase != _Phase.positioning || !_capture.fingerDetected.value) {
      _autoStart?.cancel();
      _autoStart = null;
      return;
    }
    _autoStart ??= Timer(HeartRateCard.autoStartDelay, () {
      _autoStart = null;
      if (mounted && _phase == _Phase.positioning && _capture.fingerDetected.value) {
        _measure();
      }
    });
  }

  /// Step 2: record and estimate.
  Future<void> _measure() async {
    _autoStart?.cancel();
    _autoStart = null;
    setState(() {
      _phase = _Phase.measuring;
      _live = const PpgLive(progress: 0, signal: []);
    });
    final result = await _capture.measure(
      onProgress: (live) {
        if (mounted) setState(() => _live = live);
      },
    );
    await _capture.cancel(); // torch off as soon as the frames are in
    if (!mounted) return;
    if (result.ok) {
      setState(() {
        _phase = _Phase.done;
        _result = result;
      });
      widget.onChanged(result.bpm, HeartRateSource.camera);
    } else {
      // UC3.3 E1: poor signal -> reposition and retry, or skip.
      setState(() {
        _phase = _Phase.failed;
        _message = switch (result.failure) {
          PpgFailure.tooShort => 'The measurement stopped too early.',
          // D-119: the two methods disagreed, so no number is shown.
          PpgFailure.mismatch => 'The reading was not steady enough to confirm.',
          _ => 'We could not get a clear pulse signal.',
        };
      });
    }
  }

  Future<void> _stop() async {
    await _capture.cancel();
    if (mounted) setState(() => _phase = _Phase.idle);
  }

  void _skip() {
    setState(() {
      _phase = _Phase.idle;
      _result = null;
    });
    widget.onChanged(null, null);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      key: const Key('heart-rate-card'),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.tertiaryContainer.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 20,
                backgroundColor: scheme.surface,
                child: Icon(Icons.monitor_heart_outlined, color: scheme.tertiary),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Measure Heart Rate',
                  style: Theme.of(
                    context,
                  ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
                ),
              ),
              IconButton(
                key: const Key('ppg-guide-open'),
                tooltip: 'How to place your finger',
                onPressed: () => showPpgGuide(context),
                icon: const Icon(Icons.help_outline),
              ),
            ],
          ),
          const SizedBox(height: 8),
          _body(context),
        ],
      ),
    );
  }

  Widget _preview(double size, {bool green = false}) {
    final view = ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: SizedBox(
        width: size,
        height: size,
        child: FittedBox(
          fit: BoxFit.cover,
          clipBehavior: Clip.hardEdge,
          child: SizedBox(width: size, height: size, child: _capture.preview()),
        ),
      ),
    );
    if (!green) return KeyedSubtree(key: const Key('ppg-preview'), child: view);
    // D-121: the green channel the algorithm averages (docs/06 §B: G = Y - 0.344U - 0.714V),
    // with the centre region it samples outlined.
    return Stack(
      key: const Key('ppg-green-preview'),
      children: [
        ColorFiltered(colorFilter: greenChannelFilter, child: view),
        Positioned.fill(
          child: Padding(
            padding: EdgeInsets.all(size / 4),
            child: DecoratedBox(
              decoration: BoxDecoration(
                border: Border.all(color: Colors.white.withValues(alpha: 0.8), width: 1.5),
                borderRadius: BorderRadius.circular(4),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _labelled(String label, Widget child) => Column(
    children: [
      child,
      const SizedBox(height: 4),
      Text(label, style: Theme.of(context).textTheme.labelSmall),
    ],
  );

  /// Camera and green channel side by side.
  Widget _dualPreview(double size) => Row(
    mainAxisAlignment: MainAxisAlignment.center,
    children: [
      _labelled('Camera', _preview(size)),
      const SizedBox(width: 12),
      _labelled('Green channel', _preview(size, green: true)),
    ],
  );

  Widget _fingerHint() {
    return ValueListenableBuilder<bool>(
      valueListenable: _capture.fingerDetected,
      builder: (context, covered, _) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            covered ? Icons.check_circle : Icons.touch_app_outlined,
            size: 18,
            color: covered ? Colors.green : null,
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              covered ? 'Finger detected' : 'Cover the lens and the light with your fingertip',
              key: const Key('ppg-finger-hint'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _body(BuildContext context) {
    final theme = Theme.of(context);
    switch (_phase) {
      case _Phase.idle:
        return Column(
          children: [
            const SizedBox(height: 60, child: PhoneFingerIllustration()),
            const SizedBox(height: 8),
            const Text(
              'Cover the rear camera and flash with your index fingertip.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            FilledButton.tonalIcon(
              key: const Key('ppg-start'),
              onPressed: _openCamera,
              icon: const Icon(Icons.camera_outlined),
              label: const Text('Start camera'),
            ),
            TextButton(
              key: const Key('ppg-manual'),
              onPressed: () => setState(() => _phase = _Phase.manual),
              child: const Text('Enter heart rate manually'),
            ),
          ],
        );
      case _Phase.opening:
        return const Padding(padding: EdgeInsets.all(16), child: CircularProgressIndicator());
      case _Phase.positioning:
        return Column(
          key: const Key('ppg-positioning'),
          children: [
            _dualPreview(120),
            const SizedBox(height: 10),
            _fingerHint(),
            const SizedBox(height: 4),
            Text('Measuring starts by itself.', style: theme.textTheme.bodySmall),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              alignment: WrapAlignment.center,
              children: [
                FilledButton(
                  key: const Key('ppg-measure'),
                  onPressed: _measure,
                  child: const Text('Start measuring'),
                ),
                TextButton(onPressed: _stop, child: const Text('Cancel')),
              ],
            ),
          ],
        );
      case _Phase.measuring:
        final left = ((1 - _live.progress) * CameraPpgCapture.defaultDuration.inSeconds).ceil();
        return Column(
          key: const Key('ppg-measuring'),
          children: [
            _dualPreview(104),
            const SizedBox(height: 10),
            // D-119: live reading while recording.
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Icon(Icons.favorite, size: 20, color: Colors.red.shade400),
                const SizedBox(width: 6),
                Text(
                  _live.bpm == null ? 'Finding your pulse…' : '${_live.bpm} BPM',
                  key: const Key('ppg-live'),
                  style: _live.bpm == null
                      ? theme.textTheme.bodyMedium
                      : theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
                ),
              ],
            ),
            if (_live.bpm != null) Text('Live estimate', style: theme.textTheme.bodySmall),
            const SizedBox(height: 8),
            Container(
              height: 56,
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              decoration: BoxDecoration(
                color: theme.colorScheme.surface,
                borderRadius: BorderRadius.circular(10),
              ),
              child: CustomPaint(painter: _TracePainter(_live.signal, Colors.green.shade600)),
            ),
            const SizedBox(height: 2),
            Align(
              alignment: Alignment.centerLeft,
              child: Text('Pulse signal (green intensity)', style: theme.textTheme.labelSmall),
            ),
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(value: _live.progress, minHeight: 6),
            ),
            const SizedBox(height: 4),
            Text('Keep still · $left s left', key: const Key('ppg-time-left')),
            const SizedBox(height: 8),
            _LiveStats(live: _live),
            const SizedBox(height: 6),
            _fingerHint(),
            TextButton(onPressed: _stop, child: const Text('Cancel')),
          ],
        );
      case _Phase.done:
        final r = _result!;
        return Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.favorite, color: Colors.red.shade400, size: 28),
                const SizedBox(width: 8),
                Text(
                  '${r.bpm} BPM',
                  key: const Key('ppg-result'),
                  style: theme.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w700),
                ),
              ],
            ),
            // Ch1 limitation: camera PPG is supplementary and less accurate than a device.
            if (r.fftBpm != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Row(
                  key: const Key('ppg-crosscheck'),
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.verified_outlined, size: 16, color: Colors.green.shade700),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text(
                        'Cross-checked: beat count ${r.bpm} · frequency (FFT) ${r.fftBpm} BPM',
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 4),
            Text(
              'Estimate from your phone camera, not a medical device.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            _TechnicalDetails(result: r, live: _live),
            const SizedBox(height: 4),
            Text(
              'Looks off? Measure again: two close readings are more reliable.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall,
            ),
            TextButton(onPressed: _openCamera, child: const Text('Measure again')),
          ],
        );
      case _Phase.failed:
      case _Phase.unavailable:
        return Column(
          key: Key(_phase == _Phase.failed ? 'ppg-failed' : 'ppg-unavailable'),
          children: [
            Text(_message, textAlign: TextAlign.center),
            if (_phase == _Phase.failed)
              TextButton(
                onPressed: () => showPpgGuide(context),
                child: const Text('See how to place your finger'),
              ),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 8,
              children: [
                if (_phase == _Phase.failed)
                  FilledButton(
                    key: const Key('ppg-retry'),
                    onPressed: _openCamera,
                    child: const Text('Retry'),
                  ),
                if (widget.allowSkip)
                  OutlinedButton(
                    key: const Key('ppg-skip'),
                    onPressed: _skip,
                    child: const Text('Skip'),
                  ),
                TextButton(
                  onPressed: () => setState(() => _phase = _Phase.manual),
                  child: const Text('Enter manually'),
                ),
              ],
            ),
          ],
        );
      case _Phase.manual:
        return Row(
          children: [
            Expanded(
              child: TextField(
                key: const Key('hr-manual-input'),
                controller: _manual,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: const InputDecoration(labelText: 'Heart rate', suffixText: 'bpm'),
                onChanged: (v) {
                  final n = int.tryParse(v);
                  final ok =
                      n != null && n >= BpClassifier.heartRateMin && n <= BpClassifier.heartRateMax;
                  widget.onChanged(ok ? n : null, ok ? HeartRateSource.manual : null);
                },
              ),
            ),
            TextButton(onPressed: _skip, child: const Text('Clear')),
          ],
        );
    }
  }
}

/// D-121: keeps only the green channel of the camera picture (R and B set to 0).
const greenChannelFilter = ColorFilter.matrix(<double>[
  0, 0, 0, 0, 0, //
  0, 1, 0, 0, 0, //
  0, 0, 0, 0, 0, //
  0, 0, 0, 1, 0, //
]);

/// D-121: live frame statistics while recording.
class _LiveStats extends StatelessWidget {
  const _LiveStats({required this.live});

  final PpgLive live;

  @override
  Widget build(BuildContext context) {
    Widget chip(String label, String value) => Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 6),
        margin: const EdgeInsets.symmetric(horizontal: 3),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          children: [
            Text(
              value,
              style: Theme.of(
                context,
              ).textTheme.titleSmall?.copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
            ),
            Text(label, style: Theme.of(context).textTheme.labelSmall),
          ],
        ),
      ),
    );
    return Row(
      key: const Key('ppg-stats'),
      children: [
        chip('frames', '${live.frames}'),
        chip('frame rate', '${live.fps.toStringAsFixed(1)} fps'),
        chip('green level', live.green == null ? '—' : live.green!.toStringAsFixed(1)),
      ],
    );
  }
}

/// D-121: how the number was produced, for the curious (and the examiner).
class _TechnicalDetails extends StatelessWidget {
  const _TechnicalDetails({required this.result, required this.live});

  final PpgResult result;
  final PpgLive live;

  @override
  Widget build(BuildContext context) {
    const config = PpgConfig();
    final seconds = live.fps > 0 ? live.frames / live.fps : 0.0;
    final rows = [
      ('Frames analysed', '${live.frames}'),
      ('Frame rate', '${live.fps.toStringAsFixed(1)} fps'),
      ('Recording', '${seconds.toStringAsFixed(1)} s'),
      ('Signal', 'Mean green per frame (YUV → G)'),
      (
        'Band-pass filter',
        '${config.lowHz}–${config.highHz} Hz '
            '(${(config.lowHz * 60).round()}–${(config.highHz * 60).round()} bpm)',
      ),
      ('Beat count (peaks)', '${result.bpm} BPM'),
      if (result.fftBpm != null) ('Frequency (FFT)', '${result.fftBpm} BPM'),
      ('Signal quality', '${(result.quality * 100).round()}%'),
    ];
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surface,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: Theme(
        data: theme.copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          key: const Key('ppg-tech'),
          dense: true,
          leading: const Icon(Icons.analytics_outlined, size: 20),
          title: const Text('Technical details'),
          childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          children: [
            for (final (label, value) in rows)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  children: [
                    Expanded(child: Text(label, style: theme.textTheme.bodySmall)),
                    Text(
                      value,
                      style: theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _TracePainter extends CustomPainter {
  _TracePainter(this.values, this.color);

  final List<double> values;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (values.length < 2) return;
    final lo = values.reduce((a, b) => a < b ? a : b);
    final hi = values.reduce((a, b) => a > b ? a : b);
    final range = (hi - lo).abs() < 1e-6 ? 1.0 : hi - lo;
    final path = Path();
    for (var i = 0; i < values.length; i++) {
      final x = size.width * i / (values.length - 1);
      final y = size.height * (1 - (values[i] - lo) / range);
      i == 0 ? path.moveTo(x, y) : path.lineTo(x, y);
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
  }

  @override
  bool shouldRepaint(_TracePainter old) => old.values != values;
}
