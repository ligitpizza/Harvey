import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/services/api/api_client.dart';
import '../state/portal_providers.dart';

/// D-100: the doctor writes a report; Harvey attaches the patient's latest numbers and saves
/// it as a PDF in the patient's Records (shared with the doctor, read-only for the patient).
Future<bool> showWriteReport(BuildContext context, String patientId, String patientName) async =>
    await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _WriteReportDialog(patientId: patientId, patientName: patientName),
    ) ??
    false;

class _WriteReportDialog extends ConsumerStatefulWidget {
  const _WriteReportDialog({required this.patientId, required this.patientName});

  final String patientId;
  final String patientName;

  @override
  ConsumerState<_WriteReportDialog> createState() => _WriteReportDialogState();
}

class _WriteReportDialogState extends ConsumerState<_WriteReportDialog> {
  final _form = GlobalKey<FormState>();
  final _title = TextEditingController(text: 'Clinical report');
  final _content = TextEditingController();
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _title.dispose();
    _content.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ref
          .read(portalRepositoryProvider)
          .writeReport(widget.patientId, title: _title.text.trim(), content: _content.text.trim());
      if (mounted) Navigator.of(context).pop(true);
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } catch (_) {
      setState(() => _error = 'Could not save the report. Please try again.');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    key: const Key('write-report-dialog'),
    title: Text('Report for ${widget.patientName}'),
    content: SizedBox(
      width: 560,
      child: Form(
        key: _form,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                "Saved as a PDF in the patient's Records with their latest BP, risk, medicines "
                'and appointments attached. They can open and share it, but not change it.',
              ),
              const SizedBox(height: 16),
              TextFormField(
                key: const Key('report-title'),
                controller: _title,
                maxLength: 120,
                decoration: const InputDecoration(labelText: 'Title'),
                validator: (v) => (v ?? '').trim().length < 3 ? 'Enter a title.' : null,
              ),
              TextFormField(
                key: const Key('report-content'),
                controller: _content,
                minLines: 8,
                maxLines: 16,
                maxLength: 8000,
                decoration: const InputDecoration(
                  labelText: 'Report',
                  hintText: 'Assessment, plan, advice for the patient...',
                  alignLabelWithHint: true,
                  border: OutlineInputBorder(),
                ),
                validator: (v) =>
                    (v ?? '').trim().length < 10 ? 'Write at least a sentence.' : null,
              ),
              if (_error != null)
                Text(
                  _error!,
                  key: const Key('report-error'),
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
            ],
          ),
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: _saving ? null : () => Navigator.of(context).pop(false),
        child: const Text('Cancel'),
      ),
      FilledButton.icon(
        key: const Key('report-save'),
        onPressed: _saving ? null : _save,
        icon: _saving
            ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.picture_as_pdf_outlined),
        label: const Text('Save to patient records'),
      ),
    ],
  );
}
