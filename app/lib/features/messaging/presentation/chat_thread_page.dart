import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/constants/enums.dart';
import '../../../core/utils/bp_classifier.dart';
import '../../../shared/models/health_models.dart';
import '../../auth/state/auth_providers.dart';
import '../../dashboard/state/dashboard_providers.dart';
import '../data/messaging_repository.dart';
import '../state/messaging_providers.dart';
import 'chat_ui.dart';
import '../../settings/state/settings_providers.dart';
import '../../notifications/state/notification_providers.dart';

/// Fig 4.3.15.2 Chat Thread / 4.3.15.3 Flagged Message (FR-10.1, FR-10.3, FR-14.4;
/// UC10.1, UC10.3; NFR-2.1). Used by the patient app and the doctor portal.
class ChatThreadPage extends ConsumerStatefulWidget {
  const ChatThreadPage({super.key, required this.otherId, this.backPath, this.draft});

  /// The other participant's uid (route `:threadId` / `:patientId`).
  final String otherId;
  final String? backPath;

  /// Pre-filled text the patient can edit before sending (e.g. a refill request).
  final String? draft;

  @override
  ConsumerState<ChatThreadPage> createState() => _ChatThreadPageState();
}

class _ChatThreadPageState extends ConsumerState<ChatThreadPage> {
  late final _input = TextEditingController(text: widget.draft);
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      clearChatNotifications(ref, 'message', {'from': widget.otherId});
      // D-80: Home keeps this thread's listener alive for the unread badge; if it ever
      // failed (e.g. while signing in) the error stuck, and a chat opened from the bell
      // showed "Could not load". Reconnect on open.
      final me = ref.read(authUidProvider).value;
      if (me != null && ref.read(threadProvider((me, widget.otherId))).hasError) {
        ref.invalidate(threadProvider((me, widget.otherId)));
      }
    });
  }

  bool _sending = false;
  String? _error;

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _toBottom() => WidgetsBinding.instance.addPostFrameCallback((_) {
    // D-79: the list is reversed, so the newest message is at offset 0.
    if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.minScrollExtent);
  });

  Future<void> _send(String me, Contact to) async {
    final text = _input.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      final isDoctor = ref.read(currentUserProvider).value?.role == UserRole.doctor;
      // D-76: on the patient's side, a flagged message also brings in Harvey AI.
      await ref
          .read(messagingRepositoryProvider)
          .send(me: me, to: to, text: text, aiReview: !isDoctor);
      _input.clear();
      _toBottom();
    } on RecipientNotReadyException {
      setState(() => _error = '${to.name} has not set up secure messaging yet.');
    } catch (e) {
      debugPrint('Harvey: message send failed: $e');
      setState(() => _error = 'Could not send the message. Please try again.');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  /// D-52: choose a photo or PDF and send it, with any typed text as its caption.
  Future<void> _attach(String me, Contact to) async {
    final picker = ref.read(attachmentPickerProvider);
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (c) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              key: const Key('attach-gallery'),
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Photo'),
              onTap: () => Navigator.of(c).pop('gallery'),
            ),
            if (picker.hasCamera)
              ListTile(
                key: const Key('attach-camera'),
                leading: const Icon(Icons.photo_camera_outlined),
                title: const Text('Take a photo'),
                onTap: () => Navigator.of(c).pop('camera'),
              ),
            ListTile(
              key: const Key('attach-pdf'),
              leading: const Icon(Icons.picture_as_pdf_outlined),
              title: const Text('PDF document'),
              onTap: () => Navigator.of(c).pop('pdf'),
            ),
          ],
        ),
      ),
    );
    if (choice == null || !mounted) return;
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      final picked = choice == 'pdf'
          ? await picker.pdf()
          : await picker.photo(camera: choice == 'camera');
      if (picked == null) return;
      await ref
          .read(messagingRepositoryProvider)
          .sendAttachment(
            me: me,
            to: to,
            bytes: picked.bytes,
            fileName: picked.name,
            type: picked.type,
            caption: _input.text,
          );
      _input.clear();
      _toBottom();
    } on AttachmentTooLargeException {
      setState(() => _error = 'That file is larger than 10 MB. Please choose a smaller one.');
    } on RecipientNotReadyException {
      setState(() => _error = '${to.name} has not set up secure messaging yet.');
    } catch (e) {
      debugPrint('Harvey: attachment send failed: $e');
      setState(
        () => _error = 'Could not send the file. Please check your connection and try again.',
      );
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  void _showCarePlan(BuildContext context, bool isDoctor) {
    if (isDoctor) {
      context.go('/doctor/patient/${widget.otherId}/care-plan');
      return;
    }
    final doctor = ref.read(contactProvider(widget.otherId)).value?.name ?? 'your doctor';
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheet) => Consumer(
        builder: (context, ref, _) => CarePlanSheet(
          plan: ref.watch(carePlanProvider),
          doctorName: doctor,
          onAsk: () {
            Navigator.of(sheet).pop();
            _input.text = askAboutPlan;
            _input.selection = TextSelection.collapsed(offset: _input.text.length);
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final me = ref.watch(authUidProvider).value;
    final role = ref.watch(currentUserProvider).value?.role;
    final isDoctor = role == UserRole.doctor;
    final contact = ref.watch(contactProvider(widget.otherId)).value;
    if (me == null) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    final thread = ref.watch(threadProvider((me, widget.otherId)));

    // Opening the conversation marks it read on this device (D-42).
    ref.listen(threadProvider((me, widget.otherId)), (_, next) {
      final last = next.value?.lastOrNull;
      if (last != null) {
        ref.read(chatSeenStoreProvider).markSeen(me, widget.otherId, last.sentAt);
        ref.invalidate(unreadCountProvider((me, widget.otherId)));
        _toBottom();
      }
    });

    final messages = thread.value ?? const <ChatMessage>[];
    final lastFlaggedMine = messages.lastIndexWhere((m) => m.fromMe && m.isFlagged);
    // D-76: Harvey AI notes for this patient, merged into the conversation by time.
    final patientId = isDoctor ? widget.otherId : me;
    final notes = ref.watch(chatAlertsProvider(patientId)).value ?? const <AgentNote>[];
    final items = <Object>[...messages, ...notes]..sort((a, b) => _at(a).compareTo(_at(b)));

    return Scaffold(
      appBar: AppBar(
        leading: BackButton(
          onPressed: () => context.canPop()
              ? context.pop()
              : context.go(widget.backPath ?? (isDoctor ? '/doctor/messages' : '/chat')),
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(contact?.name ?? 'Conversation'),
            if (contact?.subtitle != null)
              Text(contact!.subtitle!, style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
        actions: [
          IconButton(
            key: const Key('chat-care-plan-button'),
            tooltip: 'Care plan',
            icon: const Icon(Icons.assignment_outlined),
            onPressed: () => _showCarePlan(context, isDoctor),
          ),
        ],
      ),
      body: Column(
        children: [
          const ChatNoteBar('Messages are end-to-end encrypted', icon: Icons.lock_outline),
          Expanded(
            child: thread.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (_, _) => Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text(
                        'Could not load the conversation. Check your connection.',
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 12),
                      FilledButton.tonal(
                        key: const Key('chat-retry'),
                        onPressed: () => ref.invalidate(threadProvider((me, widget.otherId))),
                        child: const Text('Retry'),
                      ),
                    ],
                  ),
                ),
              ),
              data: (_) => items.isEmpty
                  ? const Center(
                      child: Padding(
                        padding: EdgeInsets.all(24),
                        child: Text('No messages yet. Say hello!', textAlign: TextAlign.center),
                      ),
                    )
                  : ListView.builder(
                      key: const Key('chat-list'),
                      controller: _scroll,
                      // D-79: opens at the newest message (bottom), like the pharmacy chat.
                      reverse: true,
                      padding: const EdgeInsets.all(12),
                      itemCount: items.length,
                      itemBuilder: (_, i) {
                        final item = items[items.length - 1 - i];
                        if (item is AgentNote) {
                          return ChatNotice(
                            key: Key('ai-note-${item.id}'),
                            title: 'Harvey AI · not a substitute for a doctor',
                            text: item.text,
                            time: chatTime(item.sentAt),
                            urgent: true,
                          );
                        }
                        final m = item as ChatMessage;
                        return Column(
                          children: [
                            _MessageBubble(
                              me: me,
                              message: m,
                              senderName: m.fromMe ? null : contact?.name,
                              senderRole: m.fromMe ? null : (isDoctor ? 'patient' : 'doctor'),
                              showFlag: isDoctor && m.isFlagged && !m.fromMe,
                              onDismissFlag: () =>
                                  ref.read(messagingRepositoryProvider).clearFlag(m.id),
                            ),
                            if (!isDoctor && messages.indexOf(m) == lastFlaggedMine)
                              const _FlaggedBanner(),
                          ],
                        );
                      },
                    ),
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                _error!,
                key: const Key('chat-error'),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          if (contact != null && contact.publicKey == null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                '${contact.name} has not opened Harvey yet, so secure messages cannot be '
                'sent to them for now.',
                key: const Key('chat-not-ready'),
              ),
            ),
          ChatComposer(
            controller: _input,
            enabled: contact?.publicKey != null,
            hint: 'Type a message...',
            onSend: contact?.publicKey == null || _sending ? null : () => _send(me, contact!),
            leading: IconButton(
              key: const Key('chat-attach'),
              tooltip: 'Attach a photo or PDF',
              onPressed: contact?.publicKey == null || _sending
                  ? null
                  : () => _attach(me, contact!),
              icon: const Icon(Icons.attach_file),
            ),
          ),
        ],
      ),
    );
  }
}

