import 'dart:async';

import 'package:flutter/material.dart';
import '../../core/utils/ic_number.dart';
import '../../shared/widgets/identity_fields.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants/enums.dart';
import '../../core/utils/validators.dart';
import '../../shared/providers/api_providers.dart';
import '../../shared/services/api/api_client.dart';
import '../appointments/domain/appointment_text.dart' show timeLabel;
import '../../shared/widgets/page_header.dart';
import '../settings/presentation/settings_widgets.dart' show validatePhone;

/// D-80 walk-in (pharmacist): 1. find or register the patient, 2. pick their doctor and
/// one of today's free slots, 3. book. The patient and doctor get a notification.

class WalkInPatient {
  const WalkInPatient({
    required this.id,
    required this.name,
    this.email,
    this.phone,
    this.hasEmail = true,
    this.icLast4,
    this.doctorId,
    this.doctorName,
  });

  final String id;
  final String name;
  final String? email;

  /// D-129: optional contact number; a patient without an email signs in with their ID.
  final String? phone;
  final bool hasEmail;
  final String? icLast4;
  final String? doctorId;
  final String? doctorName;

  factory WalkInPatient.fromJson(Map<String, dynamic> j) => WalkInPatient(
    id: j['id'] as String,
    name: j['name'] as String? ?? 'Patient',
    email: j['email'] as String?,
    phone: j['phone'] as String?,
    hasEmail: j['hasEmail'] as bool? ?? j['email'] != null,
    icLast4: j['icLast4'] as String?,
    doctorId: j['doctorId'] as String?,
    doctorName: j['doctorName'] as String?,
  );
}

class WalkInDoctor {
  const WalkInDoctor({
    required this.id,
    required this.name,
    required this.onLeave,
    required this.slots,
    this.specialty,
    this.full = false,
  });

  final String id;
  final String name;
  final String? specialty;
  final bool onLeave;
  final bool full;
  final List<DateTime> slots;

  factory WalkInDoctor.fromJson(Map<String, dynamic> j) => WalkInDoctor(
    id: j['id'] as String,
    name: j['name'] as String? ?? 'Doctor',
    specialty: j['specialty'] as String?,
    onLeave: j['onLeave'] == true,
    full: ((j['patients'] as num?) ?? 0) >= ((j['maxPatients'] as num?) ?? 30),
    slots: [
      for (final s in (j['slots'] as List? ?? const []))
        DateTime.parse((s as Map<String, dynamic>)['time'] as String),
    ],
  );
}

final walkInDoctorsProvider = FutureProvider.autoDispose<(bool, List<WalkInDoctor>)>((ref) async {
  final res = await ref.watch(apiClientProvider).walkInDoctors();
  return (
    res['workingDay'] == true,
    [
      for (final d in (res['doctors'] as List? ?? const []))
        WalkInDoctor.fromJson(d as Map<String, dynamic>),
    ],
  );
});

class WalkInPage extends ConsumerStatefulWidget {
  const WalkInPage({super.key});

  @override
  ConsumerState<WalkInPage> createState() => _WalkInPageState();
}

