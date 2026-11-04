import 'models.dart';

class ApprovalOption {
  const ApprovalOption(
      {required this.id, required this.name, required this.kind});
  final String id;
  final String name;
  final String kind;
  bool get isAllow => kind == 'allow_once' || kind == 'allow_always';
  bool get isAlways => kind == 'allow_always';
  factory ApprovalOption.fromJson(dynamic j) {
    final m = asMap(j);
    return ApprovalOption(
      id: asStr(m['optionId']) ?? '',
      name: asStr(m['name']) ?? '',
      kind: asStr(m['kind']) ?? '',
    );
  }
}

class Approval {
  Approval({
    required this.id,
    required this.agentId,
    required this.sessionId,
    required this.createdAt,
    required this.requester,
    required this.command,
    required this.status,
    required this.options,
    this.expiresAt,
    this.agentName = '',
    this.conversationTitle,
    this.viaSession = false,
    this.kind,
    this.resolvedAt,
    this.resolvedBy,
  });
  /// `join` for "someone asks to join this conversation"; null for tool calls.
  final String? kind;
  final DateTime? resolvedAt;
  final String? resolvedBy;
  String? platform;
  String? channel;
  bool get isJoin => kind == 'join';
  bool get allowed => status == 'allowed';
  final String id;
  final String agentId;
  final String sessionId;
  final DateTime? createdAt;
  final String requester;
  final String command;
  final String status;
  final List<ApprovalOption> options;
  final DateTime? expiresAt;
  String agentName;
  String? conversationTitle;
  bool viaSession;

  bool get pending => status == 'pending';

  factory Approval.fromJson(dynamic j) {
    final m = asMap(j);
    return Approval(
      id: asStr(m['id']) ?? '',
      agentId: asStr(m['agentId']) ?? '',
      sessionId: asStr(m['sessionId']) ?? '',
      createdAt: asDate(m['createdAt']),
      requester: asStr(m['requesterName']) ?? '',
      command: asStr(m['command']) ?? '',
      status: asStr(m['status']) ?? 'pending',
      options: asList(m['options']).map(ApprovalOption.fromJson).toList(),
      expiresAt: asDate(m['expiresAt']),
      kind: asStr(m['kind']),
      resolvedAt: asDate(m['resolvedAt']),
      resolvedBy: asStr(m['resolvedByName']),
    );
  }
}

/// Keeps the first approval for each id, drops empty ids, newest first.
List<Approval> dedupeApprovals(Iterable<Approval> input) {
  final seen = <String, Approval>{};
  for (final a in input) {
    if (a.id.isEmpty) continue;
    seen.putIfAbsent(a.id, () => a);
  }
  final out = seen.values.toList();
  out.sort((a, b) => (b.createdAt ?? DateTime(1970))
      .compareTo(a.createdAt ?? DateTime(1970)));
  return out;
}