DateTime _at(Object item) => item is AgentNote ? item.sentAt : (item as ChatMessage).sentAt;

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({
    required this.me,
    required this.message,
    required this.showFlag,
    required this.onDismissFlag,
    this.senderName,
    this.senderRole,
  });

  final String me;
  final ChatMessage message;
  final bool showFlag;
  final VoidCallback onDismissFlag;
  final String? senderName;
  final String? senderRole;

  @override
  Widget build(BuildContext context) {
    final fg = Theme.of(context).colorScheme.onSurface;
    final red = BpClassifier.color(BpCategory.crisis);
    return ChatBubble(
      mine: message.fromMe,
      senderName: senderName,
      senderRole: senderRole,
      highlight: showFlag ? red : null,
      time: message.pending ? null : chatTime(message.sentAt),
      header: showFlag
          ? Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Icon(Icons.flag, size: 16, color: red),
                const SizedBox(width: 4),
                const Text('Flagged: high-risk words'),
                TextButton(
                  key: Key('dismiss-flag-${message.id}'),
                  onPressed: onDismissFlag,
                  child: const Text('Dismiss flag'),
                ),
              ],
            )
          : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (message.attachment != null)
            _AttachmentView(me: me, attachment: message.attachment!, color: fg),
          if (message.text == null)
            Text(
              'This message was encrypted for an earlier device and cannot be shown here.',
              key: Key('earlier-device-${message.id}'),
              style: const TextStyle(fontStyle: FontStyle.italic),
            )
          else if (message.text!.isNotEmpty || message.attachment == null)
            SelectableText(message.text!),
          if (message.pending)
            Text(
              'Sending... (will send when online)',
              key: Key('pending-${message.id}'),
              style: Theme.of(context).textTheme.labelSmall,
            ),
        ],
      ),
    );
  }
}

