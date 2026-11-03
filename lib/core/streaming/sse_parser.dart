import 'dart:async';
import 'dart:convert';

class SseEvent {
  const SseEvent(this.event, this.data);
  final String event;
  final String data;
}

/// Parses a text/event-stream byte stream. Comment lines (": ...") are ignored.
/// Events without a name are reported as "message".
Stream<SseEvent> parseSse(Stream<List<int>> bytes) async* {
  var event = '';
  final data = <String>[];
  await for (final line in bytes
      .transform(utf8.decoder)
      .transform(const LineSplitter())) {
    if (line.isEmpty) {
      if (data.isNotEmpty || event.isNotEmpty) {
        yield SseEvent(event.isEmpty ? 'message' : event, data.join('\n'));
      }
      event = '';
      data.clear();
      continue;
    }
    if (line.startsWith(':')) continue;
    final i = line.indexOf(':');
    final field = i < 0 ? line : line.substring(0, i);
    var value = i < 0 ? '' : line.substring(i + 1);
    if (value.startsWith(' ')) value = value.substring(1);
    if (field == 'event') {
      event = value;
    } else if (field == 'data') {
      data.add(value);
    }
  }
}
