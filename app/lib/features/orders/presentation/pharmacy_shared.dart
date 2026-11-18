import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/services/api/api_client.dart';
import '../../appointments/domain/appointment_text.dart' show dateLabel;
import '../data/order_models.dart';
import '../state/orders_providers.dart';

/// Shared pharmacy and admin portal pieces (D-66, D-69, D-70): the action runner, card
/// section, prompt, stock and catalogue dialogs.

Future<void> runPharmacyAction(
  BuildContext context,
  WidgetRef ref,
  Future<void> Function() action,
  String done,
) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    await action();
    ref
      ..invalidate(pharmacyQueueProvider)
      ..invalidate(stockProvider);
    messenger.showSnackBar(SnackBar(content: Text(done)));
  } on ApiException catch (e) {
    // D-102: the order moved on elsewhere (courier, another tab); show where it is now.
    ref.invalidate(pharmacyQueueProvider);
    messenger.showSnackBar(SnackBar(content: Text(e.message)));
  } catch (_) {
    messenger.showSnackBar(const SnackBar(content: Text('Something went wrong. Try again.')));
  }
}

/// D-109: one order from the pharmacy Orders tabs; its back button returns there.
String pharmacyOrderPath(String id) => '/pharmacy/order/$id?back=/pharmacy&backLabel=Orders';

String isoDate(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

class PharmacySection extends StatelessWidget {
  const PharmacySection({
    super.key,
    required this.icon,
    required this.title,
    required this.child,
    this.action,
  });
  final IconData icon;
  final String title;
  final Widget child;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: Theme.of(context).colorScheme.primary),
              const SizedBox(width: 8),
              Expanded(child: Text(title, style: Theme.of(context).textTheme.titleLarge)),
              ?action,
            ],
          ),
          const SizedBox(height: 8),
          child,
        ],
      ),
    ),
  );
}

/// "New Stock" quick action (Fig 4.3.13.1).
Future<void> addStockItem(BuildContext context, WidgetRef ref) async {
  final catalog = await ref.read(catalogProvider.future).catchError((_) => <CatalogItem>[]);
  final stock = await ref.read(stockProvider.future).catchError((_) => <StockItem>[]);
  if (!context.mounted) return;
  final result = await showDialog<StockEntry>(
    context: context,
    builder: (_) => StockDialog(
      title: 'New stock item',
      askName: true,
      catalog: catalog,
      existing: [for (final s in stock) s.name],
    ),
  );
  if (result == null || !context.mounted) return;
  // D-69: a stock item named like a catalogue medicine is linked to it.
  final linked = catalog
      .where((c) => c.label.toLowerCase() == result.name.toLowerCase())
      .firstOrNull;
  await runPharmacyAction(
    context,
    ref,
    () => ref
        .read(ordersRepositoryProvider)
        .addStock(
          name: result.name,
          units: result.units,
          expiryDate: result.expiry,
          lowStockAt: result.lowStockAt,
          catalogId: linked?.id,
        ),
    '${result.name} added to stock.',
  );
}

/// What the stock dialog returns: the medicine, units received, that batch's expiry
/// (yyyy-MM-dd) and, for a new item, the low-stock warning level.
typedef StockEntry = ({String name, int units, String expiry, int lowStockAt});

/// D-114: limits checked before saving (the server checks them again).
abstract final class StockRules {
  static const maxUnits = 100000;
  static const maxWarn = 100000;
  static final medicine = RegExp(
    r"^[A-Za-z][A-Za-z .'\-]{1,40}\s\d+(\.\d+)?\s?(mg|mcg|g|ml|mg/ml|iu|%)$",
    caseSensitive: false,
  );

  static String? units(String v) {
    if (v.isEmpty) return null;
    final n = int.tryParse(v);
    if (n == null || n < 1) return 'Enter at least 1 unit.';
    if (n > maxUnits) return 'At most $maxUnits units in one delivery.';
    return null;
  }

