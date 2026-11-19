import 'dart:convert';

import '../api/models.dart';
import 'attachments.dart';

/// Decoded server frame for the live chat connection.
sealed class ChatFrame {
  const ChatFrame();
}

/// Feature the relay announces in `ready` once it forwards a turn's `thread`.
const webchatThreadsFeature = 'webchat-threads-v1';

class ReadyFrame extends ChatFrame {
  const ReadyFrame(this.conversationId, {this.participants = 0, this.features = const {}});
  final String? conversationId;

  /// Agents in the conversation (`ready.participants`); more than one is a
  /// multi-agent room, where runtime commands aren't offered.
  final int participants;

  /// What the relay forwards (`webchat-upload-previews-v1`, …).
  final Set<String> features;
}

/// The runtime's predicted next prompt (`prompt_suggestion`); null clears it.
class PromptSuggestionFrame extends ChatFrame {
  const PromptSuggestionFrame(this.text);
  final String? text;
}

class AckFrame extends ChatFrame {
  const AckFrame({required this.accepted, this.turnId, this.reason, this.steered = false});
  final bool accepted;
  final String? turnId;

  /// Why a turn was refused (`busy`, `paused`, …).
  final String? reason;

  /// A turn sent with `steer: true` went into the running turn.
  final bool steered;
}

/// `done.stopReason` of a message that joined the running turn instead of
/// starting its own: that turn goes on.
const joinedTurnStopReasons = {'steered_into_turn', 'coalesced_into_turn'};

class OutputFrame extends ChatFrame {
  const OutputFrame({required this.turnId, required this.index, this.event, this.status, this.thread});
  final String? turnId;

  /// The thread (root `postId`) this turn answers in; null at the root.
  final String? thread;
  final int index;
  final ChatEvent? event;
  final RunStatus? status;
}

/// The session's run settings snapshot (`output.status`): current model,
/// effort and permission preset, and what the runtime offers for each.
/// Lists are null when the runtime offers no selector.
class RunStatus {
  const RunStatus({
    this.model,
    this.effort,
    this.permissionMode,
    this.models,
    this.efforts,
    this.permissionModes,
    this.fastMode,
    this.fastModeAvailable,
    this.steerable,
  });

  /// The running turn takes a message sent meanwhile (`steer: true`) instead
  /// of it having to wait. Belongs to that turn only.
  final bool? steerable;

  /// Fast mode is on; offered only when [fastModeAvailable].
  final bool? fastMode;
  final bool? fastModeAvailable;
  final String? model;
  final String? effort;
  final String? permissionMode;
  final List<String>? models;
  final List<String>? efforts;
  final List<String>? permissionModes;

  static List<String>? _list(dynamic v) =>
      v is List ? v.whereType<String>().where((s) => s.isNotEmpty).toList() : null;

  static RunStatus? fromJson(dynamic j) {
    if (j is! Map) return null;
    final m = asMap(j);
    return RunStatus(
      model: asStr(m['model']),
      effort: asStr(m['effort']),
      permissionMode: asStr(m['permissionMode']),
      models: _list(m['models']),
      efforts: _list(m['efforts']),
      permissionModes: _list(m['permissionModes']),
      fastMode: m['fastMode'] is bool ? m['fastMode'] as bool : null,
      fastModeAvailable: m['fastModeAvailable'] is bool ? m['fastModeAvailable'] as bool : null,
      steerable: m['steerable'] is bool ? m['steerable'] as bool : null,
    );
  }

  /// A later partial snapshot only replaces the fields it carries.
  RunStatus merge(RunStatus o) => RunStatus(
        model: o.model ?? model,
        effort: o.effort ?? effort,
        permissionMode: o.permissionMode ?? permissionMode,
        models: o.models ?? models,
        efforts: o.efforts ?? efforts,
        permissionModes: o.permissionModes ?? permissionModes,
        fastMode: o.fastMode ?? fastMode,
        fastModeAvailable: o.fastModeAvailable ?? fastModeAvailable,
        steerable: o.steerable ?? steerable,
      );
}

