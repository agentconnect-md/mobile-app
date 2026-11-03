Map<String, dynamic> asMap(dynamic v) =>
    v is Map ? v.cast<String, dynamic>() : <String, dynamic>{};
List<dynamic> asList(dynamic v) => v is List ? v : const [];
String? asStr(dynamic v) => v is String ? v : null;
DateTime? asDate(dynamic v) =>
    v is String ? DateTime.tryParse(v)?.toLocal() : null;

class Me {
  const Me({required this.userId, required this.name});
  final String userId;
  final String name;
  factory Me.fromJson(dynamic j) {
    final m = asMap(j);
    final id = asStr(m['userId']);
    if (id == null) throw const FormatException('me');
    return Me(userId: id, name: asStr(m['name']) ?? asStr(m['email']) ?? '');
  }
}

class Org {
  const Org({required this.id, required this.name, this.role});
  final String id;
  final String name;
  final String? role;
  factory Org.fromJson(dynamic j) {
    final m = asMap(j);
    return Org(
      id: asStr(m['id']) ?? '',
      name: asStr(m['name']) ?? asStr(m['slug']) ?? '',
      role: asStr(m['role']),
    );
  }
}

class Agent {
  const Agent({
    required this.id,
    required this.name,
    this.displayName,
    this.status,
    this.webchat = false,
  });
  final String id;
  final String name;
  final String? displayName;
  final String? status;
  final bool webchat;
  String get label =>
      (displayName != null && displayName!.isNotEmpty) ? displayName! : name;
  bool get active => status == 'active';
  factory Agent.fromJson(dynamic j) {
    final m = asMap(j);
    return Agent(
      id: asStr(m['id']) ?? '',
      name: asStr(m['name']) ?? '',
      displayName: asStr(m['displayName']),
      status: asStr(m['status']),
      webchat: m['ahpWebchat'] == true,
    );
  }
}

enum ActivityState { idle, working, awaiting }

class SessionRow {
  const SessionRow({
    required this.sessionId,
    required this.agentId,
    required this.agentName,
    required this.platform,
    this.title,
    this.status,
    this.lastActivityAt,
    this.threadUrl,
    this.activityState,
  });
  final String sessionId;
  final String agentId;
  final String agentName;
  final String platform;
  final String? title;
  final String? status;
  final DateTime? lastActivityAt;
  final String? threadUrl;
  final String? activityState;

  ActivityState get state {
    switch (activityState) {
      case 'awaiting_permission':
        return ActivityState.awaiting;
      case 'thinking':
      case 'tool_call':
        return ActivityState.working;
      default:
        return ActivityState.idle;
    }
  }

  bool get isWebchat => platform == 'webchat';

  factory SessionRow.fromJson(dynamic j) {
    final m = asMap(j);
    return SessionRow(
      sessionId: asStr(m['sessionId']) ?? '',
      agentId: asStr(m['agentId']) ?? '',
      agentName: asStr(m['agentName']) ?? '',
      platform: asStr(asMap(m['sessionKey'])['platform']) ??
          asStr(m['platform']) ??
          '',
      title: asStr(m['title']),
      status: asStr(m['status']),
      lastActivityAt: asDate(m['lastActivityAt']),
      threadUrl: asStr(m['threadUrl']),
      activityState: asStr(m['activityState']),
    );
  }
}

class Conversation {
  const Conversation({
    required this.key,
    required this.platform,
    required this.sessions,
  });
  final String key;
  final String platform;
  final List<SessionRow> sessions;

  List<SessionRow> get _recent {
    final l = [...sessions];
    l.sort((a, b) => (b.lastActivityAt ?? DateTime(1970))
        .compareTo(a.lastActivityAt ?? DateTime(1970)));
    return l;
  }

  SessionRow get primary => _recent.first;

  String? get title {
    for (final s in _recent) {
      if (s.title != null && s.title!.trim().isNotEmpty) return s.title!.trim();
    }
    return null;
  }

  DateTime? get lastActivity => primary.lastActivityAt;

  ActivityState get state {
    var best = ActivityState.idle;
    for (final s in sessions) {
      if (s.state == ActivityState.awaiting) return ActivityState.awaiting;
      if (s.state == ActivityState.working) best = ActivityState.working;
    }
    return best;
  }

  String? get threadUrl {
    for (final s in _recent) {
      if (s.threadUrl != null && s.threadUrl!.isNotEmpty) return s.threadUrl;
    }
    return null;
  }

