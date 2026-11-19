import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/enums.dart';
import '../../../shared/models/health_models.dart';
import '../state/appointment_providers.dart';

// D-120: a visit covered by another doctor (the patient's own doctor away). The wording
// is pure so it is unit-tested; the widgets below only look up the names.

/// Patient app: "Consulted with Dr Lim (covering for Dr Tan)", or "With Dr Tan".
String patientDoctorLine(Appointment a, {String? doctor, String? coverFor}) {
  final verb = a.status == AppointmentStatus.completed ? 'Consulted with' : 'With';
  final who = doctor ?? 'your doctor';
  return a.isCover ? '$verb $who (covering for ${coverFor ?? 'your doctor'})' : '$verb $who';
}

/// The covering doctor's calendar.
String coveringLabel(String? coverFor) => 'Covering for ${coverFor ?? 'a colleague'}';

/// The own doctor's view of the patient's history.
String coveredByLabel(String? doctor) => 'Seen by ${doctor ?? 'another doctor'} (cover)';

String? _name(WidgetRef ref, String? uid) =>
    uid == null ? null : ref.watch(personProvider(uid)).value?.name;

/// One line naming who the patient sees (or saw) at this appointment.
class AppointmentDoctorLine extends ConsumerWidget {
  const AppointmentDoctorLine({super.key, required this.appointment, this.style});

  final Appointment appointment;
  final TextStyle? style;

  @override
  Widget build(BuildContext context, WidgetRef ref) => Text(
    patientDoctorLine(
      appointment,
      doctor: _name(ref, appointment.doctorId),
      coverFor: _name(ref, appointment.coverForDoctorId),
    ),
    key: Key('doctor-line-${appointment.id}'),
    style: style,
  );
}

/// A small "Covering for Dr X" / "Seen by Dr Y (cover)" tag for staff views.
class CoverTag extends ConsumerWidget {
  const CoverTag({super.key, required this.appointment, required this.forOwnDoctor});

  final Appointment appointment;

  /// True on the own doctor's screens ("Seen by ..."), false on the covering doctor's.
  final bool forOwnDoctor;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final a = appointment;
    final text = forOwnDoctor
        ? coveredByLabel(_name(ref, a.doctorId))
        : coveringLabel(_name(ref, a.coverForDoctorId));
    final color = Colors.indigo.shade600;
    return Container(
      key: Key('cover-tag-${a.id}'),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.swap_horiz, size: 14, color: color),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              text,
              style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}