/// D-52: a photo shown in the bubble (tap to enlarge) or a PDF row (tap to open/save).
class _AttachmentView extends ConsumerWidget {
  const _AttachmentView({required this.me, required this.attachment, required this.color});

  final String me;
  final ChatAttachment attachment;
  final Color color;

  static String _size(int bytes) => bytes >= 1024 * 1024
      ? '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB'
      : '${(bytes / 1024).ceil()} KB';

  Future<void> _openPdf(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final bytes = await ref.read(attachmentBytesProvider((me, attachment)).future);
      await ref
          .read(fileSharerProvider)
          .share(bytes, fileName: attachment.name ?? 'document.pdf', mimeType: 'application/pdf');
    } catch (_) {
      messenger.showSnackBar(const SnackBar(content: Text('Could not open the document.')));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final a = attachment;
    if (a.name == null) {
      return Text(
        'This file was encrypted for an earlier device and cannot be shown here.',
        style: TextStyle(color: color, fontStyle: FontStyle.italic),
      );
    }
    if (a.type == AttachmentType.pdf) {
      return InkWell(
        key: Key('attachment-${a.path}'),
        onTap: () => _openPdf(context, ref),
        child: Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.picture_as_pdf, color: color),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  '${a.name} · ${_size(a.size)}',
                  style: TextStyle(color: color, decoration: TextDecoration.underline),
                ),
              ),
            ],
          ),
        ),
      );
    }
    final bytes = ref.watch(attachmentBytesProvider((me, a)));
    return Padding(
      key: Key('attachment-${a.path}'),
      padding: const EdgeInsets.only(bottom: 4),
      child: bytes.when(
        loading: () => const SizedBox(
          width: 160,
          height: 120,
          child: Center(child: CircularProgressIndicator()),
        ),
        error: (_, _) => Text('Photo could not be loaded.', style: TextStyle(color: color)),
        data: (data) => GestureDetector(
          onTap: () => showDialog<void>(
            context: context,
            builder: (c) => Dialog(
              child: InteractiveViewer(child: Image.memory(data, fit: BoxFit.contain)),
            ),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 220, maxWidth: 260),
              child: Image.memory(data, fit: BoxFit.cover, semanticLabel: a.name),
            ),
          ),
        ),
      ),
    );
  }
}

