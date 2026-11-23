import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/services/api/api_client.dart';
import '../state/family_providers.dart';

/// Link to Patient (Fig 4.3.16.1; UC15.1, D-06): enter the code, wait for approval;
/// once linked, shows who you follow with Unlink (D-62). D-125: each state has its own
/// layout, so a linked member is not shown the "enter a code" intro.
class LinkPage extends ConsumerStatefulWidget {
  const LinkPage({super.key});

  @override
  ConsumerState<LinkPage> createState() => _LinkPageState();
}

class _LinkPageState extends ConsumerState<LinkPage> {
  final _code = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action, String done) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final messenger = ScaffoldMessenger.of(context);
    try {
      await action();
      messenger.showSnackBar(SnackBar(content: Text(done)));
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } catch (_) {
      setState(() => _error = 'Something went wrong. Please try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _confirmUnlink() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Stop following?'),
        content: const Text('You will no longer see their readings or get their emergency alerts.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(c).pop(false), child: const Text('Back')),
          FilledButton(
            key: const Key('unlink-confirm'),
            onPressed: () => Navigator.of(c).pop(true),
            child: const Text('Unlink'),
          ),
        ],
      ),
    );
    if (ok == true) await _run(ref.read(familyRepositoryProvider).unlink, 'Unlinked.');
  }

  void _send() {
    final code = _code.text.trim();
    if (code.length < 4) {
      setState(() => _error = 'Enter the code your family member shared.');
      return;
    }
    _run(() => ref.read(familyRepositoryProvider).requestLink(code), 'Request sent.');
  }

  @override
  Widget build(BuildContext context) {
    final linked = ref.watch(linkedPatientIdProvider).value;
    final pending = ref.watch(myPendingLinkProvider).value;
    final theme = Theme.of(context);

    final List<Widget> children;
    if (linked != null) {
      final name = ref.watch(linkedPersonProvider(linked)).value?.name;
      children = [
        _PatientCard(name: name),
        const SizedBox(height: 16),
        const _Section(
          title: 'What you can see',
          rows: [
            (Icons.monitor_heart_outlined, 'Their blood pressure and heart rate readings'),
            (Icons.insights_outlined, 'Their risk status and 7-day trend'),
            (Icons.notifications_active_outlined, 'Emergency and high-reading alerts'),
            (Icons.location_on_outlined, 'Where they are during an emergency'),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          'Read-only: only they and their doctor can change their records.',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 24),
        Text('To follow someone else, unlink first.', style: theme.textTheme.bodySmall),
        const SizedBox(height: 6),
        OutlinedButton.icon(
          key: const Key('link-unlink'),
          style: OutlinedButton.styleFrom(
            foregroundColor: theme.colorScheme.error,
            side: BorderSide(color: theme.colorScheme.error.withValues(alpha: 0.5)),
          ),
          onPressed: _busy ? null : _confirmUnlink,
          icon: const Icon(Icons.link_off),
          label: const Text('Unlink'),
        ),
      ];
    } else if (pending != null) {
      children = [
        const _Intro(
          icon: Icons.hourglass_top_rounded,
          title: 'Waiting for approval',
          text:
              'Your request was sent. Your family member must approve it in their own '
              'Harvey app before you can see their data.',
        ),
        const SizedBox(height: 16),
        Card(
          key: const Key('link-pending'),
          child: ListTile(
            leading: const Icon(Icons.schedule_send_outlined),
            title: const Text('Request sent'),
            subtitle: const Text('They will find it under Settings → Family.'),
            trailing: TextButton(
              key: const Key('link-withdraw'),
              onPressed: _busy
                  ? null
                  : () => _run(
                      () => ref.read(familyRepositoryProvider).withdraw(pending.id),
                      'Request withdrawn.',
                    ),
              child: const Text('Withdraw'),
            ),
          ),
        ),
      ];
    } else {
      children = [
        const _Intro(
          icon: Icons.link_rounded,
          title: 'Link to a family member',
          text: 'Enter their link code to follow their blood pressure and get their alerts.',
        ),
        const SizedBox(height: 16),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('Link code', style: theme.textTheme.labelLarge),
                const SizedBox(height: 8),
                TextField(
                  key: const Key('link-code'),
                  controller: _code,
                  textCapitalization: TextCapitalization.characters,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => _busy ? null : _send(),
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.key),
                    hintText: 'e.g. A1B2C3',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                FilledButton.icon(
                  key: const Key('link-send'),
                  onPressed: _busy ? null : _send,
                  icon: const Icon(Icons.send),
                  label: const Text('Send request'),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        const _Section(
          title: 'How linking works',
          numbered: true,
          rows: [
            (Icons.settings_outlined, 'They open Harvey → Settings → Family and share their code.'),
            (Icons.key, 'You enter the code here and send a request.'),
            (Icons.verified_user_outlined, 'They approve it, and their readings appear here.'),
          ],
        ),
      ];
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Family Patients')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          ...children,
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                _error!,
                key: const Key('link-error'),
                style: TextStyle(color: theme.colorScheme.error),
              ),
            ),
        ],
      ),
    );
  }
}

/// The person you follow, in the same gradient style as the dashboard header.
class _PatientCard extends StatelessWidget {
  const _PatientCard({required this.name});

  final String? name;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final primary = theme.colorScheme.primary;
    return Container(
      key: const Key('link-linked'),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        gradient: LinearGradient(
          colors: [primary, Color.lerp(primary, Colors.indigo, 0.45)!],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Row(
        children: [
          CircleAvatar(
            radius: 28,
            backgroundColor: Colors.white,
            foregroundColor: primary,
            child: Text(
              (name ?? '?').characters.first.toUpperCase(),
              style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('You are following', style: TextStyle(color: Colors.white70)),
                Text(
                  name ?? 'your family member',
                  style: theme.textTheme.titleLarge?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.check_circle, size: 14, color: Colors.white),
                SizedBox(width: 4),
                Text(
                  'Linked',
                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Icon, title and one line, for the not-linked and pending states.
class _Intro extends StatelessWidget {
  const _Intro({required this.icon, required this.title, required this.text});

  final IconData icon;
  final String title;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        CircleAvatar(
          radius: 30,
          backgroundColor: theme.colorScheme.primaryContainer,
          child: Icon(icon, color: theme.colorScheme.onPrimaryContainer, size: 30),
        ),
        const SizedBox(height: 12),
        Text(title, textAlign: TextAlign.center, style: theme.textTheme.titleLarge),
        const SizedBox(height: 4),
        Text(text, textAlign: TextAlign.center, style: theme.textTheme.bodyMedium),
      ],
    );
  }
}

/// A titled list of short lines with icons; [numbered] for real steps.
class _Section extends StatelessWidget {
  const _Section({required this.title, required this.rows, this.numbered = false});

  final String title;
  final List<(IconData, String)> rows;
  final bool numbered;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            for (final (i, (icon, text)) in rows.indexed)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (numbered)
                      CircleAvatar(
                        radius: 11,
                        backgroundColor: theme.colorScheme.primaryContainer,
                        child: Text(
                          '${i + 1}',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onPrimaryContainer,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      )
                    else
                      Icon(icon, size: 20, color: theme.colorScheme.primary),
                    const SizedBox(width: 10),
                    Expanded(child: Text(text, style: theme.textTheme.bodyMedium)),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
