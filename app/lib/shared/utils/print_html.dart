// D-129: print a small HTML page (e.g. the walk-in setup-code slip) from the staff portal.
// Web opens it in a new tab and calls the browser's print; Android has no printing (false).
export 'print_html_stub.dart' if (dart.library.js_interop) 'print_html_web.dart';
