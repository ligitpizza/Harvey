import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../features/auth/data/auth_repository.dart';
import '../features/auth/state/auth_providers.dart';
import '../features/medications/state/medication_providers.dart';
import '../features/messaging/state/messaging_providers.dart';
import '../features/notifications/state/notification_providers.dart';
import '../shared/services/push/notification_taps.dart';
import 'constants/enums.dart';
import '../shared/providers/api_providers.dart';
import 'theme/app_theme.dart';
import 'theme/theme_mode.dart';

/// D-80: taps on phone notifications (pushes, dose reminders).
final notificationTapProvider = StreamProvider<Map<String, String>>(
  (ref) => NotificationTaps.stream,
);

/// D-80: open the screen a tapped phone notification is about (patient app), with the
/// same mapping as the bell. Bottom tabs are switched to; other pages are pushed on top
/// of the current screen (or of Home when the app is still on its start screen).
void openNotificationTap(WidgetRef ref, GoRouter router, Map<String, String> data) {
  final user = ref.read(currentUserProvider).value;
  if (user == null) return; // kept in NotificationTaps.pending until signed in
  NotificationTaps.pending = null;
  if (ref.read(clientAppProvider) != ClientApp.patient) return;
  final route = notificationRoute(data['type'], data, user.role);
  if (route == null) return;
  if (isTabRoute(route)) {
    router.go(route);
    return;
  }
  final here = router.routerDelegate.currentConfiguration.uri.path;
  if (!tabRoutes.contains(here) && !here.startsWith('/chat') && here != '/notifications') {
    router.go('/dashboard');
  }
  router.push(route);
}

/// Root widget shared by all entrypoints; each passes its own router (NFR-3.2).
class CareFlowApp extends ConsumerWidget {
  const CareFlowApp({super.key, required this.title, required this.router});

  final String title;
  final Provider<GoRouter> router;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // D-33: register this device for alerts once a user of this app is signed in.
    ref.listen(currentUserProvider, (previous, next) {
      final user = next.value;
      if (user == null || user.uid == previous?.value?.uid) return;
      if (wrongAppMessage(user.role, ref.read(clientAppProvider)) != null) return;
      ref.read(pushServiceProvider).register();
      // D-80: a notification tapped before sign-in finished.
      final pending = NotificationTaps.pending;
      if (pending != null) openNotificationTap(ref, ref.read(router), pending);
      // D-42: make sure this device's public key is published so others can message us.
      if (user.role == UserRole.patient || user.role == UserRole.doctor) {
        ref
            .read(messagingRepositoryProvider)
            .publishKey(user.uid)
            .catchError((Object e) => debugPrint('Harvey: publishing message key failed: $e'));
      }
    });
    // D-43: keep this phone's dose reminders in step with the patient's medication list
    // (an empty list after sign-out cancels them, so a shared phone stops reminding).
    if (ref.watch(clientAppProvider) == ClientApp.patient) {
      // D-45: the "Medication reminders" switch off means no local reminders.
      ref.listen(reminderMedicationsProvider, (_, meds) {
        if (meds != null) syncReminders(ref, meds);
      });
    }
    ref.listen(notificationTapProvider, (_, next) {
      final data = next.value;
      if (data != null) openNotificationTap(ref, ref.read(router), data);
    });
    return MaterialApp.router(
      title: title,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: ref.watch(themeModeProvider),
      routerConfig: ref.watch(router),
      debugShowCheckedModeBanner: false,
    );
  }
}
