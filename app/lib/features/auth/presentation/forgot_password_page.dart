import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../shared/services/api/api_client.dart';
import '../../../core/utils/validators.dart';
import '../state/auth_providers.dart';

/// UC1.2 A1 forgot password with an email code (D-80):
/// 1. enter the email; a 6-digit code is emailed (valid 10 minutes);
/// 2. enter the code and a new password; then sign in with it.
///
/// From Settings (D-80) the signed-in user's [email] is given; D-93: the code is sent
/// only when they press "Send code" (opening the page never sends one), and "I already
/// have a code" goes straight to the code step. Afterwards they sign in again.
class ForgotPasswordPage extends ConsumerStatefulWidget {
  const ForgotPasswordPage({super.key, this.email});

  /// Settings: the account's email (fixed; skips the email step).
  final String? email;

  bool get fromSettings => email != null;

  @override
  ConsumerState<ForgotPasswordPage> createState() => _ForgotPasswordPageState();
}

enum _Step { email, code, done }

class _ForgotPasswordPageState extends ConsumerState<ForgotPasswordPage> {
  final _emailForm = GlobalKey<FormState>();
  final _codeForm = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _code = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  _Step _step = _Step.email;
  bool _busy = false;
  bool _hide = true;
  String? _error;
  String? _info;

  /// D-80: "Send a new code" waits this long after each code.
  static const resendWait = 30;
  int _wait = 0;
  Timer? _tick;

