import 'package:flutter/material.dart';

import '../../../core/constants/enums.dart';
import '../../auth/domain/onboarding_data.dart';
import '../../auth/presentation/onboarding/onboarding_labels.dart';
import 'settings_widgets.dart';

/// D-133: small "Updated by Dr Tan · 27 Nov" line under a field the doctor changed.
class DoctorEditTag extends StatelessWidget {
  const DoctorEditTag({super.key, required this.edit});

  final DoctorEdit? edit;

  @override
  Widget build(BuildContext context) {
    if (edit == null) return const SizedBox.shrink();
    final color = Theme.of(context).colorScheme.primary;
    return Padding(
      padding: const EdgeInsets.only(top: 2, bottom: 4),
      child: Row(
        children: [
          Icon(Icons.medical_services_outlined, size: 14, color: color),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              edit!.label,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(color: color),
            ),
          ),
        ],
      ),
    );
  }
}

/// The UC12.2 health-profile answers (onboarding step 2 and 3 without contact details).
/// Used by the patient's Settings and, D-133, by the assigned doctor in Harvey Pro.
/// Edits [data] in place.
class HealthProfileFields extends StatefulWidget {
  const HealthProfileFields({super.key, required this.data, this.patientWording = true});

  final OnboardingData data;

  /// "Conditions you have" (patient) or "Conditions" (doctor).
  final bool patientWording;

  @override
  State<HealthProfileFields> createState() => _HealthProfileFieldsState();
}

class _HealthProfileFieldsState extends State<HealthProfileFields> {
  OnboardingData get _d => widget.data;

  Widget _tag(String field) =>
      DoctorEditTag(key: Key('edited-$field'), edit: _d.doctorEdits[field]);

  @override
  Widget build(BuildContext context) {
    final year = DateTime.now().year;
    final you = widget.patientWording;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  NumberField(
                    key: const Key('settings-height'),
                    label: 'Height (cm)',
                    initial: _d.heightCm,
                    min: 100,
                    max: 250,
                    decimals: true,
                    onChanged: (v) => _d.heightCm = v?.toDouble(),
                  ),
                  _tag('heightCm'),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  NumberField(
                    key: const Key('settings-weight'),
                    label: 'Weight (kg)',
                    initial: _d.weightKg,
                    min: 25,
                    max: 300,
                    decimals: true,
                    onChanged: (v) => _d.weightKg = v?.toDouble(),
                  ),
                  _tag('weightKg'),
                ],
              ),
            ),
          ],
        ),
        NumberField(
          label: 'Year diagnosed with high blood pressure (optional)',
          initial: _d.hypertensionDiagnosedYear,
          min: 1900,
          max: year,
          required: false,
          onChanged: (v) => _d.hypertensionDiagnosedYear = v?.toInt(),
        ),
        _tag('hypertensionDiagnosedYear'),
        SectionLabel(you ? 'Conditions you have' : 'Conditions'),
        MultiChips<MedicalCondition>(
          values: MedicalCondition.values,
          selected: _d.conditions,
          label: OnboardingLabels.condition,
          onChanged: (s) => setState(() => _d.conditions = s),
        ),
        _tag('conditions'),
        const SectionLabel('Family history'),
        MultiChips<FamilyHistoryCondition>(
          values: FamilyHistoryCondition.values,
          selected: _d.familyHistory,
          label: OnboardingLabels.family,
          onChanged: (s) => setState(() => _d.familyHistory = s),
        ),
        _tag('familyHistory'),
        TextFormField(
          key: const Key('settings-allergies'),
          initialValue: _d.allergies,
          decoration: const InputDecoration(labelText: 'Allergies'),
          maxLength: 500,
          onChanged: (v) => _d.allergies = v,
        ),
        _tag('allergies'),
        const SectionLabel('Smoking'),
        ChoiceChips<SmokingStatus>(
          key: const Key('settings-smoking'),
          values: SmokingStatus.values,
          selected: _d.smokingStatus,
          label: OnboardingLabels.smoking,
          onSelected: (v) => setState(() => _d.smokingStatus = v),
        ),
        _tag('smokingStatus'),
        const SectionLabel('Alcohol'),
        ChoiceChips<AlcoholUse>(
          values: AlcoholUse.values,
          selected: _d.alcohol,
          label: OnboardingLabels.alcohol,
          onSelected: (v) => setState(() => _d.alcohol = v),
        ),
        _tag('alcohol'),
        SectionLabel(you ? 'Salt in your diet' : 'Salt in diet'),
        ChoiceChips<SaltIntake>(
          values: SaltIntake.values,
          selected: _d.saltIntake,
          label: OnboardingLabels.salt,
          onSelected: (v) => setState(() => _d.saltIntake = v),
        ),
        _tag('saltIntake'),
        const SizedBox(height: 8),
        NumberField(
          label: 'Days of exercise per week',
          initial: _d.exerciseDaysPerWeek,
          min: 0,
          max: 7,
          onChanged: (v) => _d.exerciseDaysPerWeek = v?.toInt(),
        ),
        _tag('exerciseDaysPerWeek'),
      ],
    );
  }
}

/// D-133: the profile as text, for the doctor's patient page (one row per answer).
List<(String field, String label, String value)> healthProfileSummary(OnboardingData d) {
  String list<T>(Set<T> s, String Function(T) l) => s.isEmpty ? 'None' : s.map(l).join(', ');
  String num0(num? v, String unit) =>
      v == null ? 'Not given' : '${v % 1 == 0 ? v.toInt() : v} $unit';
  final bmi = (d.heightCm != null && d.weightKg != null && d.heightCm! > 0)
      ? (d.weightKg! / ((d.heightCm! / 100) * (d.heightCm! / 100))).toStringAsFixed(1)
      : null;
  return [
    ('heightCm', 'Height', num0(d.heightCm, 'cm')),
    ('weightKg', 'Weight', '${num0(d.weightKg, 'kg')}${bmi == null ? '' : ' (BMI $bmi)'}'),
    (
      'hypertensionDiagnosedYear',
      'Diagnosed with high BP',
      d.hypertensionDiagnosedYear?.toString() ?? 'Not given',
    ),
    ('conditions', 'Conditions', list(d.conditions, OnboardingLabels.condition)),
    ('familyHistory', 'Family history', list(d.familyHistory, OnboardingLabels.family)),
    ('allergies', 'Allergies', d.allergies.trim().isEmpty ? 'None' : d.allergies.trim()),
    (
      'smokingStatus',
      'Smoking',
      d.smokingStatus == null ? 'Not given' : OnboardingLabels.smoking(d.smokingStatus!),
    ),
    ('alcohol', 'Alcohol', d.alcohol == null ? 'Not given' : OnboardingLabels.alcohol(d.alcohol!)),
    (
      'exerciseDaysPerWeek',
      'Exercise',
      d.exerciseDaysPerWeek == null ? 'Not given' : '${d.exerciseDaysPerWeek} day(s) a week',
    ),
    (
      'saltIntake',
      'Salt',
      d.saltIntake == null ? 'Not given' : OnboardingLabels.salt(d.saltIntake!),
    ),
  ];
}
