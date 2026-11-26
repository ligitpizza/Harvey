import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/services/api/api_client.dart';
import '../../auth/domain/onboarding_data.dart';
import '../../settings/presentation/health_profile_fields.dart';
import '../state/portal_providers.dart';
import 'portal_widgets.dart';

/// D-133: the patient's health profile on the doctor's patient page. The assigned doctor
/// can correct it; changed answers show "Updated by Dr …" here and in the patient's
/// Settings until the patient changes them. Setting it up stays with the patient
/// (onboarding, UC1.4).
class HealthProfileTab extends ConsumerWidget {
  const HealthProfileTab({super.key, required this.patientId, this.canEdit = true});

  final String patientId;

  /// False for a covering doctor (D-120): view only.
  final bool canEdit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(patientHealthProfileProvider(patientId));
    return AsyncSection<OnboardingData?>(
      value: profile,
      isEmpty: (d) => d == null,
      emptyText: "The patient hasn't set up their health profile yet.",
      builder: (d) => ListView(
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Answers from the patient. Changes update the risk assessment.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              if (canEdit)
                OutlinedButton.icon(
                  key: const Key('edit-health-profile'),
                  onPressed: () => editHealthProfile(context, ref, patientId, d!),
                  icon: const Icon(Icons.edit_outlined, size: 18),
                  label: const Text('Edit'),
                ),
            ],
          ),
          const SizedBox(height: 8),
          for (final (field, label, value) in healthProfileSummary(d!))
            Padding(
              key: Key('hp-row-$field'),
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 170,
                    child: Text(label, style: Theme.of(context).textTheme.labelLarge),
                  ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(value),
                        DoctorEditTag(edit: d.doctorEdits[field]),
                      ],
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// Opens the edit dialog with a copy of [current]; saving goes through FastAPI, which
/// checks the assignment, tags the changed fields and tells the patient.
Future<void> editHealthProfile(
  BuildContext context,
  WidgetRef ref,
  String patientId,
  OnboardingData current,
) async {
  final d = OnboardingData.fromDraftJson(current.toDraftJson())..doctorEdits = current.doctorEdits;
  final form = GlobalKey<FormState>();
  final messenger = ScaffoldMessenger.of(context);
  String? error;
  var saving = false;
  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) {
        Future<void> save() async {
          setState(() => error = null);
          if (!form.currentState!.validate()) return;
          if (d.smokingStatus == null || d.alcohol == null || d.saltIntake == null) {
            setState(() => error = 'Answer the smoking, alcohol and salt questions.');
            return;
          }
          setState(() => saving = true);
          try {
            final r = await ref.read(portalRepositoryProvider).saveHealthProfile(patientId, d);
            if (ctx.mounted) Navigator.of(ctx).pop();
            messenger.showSnackBar(
              SnackBar(
                content: Text(
                  r.changed.isEmpty
                      ? 'Nothing changed.'
                      : 'Saved. The patient has been told'
                            '${r.rescored ? ' and the risk assessment was updated' : ''}.',
                ),
              ),
            );
          } on ApiException catch (e) {
            setState(() => error = e.message);
          } catch (_) {
            setState(() => error = 'Could not save. Check your connection and try again.');
          } finally {
            if (ctx.mounted) setState(() => saving = false);
          }
        }

        return AlertDialog(
          key: const Key('health-profile-dialog'),
          title: const Text('Edit health profile'),
          scrollable: true,
          content: SizedBox(
            width: 560,
            child: Form(
              key: form,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'The patient will see which answers you changed and can change them '
                    'back.',
                    style: Theme.of(ctx).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 8),
                  HealthProfileFields(data: d, patientWording: false),
                  if (error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        error!,
                        key: const Key('health-profile-error'),
                        style: TextStyle(color: Theme.of(ctx).colorScheme.error),
                      ),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: saving ? null : () => Navigator.of(ctx).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              key: const Key('save-health-profile'),
              onPressed: saving ? null : save,
              child: Text(saving ? 'Saving…' : 'Save'),
            ),
          ],
        );
      },
    ),
  );
}