  static String? warnAt(String v) {
    if (v.isEmpty) return 'Enter a warning level.';
    final n = int.tryParse(v);
    if (n == null || n < 0 || n > maxWarn) return 'Enter 0 to $maxWarn units.';
    return null;
  }

  static String? name(String v, List<String> existing) {
    if (v.isEmpty) return null;
    if (!medicine.hasMatch(v)) return 'Write the name and strength, e.g. Paracetamol 500mg.';
    if (existing.any((e) => e.toLowerCase() == v.toLowerCase())) {
      return 'Already in stock. Use "Receive stock" on its row.';
    }
    return null;
  }
}

class StockDialog extends StatefulWidget {
  const StockDialog({
    super.key,
    required this.title,
    required this.askName,
    this.catalog = const [],
    this.existing = const [],
    this.current,
  });
  final String title;
  final bool askName;

  /// D-69: picking a catalogue medicine fills the name and links the stock to it.
  final List<CatalogItem> catalog;

  /// Names already in stock (a new item must not repeat one).
  final List<String> existing;

  /// When receiving: the item being topped up.
  final StockItem? current;

  @override
  State<StockDialog> createState() => StockDialogState();
}

class StockDialogState extends State<StockDialog> {
  final _name = TextEditingController();
  final _units = TextEditingController();
  final _warn = TextEditingController(text: '50');
  DateTime? _expiry;
  late bool _fromCatalog = _choices.isNotEmpty;
  String? _picked;

  List<CatalogItem> get _choices => [
    for (final c in widget.catalog)
      if (c.active && !widget.existing.any((e) => e.toLowerCase() == c.label.toLowerCase())) c,
  ];

  @override
  void dispose() {
    _name.dispose();
    _units.dispose();
    _warn.dispose();
    super.dispose();
  }

  String get _medicine => _fromCatalog ? (_picked ?? '') : _name.text.trim();