  /// Source id: slack, telegram, discord, feishu, github, chat.
  String get source {
    switch (platform) {
      case 'slack':
      case 'telegram':
      case 'discord':
      case 'feishu':
        return platform;
      case 'hook':
        return 'github';
      default:
        return 'chat';
    }
  }

  factory Conversation.fromJson(dynamic j) {
    final m = asMap(j);
    final rows = asList(m['sessions']).map(SessionRow.fromJson).toList();
    return Conversation(
      key: asStr(m['key']) ?? (rows.isEmpty ? '' : rows.first.sessionId),
      platform:
          asStr(m['platform']) ?? (rows.isEmpty ? '' : rows.first.platform),
      sessions: rows,
    );
  }
}

class ConversationPage {
  const ConversationPage({
    required this.conversations,
    this.nextCursor,
    this.degraded = false,
  });
  final List<Conversation> conversations;
  final String? nextCursor;
  final bool degraded;
  factory ConversationPage.fromJson(dynamic j) {
    final m = asMap(j);
    return ConversationPage(
      conversations: asList(m['conversations'])
          .map(Conversation.fromJson)
          .where((c) => c.sessions.isNotEmpty)
          .toList(),
      nextCursor: asStr(m['nextCursor']),
      degraded: m['accessSyncDegraded'] == true,
    );
  }
}

class ApiMessage {
  const ApiMessage({
    required this.seq,
    required this.sender,
    required this.kind,
    required this.text,
    this.toolCallId,
    this.toolStatus,
    this.toolKind,
    this.body,
    this.bodyTruncated = false,
    this.postId,
  });
  final int seq;
  final String sender;
  final String kind;
  final String text;
  final String? toolCallId;
  final String? toolStatus;
  final String? toolKind;
  final String? body;
  final bool bodyTruncated;
  final String? postId;
  factory ApiMessage.fromJson(dynamic j) {
    final m = asMap(j);
    final seq = m['seq'];
    return ApiMessage(
      seq: seq is num ? seq.toInt() : 0,
      sender: asStr(m['sender']) ?? '',
      kind: asStr(m['kind']) ?? 'text',
      text: asStr(m['text']) ?? '',
      toolCallId: asStr(m['toolCallId']),
      toolStatus: asStr(m['toolStatus']),
      toolKind: asStr(m['toolKind']),
      body: asStr(m['body']),
      bodyTruncated: m['bodyTruncated'] == true,
      postId: asStr(m['postId']),
    );
  }
}

class MessagePage {
  const MessagePage({required this.messages, this.nextCursor});
  final List<ApiMessage> messages;
  final String? nextCursor;
  factory MessagePage.fromJson(dynamic j) {
    final m = asMap(j);
    final list = asList(m['messages']).map(ApiMessage.fromJson).toList()
      ..sort((a, b) => a.seq.compareTo(b.seq));
    return MessagePage(messages: list, nextCursor: asStr(m['nextCursor']));
  }
}

class ToolBodyChunk {
  const ToolBodyChunk(this.data, this.nextOffset);
  final String data;
  final int? nextOffset;
  factory ToolBodyChunk.fromJson(dynamic j) {
    final m = asMap(j);
    final n = m['nextOffset'];
    return ToolBodyChunk(asStr(m['data']) ?? '', n is num ? n.toInt() : null);
  }
}

class WebchatGrant {
  const WebchatGrant({
    required this.credential,
    required this.relayUrl,
    required this.conversationId,
  });
  final String credential;
  final String relayUrl;
  final String conversationId;
  factory WebchatGrant.fromJson(dynamic j) {
    final m = asMap(j);
    final t = asStr(m['token']);
    final r = asStr(m['relayUrl']);
    final c = asStr(m['conversationId']);
    if (t == null || r == null || c == null) {
      throw const FormatException('grant');
    }
    return WebchatGrant(credential: t, relayUrl: r, conversationId: c);
  }

  /// wss URL for the live connection. Contains the credential: never log it.
  Uri socketUri() {
    final u = Uri.parse(relayUrl);
    final scheme = u.scheme == 'http' ? 'ws' : 'wss';
    final base =
        u.path.endsWith('/') ? u.path.substring(0, u.path.length - 1) : u.path;
    return u.replace(
      scheme: scheme,
      path: '$base/webchat',
      queryParameters: {'token': credential, 'conversation_id': conversationId},
    );
  }
}
