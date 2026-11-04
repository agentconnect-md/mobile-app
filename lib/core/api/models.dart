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
    this.description,
    this.runtime,
    this.model,
    this.daemonId,
    this.daemonName,
    this.iconUrl,
    this.builtin = false,
    this.paused = false,
    this.placementReady = true,
    this.workspace,
  });

  /// Where the agent works; null on a scratch workspace or an older server.
  final AgentRepo? workspace;
  final String id;
  final String name;
  final String? displayName;
  final String? status;
  final bool webchat;
  final String? description;
  final String? runtime;
  final String? model;
  final String? daemonId;
  final String? daemonName;
  final String? iconUrl;
  final bool builtin;
  final bool paused;
  final bool placementReady;
  String get label =>
      (displayName != null && displayName!.isNotEmpty) ? displayName! : name;
  bool get active => status == 'active';

  /// Online: active and placed on a machine that can take sessions.
  AgentHealth get health => paused
      ? AgentHealth.paused
      : !active
          ? AgentHealth.offline
          : placementReady
              ? AgentHealth.online
              : AgentHealth.offline;

  factory Agent.fromJson(dynamic j) {
    final m = asMap(j);
    return Agent(
      id: asStr(m['id']) ?? '',
      name: asStr(m['name']) ?? '',
      displayName: asStr(m['displayName']),
      status: asStr(m['status']),
      webchat: m['ahpWebchat'] == true,
      description: asStr(m['description']),
      runtime: asStr(m['runtime']),
      model: asStr(m['model']),
      daemonId: asStr(m['daemonId']),
      daemonName: asStr(m['daemonName']),
      iconUrl: asStr(m['iconUrl']),
      builtin: m['builtin'] == true,
      paused: m['pause'] == true,
      placementReady: m['placementReady'] != false,
      workspace: AgentRepo.fromJson(m['workspace']),
    );
  }
}

/// An agent's git workspace (`workspace.mode == 'git'`).
class AgentRepo {
  const AgentRepo({required this.gitRepo, this.branch, this.agentDir, this.worktrees = false});
  final String gitRepo;
  final String? branch;
  final String? agentDir;

  /// Each session gets its own worktree.
  final bool worktrees;

  /// `owner/repo` from an https or ssh address (as the console's `repoLabel`).
  String get label {
    var r = gitRepo.trim();
    if (r.endsWith('.git')) r = r.substring(0, r.length - 4);
    final ssh = RegExp(r'^[\w.-]+@[^:]+:(.+)$').firstMatch(r);
    if (ssh != null) return ssh.group(1)!;
    final uri = Uri.tryParse(r);
    if (uri != null && uri.hasScheme && uri.pathSegments.isNotEmpty) {
      return uri.pathSegments.where((s) => s.isNotEmpty).join('/');
    }
    return r;
  }

  static AgentRepo? fromJson(dynamic j) {
    final m = asMap(j);
    final repo = asStr(m['gitRepo']);
    if (m['mode'] != 'git' || repo == null || repo.isEmpty) return null;
    return AgentRepo(
      gitRepo: repo,
      branch: asStr(m['gitBranch']),
      agentDir: asStr(m['agentDir']),
      worktrees: m['worktree'] == true,
    );
  }
}

enum AgentHealth { online, paused, offline }

/// slack, telegram, discord, feishu, github or chat (webchat and anything else).
/// `chat` is web chat only; scheduled/background runs (dream, hooks without
/// a repo) are `other`.
String sourceOf(String platform) => switch (platform) {
      'slack' || 'telegram' || 'discord' || 'feishu' => platform,
      'hook' => 'github',
      'webchat' => 'chat',
      _ => 'other',
    };

/// A machine that runs agents (`GET /orgs/{org}/daemons`).
class Machine {
  const Machine({
    required this.id,
    required this.name,
    required this.status,
    required this.health,
    required this.cloud,
    this.host,
    this.version,
    this.activeSessions = 0,
    this.cpu,
    this.lastSeenAt,
    this.nodes = 1,
  });

  /// Members behind this row (the cloud pool is shown as one row).
  final int nodes;
  final String id;
  final String name;
  final String status;
  final String health;
  final bool cloud;
  final String? host;
  final String? version;
  final int activeSessions;

  /// 0–100, or null when the machine reports no load.
  final double? cpu;
  final DateTime? lastSeenAt;

  /// `status` is ready / draining / connecting / pending / unreachable / offline.
  AgentHealth get state => switch (status) {
        'ready' => health == 'degraded' ? AgentHealth.paused : AgentHealth.online,
        'draining' || 'connecting' || 'pending' => AgentHealth.paused,
        _ => AgentHealth.offline,
      };