  bool get _valid =>
      _units.text.isNotEmpty &&
      StockRules.units(_units.text) == null &&
      _expiry != null &&
      (!widget.askName ||
          (_medicine.isNotEmpty &&
              (_fromCatalog || StockRules.name(_medicine, widget.existing) == null) &&
              StockRules.warnAt(_warn.text) == null));

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final soon = _expiry != null && _expiry!.difference(DateTime.now()) < const Duration(days: 90);
    final c = widget.current;
    final digits = [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(6)];
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (c != null) ...[
                Text(
                  'On hand: ${c.units} units · warns below ${c.lowStockAt}',
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: 16),
              ],
              if (widget.askName) ...[
                if (_choices.isNotEmpty) ...[
                  SegmentedButton<bool>(
                    key: const Key('stock-source'),
                    segments: const [
                      ButtonSegment(
                        value: true,
                        icon: Icon(Icons.menu_book_outlined),
                        label: Text('From catalogue'),
                      ),
                      ButtonSegment(
                        value: false,
                        icon: Icon(Icons.edit_outlined),
                        label: Text('Other medicine'),
                      ),
                    ],
                    selected: {_fromCatalog},
                    onSelectionChanged: (v) => setState(() => _fromCatalog = v.first),
                  ),
                  const SizedBox(height: 16),
                ],
                if (_fromCatalog)
                  DropdownButtonFormField<String>(
                    key: const Key('stock-catalog'),
                    isExpanded: true,
                    initialValue: _picked,
                    decoration: const InputDecoration(
                      labelText: 'Medicine',
                      helperText: 'Catalogue medicines not yet in stock.',
                      prefixIcon: Icon(Icons.medication_outlined),
                    ),
                    items: [
                      for (final c in _choices)
                        DropdownMenuItem(value: c.label, child: Text(c.label)),
                    ],
                    onChanged: (v) => setState(() => _picked = v),
                  )
                else
                  TextField(
                    key: const Key('stock-name'),
                    controller: _name,
                    maxLength: 60,
                    decoration: InputDecoration(
                      labelText: 'Medicine and strength',
                      hintText: 'e.g. Paracetamol 500mg',
                      prefixIcon: const Icon(Icons.medication_outlined),
                      errorText: StockRules.name(_name.text.trim(), widget.existing),
                      errorMaxLines: 2,
                      counterText: '',
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                const SizedBox(height: 12),
              ],
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: TextField(
                      key: const Key('stock-units'),
                      controller: _units,
                      keyboardType: TextInputType.number,
                      inputFormatters: digits,
                      decoration: InputDecoration(
                        labelText: 'Units received',
                        suffixText: 'units',
                        prefixIcon: const Icon(Icons.inventory_2_outlined),
                        errorText: StockRules.units(_units.text),
                        errorMaxLines: 2,
                      ),
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                  if (widget.askName) ...[
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        key: const Key('stock-warn'),
                        controller: _warn,
                        keyboardType: TextInputType.number,
                        inputFormatters: digits,
                        decoration: InputDecoration(
                          labelText: 'Warn below',
                          suffixText: 'units',
                          prefixIcon: const Icon(Icons.notifications_active_outlined),
                          errorText: StockRules.warnAt(_warn.text),
                          errorMaxLines: 2,
                        ),
                        onChanged: (_) => setState(() {}),
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 12),
              InkWell(
                key: const Key('stock-expiry'),
                borderRadius: BorderRadius.circular(8),
                onTap: () async {
                  final now = DateTime.now();
                  final d = await showDatePicker(
                    context: context,
                    helpText: 'Expiry date of this batch',
                    firstDate: DateTime(now.year, now.month, now.day + 1),
                    lastDate: DateTime(now.year + 10),
                    initialDate: _expiry ?? DateTime(now.year + 1, now.month, now.day),
                  );
                  if (d != null) setState(() => _expiry = d);
                },
                child: InputDecorator(
                  decoration: InputDecoration(
                    labelText: 'Expiry date',
                    prefixIcon: const Icon(Icons.event),
                    suffixIcon: const Icon(Icons.arrow_drop_down),
                    helperText: soon ? 'Expires within 3 months. Check the batch.' : null,
                    helperStyle: TextStyle(color: Colors.amber.shade800),
                  ),
                  child: Text(
                    _expiry == null
                        ? 'Choose the batch expiry'
                        : '${dateLabel(_expiry!)} ${_expiry!.year}',
                    style: _expiry == null
                        ? theme.textTheme.bodyLarge?.copyWith(color: theme.colorScheme.outline)
                        : theme.textTheme.bodyLarge,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          key: const Key('stock-save'),
          onPressed: _valid
              ? () => Navigator.pop<StockEntry>(context, (
                  name: _medicine,
                  units: int.parse(_units.text),
                  expiry: isoDate(_expiry!),
                  lowStockAt: int.tryParse(_warn.text) ?? 50,
                ))
              : null,
          child: Text(widget.askName ? 'Add to stock' : 'Receive'),
        ),
      ],
    );
  }
}

class PromptDialog extends StatefulWidget {
  const PromptDialog({
    super.key,
    required this.title,
    required this.fieldKey,
    required this.label,
    required this.confirmText,
    this.message,
    this.initial = '',
    this.confirmKey,
    this.prefixText,
    this.keyboardType,
    this.allowed,
    this.maxLength,
    this.isValid,
    this.errorFor,
  });

  final String title;
  final String? message;
  final String initial;
  final Key fieldKey;
  final String label;
  final Key? confirmKey;
  final String confirmText;
  final String? prefixText;
  final TextInputType? keyboardType;
  final RegExp? allowed;
  final int? maxLength;
  final bool Function(String)? isValid;

  /// D-114: a message shown under the field while the value is invalid.
  final String? Function(String)? errorFor;

  @override
  State<PromptDialog> createState() => PromptDialogState();
}

class PromptDialogState extends State<PromptDialog> {
  late final _ctl = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ok = widget.isValid?.call(_ctl.text.trim()) ?? true;
    return AlertDialog(
      title: Text(widget.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (widget.message != null) Text(widget.message!),
          TextField(
            key: widget.fieldKey,
            controller: _ctl,
            autofocus: true,
            maxLength: widget.maxLength,
            keyboardType: widget.keyboardType,
            inputFormatters: [
              if (widget.allowed != null) FilteringTextInputFormatter.allow(widget.allowed!),
            ],
            decoration: InputDecoration(
              labelText: widget.label,
              prefixText: widget.prefixText,
              errorText: widget.errorFor?.call(_ctl.text.trim()),
              errorMaxLines: 2,
            ),
            onChanged: (_) => setState(() {}),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          key: widget.confirmKey,
          onPressed: ok ? () => Navigator.pop(context, _ctl.text.trim()) : null,
          child: Text(widget.confirmText),
        ),
      ],
    );
  }
}

/// What the catalogue form returns (add or edit).
typedef CatalogEntry = ({
  String name,
  String strength,
  String form,
  String drugClass,
  double price,
});

/// D-114: catalogue rules, checked before saving (the server checks them again).
abstract final class CatalogRules {
  /// The forms the server accepts (`CatalogItemRequest.form`).
  static const forms = ['tablet', 'capsule', 'syrup', 'injection', 'other'];