class _WalkInPageState extends ConsumerState<WalkInPage> {
  final _search = TextEditingController();
  Timer? _debounce;
  List<WalkInPatient> _results = const [];
  bool _searching = false;
  WalkInPatient? _patient;
  String? _doctorId;
  DateTime? _slot;
  AppointmentType _type = AppointmentType.checkup;
  bool _booking = false;
  String? _error;
  String? _done;

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  void _onSearch(String q) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () => _find(q));
  }

  Future<void> _find(String q) async {
    if (q.trim().length < 2) {
      setState(() => _results = const []);
      return;
    }
    setState(() => _searching = true);
    try {
      final res = await ref.read(apiClientProvider).findWalkInPatients(q.trim());
      if (!mounted) return;
      setState(() {
        _results = [
          for (final p in (res['patients'] as List? ?? const []))
            WalkInPatient.fromJson(p as Map<String, dynamic>),
        ];
      });
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  void _choose(WalkInPatient p) => setState(() {
    _patient = p;
    _doctorId = p.doctorId;
    _slot = null;
    _error = null;
    _done = null;
  });

  Future<void> _register() async {
    final created = await showDialog<WalkInPatient>(
      context: context,
      builder: (_) => const _RegisterDialog(),
    );
    if (created != null) _choose(created);
  }

  /// D-129: a patient without an email lost their code or forgot their password.
  Future<void> _newCode(WalkInPatient p) async {
    try {
      final res = await ref.read(apiClientProvider).walkInSetupCode(p.id);
      if (!mounted) return;
      await showSetupCode(context, p.name, res['setupCode'] as String);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  Future<void> _book() async {
    final p = _patient;
    final slot = _slot;
    final doctor = _doctorId;
    if (p == null || slot == null || doctor == null) return;
    setState(() {
      _booking = true;
      _error = null;
    });
    try {
      await ref
          .read(apiClientProvider)
          .bookWalkIn(
            patientId: p.id,
            doctorId: doctor,
            dateTime: slot.toUtc().toIso8601String(),
            type: _type.value,
          );
      ref.invalidate(walkInDoctorsProvider);
      setState(() {
        _done = '${p.name} is booked at ${timeLabel(slot)} today.';
        _patient = null;
        _slot = null;
        _search.clear();
        _results = const [];
      });
    } on ApiException catch (e) {
      setState(() => _error = e.message);
      ref.invalidate(walkInDoctorsProvider);
    } finally {
      if (mounted) setState(() => _booking = false);
    }
  }

  Widget _step(int n, String title) => Padding(
    padding: const EdgeInsets.only(top: 20, bottom: 8),
    child: Row(
      children: [
        CircleAvatar(radius: 13, child: Text('$n', style: const TextStyle(fontSize: 13))),
        const SizedBox(width: 8),
        Text(title, style: Theme.of(context).textTheme.titleMedium),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = _patient;
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        PageHeader(
          title: 'Walk-in',
          subtitle:
              'Book a patient who walked in for a visit with a doctor today. New patients get '
              'an email to set their Harvey password, or a setup code if they have no email.',
          icon: Icons.how_to_reg_outlined,
          color: Colors.green.shade700,
        ),
        if (_done != null)
          Card(
            key: const Key('walk-in-done'),
            color: Colors.green.withValues(alpha: 0.12),
            child: ListTile(
              leading: const Icon(Icons.check_circle_outline, color: Colors.green),
              title: Text(_done!),
            ),
          ),
        _step(1, 'Patient'),
        if (p != null)
          Card(
            key: const Key('walk-in-patient'),
            child: ListTile(
              leading: const CircleAvatar(child: Icon(Icons.person_outline)),
              title: Text(p.name),
              subtitle: Text(
                [
                  if (p.email != null) p.email! else 'No email · signs in with MyKad/passport',
                  if (p.phone != null) p.phone!,
                  if (p.icLast4 != null) 'IC …${p.icLast4}',
                  p.doctorName == null ? 'No doctor yet' : 'Doctor: ${p.doctorName}',
                ].join(' · '),
              ),
              trailing: Wrap(
                spacing: 8,
                children: [
                  if (!p.hasEmail)
                    OutlinedButton.icon(
                      key: const Key('walk-in-new-code'),
                      onPressed: () => _newCode(p),
                      icon: const Icon(Icons.pin_outlined, size: 18),
                      label: const Text('New setup code'),
                    ),
                  TextButton(
                    onPressed: () => setState(() => _patient = null),
                    child: const Text('Change'),
                  ),
                ],
              ),
            ),
          )
        else ...[
          Row(
            children: [
              Expanded(
                child: TextField(
                  key: const Key('walk-in-search'),
                  controller: _search,
                  onChanged: _onSearch,
                  decoration: InputDecoration(
                    prefixIcon: const Icon(Icons.search),
                    labelText: 'Find by name, email, IC or phone',
                    suffixIcon: _searching
                        ? const Padding(
                            padding: EdgeInsets.all(12),
                            child: SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          )
                        : null,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              OutlinedButton.icon(
                key: const Key('walk-in-register'),
                onPressed: _register,
                icon: const Icon(Icons.person_add_alt),
                label: const Text('New patient'),
              ),
            ],
          ),
          for (final r in _results)
            ListTile(
              key: Key('walk-in-result-${r.id}'),
              leading: const Icon(Icons.person_outline),
              title: Text(r.name),
              subtitle: Text(
                [
                  if (r.email != null) r.email! else if (r.phone != null) r.phone!,
                  if (r.icLast4 != null) 'IC …${r.icLast4}',
                  r.doctorName ?? 'No doctor yet',
                ].join(' · '),
              ),
              onTap: () => _choose(r),
            ),
          if (!_searching && _search.text.trim().length >= 2 && _results.isEmpty)
            const Padding(
              padding: EdgeInsets.all(8),
              child: Text('No patient found. Register them as a new patient.'),
            ),
        ],
        if (p != null) ...[
          _step(2, "Doctor and today's time"),
          _DoctorSlots(
            patient: p,
            doctorId: _doctorId,
            slot: _slot,
            onDoctor: (id) => setState(() {
              _doctorId = id;
              _slot = null;
            }),
            onSlot: (s) => setState(() => _slot = s),
          ),
          _step(3, 'Visit type'),
          Wrap(
            spacing: 8,
            children: [
              for (final t in AppointmentType.values)
                ChoiceChip(
                  key: Key('walk-in-type-${t.value}'),
                  label: Text(t.label),
                  selected: _type == t,
                  onSelected: (_) => setState(() => _type = t),
                ),
            ],
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                _error!,
                key: const Key('walk-in-error'),
                style: TextStyle(color: theme.colorScheme.error),
              ),
            ),
          const SizedBox(height: 16),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.icon(
              key: const Key('walk-in-book'),
              onPressed: _booking || _slot == null || _doctorId == null ? null : _book,
              icon: const Icon(Icons.event_available),
              label: Text(_slot == null ? 'Choose a time' : 'Book ${timeLabel(_slot!)} today'),
            ),
          ),
        ],
      ],
    );
  }
}

class _DoctorSlots extends ConsumerWidget {
  const _DoctorSlots({
    required this.patient,
    required this.doctorId,
    required this.slot,
    required this.onDoctor,
    required this.onSlot,
  });

  final WalkInPatient patient;
  final String? doctorId;
  final DateTime? slot;
  final ValueChanged<String> onDoctor;
  final ValueChanged<DateTime> onSlot;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(walkInDoctorsProvider);
    return data.when(
      loading: () => const LinearProgressIndicator(),
      error: (_, _) => TextButton(
        onPressed: () => ref.invalidate(walkInDoctorsProvider),
        child: const Text("Could not load today's doctors. Retry"),
      ),
      data: (d) {
        final (workingDay, doctors) = d;
        if (!workingDay) {
          return const Card(
            key: Key('walk-in-closed'),
            child: ListTile(
              leading: Icon(Icons.event_busy_outlined),
              title: Text('The clinic is closed today (Mon–Fri, 9 AM–9 PM).'),
            ),
          );
        }
        // A patient with a doctor sees that doctor; otherwise any doctor with room.
        final choices = patient.doctorId == null
            ? doctors
            : [
                for (final x in doctors)
                  if (x.id == patient.doctorId) x,
              ];
        final chosen = choices.where((x) => x.id == doctorId).firstOrNull;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (patient.doctorId == null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: DropdownButton<String>(
                  key: const Key('walk-in-doctor'),
                  value: chosen?.id,
                  hint: const Text('Choose a doctor (they become the patient\'s doctor)'),
                  items: [
                    for (final x in choices)
                      DropdownMenuItem(
                        value: x.id,
                        enabled: !x.onLeave && !x.full,
                        child: Text(
                          '${x.name}${x.specialty == null ? '' : ' · ${x.specialty}'}'
                          '${x.onLeave
                              ? ' (on leave)'
                              : x.full
                              ? ' (full)'
                              : ' · ${x.slots.length} free'}',
                        ),
                      ),
                  ],
                  onChanged: (v) => v == null ? null : onDoctor(v),
                ),
              ),
            if (chosen == null && patient.doctorId != null)
              const Text("This patient's doctor isn't available today. Ask the admin."),
            if (chosen != null && chosen.onLeave)
              Text(
                '${chosen.name} is on leave today. Ask the admin to assign another doctor.',
                key: const Key('walk-in-on-leave'),
              )
            else if (chosen != null && chosen.slots.isEmpty)
              Text('${chosen.name} has no free time left today.')
            else if (chosen != null)
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final s in chosen.slots)
                    ChoiceChip(
                      key: Key('walk-in-slot-${s.toUtc().toIso8601String()}'),
                      label: Text(timeLabel(s)),
                      selected: slot == s,
                      onSelected: (_) => onSlot(s),
                    ),
                ],
              ),
          ],
        );
      },
    );
  }
}

