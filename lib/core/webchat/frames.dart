import 'dart:convert';

import '../api/models.dart';

/// Decoded server frame for the live chat connection.
sealed class ChatFrame {
  const ChatFrame();
}

class ReadyFrame extends ChatFrame {
  const ReadyFrame(this.conversationId);
  final String? conversationId;
}

class AckFrame extends ChatFrame {
  const AckFrame({required this.accepted, this.turnId});
  final bool accepted;
  final String? turnId;
}

class OutputFrame extends ChatFrame {
  const OutputFrame({required this.turnId, required this.index, this.event, this.status});
  final String? turnId;
  final int index;
  final ChatEvent? event;
  final String? status;
}

class PostFrame extends ChatFrame {
  const PostFrame({this.postId, required this.text, required this.fromAgent});
  final String? postId;
  final String text;
  final bool fromAgent;
}

class DoneFrame extends ChatFrame {
  const DoneFrame({this.turnId, this.stopReason, this.error});
  final String? turnId;
  final String? stopReason;
  final String? error;
}

class ErrorFrame extends ChatFrame {
  const ErrorFrame(this.message);
  final String message;
}

class OtherFrame extends ChatFrame {
  const OtherFrame(this.type);
  final String type; // resync, refused, unknown
}

sealed class ChatEvent {
  const ChatEvent();
}

class MessageEvent extends ChatEvent {
  const MessageEvent(this.text, this.segmentId, this.postId);
  final String text;
  final String? segmentId;
  final String? postId;
}

class ThinkingEvent extends ChatEvent {
  const ThinkingEvent(this.text);
  final String text;
}

class ToolEvent extends ChatEvent {
  const ToolEvent({required this.toolCallId, this.title, required this.status, required this.isUpdate});
  final String toolCallId;
  final String? title;
  final String status;
  final bool isUpdate;
}

class SessionInfoEvent extends ChatEvent {
  const SessionInfoEvent(this.title);
  final String title;
}

class NoticeEvent extends ChatEvent {
  const NoticeEvent(this.text);
  final String text;
}

/// An in-stream approval: tool and detail come from the agent.
class PermissionEvent extends ChatEvent {
  const PermissionEvent(this.requestId, this.tool, this.detail);
  final String requestId;
  final String tool;
  final String detail;
}

class UnsupportedEvent extends ChatEvent {
  const UnsupportedEvent(this.kind);
  final String kind;
}

ChatFrame? decodeFrame(String raw) {
  dynamic j;
  try {
    j = jsonDecode(raw);
  } catch (_) {
    return null;
  }
  final m = asMap(j);
  final type = asStr(m['type']);
  switch (type) {
    case 'ready':
      return ReadyFrame(asStr(m['conversationId']));
    case 'ack':
      final a = asMap(m['ack']);
      return AckFrame(accepted: a['accepted'] != false, turnId: asStr(a['turnId']));
    case 'output':
      final o = asMap(m['output']);
      final idx = o['index'];
      final ev = o['event'];
      final status = o['status'];
      return OutputFrame(
        turnId: asStr(o['turnId']),
        index: idx is num ? idx.toInt() : 0,
        event: ev is Map ? _event(asMap(ev)) : null,
        status: status is String ? status : null,
      );
    case 'post':
      final p = asMap(m['post']);
      return PostFrame(
        postId: asStr(p['postId']),
        text: asStr(p['text']) ?? '',
        fromAgent: asStr(asMap(p['author'])['kind']) != 'user',
      );
    case 'done':
      final d = asMap(m['done']);
      final err = d['error'];
      return DoneFrame(
        turnId: asStr(d['turnId']),
        stopReason: asStr(d['stopReason']),
        error: err == null ? null : (err is String ? err : 'error'),
      );
    case 'error':
      return ErrorFrame(asStr(m['message']) ?? '');
    case null:
      return null;
    default:
      return OtherFrame(type);
  }
}

ChatEvent _event(Map<String, dynamic> e) {
  final kind = asStr(e['kind']) ?? '';
  switch (kind) {
    case 'message':
      return MessageEvent(asStr(e['text']) ?? '', asStr(e['segmentId']), asStr(e['postId']));
    case 'thinking':
      return ThinkingEvent(asStr(e['text']) ?? '');
    case 'tool_call':
    case 'tool_update':
      return ToolEvent(
        toolCallId: asStr(e['toolCallId']) ?? '',
        title: asStr(e['title']),
        status: asStr(e['status']) ?? '',
        isUpdate: kind == 'tool_update',
      );
    case 'session_info':
      return SessionInfoEvent(asStr(e['title']) ?? '');
    case 'notice':
      return NoticeEvent(asStr(e['text']) ?? '');
    case 'permission':
      return PermissionEvent(asStr(e['requestId']) ?? '', asStr(e['tool']) ?? '',
          asStr(e['detail']) ?? '');
    default:
      return UnsupportedEvent(kind);
  }
}

/// Orders output frames of a turn by index and drops duplicates.
class OutputOrderer {
  int? _next;
  final Map<int, OutputFrame> _held = {};

  /// Returns the frames that can be applied now, in order.
  List<OutputFrame> add(OutputFrame f) {
    final n = _next;
    if ((n != null && f.index < n) || _held.containsKey(f.index)) {
      return const [];
    }
    _held[f.index] = f;
    if (n == null) {
      if (f.index > 1) return const [];
      _next = f.index;
    }
    final out = <OutputFrame>[];
    while (_held.containsKey(_next)) {
      out.add(_held.remove(_next)!);
      _next = _next! + 1;
    }
    return out;
  }

  /// Frames still held behind a gap, in index order.
  List<OutputFrame> flush() {
    final keys = _held.keys.toList()..sort();
    final out = [for (final k in keys) _held[k]!];
    if (keys.isNotEmpty) _next = keys.last + 1;
    _held.clear();
    return out;
  }
}