  /// Offered in the class menu; any other class can be typed.
  static const commonClasses = [
    'ACE inhibitor',
    'Angiotensin receptor blocker',
    'Beta blocker',
    'Calcium channel blocker',
    'Diuretic',
    'Alpha blocker',
    'Statin',
    'Antiplatelet',
  ];

  static final _name = RegExp(r"^[A-Za-z][A-Za-z .'\-]{1,39}$");
  static final _strength = RegExp(
    r'^\d+(\.\d+)?\s?(mg|mcg|g|ml|mg/ml|mg/5ml|iu|%)$',
    caseSensitive: false,
  );
  static final _price = RegExp(r'^\d{1,4}(\.\d{1,2})?$');

  static String? name(String v) {
    if (v.isEmpty) return 'Enter the medicine name.';
    if (RegExp(r'\d').hasMatch(v)) return 'Name only. Put the strength in its own box.';
    if (!_name.hasMatch(v)) return '2 to 40 letters, e.g. Olmesartan.';
    return null;
  }

  static String? strength(String v) {
    if (v.isEmpty) return 'Enter the strength.';
    if (!_strength.hasMatch(v)) return 'e.g. 5mg, 6.25mg or 10mg/ml.';
    return null;
  }

  static String? drugClass(String v) {
    if (v.trim().length < 3) return 'Choose or type the drug class.';
    if (v.trim().length > 60) return 'At most 60 characters.';
    return null;
  }

  static String? price(String v) {
    if (v.isEmpty) return 'Enter the price.';
    if (!_price.hasMatch(v)) return 'A price like 0.45 (two decimals at most).';
    final p = double.parse(v);
    if (p < 0.01 || p > 1000) return 'Between RM0.01 and RM1000.';
    return null;
  }
}

/// D-114: add or edit a catalogue medicine. Form is a menu (as when a doctor prescribes),
/// the class is picked or typed, and a name + strength already in the catalogue is
/// refused.
class CatalogFormDialog extends StatefulWidget {
  const CatalogFormDialog({super.key, this.item, this.catalog = const []});

  /// Null to add a new medicine.
  final CatalogItem? item;
  final List<CatalogItem> catalog;

