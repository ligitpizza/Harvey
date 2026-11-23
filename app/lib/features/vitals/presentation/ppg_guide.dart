import 'package:flutter/material.dart';

/// D-121: how to place the finger for a camera heart-rate reading. Opened from the
/// Measure Heart Rate card so the card itself stays short.
Future<void> showPpgGuide(BuildContext context) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (_) => const PpgGuide(),
);

/// The steps, also used by tests.
const ppgGuideSteps = [
  (
    Icons.back_hand_outlined,
    'Use your index finger',
    'The fingertip of either hand. Warm hands give a clearer signal.',
  ),
  (
    Icons.flashlight_on_outlined,
    'Cover the camera and the flash',
    'Lay the soft pad of your fingertip over the rear lens and the light beside it.',
  ),
  (
    Icons.touch_app_outlined,
    'Touch lightly',
    'Do not press hard: pressing squeezes the blood out and hides the pulse.',
  ),
  (
    Icons.thermostat_outlined,
    'Measure somewhere warm',
    'Cold rooms and cold hands narrow the blood vessels in your fingertip, which weakens the '
        'pulse. Rub your hands together or wait a few minutes in a warm room first.',
  ),
  (
    Icons.self_improvement_outlined,
    'Rest and keep still for 15 s',
    'Sit down, rest your arm on a table and do not talk while it measures.',
  ),
];

class PpgGuide extends StatelessWidget {
  const PpgGuide({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: SingleChildScrollView(
        key: const Key('ppg-guide'),
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'How to place your finger',
              style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 12),
            const Center(
              child: SizedBox(width: 150, height: 170, child: PhoneFingerIllustration()),
            ),
            const SizedBox(height: 12),
            for (final (i, step) in ppgGuideSteps.indexed)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    CircleAvatar(
                      radius: 16,
                      backgroundColor: theme.colorScheme.tertiaryContainer,
                      child: Text(
                        '${i + 1}',
                        style: TextStyle(
                          color: theme.colorScheme.onTertiaryContainer,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(step.$1, size: 18, color: theme.colorScheme.tertiary),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(
                                  step.$2,
                                  style: theme.textTheme.titleSmall?.copyWith(
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 2),
                          Text(step.$3, style: theme.textTheme.bodyMedium),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: theme.colorScheme.secondaryContainer.withValues(alpha: 0.6),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.tips_and_updates_outlined, size: 20),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'The picture turns evenly red when your finger is placed well. If a '
                      'number looks wrong, measure once more: two close readings are more '
                      'reliable than one.',
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                key: const Key('ppg-guide-close'),
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Got it'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The back of a phone with the camera and flash, and a fingertip covering both.
class PhoneFingerIllustration extends StatelessWidget {
  const PhoneFingerIllustration({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return CustomPaint(
      painter: _PhoneFingerPainter(
        body: scheme.surfaceContainerHighest,
        outline: scheme.outline,
        lens: scheme.onSurface,
        finger: const Color(0xFFE9A98B),
      ),
    );
  }
}

class _PhoneFingerPainter extends CustomPainter {
  _PhoneFingerPainter({
    required this.body,
    required this.outline,
    required this.lens,
    required this.finger,
  });

  final Color body;
  final Color outline;
  final Color lens;
  final Color finger;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    // Phone back.
    final phone = RRect.fromRectAndRadius(
      Rect.fromLTWH(w * 0.12, 0, w * 0.76, h),
      Radius.circular(w * 0.12),
    );
    canvas.drawRRect(phone, Paint()..color = body);
    canvas.drawRRect(
      phone,
      Paint()
        ..color = outline
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
    // Camera lens and flash (top left).
    final lensC = Offset(w * 0.34, h * 0.14);
    final flashC = Offset(w * 0.34, h * 0.27);
    canvas.drawCircle(lensC, w * 0.08, Paint()..color = lens);
    canvas.drawCircle(lensC, w * 0.04, Paint()..color = outline);
    canvas.drawCircle(flashC, w * 0.04, Paint()..color = const Color(0xFFFFE08A));
    // Fingertip coming from below, covering both (semi-transparent so they show through).
    final tip = Path()
      ..moveTo(w * 0.18, h * 0.62)
      ..lineTo(w * 0.18, h * 0.2)
      ..quadraticBezierTo(w * 0.18, h * 0.04, w * 0.34, h * 0.04)
      ..quadraticBezierTo(w * 0.5, h * 0.04, w * 0.5, h * 0.2)
      ..lineTo(w * 0.5, h * 0.62)
      ..close();
    canvas.drawPath(tip, Paint()..color = finger.withValues(alpha: 0.8));
    canvas.drawPath(
      tip,
      Paint()
        ..color = finger.withValues(alpha: 1)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
    // Nail outline hint.
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(w * 0.25, h * 0.08, w * 0.18, h * 0.1),
        Radius.circular(w * 0.06),
      ),
      Paint()
        ..color = Colors.white.withValues(alpha: 0.5)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
  }

  @override
  bool shouldRepaint(_PhoneFingerPainter old) => old.body != body || old.lens != lens;
}
