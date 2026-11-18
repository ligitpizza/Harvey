import 'package:flutter/material.dart';
import '../../../core/utils/ic_number.dart';
import '../../../shared/widgets/identity_fields.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/constants/enums.dart';
import '../../../shared/services/api/api_client.dart';
import '../../provider_portal/presentation/portal_widgets.dart' show formatDate;
import '../data/admin_repository.dart';
import '../state/admin_providers.dart';
import 'user_actions.dart';
import '../../../shared/widgets/import_dialog.dart';
import '../../../shared/widgets/page_header.dart';
import '../../../shared/widgets/wide_table.dart' show TablePill;

const _pageSize = 10;

String roleLabel(UserRole? r) => switch (r) {
  UserRole.patient => 'Patient',
  UserRole.doctor => 'Doctor',
  UserRole.pharmacist => 'Pharmacist',
  UserRole.admin => 'Admin',
  UserRole.familyMember => 'Family',
  null => 'No role',
};

/// D-116: one colour per role (avatars, role pills, the user's page header).
Color roleColor(UserRole? r) => switch (r) {
  UserRole.patient => Colors.teal.shade700,
  UserRole.doctor => Colors.indigo.shade600,
  UserRole.pharmacist => Colors.brown.shade500,
  UserRole.admin => Colors.deepPurple.shade500,
  UserRole.familyMember => Colors.orange.shade800,
  null => Colors.grey.shade600,
};

/// User Management (Fig 4.3.14.1; FR-11.1, UC11.1; D-59): search, filter by role,
/// edit, deactivate / reactivate. "Add new user" opens staff provisioning (UC1.5).
class AdminUsersPage extends ConsumerStatefulWidget {
  const AdminUsersPage({super.key});

  @override
  ConsumerState<AdminUsersPage> createState() => _AdminUsersPageState();
}

class _AdminUsersPageState extends ConsumerState<AdminUsersPage> {
  final _search = TextEditingController();
  UserRole? _role;
  String _query = '';
  int _page = 0;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _refresh() => ref.invalidate(adminUsersProvider((_role, _query)));

  Future<void> _after(Future<bool> change) async {
    if (await change) _refresh();
  }

  /// D-60: open a patient account; the setup link is shown if it could not be emailed.
  Future<void> _createPatient() async {
    final created = await showDialog<(String, String?)>(
      context: context,
      builder: (_) => const _PatientDialog(),
    );
    if (created == null || !mounted) return;
    _refresh();
    final (name, link) = created;
    if (link == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Account created. $name was emailed a setup link.')));
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Account created'),
        content: SelectableText(
          'The email could not be sent. Give $name this link to set a password:\n\n$link',
          key: const Key('patient-setup-link'),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: link));
              Navigator.of(c).pop();
            },
            child: const Text('Copy and close'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final users = ref.watch(adminUsersProvider((_role, _query)));
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        PageHeader(
          title: 'User Management',
          subtitle: 'Manage all system users, roles, and access statuses.',
          icon: Icons.manage_accounts_outlined,
          actions: [
            SizedBox(
              width: 280,
              child: TextField(
                key: const Key('user-search'),
                controller: _search,
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search),
                  hintText: 'Search users…',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                onSubmitted: (v) => setState(() {
                  _query = v.trim();
                  _page = 0;
                }),
              ),
            ),
            MenuAnchor(
              builder: (context, controller, _) => FilledButton.icon(
                key: const Key('add-user'),
                onPressed: () => controller.isOpen ? controller.close() : controller.open(),
                icon: const Icon(Icons.add),
                label: const Text('Add new user'),
              ),
              menuChildren: [
                MenuItemButton(
                  key: const Key('add-staff'),
                  leadingIcon: const Icon(Icons.badge_outlined),
                  onPressed: () => context.push('/admin/users/new'),
                  child: const Text('Staff account'),
                ),
                MenuItemButton(
                  key: const Key('add-patient'),
                  leadingIcon: const Icon(Icons.person_add_alt),
                  onPressed: _createPatient,
                  child: const Text('Patient account'),
                ),
                // D-79: several staff accounts at once from a CSV / JSON file.
                MenuItemButton(
                  key: const Key('import-users'),
                  leadingIcon: const Icon(Icons.upload_file),
                  onPressed: () async {
                    if (await showImportDialog(context, ImportKind.users)) {
                      ref.invalidate(adminUsersProvider);
                    }
                  },
                  child: const Text('Import staff from file'),
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 16),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(child: Text('System users', style: theme.textTheme.titleLarge)),
                    if (users.value != null)
                      Text('${users.value!.length} shown', style: theme.textTheme.bodySmall),
                  ],
                ),
                const SizedBox(height: 12),
                // D-116: role filter as chips instead of a dropdown.
                Wrap(
                  key: const Key('role-filter'),
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final r in <UserRole?>[null, ...UserRole.values])
                      ChoiceChip(
                        key: Key('role-filter-${r?.value ?? 'all'}'),
                        avatar: r == null
                            ? null
                            : CircleAvatar(backgroundColor: roleColor(r), radius: 5),
                        label: Text(r == null ? 'All roles' : roleLabel(r)),
                        selected: _role == r,
                        onSelected: (_) => setState(() {
                          _role = r;
                          _page = 0;
                        }),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                const _UserHeader(),
                users.when(
                  loading: () => const Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(child: CircularProgressIndicator()),
                  ),
                  error: (_, _) => ListTile(
                    leading: const Icon(Icons.cloud_off),
                    title: const Text('Could not load users.'),
                    trailing: TextButton(onPressed: _refresh, child: const Text('Retry')),
                  ),
                  data: (all) {
                    if (all.isEmpty) {
                      return const Padding(
                        padding: EdgeInsets.all(16),
                        child: Text('No users match.', key: Key('no-users')),
                      );
                    }
                    final pages = (all.length / _pageSize).ceil();
                    final page = _page.clamp(0, pages - 1);
                    final shown = all.skip(page * _pageSize).take(_pageSize).toList();
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (final u in shown)
                          _UserRow(
                            user: u,
                            onEdit: () => _after(editUser(context, ref, u)),
                            onToggle: () => _after(toggleUserActive(context, ref, u)),
                            onDelete: () => _after(deleteUser(context, ref, u)),
                            onOpen: () => context.push('/admin/users/${u.uid}'),
                          ),
                        const Divider(),
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                'Showing ${page * _pageSize + 1} to '
                                '${page * _pageSize + shown.length} of ${all.length} entries',
                                key: const Key('users-count'),
                              ),
                            ),
                            IconButton(
                              key: const Key('users-prev'),
                              icon: const Icon(Icons.chevron_left),
                              onPressed: page > 0 ? () => setState(() => _page = page - 1) : null,
                            ),
                            Text('${page + 1} / $pages'),
                            IconButton(
                              key: const Key('users-next'),
                              icon: const Icon(Icons.chevron_right),
                              onPressed: page < pages - 1
                                  ? () => setState(() => _page = page + 1)
                                  : null,
                            ),
                          ],
                        ),
                      ],
                    );
                  },
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// Column titles above the user rows (wide pages only).
class _UserHeader extends StatelessWidget {
  const _UserHeader();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.labelLarge?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    return LayoutBuilder(
      builder: (context, box) => box.maxWidth < _UserRow.wide
          ? const Divider(height: 1)
          : Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: BoxDecoration(
                color: theme.colorScheme.primaryContainer.withValues(alpha: 0.35),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                children: [
                  Expanded(flex: 5, child: Text('User', style: style)),
                  Expanded(flex: 2, child: Text('Role', style: style)),
                  Expanded(flex: 2, child: Text('Status', style: style)),
                  Expanded(flex: 2, child: Text('Joined', style: style)),
                  const SizedBox(width: 48),
                ],
              ),
            ),
    );
  }
}