  @override
  State<CatalogFormDialog> createState() => CatalogFormDialogState();
}

class CatalogFormDialogState extends State<CatalogFormDialog> {
  late final _name = TextEditingController(text: widget.item?.name ?? '');
  late final _strength = TextEditingController(text: widget.item?.strength ?? '');
  late final _class = TextEditingController(text: widget.item?.drugClass ?? '');
  late final _price = TextEditingController(
    text: widget.item == null ? '' : widget.item!.unitPrice.toStringAsFixed(2),
  );
  late String _form = CatalogRules.forms.contains(widget.item?.form) ? widget.item!.form : 'tablet';

  /// Errors show once a field has been touched, or after Save is pressed.
  final _touched = <String>{};
  bool _tried = false;

  @override
  void dispose() {
    for (final c in [_name, _strength, _class, _price]) {
      c.dispose();
    }
    super.dispose();
  }

  String? _duplicate() {
    final label = '${_name.text.trim()} ${_strength.text.trim()}'.toLowerCase();
    final clash = widget.catalog.any(
      (c) => c.id != widget.item?.id && c.label.toLowerCase() == label,
    );
    return clash ? 'Already in the catalogue.' : null;
  }

  String? _error(String field) {
    if (!_tried && !_touched.contains(field)) return null;
    return switch (field) {
      'name' => CatalogRules.name(_name.text.trim()),
      'strength' => CatalogRules.strength(_strength.text.trim()) ?? _duplicate(),
      'class' => CatalogRules.drugClass(_class.text),
      'price' => CatalogRules.price(_price.text.trim()),
      _ => null,
    };
  }

  bool get _valid =>
      CatalogRules.name(_name.text.trim()) == null &&
      CatalogRules.strength(_strength.text.trim()) == null &&
      _duplicate() == null &&
      CatalogRules.drugClass(_class.text) == null &&
      CatalogRules.price(_price.text.trim()) == null;

  void _save() {
    if (!_valid) {
      setState(() => _tried = true);
      return;
    }
    Navigator.pop<CatalogEntry>(context, (
      name: _name.text.trim(),
      strength: _strength.text.trim().replaceAll(' ', ''),
      form: _form,
      drugClass: _class.text.trim(),
      price: double.parse(_price.text.trim()),
    ));
  }

  void _touch(String field) => setState(() => _touched.add(field));

