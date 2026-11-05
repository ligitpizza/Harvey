import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// D-82: a dose is an amount (numbers and one decimal point only) and a unit from a list.
/// Saved as one string the same way the API writes it: strengths without a space ("5mg",
/// "2.5ml"), counts with one ("1 tablet", "2 tablets"). Mirrors backend `schemas/dose.py`.
class Dose {
  const Dose(this.amount, this.unit);

  final double amount;
  final String unit;

  static const strengthUnits = ['mg', 'mcg', 'g', 'ml', 'IU'];
  static const countUnits = ['tablet', 'capsule', 'drop', 'puff', 'sachet'];
  static const units = [...strengthUnits, ...countUnits];

  /// Unit names as shown in the dropdown.
  static String unitLabel(String unit) => countUnits.contains(unit) ? '$unit(s)' : unit;

  static final _re = RegExp(r'^\s*(\d{1,4}(?:\.\d{1,2})?)\s*([A-Za-z]+)\s*$');

  /// '5mg', '5 MG', '2 tablets' -> Dose; null for anything else (e.g. '20mg 1 tablet').
  static Dose? parse(String? text) {
    final m = _re.firstMatch(text ?? '');
    if (m == null) return null;
    final raw = m.group(2)!.toLowerCase();
    String? unit;
    for (final u in strengthUnits) {
      if (u.toLowerCase() == raw) unit = u;
    }
    for (final u in countUnits) {
      if (raw == u || raw == '${u}s') unit = u;
    }
    final amount = double.parse(m.group(1)!);
    return unit == null || amount <= 0 ? null : Dose(amount, unit);
  }

  static String amountText(double a) =>
      a == a.roundToDouble() ? a.toStringAsFixed(0) : a.toString();

  @override
  String toString() {
    final a = amountText(amount);
    if (strengthUnits.contains(unit)) return '$a$unit';
    return '$a $unit${amount == 1 ? '' : 's'}';
  }
}

/// Amount + unit inputs. [onChanged] gets the combined dose ('5mg') or null while the
/// amount is empty or invalid. The amount field has key [fieldKey]; the unit
/// `<fieldKey>-unit`.
class DoseField extends StatefulWidget {
  const DoseField({
    super.key,
    required this.fieldKey,
    required this.onChanged,
    this.initial,
    this.enabled = true,
    this.defaultUnit = 'mg',
    this.label = 'Dose',
    this.dense = false,
  });

  final String fieldKey;
  final String? initial;
  final ValueChanged<String?> onChanged;
  final bool enabled;
  final String defaultUnit;
  final String label;

  /// Narrow layout for the doctor's prescription lines.
  final bool dense;

  @override
  State<DoseField> createState() => _DoseFieldState();
}

class _DoseFieldState extends State<DoseField> {
  late final Dose? _start = Dose.parse(widget.initial);
  late final _amount = TextEditingController(
    text: _start == null ? '' : Dose.amountText(_start.amount),
  );
  late String _unit = _start?.unit ?? widget.defaultUnit;

  @override
  void initState() {
    super.initState();
    // An older free-text dose that can't be split is shown so the user re-enters it.
    WidgetsBinding.instance.addPostFrameCallback((_) => _emit());
  }

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  void _emit() {
    final a = double.tryParse(_amount.text);
    widget.onChanged(a == null || a <= 0 ? null : Dose(a, _unit).toString());
  }

  static String? validateAmount(String? v) {
    final t = (v ?? '').trim();
    if (t.isEmpty) return 'Enter the amount.';
    final a = double.tryParse(t);
    if (a == null) return 'Numbers only, e.g. 5 or 2.5.';
    if (a <= 0) return 'Must be more than 0.';
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final old = widget.initial != null && widget.initial!.trim().isNotEmpty && _start == null;
    final amount = TextFormField(
      key: Key(widget.fieldKey),
      controller: _amount,
      enabled: widget.enabled,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      // Digits and one decimal point only (at most 4 + 2 digits).
      inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'^\d{0,4}(\.\d{0,2})?'))],
      decoration: InputDecoration(
        labelText: widget.label,
        hintText: 'e.g. 5',
        helperText: old && !widget.dense ? 'Was "${widget.initial}". Re-enter it.' : null,
      ),
      validator: validateAmount,
      onChanged: (_) => _emit(),
    );
    final unit = DropdownButtonFormField<String>(
      key: Key('${widget.fieldKey}-unit'),
      initialValue: _unit,
      isExpanded: true,
      decoration: const InputDecoration(labelText: 'Unit'),
      items: [
        for (final u in Dose.units) DropdownMenuItem(value: u, child: Text(Dose.unitLabel(u))),
      ],
      onChanged: widget.enabled
          ? (u) {
              if (u == null) return;
              setState(() => _unit = u);
              _emit();
            }
          : null,
    );
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(flex: widget.dense ? 4 : 3, child: amount),
        const SizedBox(width: 12),
        Expanded(flex: widget.dense ? 5 : 2, child: unit),
      ],
    );
  }
}