class PostFrame extends ChatFrame {
  const PostFrame({this.postId, required this.text, required this.fromAgent, this.thread, this.images = const []});
  final String? postId;

  /// The thread this post is a reply in; null for a root.
  final String? thread;
  final String text;
  final bool fromAgent;

  /// Inline images, and the preview of an image the agent shared.
  final List<ImageAttachment> images;
}

class DoneFrame extends ChatFrame {
  const DoneFrame({this.turnId, this.stopReason, this.error, this.thread});
  final String? turnId;
  final String? thread;
  final String? stopReason;
  final String? error;
}

/// The daemon refused an op for this browser alone (`refused`), with why.
class RefusedFrame extends ChatFrame {
  const RefusedFrame(this.op, this.reason);
  final String? op;
  final String reason;
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

/// A Fill card (`fill_request`): the agent asks the person to fill a website
/// form on a computer. Carries field descriptors only, never a value.
class FillRequestEvent extends ChatEvent {
  const FillRequestEvent(this.card);
  final FillCard card;
}

/// The same card, settled (`fill_resolved`). Never carries a value.
class FillResolvedEvent extends ChatEvent {
  const FillResolvedEvent(this.requestId, this.outcome);
  final String requestId;
  final String outcome;
}

/// `fill_resolved` outcomes (`COMPUTER_FILL_CARD_OUTCOMES`).
const fillOutcomes = {
  'filled',
  'partial',
  'failed',
  'uncertain',
  'target_changed',
  'unsupported',
  'cancelled',
  'expired',
};

class FillOption {
  const FillOption(this.value, this.label);
  final String value;
  final String label;
}

/// One form field the card asks for (`ComputerFormField`).
class FillField {
  const FillField({
    required this.id,
    required this.control,
    required this.purpose,
    this.label,
    this.name,
    this.placeholder,
    this.required = false,
    this.secret = false,
    this.ambiguous = false,
    this.maxLength,
    this.options = const [],
  });
  final String id;

  /// text, email, password, tel, number, url, search, date, textarea, select, checkbox, radio.
  final String control;
  final String purpose;
  final String? label;
  final String? name;
  final String? placeholder;
  final bool required;

  /// Always masked here, whatever the website does with it.
  final bool secret;
  final bool ambiguous;
  final int? maxLength;
  final List<FillOption> options;

  static const _secretPurposes = {'current-password', 'new-password', 'one-time-code'};

  /// Masked: flagged secret, or a purpose that is always secret.
  bool get masked => secret || _secretPurposes.contains(purpose);
  bool get isCheckbox => control == 'checkbox';
  bool get isChoice => (control == 'select' || control == 'radio') && options.isNotEmpty;

  String get title {
    for (final s in [label, placeholder, name]) {
      if (s != null && s.trim().isNotEmpty) return s.trim();
    }
    return purpose;
  }

  static FillField? fromJson(dynamic j) {
    final m = asMap(j);
    final id = asStr(m['id']);
    final control = asStr(m['control']);
    if (id == null || id.isEmpty || control == null) return null;
    final ml = m['maxLength'];
    return FillField(
      id: id,
      control: control,
      purpose: asStr(m['purpose']) ?? 'unknown',
      label: asStr(m['label']),
      name: asStr(m['name']),
      placeholder: asStr(m['placeholder']),
      required: m['required'] == true,
      secret: m['secret'] == true,
      ambiguous: m['ambiguous'] == true,
      maxLength: ml is num ? ml.toInt() : null,
      options: [
        for (final o in asList(m['options']))
          if (asStr(asMap(o)['value']) case final v?) FillOption(v, asStr(asMap(o)['label']) ?? v),
      ],
    );
  }
}

/// `ComputerFillCard`: the website as the browser reports it, the agent's
/// reason (untrusted text) and the fields.
class FillCard {
  const FillCard({
    required this.requestId,
    required this.computerName,
    required this.origin,
    this.title,
    this.frameOrigin,
    this.kind,
    required this.fields,
    this.reason,
    this.expiresAt,
  });
  final String requestId;
  final String computerName;
  final String origin;
  final String? title;
  final String? frameOrigin;
  final String? kind;
  final List<FillField> fields;
  final String? reason;
  final DateTime? expiresAt;