  void _startCooldown() {
    _tick?.cancel();
    setState(() => _wait = resendWait);
    _tick = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return t.cancel();
      setState(() => _wait--);
      if (_wait <= 0) t.cancel();
    });
  }

  @override
  void initState() {
    super.initState();
    final email = widget.email;
    if (email != null) {
      _email.text = email;
    }
  }

  @override
  void dispose() {
    _tick?.cancel();
    _email.dispose();
    _code.dispose();
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _sendCode({bool resend = false}) async {
    if (!resend && !_emailForm.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
      _info = null;
    });
    try {
      await ref.read(authRepositoryProvider).requestPasswordCode(_email.text);
    } on ApiException catch (e) {
      if (e.code == 'RATE_LIMITED') {
        if (mounted) {
          setState(() {
            _busy = false;
            _error = e.message.isNotEmpty
                ? e.message
                : 'Too many requests. Please wait and try again.';
          });
        }
        return;
      }
      // Anything else: carry on as if sent (never reveal whether the email exists).
    } catch (_) {}
    if (mounted) {
      setState(() {
        _busy = false;
        _step = _Step.code;
        _code.clear();
        if (resend) _info = 'A new code is on its way.';
      });
      _startCooldown();
    }
  }

  /// D-93: a code was already emailed (e.g. before "Too many codes requested").
  void _haveCode() {
    if (!widget.fromSettings && !_emailForm.currentState!.validate()) return;
    setState(() {
      _error = null;
      _info = null;
      _step = _Step.code;
      _code.clear();
    });
  }

  Future<void> _verify() async {
    if (!_codeForm.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
      _info = null;
    });
    try {
      await ref
          .read(authRepositoryProvider)
          .resetPasswordWithCode(email: _email.text, code: _code.text, newPassword: _password.text);
      if (mounted) setState(() => _step = _Step.done);
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

  void _back() {
    if (widget.fromSettings) {
      Navigator.of(context).maybePop();
    } else {
      context.canPop() ? context.pop() : context.go('/login');
    }
  }

  /// Settings: the old sessions were signed out by the server, so sign in again here.
  Future<void> _signInAgain() async {
    // Read everything first: the page closes before the sign-out finishes.
    final app = ref.read(clientAppProvider);
    final auth = ref.read(authRepositoryProvider);
    Navigator.of(context).maybePop();
    await auth.signOut(app);
  }

  Widget _errorText() => _error == null
      ? const SizedBox.shrink()
      : Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            _error!,
            key: const Key('reset-error'),
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        );

  Widget _emailStep() => Form(
    key: _emailForm,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.fromSettings) ...[
          const Icon(Icons.lock_reset, size: 48),
          const SizedBox(height: 12),
          Text(
            "To change your password we'll email a 6-digit code to ${widget.email}.",
            key: const Key('reset-settings-intro'),
            textAlign: TextAlign.center,
          ),
        ] else ...[
          const Text(
            'Enter your email and we will send you a 6-digit code to reset your password.',
          ),
          const SizedBox(height: 16),
          TextFormField(
            key: const Key('reset-email'),
            controller: _email,
            keyboardType: TextInputType.emailAddress,
            decoration: const InputDecoration(labelText: 'Email address'),
            validator: Validators.email,
          ),
          const SizedBox(height: 8),
          // D-129: no email means no code by email; the counter gives a new one.
          Text(
            'Sign in with MyKad or passport? Enter the email you added in Settings. No email '
            'added? Ask the clinic counter for a new setup code.',
            key: const Key('reset-no-email-note'),
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
        _errorText(),
        const SizedBox(height: 20),
        FilledButton(
          key: const Key('reset-submit'),
          onPressed: _busy ? null : () => _sendCode(resend: widget.fromSettings),
          child: const Text('Send code'),
        ),
        const SizedBox(height: 8),
        TextButton(
          key: const Key('reset-have-code'),
          onPressed: _busy ? null : _haveCode,
          child: const Text('I already have a code'),
        ),
      ],
    ),
  );

  Widget _codeStep() => Form(
    key: _codeForm,
    child: Column(
      key: const Key('reset-sent'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Icon(Icons.mark_email_read_outlined, size: 48),
        const SizedBox(height: 12),
        Text(
          'If an account exists for ${_email.text.trim()}, a 6-digit code from Harvey is on its '
          'way (check spam too). It works for 10 minutes.',
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 16),
        TextFormField(
          key: const Key('reset-code'),
          controller: _code,
          keyboardType: TextInputType.number,
          maxLength: 6,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 24, letterSpacing: 8, fontWeight: FontWeight.bold),
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: const InputDecoration(labelText: 'Code', counterText: ''),
          validator: (v) => (v ?? '').length == 6 ? null : 'Enter the 6-digit code.',
        ),
        const SizedBox(height: 8),
        TextFormField(
          key: const Key('reset-password'),
          controller: _password,
          obscureText: _hide,
          decoration: InputDecoration(
            labelText: 'New password',
            helperText: Validators.passwordRule,
            suffixIcon: IconButton(
              tooltip: _hide ? 'Show password' : 'Hide password',
              icon: Icon(_hide ? Icons.visibility_outlined : Icons.visibility_off_outlined),
              onPressed: () => setState(() => _hide = !_hide),
            ),
          ),
          validator: Validators.password,
        ),
        const SizedBox(height: 8),
        TextFormField(
          key: const Key('reset-confirm'),
          controller: _confirm,
          obscureText: _hide,
          decoration: const InputDecoration(labelText: 'Confirm new password'),
          validator: (v) => v == _password.text ? null : 'Passwords do not match.',
        ),
        _errorText(),
        if (_info != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_info!)),
        const SizedBox(height: 20),
        FilledButton(
          key: const Key('reset-verify'),
          onPressed: _busy ? null : _verify,
          child: const Text('Set new password'),
        ),
        const SizedBox(height: 8),
        TextButton(
          key: const Key('reset-resend'),
          onPressed: _busy || _wait > 0 ? null : () => _sendCode(resend: true),
          child: Text(
            _wait > 0 ? 'Send a new code in ${_wait}s' : "Didn't get it? Send a new code",
          ),
        ),
      ],
    ),
  );

  Widget _doneStep() => Column(
    key: const Key('reset-done'),
    children: [
      Icon(Icons.check_circle_outline, size: 56, color: Colors.green.shade600),
      const SizedBox(height: 16),
      const Text(
        'Your password has been changed. Sign in with your new password. Other devices '
        'were signed out.',
        textAlign: TextAlign.center,
      ),
      const SizedBox(height: 24),
      if (widget.fromSettings)
        FilledButton(
          key: const Key('reset-sign-in-again'),
          onPressed: _signInAgain,
          child: const Text('Sign in with the new password'),
        )
      else
        FilledButton(onPressed: _back, child: const Text('Back to sign in')),
    ],
  );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Reset password'),
        leading: BackButton(onPressed: _back),
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: switch (_step) {
              _Step.email => _emailStep(),
              _Step.code => _codeStep(),
              _Step.done => _doneStep(),
            },
          ),
        ),
      ),
    );
  }
}