  /// The install-wide pool as one row: online when any member is, sessions
  /// summed, CPU averaged over members that report it.
  static Machine pool(List<Machine> members) {
    final online = members.where((m) => m.state == AgentHealth.online).toList();
    final cpus = online.map((m) => m.cpu).whereType<double>().toList();
    final versions = <String, int>{};
    for (final m in members) {
      if (m.version != null) versions[m.version!] = (versions[m.version!] ?? 0) + 1;
    }
    final version = versions.entries.isEmpty
        ? null
        : (versions.entries.toList()..sort((a, b) => b.value.compareTo(a.value))).first.key;
    return Machine(
      id: 'cloud-pool',
      name: '',
      status: online.isNotEmpty
          ? 'ready'
          : members.any((m) => m.state == AgentHealth.paused)
              ? 'connecting'
              : 'offline',
      health: '',
      cloud: true,
      version: version,
      activeSessions: members.fold(0, (s, m) => s + m.activeSessions),
      cpu: cpus.isEmpty ? null : cpus.reduce((a, b) => a + b) / cpus.length,
      nodes: members.length,
    );
  }

  factory Machine.fromJson(dynamic j) {
    final m = asMap(j);
    final load = asMap(m['load']);
    final cpu = load['cpu'];
    final active = m['activeSessions'];
    return Machine(
      id: asStr(m['daemonId']) ?? '',
      name: asStr(m['name']) ?? asStr(m['host']) ?? asStr(m['daemonId']) ?? '',
      status: asStr(m['status']) ?? '',
      health: asStr(m['health']) ?? '',
      cloud: m['cloud'] == true,
      host: asStr(m['host']),
      version: asStr(m['agentVersion']),
      activeSessions: active is num ? active.toInt() : 0,
      // Some machines report 0–1, others 0–100.
      cpu: cpu is num ? (cpu <= 1 ? cpu * 100 : cpu).toDouble() : null,
      lastSeenAt: asDate(m['lastSeenAt']),
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
    this.channelName,
    this.channelId,
    this.subsession = false,
    this.model,
    this.runtime,
    this.effort,
    this.permissionMode,
    this.workspaceIsolation,
    this.contentPurged = false,
  });

  /// `session`: the session works in its own worktree; `shared`: in the
  /// agent's checkout. Null on servers that predate the field.
  final String? workspaceIsolation;
  final bool contentPurged;
  bool get ownWorktree => workspaceIsolation == 'session' && !contentPurged;
  final String? effort;
  /// `sessionKey.channel`: for a webchat session, its conversation id.
  final String? channelId;
  /// A task (follow-up, delegated task): never its conversation's own session.
  final bool subsession;
  final String? permissionMode;
  final String? channelName;
  final String? model;
  final String? runtime;
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

  /// The webchat conversation to resume when replying, as the web console
  /// does; null for other origins and tasks (they continue by session id).
  String? get webchatConversationId =>
      isWebchat && !subsession && channelId != null && channelId!.isNotEmpty ? channelId : null;

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
      channelName: asStr(m['channelName']),
      channelId: asStr(asMap(m['sessionKey'])['channel']) ?? asStr(m['channelId']),
      subsession: m['subsession'] == true,
      model: asStr(m['model']),
      runtime: asStr(m['runtime']),
      effort: asStr(m['effort']),
      permissionMode: asStr(m['permissionMode']),
      workspaceIsolation: asStr(m['workspaceIsolation']),
      contentPurged: asStr(m['contentPurgedAt']) != null,
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
  String get source => sourceOf(platform);

  /// Where it lives, as in the design: "#deploys", "acme/api#1284", "Web chat" (null).
  String? get place {
    for (final s in _recent) {
      final c = s.channelName;
      if (c != null && c.isNotEmpty) return c;
    }
    return null;
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
    this.total,
  });
  final List<Conversation> conversations;
  final String? nextCursor;
  final bool degraded;

  /// Matching conversations across all pages; null when the server can't say.
  final int? total;
  factory ConversationPage.fromJson(dynamic j) {
    final m = asMap(j);
    final total = m['total'];
    return ConversationPage(
      conversations: asList(m['conversations'])
          .map(Conversation.fromJson)
          .where((c) => c.sessions.isNotEmpty)
          .toList(),
      nextCursor: asStr(m['nextCursor']),
      degraded: m['accessSyncDegraded'] == true,
      total: total is num ? total.toInt() : null,
    );
  }
}

/// The Sessions filter, as in the web console: one value per facet, null = all.
/// Values are the facet values `/sessions/facets` returns.
class SessionFilters {
  const SessionFilters({this.agent, this.integration, this.channel, this.trigger});
  final String? agent;
  final String? integration;
  final String? channel;
  final String? trigger;