  bool expired([DateTime? now]) => expiresAt != null && !expiresAt!.isAfter(now ?? DateTime.now());

  /// A secret the website shows as typed (not a password input): later
  /// screenshots can include it.
  bool get unmaskedOnPage => fields.any((f) => f.masked && f.control != 'password');

  static FillCard? fromJson(dynamic j) {
    final m = asMap(j);
    final id = asStr(m['requestId']);
    final origin = asStr(asMap(m['website'])['origin']);
    final fields = asList(m['fields']).map(FillField.fromJson).whereType<FillField>().toList();
    if (id == null || origin == null || fields.isEmpty) return null;
    return FillCard(
      requestId: id,
      computerName: asStr(m['computerName']) ?? '',
      origin: origin,
      title: asStr(asMap(m['website'])['title']),
      frameOrigin: asStr(m['frameOrigin']),
      kind: asStr(m['kind']),
      fields: fields,
      reason: asStr(m['reason']),
      expiresAt: asDate(m['expiresAt']),
    );
  }
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
      return ReadyFrame(asStr(m['conversationId']),
          participants: asList(m['participants']).length,
          features: asList(m['features']).whereType<String>().toSet());
    case 'ack':
      final a = asMap(m['ack']);
      return AckFrame(
          accepted: a['accepted'] != false,
          turnId: asStr(a['turnId']),
          reason: asStr(a['reason']),
          steered: a['steered'] == true);
    case 'output':
      final o = asMap(m['output']);
      final idx = o['index'];
      final ev = o['event'];
      return OutputFrame(
        turnId: asStr(o['turnId']),
        index: idx is num ? idx.toInt() : 0,
        event: ev is Map ? _event(asMap(ev)) : null,
        status: RunStatus.fromJson(o['status']),
        thread: asStr(o['thread']),
      );
    case 'post':
      final p = asMap(m['post']);
      return PostFrame(
        postId: asStr(p['postId']),
        text: asStr(p['text']) ?? '',
        fromAgent: asStr(asMap(p['author'])['kind']) != 'user',
        thread: asStr(p['thread']),
        images: [
          ...ImageAttachment.listFrom(p['attachments']),
          ?ImageAttachment.fromJson(asMap(p['image'])['attachment']),
        ],
      );
    case 'done':
      final d = asMap(m['done']);
      final err = d['error'];
      return DoneFrame(
        turnId: asStr(d['turnId']),
        stopReason: asStr(d['stopReason']),
        error: err == null ? null : (err is String ? err : 'error'),
        thread: asStr(d['thread']),
      );
    case 'prompt_suggestion':
      final t = asStr(asMap(m['suggestion'])['text']);
      return PromptSuggestionFrame(t == null || t.trim().isEmpty ? null : t);
    case 'error':
      return ErrorFrame(asStr(m['message']) ?? '');
    case 'refused':
      final rf = asMap(m['refused']);
      return RefusedFrame(asStr(rf['op']), asStr(rf['reason']) ?? '');
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
    case 'fill_request':
      final card = FillCard.fromJson(e['card']);
      return card == null ? const UnsupportedEvent('fill_request') : FillRequestEvent(card);
    case 'fill_resolved':
      final id = asStr(e['requestId']);
      final outcome = asStr(e['outcome']);
      return id == null || outcome == null ? const UnsupportedEvent('fill_resolved') : FillResolvedEvent(id, outcome);
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