class _UserRow extends StatelessWidget {
  const _UserRow({
    required this.user,
    required this.onEdit,
    required this.onToggle,
    required this.onDelete,
    required this.onOpen,
  });

  /// Below this width the row stacks role and status under the name.
  static const wide = 760.0;

  final AdminUser user;
  final VoidCallback onEdit;
  final VoidCallback onToggle;
  final VoidCallback onDelete;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final u = user;
    final theme = Theme.of(context);
    final status = !u.isActive
        ? (u.deletionRequested ? 'Deletion pending' : 'Deactivated')
        : 'Active';
    final statusColor = u.isActive ? Colors.green.shade700 : theme.colorScheme.error;
    final colour = roleColor(u.role);
    final initials = u.name.trim().isEmpty
        ? '?'
        : u.name.trim().split(RegExp(r'\s+')).take(2).map((w) => w[0].toUpperCase()).join();
    final who = Row(
      children: [
        CircleAvatar(
          radius: 20,
          backgroundColor: colour.withValues(alpha: 0.15),
          child: Text(
            initials,
            style: theme.textTheme.labelLarge?.copyWith(color: colour, fontWeight: FontWeight.w700),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                u.name.isEmpty ? '(no name)' : u.name,
                style: theme.textTheme.titleSmall,
                overflow: TextOverflow.ellipsis,
              ),
              Text(
                u.email,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                overflow: TextOverflow.ellipsis,
              ),
              if (u.isDoctor)
                Text(
                  '${u.specialty ?? 'Doctor'} · ${u.caseload ?? 0} / ${u.maxPatients} patients',
                  style: theme.textTheme.bodySmall,
                ),
            ],
          ),
        ),
      ],
    );
    final role = TablePill(roleLabel(u.role), color: colour);
    final state = TablePill(
      status,
      key: Key('status-${u.uid}'),
      color: statusColor,
      icon: u.isActive ? Icons.circle : Icons.block,
    );
    final joined = Text(
      u.createdAt == null ? '-' : formatDate(u.createdAt!).split(',').first,
      style: theme.textTheme.bodyMedium,
    );
    final menu = PopupMenuButton<String>(
      key: Key('user-menu-${u.uid}'),
      tooltip: 'Actions',
      onSelected: (a) => switch (a) {
        'edit' => onEdit(),
        'delete' => onDelete(),
        _ => onToggle(),
      },
      itemBuilder: (_) => [
        const PopupMenuItem(
          value: 'edit',
          child: ListTile(leading: Icon(Icons.edit_outlined), title: Text('Edit')),
        ),
        PopupMenuItem(
          value: 'toggle',
          child: ListTile(
            leading: Icon(u.isActive ? Icons.block : Icons.check_circle_outline),
            title: Text(u.isActive ? 'Deactivate' : 'Reactivate'),
          ),
        ),
        PopupMenuItem(
          value: 'delete',
          child: ListTile(
            leading: Icon(Icons.delete_outline, color: theme.colorScheme.error),
            title: Text('Delete permanently', style: TextStyle(color: theme.colorScheme.error)),
          ),
        ),
      ],
    );
    return InkWell(
      key: Key('user-${u.uid}'),
      onTap: onOpen,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: theme.colorScheme.outlineVariant)),
        ),
        child: LayoutBuilder(
          builder: (context, box) => box.maxWidth < wide
              ? Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          who,
                          const SizedBox(height: 8),
                          Wrap(spacing: 8, runSpacing: 6, children: [role, state, joined]),
                        ],
                      ),
                    ),
                    menu,
                  ],
                )
              : Row(
                  children: [
                    Expanded(flex: 5, child: who),
                    Expanded(
                      flex: 2,
                      child: Align(alignment: Alignment.centerLeft, child: role),
                    ),
                    Expanded(
                      flex: 2,
                      child: Align(alignment: Alignment.centerLeft, child: state),
                    ),
                    Expanded(flex: 2, child: joined),
                    SizedBox(width: 48, child: menu),
                  ],
                ),
        ),
      ),
    );
  }
}

