import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/settings/state/settings_providers.dart';
import '../providers/api_providers.dart';
import '../services/api/api_client.dart';

/// D-79: CSV / JSON import with a preview. The server checks every row; nothing is saved
/// until the admin presses Import.
enum ImportKind { inventory, users }

/// Picks a .csv / .json file; null when cancelled. Overridable in tests.
typedef ImportFilePicker = Future<(String name, Uint8List bytes)?> Function();

final importFilePickerProvider = Provider<ImportFilePicker>(
  (ref) => () async {
    final f = await FilePicker.pickFile(type: FileType.custom, allowedExtensions: ['csv', 'json']);
    if (f == null) return null;
    return (f.name, await f.readAsBytes());
  },
);

class ImportDialog extends ConsumerStatefulWidget {
  const ImportDialog({super.key, required this.kind});

  final ImportKind kind;

  @override
  ConsumerState<ImportDialog> createState() => _ImportDialogState();
}

class _ImportDialogState extends ConsumerState<ImportDialog> {
  String? _fileName;
  String? _format;
  String? _content;
  Map<String, dynamic>? _preview;
  String? _error;
  bool _busy = false;
  Map<String, dynamic>? _done;

  bool get _users => widget.kind == ImportKind.users;

  Future<Map<String, dynamic>> _call(bool commit) {
    final api = ref.read(apiClientProvider);
    return _users
        ? api.importUsers(_format!, _content!, commit)
        : api.importInventory(_format!, _content!, commit);
  }

  Future<void> _pick() async {
    final picked = await ref.read(importFilePickerProvider)();
    if (picked == null) return;
    final (name, bytes) = picked;
    final lower = name.toLowerCase();
    if (!lower.endsWith('.csv') && !lower.endsWith('.json')) {
      setState(() => _error = 'Choose a .csv or .json file.');
      return;
    }
    setState(() {
      _fileName = name;
      _format = lower.endsWith('.json') ? 'json' : 'csv';
      _content = utf8.decode(bytes, allowMalformed: true);
      _preview = null;
      _done = null;
      _error = null;
      _busy = true;
    });
    try {
      final p = await _call(false);
      setState(() => _preview = p);
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _commit() async {
    setState(() => _busy = true);
    try {
      final r = await _call(true);
      setState(() => _done = r);
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _template() async {
    try {
      final api = ref.read(apiClientProvider);
      final t = await (_users ? api.usersTemplate() : api.inventoryTemplate());
      await ref
          .read(fileSharerProvider)
          .share(
            Uint8List.fromList(utf8.encode('${t['csv']}')),
            fileName: _users ? 'harvey-staff-template.csv' : 'harvey-inventory-template.csv',
            mimeType: 'text/csv',
          );
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not download the template.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rows = [
      for (final r in (_done ?? _preview)?['rows'] as List<dynamic>? ?? const [])
        Map<String, dynamic>.from(r as Map),
    ];
    final valid = (_preview?['valid'] as num?)?.toInt() ?? 0;
    final invalid = (_preview?['invalid'] as num?)?.toInt() ?? 0;
    return AlertDialog(
      title: Text(_users ? 'Import staff accounts' : 'Import medicines and stock'),
      content: SizedBox(
        width: 720,
        height: 480,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _users
                  ? 'Columns: name, email, role (doctor / pharmacist / admin), specialty. '
                        'Each new account gets a password-setup email. Patients register '
                        'themselves.'
                  : 'Columns: name, strength, form, drugClass, unitPrice, units, lowStockAt, '
                        'expiryDate (YYYY-MM-DD). Rows matching a catalogue medicine (name + '
                        'strength) update it; units set the stock level.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                FilledButton.icon(
                  key: const Key('import-choose'),
                  onPressed: _busy || _done != null ? null : _pick,
                  icon: const Icon(Icons.upload_file),
                  label: const Text('Choose CSV or JSON file'),
                ),
                TextButton.icon(
                  key: const Key('import-template'),
                  onPressed: _template,
                  icon: const Icon(Icons.download),
                  label: const Text('Download template'),
                ),
                if (_fileName != null) Chip(label: Text(_fileName!)),
              ],
            ),
            if (_busy) const LinearProgressIndicator(),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  _error!,
                  key: const Key('import-error'),
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ),
            if (_done != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  _users
                      ? 'Created ${_done!['created']} account(s).'
                      : 'Added ${_done!['added']}, updated ${_done!['updated']}.',
                  key: const Key('import-done'),
                  style: TextStyle(color: Colors.green.shade700, fontWeight: FontWeight.bold),
                ),
              )
            else if (_preview != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  '$valid row(s) ready to import · $invalid with problems (skipped)',
                  key: const Key('import-summary'),
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
            const SizedBox(height: 8),
            Expanded(
              child: rows.isEmpty
                  ? const Center(child: Text('Choose a file to see a preview.'))
                  : SingleChildScrollView(
                      child: Column(
                        children: [
                          for (final r in rows)
                            ListTile(
                              key: Key('import-row-${r['row']}'),
                              dense: true,
                              leading: Icon(
                                r['error'] == null ? Icons.check_circle : Icons.error,
                                color: r['error'] == null
                                    ? Colors.green.shade600
                                    : theme.colorScheme.error,
                              ),
                              title: Text(
                                'Row ${r['row']}: ${r['name'] ?? ''}'
                                '${_users && r['email'] != null ? ' <${r['email']}>' : ''}',
                              ),
                              subtitle: Text(
                                r['error'] as String? ??
                                    (_users
                                        ? '${r['role']}'
                                              '${r['setupLink'] != null ? ' · setup link: ${r['setupLink']}' : ''}'
                                        : '${r['action']}'),
                              ),
                            ),
                        ],
                      ),
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, _done != null),
          child: Text(_done != null ? 'Close' : 'Cancel'),
        ),
        if (_done == null)
          FilledButton(
            key: const Key('import-commit'),
            onPressed: _busy || valid == 0 ? null : _commit,
            child: Text('Import $valid row(s)'),
          ),
      ],
    );
  }
}

/// Opens the dialog; true when something was imported.
Future<bool> showImportDialog(BuildContext context, ImportKind kind) async =>
    await showDialog<bool>(
      context: context,
      builder: (_) => ImportDialog(kind: kind),
    ) ??
    false;
