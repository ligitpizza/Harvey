import 'package:flutter/material.dart';
import '../../../shared/widgets/contact_email_dialog.dart';
import '../../../shared/widgets/identity_fields.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/constants/enums.dart';
import '../../../shared/providers/api_providers.dart';
import '../../../shared/services/api/api_client.dart';
import '../../auth/domain/onboarding_data.dart';
import '../../auth/presentation/onboarding/onboarding_labels.dart';
import '../../auth/state/auth_providers.dart';
import '../state/settings_providers.dart';
import 'health_profile_fields.dart';
import 'settings_widgets.dart';
import '../../../core/utils/ic_number.dart';

/// Shared save handling: validate, call the API, show the result (UC12.1 E1 inline).
mixin _SaveFlow<W extends ConsumerStatefulWidget> on ConsumerState<W> {
  final form = GlobalKey<FormState>();
  bool saving = false;
  String? error;

  /// [action] returns true when the risk score was re-generated.
  Future<void> save(Future<bool> Function() action) async {
    setState(() => error = null);
    if (!form.currentState!.validate()) return;
    setState(() => saving = true);
    try {
      final rescored = await action();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(rescored ? 'Saved. Your risk assessment was updated.' : 'Saved.')),
      );
      context.pop();
    } on ApiException catch (e) {
      setState(() => error = e.message);
    } catch (_) {
      setState(() => error = 'Could not save. Please check your connection and try again.');
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }
}

Widget _loading(AsyncValue<OnboardingData?> value, Widget Function(OnboardingData) form) =>
    value.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (_, _) => const Center(child: Text('Could not load your profile.')),
      data: (d) => d == null
          ? const Center(child: Text('Finish onboarding to set up your profile.'))
          : form(d),
    );

// ---------------- UC12.1 personal information ----------------

class PersonalInfoPage extends ConsumerWidget {
  const PersonalInfoPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(currentUserProvider).value;
    return Scaffold(
      appBar: AppBar(title: const Text('Personal information')),
      // Wait for the user document so the form starts with the saved values.
      body: user == null
          ? const Center(child: CircularProgressIndicator())
          : _PersonalForm(
              name: user.name,
              dateOfBirth: user.dateOfBirth,
              gender: user.gender,
              icNumber: user.icNumber ?? user.passportNumber,
              nationality: user.nationality,
            ),
    );
  }
}

class _PersonalForm extends ConsumerStatefulWidget {
  const _PersonalForm({
    required this.name,
    this.dateOfBirth,
    this.gender,
    this.icNumber,
    this.nationality,
  });

  final String name;

  /// D-103: the MyKad or passport number.
  final String? icNumber;
  final String? nationality;
  final DateTime? dateOfBirth;
  final Gender? gender;

  @override
  ConsumerState<_PersonalForm> createState() => _PersonalInfoPageState();
}

class _PersonalInfoPageState extends ConsumerState<_PersonalForm> with _SaveFlow<_PersonalForm> {
  late final _name = TextEditingController(text: widget.name);
  late final _ic = TextEditingController(text: widget.icNumber);
  late final _nationality = TextEditingController(text: widget.nationality);
  late DateTime? _dob = widget.dateOfBirth;
  late Gender? _gender = widget.gender;

  @override
  void dispose() {
    _name.dispose();
    _ic.dispose();
    _nationality.dispose();
    super.dispose();
  }