class _RegisterDialog extends ConsumerStatefulWidget {
  const _RegisterDialog();

  @override
  ConsumerState<_RegisterDialog> createState() => _RegisterDialogState();
}

class _RegisterDialogState extends ConsumerState<_RegisterDialog> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _phone = TextEditingController(); // D-129
  final _ic = TextEditingController();
  final _nationality = TextEditingController(); // D-103
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    _phone.dispose();
    _ic.dispose();
    _nationality.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final email = _email.text.trim();
      final phone = _phone.text.trim();
      final res = await ref
          .read(apiClientProvider)
          .registerWalkIn(
            _name.text.trim(),
            email.isEmpty ? null : email,
            parseIdentity(_ic.text).value,
            nationality: looksLikePassport(_ic.text) ? _nationality.text.trim() : null,
            phone: phone.isEmpty ? null : phone,
          );
      if (!mounted) return;
      final code = res['setupCode'] as String?;
      if (code != null) await showSetupCode(context, _name.text.trim(), code);
      if (!mounted) return;
      Navigator.pop(
        context,
        WalkInPatient(
          id: res['uid'] as String,
          name: _name.text.trim(),
          email: email.isEmpty ? null : email,
          phone: phone.isEmpty ? null : phone,
          hasEmail: email.isNotEmpty,
          icLast4: () {
            final v = parseIdentity(_ic.text).value.replaceAll('-', '');
            return v.substring((v.length - 4).clamp(0, 99));
          }(),
        ),
      );
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('New walk-in patient'),
    content: SizedBox(
      width: 420,
      child: Form(
        key: _form,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextFormField(
              key: const Key('walk-in-name'),
              controller: _name,
              decoration: const InputDecoration(labelText: 'Full name (as on MyKad or passport)'),
              validator: (v) => (v ?? '').trim().length < 2 ? 'Enter the name.' : null,
            ),
            TextFormField(
              key: const Key('walk-in-email'),
              controller: _email,
              keyboardType: TextInputType.emailAddress,
              decoration: const InputDecoration(
                labelText: 'Email (optional)',
                helperText: 'No email? They get a setup code to sign in with their MyKad/passport.',
                helperMaxLines: 2,
              ),
              validator: (v) => (v ?? '').trim().isEmpty ? null : Validators.email(v),
            ),
            TextFormField(
              key: const Key('walk-in-phone'),
              controller: _phone,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(
                labelText: 'Phone number (optional)',
                hintText: '012-345 6789',
              ),
              validator: (v) => validatePhone(v, required: false),
            ),
            // D-103: MyKad or passport (with nationality).
            IdentityFields(
              id: _ic,
              nationality: _nationality,
              idKey: const Key('walk-in-ic'),
              nationalityKey: const Key('walk-in-nationality'),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
              ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
      FilledButton(
        key: const Key('walk-in-save'),
        onPressed: _busy ? null : _save,
        child: const Text('Register patient'),
      ),
    ],
  );
}