/// D-60: name, email and IC (the IC fills the date of birth and gender, D-51).
class _PatientDialog extends ConsumerStatefulWidget {
  const _PatientDialog();

  @override
  ConsumerState<_PatientDialog> createState() => _PatientDialogState();
}

class _PatientDialogState extends ConsumerState<_PatientDialog> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _ic = TextEditingController();
  final _nationality = TextEditingController(); // D-103
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    for (final c in [_name, _email, _ic, _nationality]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final link = await ref
          .read(adminRepositoryProvider)
          .createPatient(
            name: _name.text.trim(),
            email: _email.text.trim(),
            icNumber: parseIdentity(_ic.text).value,
            nationality: looksLikePassport(_ic.text) ? _nationality.text.trim() : null,
          );
      if (mounted) Navigator.of(context).pop((_name.text.trim(), link));
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } catch (_) {
      setState(() => _error = 'Something went wrong. Try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    // D-116: a header with an icon, grouped fields with icons, and the next steps
    // explained in a tinted box.
    return AlertDialog(
      key: const Key('patient-dialog'),
      titlePadding: EdgeInsets.zero,
      title: Container(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 16),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [Colors.teal.withValues(alpha: 0.14), scheme.surface],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.teal.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Icon(Icons.person_add_alt_1, color: Colors.teal.shade700),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Create patient account', style: theme.textTheme.titleLarge),
                  Text(
                    'For a patient registered at the counter.',
                    style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      content: SizedBox(
        width: 460,
        child: Form(
          key: _form,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: 8),
                TextFormField(
                  key: const Key('patient-name'),
                  controller: _name,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(
                    labelText: 'Full name',
                    hintText: 'As on MyKad or passport',
                    prefixIcon: Icon(Icons.person_outline),
                  ),
                  validator: (v) => (v ?? '').trim().length < 2 ? 'Enter the full name.' : null,
                ),
                const SizedBox(height: 14),
                TextFormField(
                  key: const Key('patient-email'),
                  controller: _email,
                  keyboardType: TextInputType.emailAddress,
                  decoration: const InputDecoration(
                    labelText: 'Email',
                    hintText: 'The setup link is sent here',
                    prefixIcon: Icon(Icons.mail_outline),
                  ),
                  validator: (v) => RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch((v ?? '').trim())
                      ? null
                      : 'Enter a valid email.',
                ),
                const SizedBox(height: 14),
                // D-103: MyKad or passport (with nationality).
                IdentityFields(
                  id: _ic,
                  nationality: _nationality,
                  idKey: const Key('patient-ic'),
                  nationalityKey: const Key('patient-nationality'),
                ),
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: scheme.primaryContainer.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.info_outline, size: 20, color: scheme.primary),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'A setup link is emailed. The patient signs in to the app and completes '
                          'their health profile; a doctor request is then created automatically.',
                          style: theme.textTheme.bodySmall,
                        ),
                      ),
                    ],
                  ),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: scheme.errorContainer,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.error_outline, size: 20, color: scheme.onErrorContainer),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            _error!,
                            key: const Key('patient-error'),
                            style: TextStyle(color: scheme.onErrorContainer),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
      actionsPadding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton.icon(
          key: const Key('patient-save'),
          onPressed: _busy ? null : _save,
          icon: _busy
              ? const SizedBox.square(
                  dimension: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.send_outlined, size: 18),
          label: const Text('Create and send link'),
        ),
      ],
    );
  }
}
