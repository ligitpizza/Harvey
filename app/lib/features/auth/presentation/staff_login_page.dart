import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/constants/enums.dart';
import '../../../core/utils/validators.dart';
import '../../../shared/providers/api_providers.dart';
import '../data/auth_repository.dart';
import '../state/auth_providers.dart';
import 'widgets/role_toggle.dart';
import '../../../shared/widgets/harvey_logo.dart';

/// Staff Portal login (Fig 4.3.14.8, UC1.2). Role toggle must match the
/// account's role claim (D-26). SSO is out of scope, so the button is omitted.
class StaffLoginPage extends ConsumerStatefulWidget {
  const StaffLoginPage({super.key});

  @override
  ConsumerState<StaffLoginPage> createState() => _StaffLoginPageState();
}

class _StaffLoginPageState extends ConsumerState<StaffLoginPage> {
  final _form = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _emailFocus = FocusNode();
  UserRole _role = UserRole.doctor;
  bool _obscure = true;
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    _emailFocus.dispose();
    super.dispose();
  }

  /// D-84: after a failed sign-in (or a role switch) start again with empty fields and the
  /// cursor in Email, so the user can retype straight away.
  void _clearFields() {
    _email.clear();
    _password.clear();
    _form.currentState?.reset();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _emailFocus.requestFocus();
    });
  }

  Future<void> _submit() async {
    setState(() => _error = null);
    if (!_form.currentState!.validate()) return;
    setState(() => _submitting = true);
    final busy = ref.read(authBusyProvider.notifier)..set(true);
    try {
      await ref
          .read(authRepositoryProvider)
          .signIn(
            email: _email.text,
            password: _password.text,
            selectedRole: _role,
            app: ClientApp.staff,
          );
    } on AuthFailure catch (f) {
      if (mounted) {
        setState(() => _error = f.message);
        // Wrong email or password, or the wrong role: clear both and let them retype.
        if (f.reason == LoginFailureReason.invalidCredentials ||
            f.reason == LoginFailureReason.roleMismatch) {
          _clearFields();
        }
      }
    } catch (_) {
      if (mounted) setState(() => _error = AuthMessages.generic);
    } finally {
      busy.set(false);
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final health = ref.watch(apiHealthProvider);
    final status = health.when(
      data: (_) => ('System Status: All Operational', Colors.green.shade600),
      loading: () => ('System Status: checking…', Colors.blueGrey),
      error: (_, _) => ('System Status: API unreachable', scheme.error),
    );
    final form = ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 440),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Card(
            elevation: 2,
            child: Padding(
              padding: const EdgeInsets.all(28),
              child: Form(
                key: _form,
                child: AutofillGroup(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Center(child: const HarveyLogo.mark(size: 56)),
                      const SizedBox(height: 12),
                      Text(
                        'Harvey Pro',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const Text('Secure Staff Portal', textAlign: TextAlign.center),
                      const SizedBox(height: 20),
                      Center(
                        child: RoleToggle(
                          roles: const [UserRole.doctor, UserRole.admin, UserRole.pharmacist],
                          selected: _role,
                          onChanged: (r) {
                            setState(() {
                              _role = r;
                              _error = null;
                            });
                            _clearFields();
                          },
                          showIcons: false,
                        ),
                      ),
                      const SizedBox(height: 20),
                      TextFormField(
                        key: const Key('staff-email'),
                        controller: _email,
                        focusNode: _emailFocus,
                        keyboardType: TextInputType.emailAddress,
                        autofillHints: const [AutofillHints.email],
                        decoration: const InputDecoration(
                          labelText: 'Staff Email',
                          prefixIcon: Icon(Icons.mail_outline),
                        ),
                        validator: Validators.email,
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        key: const Key('staff-password'),
                        controller: _password,
                        obscureText: _obscure,
                        autofillHints: const [AutofillHints.password],
                        decoration: InputDecoration(
                          labelText: 'Password',
                          prefixIcon: const Icon(Icons.lock_outline),
                          suffixIcon: IconButton(
                            tooltip: _obscure ? 'Show password' : 'Hide password',
                            icon: Icon(_obscure ? Icons.visibility : Icons.visibility_off),
                            onPressed: () => setState(() => _obscure = !_obscure),
                          ),
                        ),
                        validator: (v) => Validators.requiredText(v, label: 'Password'),
                        onFieldSubmitted: (_) => _submit(),
                      ),
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton(
                          onPressed: () => context.push('/forgot-password'),
                          child: const Text('Forgot Password?'),
                        ),
                      ),
                      if (_error != null) ...[
                        Text(
                          _error!,
                          key: const Key('staff-login-error'),
                          style: TextStyle(color: scheme.error),
                        ),
                        const SizedBox(height: 8),
                      ],
                      FilledButton.icon(
                        key: const Key('staff-login-submit'),
                        onPressed: _submitting ? null : _submit,
                        icon: const Icon(Icons.arrow_forward),
                        label: const Text('Sign In'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.circle, size: 10, color: status.$2),
              const SizedBox(width: 6),
              Flexible(child: Text(status.$1, key: const Key('staff-system-status'))),
            ],
          ),
        ],
      ),
    );
    // D-79: a split screen on wide displays: the Harvey brand panel and the sign-in form.
    return Scaffold(
      backgroundColor: scheme.surfaceContainerLow,
      body: LayoutBuilder(
        builder: (context, box) {
          final formSide = Center(
            child: SingleChildScrollView(padding: const EdgeInsets.all(24), child: form),
          );
          if (box.maxWidth < 900) return formSide;
          return Row(
            children: [
              const Expanded(child: _BrandPanel()),
              Expanded(child: formSide),
            ],
          );
        },
      ),
    );
  }
}

/// D-79: left half of the staff sign-in page.
class _BrandPanel extends StatelessWidget {
  const _BrandPanel();

  @override
  Widget build(BuildContext context) {
    const white = TextStyle(color: Colors.white);
    Widget point(IconData icon, String text) => Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        children: [
          Icon(icon, color: Colors.white70),
          const SizedBox(width: 12),
          Expanded(child: Text(text, style: white.copyWith(fontSize: 15))),
        ],
      ),
    );
    return Container(
      key: const Key('staff-login-brand'),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [Color(0xFF0D47A1), Color(0xFF1976D2), Color(0xFF26A69A)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      padding: const EdgeInsets.all(48),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16)),
            child: const HarveyLogo.mark(size: 56),
          ),
          const SizedBox(height: 24),
          Text(
            'Harvey Pro',
            style: Theme.of(
              context,
            ).textTheme.displaySmall?.copyWith(color: Colors.white, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Text(
            'Hypertension care, coordinated.',
            style: Theme.of(context).textTheme.titleLarge?.copyWith(color: Colors.white70),
          ),
          const SizedBox(height: 32),
          point(
            Icons.monitor_heart_outlined,
            'Live blood pressure, risk and alerts for your patients',
          ),
          point(Icons.local_pharmacy_outlined, 'Prescriptions, orders and deliveries in one place'),
          point(Icons.lock_outline, 'Secure, role-based access for clinicians and staff'),
        ],
      ),
    );
  }
}
