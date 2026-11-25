import 'dart:js_interop';
import 'dart:js_interop_unsafe';

/// Opens [html] in a new tab and shows the browser's print dialog. Must be called from a
/// click (popup blockers allow that). False if the tab could not be opened.
bool printHtml(String html) {
  final win = globalContext.callMethod('open'.toJS, ''.toJS, '_blank'.toJS);
  if (win == null || win.isUndefinedOrNull) return false;
  final w = win as JSObject;
  final doc = w['document'] as JSObject;
  doc.callMethod('open'.toJS);
  doc.callMethod('write'.toJS, html.toJS);
  doc.callMethod('close'.toJS);
  w.callMethod('focus'.toJS);
  w.callMethod('print'.toJS);
  return true;
}