/// Fig 4.3.15.3 (999, not 911 as in the mockup).
class _FlaggedBanner extends StatelessWidget {
  const _FlaggedBanner();

  @override
  Widget build(BuildContext context) {
    final red = BpClassifier.color(BpCategory.crisis);
    return Container(
      key: const Key('chat-flagged-banner'),
      margin: const EdgeInsets.symmetric(vertical: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: red.withValues(alpha: 0.12),
        border: Border(left: BorderSide(color: red, width: 4)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.warning_amber_rounded, color: red),
          const SizedBox(width: 8),
          const Expanded(
            child: Text(
              'This message has been flagged for urgent review. Your care team has been '
              'notified and will respond shortly. If symptoms worsen, call 999 or go to the '
              'nearest emergency department.',
            ),
          ),
        ],
      ),
    );
  }
}

/// D-80: what the "Ask about this" button puts in the message box.
const askAboutPlan = "About my care plan: I don't fully understand this part: ";

/// UC10.2 / D-80: the doctor's care plan as a readable card in the chat.
class CarePlanSheet extends StatelessWidget {
  const CarePlanSheet({
    super.key,
    required this.plan,
    required this.doctorName,
    required this.onAsk,
  });

  final AsyncValue<CarePlan?> plan;
  final String doctorName;
  final VoidCallback onAsk;

  /// One point per line; a single paragraph is split into its sentences.
  static List<String> points(String content) {
    final lines = content
        .split(RegExp(r'\r?\n'))
        .map((l) => l.replaceFirst(RegExp(r'^\s*([-*•]|\d+[.)])\s*'), '').trim())
        .where((l) => l.isNotEmpty)
        .toList();
    if (lines.length > 1) return lines;
    final one = lines.isEmpty ? '' : lines.first;
    final sentences = one
        .split(RegExp(r'(?<=[.!?])\s+'))
        .map((x) => x.trim())
        .where((x) => x.isNotEmpty)
        .toList();
    return sentences.isEmpty ? [one] : sentences;
  }

  static String _capital(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

  static String _date(DateTime t) {
    const m = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    final l = t.toLocal();
    return '${l.day} ${m[l.month - 1]} ${l.year}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final updated = plan.value == null ? '' : ' · updated ${_date(plan.value!.updatedAt)}';
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              key: const Key('care-plan-header'),
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(18),
                gradient: LinearGradient(
                  colors: [scheme.primary, Color.lerp(scheme.primary, Colors.teal, 0.45)!],
                ),
              ),
              child: Row(
                children: [
                  const CircleAvatar(
                    backgroundColor: Colors.white,
                    child: Icon(Icons.assignment_turned_in_outlined),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'My care plan',
                          style: theme.textTheme.titleLarge?.copyWith(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Text(
                          'From $doctorName$updated',
                          style: const TextStyle(color: Colors.white70),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            plan.when(
              loading: () => const LinearProgressIndicator(),
              error: (_, _) => const Text('Could not load your care plan.'),
              data: (p) {
                if (p == null || p.content.trim().isEmpty) {
                  return Container(
                    key: const Key('chat-care-plan'),
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: scheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: const Text(
                      'Your doctor has not written a care plan yet.', // UC10.2 E1
                      textAlign: TextAlign.center,
                    ),
                  );
                }
                final items = points(p.content);
                return ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.45),
                  child: SingleChildScrollView(
                    child: Column(
                      key: const Key('chat-care-plan'),
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (var i = 0; i < items.length; i++)
                          Container(
                            key: Key('care-plan-point-$i'),
                            margin: const EdgeInsets.only(bottom: 8),
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: scheme.primaryContainer.withValues(alpha: 0.45),
                              borderRadius: BorderRadius.circular(12),
                              border: Border(left: BorderSide(color: scheme.primary, width: 4)),
                            ),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Icon(Icons.check_circle_outline, size: 20, color: scheme.primary),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text(_capital(items[i]), style: theme.textTheme.bodyLarge),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                );
              },
            ),
            const SizedBox(height: 8),
            Text(
              "Follow your doctor's plan. Not sure about something? Ask them here.",
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            FilledButton.tonalIcon(
              key: const Key('care-plan-ask'),
              onPressed: onAsk,
              icon: const Icon(Icons.help_outline),
              label: Text('Ask $doctorName about this'),
            ),
          ],
        ),
      ),
    );
  }
}
