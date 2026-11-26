import 'dart:async';

/// D-132: data of every push received while Harvey is open, so screens can refresh
/// (e.g. the Orders list after the pharmacy cancels an order).
class PushEvents {
  PushEvents._();

  static final _controller = StreamController<Map<String, String>>.broadcast();

  static Stream<Map<String, String>> get stream => _controller.stream;

  static void add(Map<String, dynamic> data) =>
      _controller.add({for (final e in data.entries) e.key: '${e.value}'});
}