/// D-129: the one-time setup code for a patient without an email, shown at the counter.
Future<void> showSetupCode(BuildContext context, String name, String code) => showDialog<void>(
  context: context,
  barrierDismissible: false,
  builder: (context) => AlertDialog(
    key: const Key('walk-in-code-dialog'),
    icon: const Icon(Icons.pin_outlined),
    title: Text('Setup code for $name'),
    content: SizedBox(
      width: 420,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SelectableText(
            code,
            key: const Key('walk-in-code'),
            style: Theme.of(
              context,
            ).textTheme.displaySmall?.copyWith(fontWeight: FontWeight.bold, letterSpacing: 8),
          ),
          const SizedBox(height: 12),
          const Text(
            'Write this code down for the patient. In the Harvey app they tap '
            '"Registered at the clinic? Use your setup code", enter their MyKad or passport '
            'number and this code, and choose a password. Then they sign in with their '
            'MyKad/passport number and fill in their health profile.\n\n'
            'The code works once and lasts 7 days. It is not shown again; use "New setup '
            'code" if it is lost.',
          ),
        ],
      ),
    ),
    actions: [
      FilledButton(
        key: const Key('walk-in-code-done'),
        onPressed: () => Navigator.pop(context),
        child: const Text('Done'),
      ),
    ],
  ),
);
