import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../shared/models/health_models.dart';
import '../../../shared/services/api/api_client.dart';
import '../data/medications_repository.dart';
import '../domain/med_schedule.dart';
import '../state/medication_providers.dart';
import '../../../shared/widgets/dose_input.dart';

/// UC5.1 add / edit a medication, with UC5.1 E1 duplicate and UC5.6 interaction warnings.
class MedicationFormPage extends ConsumerStatefulWidget {
  const MedicationFormPage({super.key, this.existing, this.prefill});

  /// Null when adding.
  final Medication? existing;

  /// D-49: values copied from a doctor's prescription ("Add to my reminders").
  final MedicationDraft? prefill;

  @override
  ConsumerState<MedicationFormPage> createState() => _MedicationFormPageState();
}

class _MedicationFormPageState extends ConsumerState<MedicationFormPage> {
  final _form = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.existing?.name ?? widget.prefill?.name);
  late final _dosage = TextEditingController(
    text: widget.existing?.dosage ?? widget.prefill?.dosage,
  );
  late final String? _initialSchedule = widget.existing?.schedule ?? widget.prefill?.schedule;
  late final _quantity = TextEditingController(
    text: widget.existing?.quantityOnHand?.toStringAsFixed(0),
  );
  late final _threshold = TextEditingController(
    text: '${widget.existing?.refillThresholdDays ?? 7}',
  );
  late bool _asNeeded = _initialSchedule != null && tryParseSchedule(_initialSchedule) == null;
  late final List<DoseTime> _times = [
    ...?(_initialSchedule == null ? null : tryParseSchedule(_initialSchedule)),
  ];
  bool _saving = false;
  String? _error;

  bool get _editing => widget.existing != null;

  /// D-69: set by the doctor; only the reminder times can change.
  bool get _locked => widget.existing?.fromDoctor ?? false;

  @override
  void dispose() {
    for (final c in [_name, _dosage, _quantity, _threshold]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _addTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: const TimeOfDay(hour: 8, minute: 0),
      helpText: 'Dose time (Malaysia time)',
    );
    if (picked == null) return;
    final t = DoseTime(picked.hour, picked.minute);
    setState(() {
      if (!_times.contains(t)) _times.add(t);
      _times.sort();
    });
  }

  /// D-90: move one reminder of a doctor-set medicine; the number of times stays.
  Future<void> _moveTime(int index) async {
    final now = _times[index];
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: now.hour, minute: now.minute),
      helpText: 'Move this reminder (Malaysia time)',
    );
    if (picked == null || !mounted) return;
    final t = DoseTime(picked.hour, picked.minute);
    if (t != now && _times.contains(t)) {
      setState(() => _error = 'You already have a reminder at ${t.label}.');
      return;
    }
    setState(() {
      _error = null;
      _times[index] = t;
      _times.sort();
    });
  }

  MedicationDraft _draft() => MedicationDraft(
    name: _name.text.trim(),
    dosage: _dosage.text.trim(),
    schedule: formatSchedule(_asNeeded ? null : _times),
    quantityOnHand: double.tryParse(_quantity.text.trim()),
    refillThresholdDays: int.tryParse(_threshold.text.trim()) ?? 7,
  );

  Future<void> _save({bool acknowledge = false}) async {
    setState(() => _error = null);
    if (!_form.currentState!.validate()) return;
    if (!_asNeeded && _times.isEmpty) {
      setState(() => _error = 'Add at least one dose time, or choose "As needed".');
      return;
    }
    setState(() => _saving = true);
    try {
      await ref
          .read(medicationsRepositoryProvider)
          .save(_draft(), id: widget.existing?.id, acknowledge: acknowledge);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_editing ? 'Medication updated.' : 'Medication added.')),
      );
      context.pop();
    } on MedicationWarnings catch (w) {
      if (!mounted) return;
      setState(() => _saving = false);
      final go = await _showWarnings(context, w);
      if (go == true) await _save(acknowledge: true);
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } catch (_) {
      setState(() => _error = 'Could not save. Please check your connection and try again.');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Delete medication?'),
        content: Text('${widget.existing!.name} and its reminders will be removed.'),
        actions: [
          TextButton(onPressed: () => c.pop(false), child: const Text('Cancel')),
          FilledButton(onPressed: () => c.pop(true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _saving = true);
    try {
      await ref.read(medicationsRepositoryProvider).delete(widget.existing!.id);
      if (mounted) context.pop();
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not delete. Please try again.');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_locked) return _record(context);
    final digits = [FilteringTextInputFormatter.digitsOnly];
    return Scaffold(
      appBar: AppBar(
        title: Text(_editing ? 'Edit medication' : 'Add medication'),
        actions: [
          if (_editing && !_locked)
            IconButton(
              key: const Key('delete-medication'),
              tooltip: 'Delete',
              onPressed: _saving ? null : _delete,
              icon: const Icon(Icons.delete_outline),
            ),
        ],
      ),
      body: Form(
        key: _form,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (_locked)
              Card(
                key: const Key('med-locked'),
                color: Theme.of(context).colorScheme.secondaryContainer,
                child: ListTile(
                  leading: const Icon(Icons.lock_outline),
                  title: Text('Prescribed by ${widget.existing!.prescribedBy ?? 'your doctor'}'),
                  subtitle: const Text(
                    'You can change the reminder times. Ask your doctor to change the '
                    'medicine, dose or quantity.',
                  ),
                ),
              ),
            TextFormField(
              key: const Key('med-name'),
              controller: _name,
              readOnly: _locked,
              decoration: const InputDecoration(labelText: 'Medicine name'),
              textCapitalization: TextCapitalization.words,
              validator: (v) => (v ?? '').trim().length < 2 ? 'Enter the medicine name.' : null,
            ),
            const SizedBox(height: 12),
            // D-82: amount (numbers only) + unit. The doctor's dose is shown as set.
            if (_locked)
              TextFormField(
                key: const Key('med-dosage'),
                controller: _dosage,
                readOnly: true,
                decoration: const InputDecoration(labelText: 'Dosage'),
              )
            else
              DoseField(
                fieldKey: 'med-dosage',
                label: 'Dosage',
                initial: _dosage.text,
                onChanged: (v) => _dosage.text = v ?? '',
              ),
            const SizedBox(height: 16),
            Text('When do you take it?', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            SegmentedButton<bool>(
              key: const Key('med-mode'),
              segments: const [
                ButtonSegment(value: false, label: Text('At set times')),
                ButtonSegment(value: true, label: Text('As needed')),
              ],
              selected: {_asNeeded},
              onSelectionChanged: (s) => setState(() => _asNeeded = s.first),
            ),
            if (!_asNeeded) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final t in _times)
                    InputChip(
                      key: Key('time-${t.hhmm}'),
                      label: Text(t.label),
                      onDeleted: () => setState(() => _times.remove(t)),
                    ),
                  ActionChip(
                    key: const Key('add-time'),
                    avatar: const Icon(Icons.add_alarm, size: 18),
                    label: const Text('Add time'),
                    onPressed: _times.length >= 8 ? null : _addTime,
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                "You'll get a reminder at each time (Malaysia time).",
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            const SizedBox(height: 16),
            TextFormField(
              key: const Key('med-quantity'),
              controller: _quantity,
              readOnly: _locked,
              keyboardType: TextInputType.number,
              inputFormatters: digits,
              decoration: const InputDecoration(
                labelText: 'Doses on hand (optional)',
                helperText: 'Used for refill reminders.',
              ),
            ),
            const SizedBox(height: 12),
            TextFormField(
              key: const Key('med-threshold'),
              controller: _threshold,
              keyboardType: TextInputType.number,
              inputFormatters: digits,
              decoration: const InputDecoration(
                labelText: 'Remind me to refill when this many days are left',
              ),
              validator: (v) {
                final n = int.tryParse((v ?? '').trim());
                return n == null || n < 1 || n > 60 ? 'Enter 1 to 60 days.' : null;
              },
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                key: const Key('med-error'),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            const SizedBox(height: 24),
            FilledButton(
              key: const Key('save-medication'),
              onPressed: _saving ? null : _save,
              child: _saving
                  ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator())
                  : const Text('Save'),
            ),
          ],
        ),
      ),
    );
  }

  /// D-90: a doctor-set medicine is a record, not a form. The patient sees what the doctor
  /// prescribed and may only move the reminder times (same number as the doctor's
  /// frequency) and set when the refill reminder comes.
  Widget _record(BuildContext context) {
    final theme = Theme.of(context);
    final med = widget.existing!;
    final howOften = _asNeeded
        ? 'As needed'
        : switch (_times.length) {
            1 => 'Once a day',
            2 => 'Twice a day',
            final n => '$n times a day',
          };
    final rate = med.adherenceRate;
    Widget fact(String label, String value, {Key? key}) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 130, child: Text(label, style: theme.textTheme.bodyMedium)),
          Expanded(
            child: Text(
              value,
              key: key,
              style: theme.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
    return Scaffold(
      appBar: AppBar(title: const Text('Medication details')),
      body: Form(
        key: _form,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Card(
              key: const Key('med-locked'),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        CircleAvatar(
                          backgroundColor: theme.colorScheme.primaryContainer,
                          child: Icon(Icons.medication, color: theme.colorScheme.primary),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            med.name,
                            key: const Key('med-record-name'),
                            style: theme.textTheme.titleLarge,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    fact('Dose', med.dosage, key: const Key('med-record-dose')),
                    fact('How often', howOften, key: const Key('med-record-frequency')),
                    fact(
                      'Doses on hand',
                      med.quantityOnHand == null ? '—' : med.quantityOnHand!.toStringAsFixed(0),
                    ),
                    if (!_asNeeded)
                      fact(
                        'Adherence (30 days)',
                        rate == null ? 'No history yet' : '${rate.toStringAsFixed(0)}%',
                      ),
                    const Divider(height: 24),
                    Row(
                      children: [
                        Icon(Icons.lock_outline, size: 18, color: theme.colorScheme.outline),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Prescribed by ${med.prescribedBy ?? 'your doctor'}. Ask your doctor '
                            'to change the medicine, dose or how often.',
                            style: theme.textTheme.bodySmall,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text('Reminder times', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            if (_asNeeded)
              const Text('Take it when you need it. There are no set reminders.')
            else ...[
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final (i, t) in _times.indexed)
                    ActionChip(
                      key: Key('time-${t.hhmm}'),
                      avatar: const Icon(Icons.alarm, size: 18),
                      label: Text(t.label),
                      onPressed: _saving ? null : () => _moveTime(i),
                    ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                'Tap a time to move it (Malaysia time). Your doctor set how many a day.',
                style: theme.textTheme.bodySmall,
              ),
            ],
            const SizedBox(height: 20),
            TextFormField(
              key: const Key('med-threshold'),
              controller: _threshold,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: const InputDecoration(
                labelText: 'Remind me to refill when this many days are left',
                helperText: 'Your own setting, from 1 to 60 days.',
              ),
              validator: (v) {
                final n = int.tryParse((v ?? '').trim());
                return n == null || n < 1 || n > 60 ? 'Enter 1 to 60 days.' : null;
              },
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                key: const Key('med-error'),
                style: TextStyle(color: theme.colorScheme.error),
              ),
            ],
            const SizedBox(height: 24),
            FilledButton(
              key: const Key('save-medication'),
              onPressed: _saving ? null : _save,
              child: _saving
                  ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator())
                  : const Text('Save changes'),
            ),
          ],
        ),
      ),
    );
  }
}

/// UC5.1 E1 / UC5.6 E1: show warnings; true = save anyway.
Future<bool?> _showWarnings(BuildContext context, MedicationWarnings w) => showDialog<bool>(
  context: context,
  builder: (c) => AlertDialog(
    key: const Key('med-warnings'),
    icon: const Icon(Icons.warning_amber_rounded),
    title: const Text('Please check before saving'),
    content: SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final d in w.duplicates)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text('You already have $d on your list.'),
            ),
          for (final i in w.interactions)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                '${i.isCritical ? 'Serious interaction' : 'Possible interaction'} '
                'with ${i.existingDrug} (${i.severity}): ${i.message}',
              ),
            ),
          const SizedBox(height: 4),
          Text(
            'This check is not a substitute for a doctor or pharmacist. '
            'Ask them before taking these together.',
            style: Theme.of(c).textTheme.bodySmall,
          ),
        ],
      ),
    ),
    actions: [
      TextButton(onPressed: () => c.pop(false), child: const Text('Go back')),
      FilledButton(
        key: const Key('save-anyway'),
        onPressed: () => c.pop(true),
        child: const Text('Save anyway'),
      ),
    ],
  ),
);
