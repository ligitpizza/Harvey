import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/enums.dart';
import '../../../shared/providers/api_providers.dart';
import '../../auth/state/auth_providers.dart';
import '../data/notifications_repository.dart';

final notificationsRepositoryProvider = Provider<NotificationsRepository>(
  (ref) => ApiNotificationsRepository(ref.watch(apiClientProvider)),
);

/// D-77 the bell inbox; refreshed by the bell every minute and when it opens.
/// D-124: rebuilt when the signed-in account changes, so a phone that switches between a
/// patient and a family account never shows the previous account's notifications.
final notificationInboxProvider = FutureProvider<NotificationInbox>((ref) {
  ref.watch(authUidProvider.select((uid) => uid.value));
  return ref.watch(notificationsRepositoryProvider).inbox();
}, retry: (_, _) => null);

final bellPrefsProvider = FutureProvider.autoDispose<Map<String, bool>>(
  (ref) => ref.watch(notificationsRepositoryProvider).prefs(),
  retry: (_, _) => null,
);

/// Where a notification leads, from its push data; null = nowhere (just mark it read).
/// D-80: the phone's bottom-tab pages (inside the tab shell): open with `go`, not `push`.
const tabRoutes = {
  '/dashboard',
  '/vitals',
  '/medications',
  '/records',
  '/settings',
  // D-124: the family bottom tabs.
  '/family/home',
  '/family/link',
  '/family/settings',
};

bool isTabRoute(String route) => tabRoutes.contains(Uri.parse(route).path);

String? notificationRoute(String? type, Map<String, String> data, UserRole? role) {
  final staffBase = switch (role) {
    UserRole.doctor => '/doctor',
    UserRole.pharmacist => '/pharmacy',
    UserRole.admin => '/admin',
    _ => null,
  };
  // D-124: family members only have the family screens.
  if (role == UserRole.familyMember) {
    final alertId = data['alertId'];
    return switch (type) {
      'emergency_alert' ||
      'emergency_ack' => alertId == null ? '/family/home' : '/family/alert/$alertId',
      'bp_alert' || 'risk' || 'escalation' || 'sos' || 'triage' => '/family/home',
      'family_link' || 'family_request' => '/family/link',
      _ => null,
    };
  }
  final id = data['id'];
  final from = data['from'];
  final orderId = data['orderId']; // D-97
  if (staffBase == null) {
    // Patient app.
    return switch (type) {
      'message' => from == null ? '/chat' : '/chat/$from',
      'conversation' => id == null ? '/chat' : '/conversation/$id',
      'pharmacy_chat' => '/pharmacy-chat',
      'weekly_summary' => '/ai-agent',
      'order' => orderId == null ? '/orders' : '/orders/$orderId/open',
      'appointment' || 'assignment' => '/appointments',
      'dose' || 'refill' => '/medications',
      'bp_alert' || 'risk' || 'triage' => '/dashboard',
      'family_link' || 'family_request' => '/family-requests',
      'record_shared' => '/records',
      _ => null,
    };
  }
  return switch (type) {
    'message' when role == UserRole.doctor =>
      from == null ? '/doctor/messages' : '/doctor/messages/$from',
    'conversation' when id != null =>
      role == UserRole.admin ? '/admin/messages/$id' : '$staffBase/messages/team/$id',
    'pharmacy_chat' when role == UserRole.pharmacist => '/pharmacy/messages',
    'order' when role == UserRole.pharmacist =>
      orderId == null ? '/pharmacy' : '/pharmacy/order/$orderId',
    'order' when role == UserRole.admin =>
      orderId == null ? '/admin/orders' : '/admin/orders/$orderId',
    'clinical_alert' ||
    'escalation' ||
    'bp_alert' ||
    'risk' ||
    'triage' ||
    'emergency_alert' when role == UserRole.doctor => '/doctor',
    'appointment' when role == UserRole.doctor => '/doctor/calendar',
    // D-120: a colleague saw this doctor's patient; open the patient (notes).
    'cover_handover' when role == UserRole.doctor =>
      data['patientId'] == null ? '/doctor' : '/doctor/patient/${data['patientId']}',
    'appointment' when role == UserRole.admin => '/admin/appointments',
    'assignment' when role == UserRole.admin => '/admin/assignments',
    'staff_request' => role == UserRole.admin ? '/admin/requests' : '$staffBase/admin-center',
    'leave' => '$staffBase/leave', // D-80
    _ => null,
  };
}

/// D-79: a chat was opened, so its notifications in the bell are read too (they stayed
/// unread before, which kept the badge up after reading a pharmacy reply).
Future<void> clearChatNotifications(
  WidgetRef ref,
  String type, [
  Map<String, String> data = const {},
]) async {
  try {
    final r = await ref.read(apiClientProvider).readMatchingNotifications(type, data);
    if (((r['updated'] as num?) ?? 0) > 0) ref.invalidate(notificationInboxProvider);
  } catch (_) {
    // The bell catches up on its next refresh.
  }
}
