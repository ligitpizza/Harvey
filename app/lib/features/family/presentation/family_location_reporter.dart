import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../auth/state/auth_providers.dart';
import '../state/family_providers.dart';

/// D-80: keeps the family map's "last known location" fresh. When the patient app opens
/// or returns to the screen, and every [every] while it stays open, it saves where the
/// phone is, unless the patient switched sharing off or location isn't allowed. It never
/// asks for permission itself (Settings and SOS do).
class FamilyLocationReporter extends ConsumerStatefulWidget {
  const FamilyLocationReporter({
    super.key,
    required this.child,
    this.every = const Duration(minutes: 15),
    this.minGap = const Duration(minutes: 5),
  });

  final Widget child;
  final Duration every;

  /// Don't save again sooner than this (tab switches, quick resumes).
  final Duration minGap;

  @override
  ConsumerState<FamilyLocationReporter> createState() => _FamilyLocationReporterState();
}

class _FamilyLocationReporterState extends ConsumerState<FamilyLocationReporter>
    with WidgetsBindingObserver {
  Timer? _timer;
  DateTime? _last;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _report());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _report();
    } else if (state == AppLifecycleState.paused) {
      _timer?.cancel();
      _timer = null;
    }
  }

  Future<void> _report({bool force = false}) async {
    final now = DateTime.now();
    if (!force && _last != null && now.difference(_last!) < widget.minGap) return;
    try {
      final uid = ref.read(authUidProvider).value;
      if (uid == null) return;
      final repo = ref.read(patientLocationRepositoryProvider);
      final saved = await repo.watch(uid).first;
      if (saved != null && !saved.sharing) {
        // The patient switched it off: no background updates either.
        await ref.read(backgroundLocationProvider).stop();
        return;
      }
      final source = ref.read(locationSourceProvider);
      if (!await source.granted()) return;
      final loc = await source.current();
      if (loc == null || !mounted) return;
      await repo.save(uid, lat: loc['lat']!, lng: loc['lng']!);
      _last = now;
      // Only once sharing works: keep it fresh while the app stays open, and while it
      // is closed when "Allow all the time" is granted (start() checks that).
      _timer ??= Timer.periodic(widget.every, (_) => _report(force: true));
      await ref.read(backgroundLocationProvider).start();
    } catch (_) {
      // Offline or signed out: try again on the next resume.
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // The signed-in user can arrive after the first frame.
    ref.listen(authUidProvider, (prev, next) {
      if (next.value != null && prev?.value != next.value) _report();
    });
    return widget.child;
  }
}