  @override
  Widget build(BuildContext context) {
    final editing = widget.item != null;
    final classes = {
      ...CatalogRules.commonClasses,
      for (final c in widget.catalog)
        if (c.drugClass.isNotEmpty) c.drugClass,
    }.toList()..sort();
    return AlertDialog(
      title: Text(editing ? 'Edit ${widget.item!.label}' : 'Add a medicine'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                editing
                    ? 'A new price applies to new prescriptions only.'
                    : 'Doctors can prescribe it once it is added.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 16),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    flex: 3,
                    child: TextField(
                      key: Key(editing ? 'catalog-edit-name' : 'catalog-name'),
                      controller: _name,
                      maxLength: 40,
                      decoration: InputDecoration(
                        labelText: 'Name',
                        hintText: 'e.g. Olmesartan',
                        prefixIcon: const Icon(Icons.medication_outlined),
                        errorText: _error('name'),
                        errorMaxLines: 2,
                        counterText: '',
                      ),
                      onChanged: (_) => _touch('name'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 2,
                    child: TextField(
                      key: Key(editing ? 'catalog-edit-strength' : 'catalog-strength'),
                      controller: _strength,
                      maxLength: 12,
                      decoration: InputDecoration(
                        labelText: 'Strength',
                        hintText: 'e.g. 20mg',
                        errorText: _error('strength'),
                        errorMaxLines: 2,
                        counterText: '',
                      ),
                      onChanged: (_) => _touch('strength'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                key: Key(editing ? 'catalog-edit-form' : 'catalog-form'),
                initialValue: _form,
                decoration: const InputDecoration(
                  labelText: 'Form',
                  prefixIcon: Icon(Icons.category_outlined),
                ),
                items: [
                  for (final f in CatalogRules.forms)
                    DropdownMenuItem(value: f, child: Text(f[0].toUpperCase() + f.substring(1))),
                ],
                onChanged: (v) => setState(() => _form = v ?? _form),
              ),
              const SizedBox(height: 12),
              LayoutBuilder(
                builder: (context, box) => DropdownMenu<String>(
                  key: Key(editing ? 'catalog-edit-class' : 'catalog-class'),
                  controller: _class,
                  width: box.maxWidth,
                  requestFocusOnTap: true,
                  enableFilter: true,
                  label: const Text('Drug class'),
                  leadingIcon: const Icon(Icons.science_outlined),
                  helperText: 'Pick one or type another.',
                  errorText: _error('class'),
                  menuHeight: 280,
                  dropdownMenuEntries: [
                    for (final c in classes) DropdownMenuEntry(value: c, label: c),
                  ],
                  onSelected: (_) => _touch('class'),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                key: Key(editing ? 'catalog-edit-price' : 'catalog-price'),
                controller: _price,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'^\d{0,4}(\.\d{0,2})?')),
                ],
                decoration: InputDecoration(
                  labelText: 'Price per $_form',
                  prefixText: 'RM ',
                  prefixIcon: const Icon(Icons.payments_outlined),
                  errorText: _error('price'),
                ),
                onChanged: (_) => _touch('price'),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          key: Key(editing ? 'catalog-edit-save' : 'catalog-save'),
          onPressed: _save,
          child: Text(editing ? 'Save' : 'Add medicine'),
        ),
      ],
    );
  }
}

/// D-74: cancel an unpaid order after asking for the reason shown to the patient.
Future<bool> cancelOrderWithReason(BuildContext context, WidgetRef ref, MedicationOrder o) async {
  final reason = await showDialog<String>(
    context: context,
    builder: (_) => PromptDialog(
      title: 'Cancel order ${o.ref}?',
      message: 'The patient is told the order was cancelled and why.',
      fieldKey: const Key('cancel-reason'),
      label: 'Reason',
      confirmKey: const Key('cancel-confirm'),
      confirmText: 'Cancel order',
      maxLength: 300,
      isValid: (v) => v.trim().length >= 3,
    ),
  );
  if (reason == null || !context.mounted) return false;
  await runPharmacyAction(
    context,
    ref,
    () => ref.read(ordersRepositoryProvider).cancelOrder(o.id, reason),
    'Order ${o.ref} cancelled.',
  );
  ref.invalidate(ordersOverviewProvider);
  ref.invalidate(orderProvider(o.id));
  return true;
}

/// D-89: the driver rejected the booking, or none is coming. The booking is cancelled at
/// the courier and the delivery fails; the patient is asked to rebook or collect.
Future<bool> cancelCourierWithReason(BuildContext context, WidgetRef ref, MedicationOrder o) async {
  final reason = await showDialog<String>(
    context: context,
    builder: (_) => PromptDialog(
      title: 'Cancel the ${o.courierBrand} booking?',
      message:
          'Use this when the driver rejected the order or none is coming. The delivery is '
          'marked failed and the patient is asked to rebook or collect at the pharmacy.',
      fieldKey: const Key('courier-cancel-reason'),
      label: 'Reason',
      initial: 'The driver rejected the order.',
      confirmKey: const Key('courier-cancel-confirm'),
      confirmText: 'Cancel booking',
      maxLength: 300,
      isValid: (v) => v.trim().length >= 3,
    ),
  );
  if (reason == null || !context.mounted) return false;
  await runPharmacyAction(
    context,
    ref,
    () => ref.read(ordersRepositoryProvider).cancelCourier(o.id, reason.trim()),
    'Courier booking cancelled. The patient has been told.',
  );
  ref.invalidate(ordersOverviewProvider);
  ref.invalidate(orderProvider(o.id));
  return true;
}
