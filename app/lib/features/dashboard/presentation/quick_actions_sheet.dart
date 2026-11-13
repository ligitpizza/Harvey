import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

/// D-83: the patient's shortcuts (FR-2.2, UC2.5), opened from the "+" in the bottom bar
/// instead of a Quick Actions grid on Home. Records lives here too.
class QuickAction {
  const QuickAction(this.label, this.icon, this.path, this.key, this.color, {this.tab = false});

  final String label;
  final IconData icon;
  final String path;
  final Key key;
  final MaterialColor color;

  /// A bottom-tab page (inside the tab shell): switched to with `go`, not pushed.
  final bool tab;
}

const quickActions = [
  QuickAction('Log Vitals', Icons.favorite_border, '/vitals/log', Key('qa-vitals'), Colors.red),
  QuickAction('Symptoms', Icons.sick_outlined, '/symptom', Key('qa-symptoms'), Colors.orange),
  QuickAction('Messages', Icons.chat_bubble_outline, '/chat', Key('qa-messages'), Colors.blue),
  QuickAction('AI Agent', Icons.smart_toy_outlined, '/ai-agent', Key('qa-agent'), Colors.teal),
  QuickAction(
    'Appointments',
    Icons.event_outlined,
    '/appointments',
    Key('qa-appointments'),
    Colors.purple,
  ),
  QuickAction('Orders', Icons.local_pharmacy_outlined, '/orders', Key('qa-orders'), Colors.green),
  QuickAction(
    'Records',
    Icons.folder_shared_outlined,
    '/records',
    Key('qa-records'),
    Colors.indigo,
    tab: true,
  ),
];

/// Opens the shortcuts sheet from the "+" button.
Future<void> showQuickActions(BuildContext context) => showModalBottomSheet<void>(
  context: context,
  showDragHandle: true,
  shape: const RoundedRectangleBorder(
    borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
  ),
  builder: (sheet) => SafeArea(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Quick actions', style: Theme.of(sheet).textTheme.titleMedium),
          const SizedBox(height: 12),
          GridView.count(
            key: const Key('quick-actions'),
            crossAxisCount: 4,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 8,
            crossAxisSpacing: 8,
            childAspectRatio: 0.82,
            children: [
              for (final a in quickActions)
                Card(
                  key: a.key,
                  margin: EdgeInsets.zero,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(12),
                    onTap: () {
                      Navigator.of(sheet).pop();
                      if (a.tab) {
                        context.go(a.path);
                      } else {
                        context.push(a.path);
                      }
                    },
                    child: Padding(
                      padding: const EdgeInsets.all(6),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          // D-77: each shortcut keeps its own colour.
                          CircleAvatar(
                            backgroundColor: a.color.withValues(alpha: 0.15),
                            foregroundColor: a.color.shade700,
                            child: Icon(a.icon),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            a.label,
                            textAlign: TextAlign.center,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(sheet).textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    ),
  ),
);
