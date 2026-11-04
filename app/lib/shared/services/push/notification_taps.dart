import 'dart:async';
import 'dart:convert';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// D-80: taps on phone notifications (FCM pushes and local dose reminders). Each tap
/// carries the push's data (`type`, `from`, `id`…); the app root turns it into a route
/// with `notificationRoute`, the same mapping the in-app bell uses.
class NotificationTaps {
  NotificationTaps._();

  static final _controller = StreamController<Map<String, String>>.broadcast();

  /// A tap that arrived before anything listened (cold start), opened once signed in.
  static Map<String, String>? pending;

  static Stream<Map<String, String>> get stream => _controller.stream;

  static void add(Map<String, dynamic> data) {
    final clean = {for (final e in data.entries) e.key: '${e.value}'};
    if (clean.isEmpty) return;
    pending = clean;
    _controller.add(clean);
  }

  /// Payload of a local notification: `dose:<medicationId>` (reminders) or JSON data
  /// (pushes shown while the app was open).
  static Map<String, String>? fromPayload(String? payload) {
    if (payload == null || payload.isEmpty) return null;
    if (payload.startsWith('dose:')) return {'type': 'dose', 'id': payload.substring(5)};
    try {
      final d = jsonDecode(payload);
      if (d is Map) return {for (final e in d.entries) '${e.key}': '${e.value}'};
    } catch (_) {}
    return null;
  }

  /// Passed to every `FlutterLocalNotificationsPlugin.initialize` call (the plugin keeps
  /// one handler, so pushes and reminders must share it).
  static void onLocalTap(NotificationResponse response) {
    final data = fromPayload(response.payload);
    if (data != null) add(data);
  }

  /// The app was started by tapping a local notification.
  static Future<void> checkLocalLaunch(FlutterLocalNotificationsPlugin plugin) async {
    try {
      final details = await plugin.getNotificationAppLaunchDetails();
      if (details?.didNotificationLaunchApp ?? false) {
        final data = fromPayload(details!.notificationResponse?.payload);
        if (data != null) add(data);
      }
    } catch (_) {}
  }
}