  /// Web chat conversations each have their own channel id; the console shows
  /// them as one channel and filters them by platform instead.
  static const webchatChannel = 'webchat';

  /// GitHub triggers are grouped per repository: `github-repo:<id>`.
  static const githubRepoPrefix = 'github-repo:';

  bool get active => agent != null || integration != null || channel != null || trigger != null;

  SessionFilters with_(SessionFacet facet, String? value) => SessionFilters(
        agent: facet == SessionFacet.agent ? value : agent,
        integration: facet == SessionFacet.integration ? value : integration,
        channel: facet == SessionFacet.channel ? value : channel,
        trigger: facet == SessionFacet.trigger ? value : trigger,
      );

  String? of(SessionFacet facet) => switch (facet) {
        SessionFacet.agent => agent,
        SessionFacet.integration => integration,
        SessionFacet.channel => channel,
        SessionFacet.trigger => trigger,
      };

  /// Query parameters for `/sessions` and `/sessions/facets`.
  Map<String, String> get query {
    final channel = this.channel, trigger = this.trigger;
    final repo = trigger != null && trigger.startsWith(githubRepoPrefix)
        ? trigger.substring(githubRepoPrefix.length)
        : null;
    return {
      'agentId': ?agent,
      'integration': ?integration,
      if (channel == webchatChannel) 'platform': 'webchat' else 'channel': ?channel,
      if (repo != null && RegExp(r'^[1-9]\d*$').hasMatch(repo)) 'githubRepoId': repo else 'triggeredBy': ?trigger,
    };
  }

  @override
  bool operator ==(Object other) =>
      other is SessionFilters &&
      other.agent == agent &&
      other.integration == integration &&
      other.channel == channel &&
      other.trigger == trigger;

  @override
  int get hashCode => Object.hash(agent, integration, channel, trigger);
}

enum SessionFacet { agent, integration, channel, trigger }

/// `GET /orgs/{org}/sessions/facets`: what else the list can be narrowed by,
/// each facet computed with the other active filters applied.
class SessionFacets {
  const SessionFacets({
    this.agents = const [],
    this.agentNames = const {},
    this.integrations = const [],
    this.channels = const [],
    this.triggers = const [],
  });
  final List<String> agents;
  final Map<String, String> agentNames;
  final List<String> integrations;
  final List<ChannelFacet> channels;
  final List<TriggerFacet> triggers;

  factory SessionFacets.fromJson(dynamic j) {
    final m = asMap(j);
    return SessionFacets(
      agents: asList(m['agents']).whereType<String>().toList(),
      agentNames: {
        for (final e in asMap(m['agentNames']).entries)
          if (e.value is String) e.key: e.value as String,
      },
      integrations: asList(m['integrations']).whereType<String>().toList(),
      channels: asList(m['channels'])
          .map(ChannelFacet.fromJson)
          .where((c) => c.value.isNotEmpty)
          .toList(),
      triggers: asList(m['triggers'])
          .map(TriggerFacet.fromJson)
          .where((t) => t.value.isNotEmpty)
          .toList(),
    );
  }
}

class ChannelFacet {
  const ChannelFacet({
    required this.value,
    required this.platform,
    required this.integration,
    this.name,
    this.triggeredByName,
  });
  final String value;
  final String platform;
  final String integration;
  final String? name;
  final String? triggeredByName;
  factory ChannelFacet.fromJson(dynamic j) {
    final m = asMap(j);
    final platform = asStr(m['platform']) ?? 'slack';
    return ChannelFacet(
      value: asStr(m['value']) ?? '',
      platform: platform,
      integration: asStr(m['integration']) ?? platform,
      name: asStr(m['name']),
      triggeredByName: asStr(m['triggeredByName']),
    );
  }
}

class TriggerFacet {
  const TriggerFacet({
    required this.value,
    required this.integration,
    this.name,
    this.hookKind,
    this.githubRepoId,
  });
  final String value;
  final String integration;
  final String? name;
  final String? hookKind;
  final String? githubRepoId;

  /// The value the filter sends: GitHub hooks collapse per repository.
  String get filterValue => hookKind == 'github' && githubRepoId != null
      ? '${SessionFilters.githubRepoPrefix}$githubRepoId'
      : value;

  factory TriggerFacet.fromJson(dynamic j) {
    final m = asMap(j);
    return TriggerFacet(
      value: asStr(m['value']) ?? '',
      integration: asStr(m['integration']) ?? '',
      name: asStr(m['name']),
      hookKind: asStr(m['hookKind']),
      githubRepoId: asStr(m['githubRepoId']),
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
    this.senderName,
    this.ts,
  });
  final String? senderName;
  final DateTime? ts;
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
      senderName: asStr(m['senderName']),
      ts: asDate(m['ts']),
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
