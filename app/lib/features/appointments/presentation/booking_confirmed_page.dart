import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../shared/models/health_models.dart';
import '../../dashboard/state/dashboard_providers.dart';
import '../domain/appointment_text.dart';
import '../state/appointment_providers.dart';
import '../../family/state/family_providers.dart'
    show directionsUrl, mapBuilderProvider, openUrlProvider;
import 'appointments_page.dart';

/// Fig 4.3.6.2 Booking confirmed (FR-7.1, FR-7.4). "Complete intake form" is out of scope
/// (D-53).
class BookingConfirmedPage extends ConsumerWidget {
  const BookingConfirmedPage({super.key, required this.appointmentId});

  final String appointmentId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final now = ref.watch(nowProvider)();
    final list = ref.watch(myUpcomingAppointmentsProvider);
    final a = (list.value ?? const <Appointment>[]).where((x) => x.id == appointmentId).firstOrNull;
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Appointment')),
      body: list.isLoading && a == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                const SizedBox(height: 8),
                CircleAvatar(
                  radius: 36,
                  backgroundColor: theme.colorScheme.primary,
                  child: Icon(Icons.check, size: 40, color: theme.colorScheme.onPrimary),
                ),
                const SizedBox(height: 12),
                Text(
                  'Appointment confirmed!',
                  key: const Key('booking-confirmed'),
                  textAlign: TextAlign.center,
                  style: theme.textTheme.headlineSmall,
                ),
                const Text(
                  "We'll remind you 24 hours and 1 hour before.",
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                if (a != null) ...[
                  AppointmentCard(appointment: a, now: now),
                  const ClinicLocationCard(),
                ] else
                  const Text('This appointment is no longer active.', textAlign: TextAlign.center),
              ],
            ),
      bottomNavigationBar: SafeArea(
        minimum: const EdgeInsets.all(16),
        child: FilledButton(
          key: const Key('booking-done'),
          onPressed: () => context.go('/appointments'),
          child: const Text('Done'),
        ),
      ),
    );
  }
}

/// D-82: the clinic on a map with its address and a Directions button.
class ClinicLocationCard extends ConsumerWidget {
  const ClinicLocationCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final info = ref.watch(clinicLocationProvider).value;
    final name = info?['name'] as String? ?? clinicName;
    final address = info?['address'] as String?;
    final lat = (info?['lat'] as num?)?.toDouble();
    final lng = (info?['lng'] as num?)?.toDouble();
    return Card(
      key: const Key('clinic-location'),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ListTile(
            leading: Icon(Icons.location_on, color: theme.colorScheme.primary),
            title: Text(name, style: const TextStyle(fontWeight: FontWeight.w600)),
            subtitle: Text(address ?? 'Location', key: const Key('clinic-address')),
          ),
          if (lat != null && lng != null) ...[
            SizedBox(
              key: const Key('clinic-map'),
              height: 200,
              child: ref.read(mapBuilderProvider)(lat, lng, name),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
              child: Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  key: const Key('clinic-directions'),
                  onPressed: () => ref.read(openUrlProvider)(directionsUrl(lat, lng)),
                  icon: const Icon(Icons.directions_outlined),
                  label: const Text('Directions'),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
