import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pdfx/pdfx.dart';

import '../../provider_portal/presentation/portal_widgets.dart' show formatDate;
import '../../settings/state/settings_providers.dart';
import '../data/records_repository.dart';
import '../state/records_providers.dart';
import 'record_widgets.dart';

/// Draws a PDF's pages from its bytes. Behind a provider so widget tests can swap the
/// native renderer for a plain box.
typedef PdfPagesBuilder = Widget Function(Uint8List bytes, String name);

final pdfPagesBuilderProvider = Provider<PdfPagesBuilder>((ref) => defaultPdfPages);

Widget defaultPdfPages(Uint8List bytes, String name) => _PdfPages(bytes: bytes, name: name);

/// D-88: a record (image or PDF, including receipts) opens full screen inside Harvey,
/// so the patient doesn't have to send it to WhatsApp just to read it (UC6.3).
class RecordViewerPage extends ConsumerStatefulWidget {
  const RecordViewerPage({super.key, required this.record});

  final HealthRecord record;

  @override
  ConsumerState<RecordViewerPage> createState() => _RecordViewerPageState();
}

class _RecordViewerPageState extends ConsumerState<RecordViewerPage> {
  late Future<Uint8List> _bytes = _load();

  Future<Uint8List> _load() => ref.read(recordsRepositoryProvider).fileBytes(widget.record.id);

  @override
  Widget build(BuildContext context) {
    final r = widget.record;
    return Scaffold(
      key: const Key('record-viewer'),
      appBar: AppBar(
        title: Text(r.fileName, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            key: const Key('viewer-share-out'),
            tooltip: 'Share to other apps',
            icon: const Icon(Icons.ios_share),
            onPressed: () => shareRecordOut(context, ref, r),
          ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Details(record: r),
          const Divider(height: 1),
          Expanded(
            child: FutureBuilder<Uint8List>(
              future: _bytes,
              builder: (context, snap) {
                if (snap.hasError) {
                  return _Problem(onRetry: () => setState(() => _bytes = _load()));
                }
                final bytes = snap.data;
                if (bytes == null) return const Center(child: CircularProgressIndicator());
                if (r.isPdf) return ref.watch(pdfPagesBuilderProvider)(bytes, r.fileName);
                return InteractiveViewer(
                  key: const Key('record-image'),
                  maxScale: 5,
                  child: Center(
                    child: Image.memory(bytes, fit: BoxFit.contain, semanticLabel: r.fileName),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _Details extends StatelessWidget {
  const _Details({required this.record});
  final HealthRecord record;

  @override
  Widget build(BuildContext context) {
    final r = record;
    final (icon, color) = categoryStyle(r.category);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Wrap(
        spacing: 8,
        runSpacing: 6,
        children: [
          Chip(
            avatar: Icon(icon, size: 18, color: color),
            label: Text(r.category.label),
            visualDensity: VisualDensity.compact,
          ),
          Chip(
            avatar: const Icon(Icons.event, size: 18),
            label: Text(formatDate(r.uploadedAt)),
            visualDensity: VisualDensity.compact,
          ),
          if (r.sharedWithDoctor)
            Chip(
              key: const Key('viewer-shared'),
              avatar: Icon(Icons.check_circle, size: 18, color: Colors.green.shade700),
              label: const Text('Shared with doctor'),
              visualDensity: VisualDensity.compact,
            ),
        ],
      ),
    );
  }
}

class _Problem extends StatelessWidget {
  const _Problem({required this.onRetry});
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.cloud_off, size: 48),
        const SizedBox(height: 8),
        const Text('Could not open the document.'),
        const SizedBox(height: 8),
        OutlinedButton(
          key: const Key('viewer-retry'),
          onPressed: onRetry,
          child: const Text('Try again'),
        ),
      ],
    ),
  );
}

/// The pages of a PDF, scrolled top to bottom and pinch-zoomable (pdfx: Android's own
/// PdfRenderer on the phone, pdf.js in the portal).
class _PdfPages extends StatefulWidget {
  const _PdfPages({required this.bytes, required this.name});
  final Uint8List bytes;
  final String name;

  @override
  State<_PdfPages> createState() => _PdfPagesState();
}

class _PdfPagesState extends State<_PdfPages> {
  late final _controller = PdfControllerPinch(document: PdfDocument.openData(widget.bytes));

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ColoredBox(
    key: const Key('record-pdf'),
    color: Theme.of(context).colorScheme.surfaceContainerHighest,
    child: PdfViewPinch(
      controller: _controller,
      builders: PdfViewPinchBuilders<DefaultBuilderOptions>(
        options: const DefaultBuilderOptions(),
        documentLoaderBuilder: (_) => const Center(child: CircularProgressIndicator()),
        pageLoaderBuilder: (_) => const Center(child: CircularProgressIndicator()),
        errorBuilder: (_, _) => _PdfFallback(name: widget.name),
      ),
    ),
  );
}

class _PdfFallback extends StatelessWidget {
  const _PdfFallback({required this.name});
  final String name;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.picture_as_pdf, size: 64),
          const SizedBox(height: 8),
          Text(name, textAlign: TextAlign.center),
          const SizedBox(height: 8),
          const Text(
            'This PDF could not be shown here. Use "Share to other apps" to open it elsewhere.',
            textAlign: TextAlign.center,
          ),
        ],
      ),
    ),
  );
}

/// Sends the file to another app (WhatsApp, Drive, a printer) through the share sheet;
/// a download in the browser.
Future<void> shareRecordOut(BuildContext context, WidgetRef ref, HealthRecord r) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    final bytes = await ref.read(recordsRepositoryProvider).fileBytes(r.id);
    await ref.read(fileSharerProvider).share(bytes, fileName: r.fileName, mimeType: r.contentType);
  } catch (_) {
    messenger.showSnackBar(const SnackBar(content: Text('Could not share the document.')));
  }
}