  Future<void> _pickDob() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _dob ?? DateTime(now.year - 50),
      firstDate: DateTime(now.year - 120),
      lastDate: DateTime(now.year - 18, now.month, now.day),
      helpText: 'Date of birth',
    );
    if (picked != null) setState(() => _dob = picked);
  }

  @override
  Widget build(BuildContext context) {
    final dob = _dob;
    return Form(
      key: form,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextFormField(
            key: const Key('settings-name'),
            controller: _name,
            decoration: const InputDecoration(labelText: 'Full name'),
            textCapitalization: TextCapitalization.words,
            validator: (v) => (v ?? '').trim().length < 2 ? 'Enter your full name.' : null,
          ),
          // D-51/D-103: MyKad (fills birthday and gender) or passport with nationality.
          // Required once set; accounts made before D-51 may leave it empty.
          IdentityFields(
            id: _ic,
            nationality: _nationality,
            required: widget.icNumber != null,
            idKey: const Key('settings-ic'),
            nationalityKey: const Key('settings-nationality'),
            helperText: widget.icNumber == null
                ? 'Add your MyKad or passport number for your records.'
                : null,
            // Fill date of birth and gender from a newly entered MyKad.
            onParsed: (info) {
              if (info.dateOfBirth == null) return;
              setState(() {
                _dob = info.dateOfBirth;
                _gender = info.gender;
              });
            },
          ),
          const SectionLabel('Date of birth'),
          OutlinedButton.icon(
            key: const Key('settings-dob'),
            onPressed: _pickDob,
            icon: const Icon(Icons.cake_outlined),
            label: Text(dob == null ? 'Choose date' : '${dob.day}/${dob.month}/${dob.year}'),
          ),
          const SectionLabel('Gender'),
          ChoiceChips<Gender>(
            values: Gender.values,
            selected: _gender,
            label: OnboardingLabels.gender,
            onSelected: (g) => setState(() => _gender = g),
          ),
          SaveBar(
            saving: saving,
            error: error,
            onSave: () {
              if (_dob == null || _gender == null) {
                setState(() => error = 'Choose your date of birth and gender.');
                return;
              }
              save(
                () => ref
                    .read(settingsRepositoryProvider)
                    .updatePersonal(
                      name: _name.text,
                      dateOfBirth: _dob!,
                      gender: _gender!,
                      icNumber: _ic.text.trim().isEmpty ? null : parseIdentity(_ic.text).value,
                      nationality: looksLikePassport(_ic.text) ? _nationality.text.trim() : null,
                    ),
              );
            },
          ),
        ],
      ),
    );
  }
}

// ---------------- UC12.1 contact details ----------------

class ContactDetailsPage extends ConsumerWidget {
  const ContactDetailsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => Scaffold(
    appBar: AppBar(title: const Text('Contact details')),
    body: _loading(ref.watch(healthProfileProvider), (d) => _ContactForm(data: d)),
  );
}

class _ContactForm extends ConsumerStatefulWidget {
  const _ContactForm({required this.data});

  final OnboardingData data;

  @override
  ConsumerState<_ContactForm> createState() => _ContactFormState();
}

class _ContactFormState extends ConsumerState<_ContactForm> with _SaveFlow<_ContactForm> {
  late final OnboardingData _d = widget.data;

  @override
  Widget build(BuildContext context) {
    final me = ref.watch(currentUserProvider).value;
    final email = me?.signInId ?? '';
    final byEmail = (me?.email ?? '').isNotEmpty || me == null;
    return Form(
      key: form,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(byEmail ? Icons.email_outlined : Icons.badge_outlined),
            title: Text(email),
            subtitle: Text(
              byEmail ? 'Sign-in email (cannot be changed here)' : 'You sign in with this number',
            ),
          ),
          if (!byEmail) _ContactEmailTile(current: me.contactEmail),
          TextFormField(
            key: const Key('settings-phone'),
            initialValue: _d.phone,
            decoration: const InputDecoration(labelText: 'Phone number'),
            keyboardType: TextInputType.phone,
            onChanged: (v) => _d.phone = v,
            validator: validatePhone,
          ),
          const SectionLabel('Emergency contact (optional)'),
          TextFormField(
            key: const Key('settings-emergency-name'),
            initialValue: _d.emergencyName,
            decoration: const InputDecoration(labelText: 'Name'),
            onChanged: (v) => _d.emergencyName = v,
            validator: (v) =>
                _d.hasEmergencyContact && (v ?? '').trim().length < 2 ? 'Enter their name.' : null,
          ),
          TextFormField(
            key: const Key('settings-emergency-phone'),
            initialValue: _d.emergencyPhone,
            decoration: const InputDecoration(labelText: 'Phone'),
            keyboardType: TextInputType.phone,
            onChanged: (v) => _d.emergencyPhone = v,
            validator: (v) => validatePhone(v, required: _d.hasEmergencyContact),
          ),
          TextFormField(
            key: const Key('settings-emergency-relationship'),
            initialValue: _d.emergencyRelationship,
            decoration: const InputDecoration(labelText: 'Relationship'),
            onChanged: (v) => _d.emergencyRelationship = v,
            validator: (v) => _d.hasEmergencyContact && (v ?? '').trim().length < 2
                ? 'Enter the relationship.'
                : null,
          ),
          SaveBar(
            saving: saving,
            error: error,
            onSave: () => save(() async {
              await ref.read(settingsRepositoryProvider).updateContact(_d);
              return false;
            }),
          ),
        ],
      ),
    );
  }
}

