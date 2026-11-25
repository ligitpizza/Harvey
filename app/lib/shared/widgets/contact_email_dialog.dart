import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/utils/validators.dart';
import '../services/api/api_client.dart';

/// D-130: add a contact email to a MyKad/passport account (D-129). Step 1 emails a 6-digit
/// code to the address; step 2 checks it. Used by the patient in Settings and by the
/// counter (with the patient present, who reads the code from their email).
/// Returns the saved email, or null if closed.
///
/// [scope] names whose email this is (e.g. the patient's uid). A code already sent for that
/// scope in the last 10 minutes reopens on the code step, so closing the dialog by mistake
/// does not mean asking for a second code. Tapping outside does not close it.
Future<String?> showContactEmailDialog(
  BuildContext context, {
  required String scope,
  required Future<void> Function(String email) send,
  required Future<void> Function(String email, String code) verify,
  String? current,
  bool atCounter = false,
  DateTime Function() now = DateTime.now,
}) async {
  final pending = _pending[scope];
  final open = pending != null && now().difference(pending.$2) < codeLifetime ? pending.$1 : null;
  if (open == null) _pending.remove(scope);
  final saved = await showDialog<String>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _ContactEmailDialog(
      send: (e) async {
        await send(e);
        _pending[scope] = (e, now());
      },
      verify: verify,
      current: current,
      atCounter: atCounter,
      pendingEmail: open,
    ),
  );
  if (saved != null) _pending.remove(scope);
  return saved;
}

/// Matches the backend's code lifetime (10 minutes).
const codeLifetime = Duration(minutes: 10);

/// Codes sent but not yet entered, per scope: (email, sent at). Kept for the app session.
final _pending = <String, (String, DateTime)>{};

/// For tests.
void clearPendingContactEmails() => _pending.clear();

class _ContactEmailDialog extends StatefulWidget {
  const _ContactEmailDialog({
    required this.send,
    required this.verify,
    required this.current,
    required this.atCounter,
    this.pendingEmail,
  });

  /// A code was already sent to this address: start on the code step.
  final String? pendingEmail;
  final Future<void> Function(String email) send;
  final Future<void> Function(String email, String code) verify;
  final String? current;
  final bool atCounter;

  @override
  State<_ContactEmailDialog> createState() => _ContactEmailDialogState();
}

class _ContactEmailDialogState extends State<_ContactEmailDialog> {
  final _form = GlobalKey<FormState>();
  late final _email = TextEditingController(text: widget.pendingEmail ?? widget.current ?? '');
  final _code = TextEditingController();
  late bool _codeStep = widget.pendingEmail != null;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    _code.dispose();
    super.dispose();
  }

  String get _address => _email.text.trim().toLowerCase();

  Future<void> _run(Future<void> Function() action) async {
    if (!_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } on ApiException catch (e) {
      if (mounted) {
        setState(
          () => _error = e.code == 'NETWORK_ERROR'
              ? 'No connection. Check your internet and try again.'
              : e.message,
        );
      }
    } catch (_) {
      if (mounted) setState(() => _error = 'Something went wrong. Please try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _send() => _run(() async {
    await widget.send(_address);
    if (mounted) {
      setState(() {
        _codeStep = true;
        _code.clear();
      });
    }
  });

  Future<void> _verify() => _run(() async {
    await widget.verify(_address, _code.text);
    if (mounted) Navigator.pop(context, _address);
  });

  @override
  Widget build(BuildContext context) => AlertDialog(
    key: const Key('contact-email-dialog'),
    title: Text(widget.current == null ? 'Add an email' : 'Change email'),
    scrollable: true,
    content: SizedBox(
      width: 420,
      child: Form(
        key: _form,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (!_codeStep) ...[
              Text(
                widget.atCounter
                    ? 'Harvey emails a 6-digit code to this address. Ask the patient to read '
                          'it from their email. Sign-in stays MyKad/passport.'
                    : 'Used for appointment reminders and to reset your password. You still '
                          'sign in with your MyKad or passport number.',
              ),
              const SizedBox(height: 12),
              TextFormField(
                key: const Key('contact-email-field'),
                controller: _email,
                keyboardType: TextInputType.emailAddress,
                decoration: const InputDecoration(labelText: 'Email address'),
                validator: Validators.email,
              ),
            ] else ...[
              Text('Enter the 6-digit code sent to $_address (check spam too).'),
              const SizedBox(height: 12),
              TextFormField(
                key: const Key('contact-email-code'),
                controller: _code,
                keyboardType: TextInputType.number,
                maxLength: 6,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 22, letterSpacing: 8, fontWeight: FontWeight.bold),
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: const InputDecoration(labelText: 'Code', counterText: ''),
                validator: (v) => (v ?? '').length == 6 ? null : 'Enter the 6-digit code.',
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  key: const Key('contact-email-back'),
                  onPressed: _busy ? null : () => setState(() => _codeStep = false),
                  child: const Text('Change address or send again'),
                ),
              ),
            ],
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  _error!,
                  key: const Key('contact-email-error'),
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
      FilledButton(
        key: const Key('contact-email-submit'),
        onPressed: _busy ? null : (_codeStep ? _verify : _send),
        child: Text(_codeStep ? 'Confirm' : 'Send code'),
      ),
    ],
  );
}
