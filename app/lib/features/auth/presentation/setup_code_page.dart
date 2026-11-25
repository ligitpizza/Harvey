import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/utils/ic_number.dart';
import '../../../core/utils/login_alias.dart';
import '../../../core/utils/validators.dart';
import '../../../shared/services/api/api_client.dart';
import '../../../shared/widgets/harvey_logo.dart';
import '../state/auth_providers.dart';

/// D-129: a walk-in patient registered without an email sets their password with the
/// 6-digit code the clinic counter gave them (valid 7 days), then signs in with their
/// MyKad or passport number. The code is checked like an emailed reset code (D-80).
class SetupCodePage extends ConsumerStatefulWidget {
  const SetupCodePage({super.key});

  @override
  ConsumerState<SetupCodePage> createState() => _SetupCodePageState();
}

class _SetupCodePageState extends ConsumerState<SetupCodePage> {
  final _form = GlobalKey<FormState>();
  final _id = TextEditingController();
  final _code = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  bool _busy = false;
  bool _hide = true;
  bool _done = false;
  String? _error;

  @override
  void dispose() {
    _id.dispose();
    _code.dispose();
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref
          .read(authRepositoryProvider)
          .resetPasswordWithCode(
            email: loginAlias(_id.text),
            code: _code.text,
            newPassword: _password.text,
          );
      if (mounted) setState(() => _done = true);
    } on ApiException catch (e) {
      if (mounted) {
        setState(
          () => _error = switch (e.code) {
            'NETWORK_ERROR' => 'No connection. Check your internet and try again.',
            'INVALID_CODE' || 'TOO_MANY_TRIES' =>
              '${e.message.replaceAll('Check the email or request a new code.', '').trim()} '
                  'Check your MyKad/passport number and the code, or ask the clinic counter '
                  'for a new code.',
            _ => e.message,
          },
        );
      }
    } catch (_) {
      if (mounted) setState(() => _error = 'Something went wrong. Please try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _back() => context.canPop() ? context.pop() : context.go('/login');

  Widget _formView() => Form(
    key: _form,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        HarveyLogo.mark(size: 56),
        const SizedBox(height: 12),
        Text(
          'Set up your Harvey account',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 6),
        const Text(
          'Enter your MyKad or passport number and the 6-digit code from the clinic '
          'counter, then choose a password.',
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 20),
        TextFormField(
          key: const Key('setup-id'),
          controller: _id,
          inputFormatters: [IdInputFormatter()],
          decoration: const InputDecoration(
            labelText: 'MyKad or passport number',
            prefixIcon: Icon(Icons.badge_outlined),
          ),
          validator: validateIdentity,
        ),
        const SizedBox(height: 12),
        TextFormField(
          key: const Key('setup-code'),
          controller: _code,
          keyboardType: TextInputType.number,
          maxLength: 6,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 24, letterSpacing: 8, fontWeight: FontWeight.bold),
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: const InputDecoration(labelText: 'Setup code', counterText: ''),
          validator: (v) => (v ?? '').length == 6 ? null : 'Enter the 6-digit code.',
        ),
        const SizedBox(height: 8),
        TextFormField(
          key: const Key('setup-password'),
          controller: _password,
          obscureText: _hide,
          decoration: InputDecoration(
            labelText: 'Choose a password',
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
          key: const Key('setup-confirm'),
          controller: _confirm,
          obscureText: _hide,
          decoration: const InputDecoration(labelText: 'Confirm password'),
          validator: (v) => (v ?? '').isEmpty
              ? 'Confirm your password.'
              : v == _password.text
              ? null
              : 'Passwords do not match.',
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              _error!,
              key: const Key('setup-error'),
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        const SizedBox(height: 20),
        FilledButton(
          key: const Key('setup-submit'),
          onPressed: _busy ? null : _submit,
          child: const Text('Set password'),
        ),
        const SizedBox(height: 8),
        Text(
          'No code, or it expired (7 days)? Ask the clinic counter for a new one.',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    ),
  );

  Widget _doneView() => Column(
    key: const Key('setup-done'),
    children: [
      Icon(Icons.check_circle_outline, size: 56, color: Colors.green.shade600),
      const SizedBox(height: 16),
      const Text(
        'Your password is set. Sign in with your MyKad or passport number and this '
        'password. Next, you will fill in your health profile.',
        textAlign: TextAlign.center,
      ),
      const SizedBox(height: 24),
      FilledButton(
        key: const Key('setup-sign-in'),
        onPressed: () => context.go('/login'),
        child: const Text('Go to sign in'),
      ),
    ],
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Clinic setup code'),
      leading: BackButton(onPressed: _back),
    ),
    body: Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: _done ? _doneView() : _formView(),
        ),
      ),
    ),
  );
}