// ---------------- UC12.2 health profile ----------------

class HealthProfilePage extends ConsumerWidget {
  const HealthProfilePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => Scaffold(
    appBar: AppBar(title: const Text('Health profile')),
    body: _loading(ref.watch(healthProfileProvider), (d) => _HealthForm(data: d)),
  );
}

class _HealthForm extends ConsumerStatefulWidget {
  const _HealthForm({required this.data});

  final OnboardingData data;

  @override
  ConsumerState<_HealthForm> createState() => _HealthFormState();
}

class _HealthFormState extends ConsumerState<_HealthForm> with _SaveFlow<_HealthForm> {
  late final OnboardingData _d = widget.data;

  @override
  Widget build(BuildContext context) {
    return Form(
      key: form,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            'Changes to these answers update your risk assessment.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          // D-133: a value your doctor changed shows "Updated by Dr …" until you change it.
          if (_d.doctorEdits.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                'Your doctor updated some answers. You can change them if they are wrong.',
                key: const Key('doctor-edited-note'),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          HealthProfileFields(data: _d),
          SaveBar(
            saving: saving,
            error: error,
            onSave: () {
              if (_d.smokingStatus == null || _d.alcohol == null || _d.saltIntake == null) {
                setState(() => error = 'Answer the smoking, alcohol and salt questions.');
                return;
              }
              save(() => ref.read(settingsRepositoryProvider).updateHealth(_d));
            },
          ),
        ],
      ),
    );
  }
}

/// D-130: a MyKad/passport patient's email for reminders and password reset.
class _ContactEmailTile extends ConsumerWidget {
  const _ContactEmailTile({required this.current});

  final String? current;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final api = ref.read(apiClientProvider);
    Future<void> edit() async {
      final saved = await showContactEmailDialog(
        context,
        scope: ref.read(currentUserProvider).value?.uid ?? 'me',
        current: current,
        send: (e) => api.requestContactEmailCode(e),
        verify: (e, c) => api.verifyContactEmail(e, c),
      );
      if (saved != null && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Email saved: $saved')));
      }
    }

    Future<void> remove() async {
      try {
        await api.removeContactEmail();
      } on ApiException catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
        }
      }
    }

    return ListTile(
      key: const Key('settings-contact-email'),
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.alternate_email),
      title: Text(current ?? 'No email added'),
      subtitle: const Text('For appointment reminders and resetting your password'),
      trailing: Wrap(
        spacing: 4,
        children: [
          TextButton(
            key: const Key('settings-contact-email-edit'),
            onPressed: edit,
            child: Text(current == null ? 'Add' : 'Change'),
          ),
          if (current != null)
            IconButton(
              key: const Key('settings-contact-email-remove'),
              tooltip: 'Remove email',
              onPressed: remove,
              icon: const Icon(Icons.close),
            ),
        ],
      ),
    );
  }
}
