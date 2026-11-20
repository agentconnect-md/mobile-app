import 'models.dart';

/// A scheduled run (the server's "cron"): on every tick of [expression], read
/// in [timezone], the agent is prompted with [prompt]. `GET /orgs/{org}/crons`.
class Schedule {
  const Schedule({
    required this.id,
    this.agentId,
    this.name,
    required this.expression,
    this.timezone = 'UTC',
    this.targetPlatform = '',
    this.targetChannel,
    this.targetIntegrationId,
    this.prompt = '',
    this.enabled = false,
    this.lastRunAt,
    this.createdBy,
    this.createdAt,
    this.lastModifiedBy,
    this.lastModifiedAt,
    this.visibility = 'org',
    this.sharedWith = const [],
    this.canEdit = false,
  });

  final String id;

  /// Null when the agent was deleted: the schedule never fires until it is
  /// given another agent (in the console).
  final String? agentId;

  /// Display name; null for schedules made outside the console.
  final String? name;

  /// The cron expression (`schedule` on the wire), never converted.
  final String expression;

  /// IANA zone the expression is read in.
  final String timezone;
  final String targetPlatform;

  /// Where the run posts; null = nowhere (the output stays in its session).
  final String? targetChannel;
  final String? targetIntegrationId;

  /// What the agent is asked on each run (`trigger` on the wire). Shown only;
  /// never logged or stored.
  final String prompt;
  final bool enabled;
  final DateTime? lastRunAt;

  /// User ids; null for schedules made by an agent or the CLI.
  final String? createdBy;
  final DateTime? createdAt;
  final String? lastModifiedBy;
  final DateTime? lastModifiedAt;

  /// `org` (every member) or `restricted` ([sharedWith] and the owners).
  final String visibility;
  final List<String> sharedWith;

  /// The server's answer to "may this member change or run it".
  final bool canEdit;

  bool get restricted => visibility == 'restricted';

  /// The whole `PUT /crons/{id}` body for this schedule with [enabled]
  /// changed (the route replaces the definition, so every field is sent
  /// back as it came). Null without an agent: the server requires one.
  Map<String, Object>? updateBody({required bool enabled}) {
    final agent = agentId;
    if (agent == null) return null;
    return {
      'agentId': agent,
      if (name != null && name!.isNotEmpty) 'name': name!,
      'schedule': expression,
      'timezone': timezone,
      'targetPlatform': targetPlatform,
      if (targetChannel != null && targetChannel!.isNotEmpty) 'targetChannel': targetChannel!,
      if (targetIntegrationId != null && targetIntegrationId!.isNotEmpty) 'targetIntegrationId': targetIntegrationId!,
      'trigger': prompt,
      'enabled': enabled,
    };
  }

  /// Null for a row without an id or an expression.
  static Schedule? fromJson(dynamic j) {
    final m = asMap(j);
    final id = asStr(m['id']);
    final expression = asStr(m['schedule']);
    if (id == null || id.isEmpty || expression == null) return null;
    final zone = asStr(m['timezone']);
    return Schedule(
      id: id,
      agentId: asStr(m['agentId']),
      name: asStr(m['name']),
      expression: expression,
      timezone: zone == null || zone.isEmpty ? 'UTC' : zone,
      targetPlatform: asStr(m['targetPlatform']) ?? '',
      targetChannel: asStr(m['targetChannel']),
      targetIntegrationId: asStr(m['targetIntegrationId']),
      prompt: asStr(m['trigger']) ?? '',
      enabled: m['enabled'] == true,
      lastRunAt: asDate(m['lastRunAt']),
      createdBy: asStr(m['createdBy']),
      createdAt: asDate(m['createdAt']),
      lastModifiedBy: asStr(m['lastModifiedBy']),
      lastModifiedAt: asDate(m['lastModifiedAt']),
      visibility: asStr(m['visibility']) ?? 'org',
      sharedWith: asList(m['sharedWith']).whereType<String>().toList(),
      canEdit: m['canEdit'] == true,
    );
  }

  static List<Schedule> listFromJson(dynamic j) => asList(j).map(fromJson).whereType<Schedule>().toList();
}

enum ScheduleRunStatus { running, success, failed }

/// One run a daemon reported (`GET /orgs/{org}/crons/{id}/runs`, newest first).
class ScheduleRun {
  const ScheduleRun({
    required this.id,
    required this.status,
    this.startedAt,
    this.durationMs,
    this.sessionId,
    this.reason,
  });

  final String id;
  final ScheduleRunStatus status;
  final DateTime? startedAt;
  final int? durationMs;

  /// The session the run prompted; null when it made none.
  final String? sessionId;

  /// Short failure text.
  final String? reason;

  static ScheduleRun? fromJson(dynamic j) {
    final m = asMap(j);
    final id = asStr(m['id']);
    if (id == null || id.isEmpty) return null;
    final ms = m['durationMs'];
    final session = asStr(m['sessionId']);
    final reason = asStr(m['reason']);
    return ScheduleRun(
      id: id,
      // An unknown status (a newer server) reads as still running: nothing is claimed about its outcome.
      status: ScheduleRunStatus.values.asNameMap()[asStr(m['status'])] ?? ScheduleRunStatus.running,
      startedAt: asDate(m['startedAt']),
      durationMs: ms is num ? ms.round() : null,
      sessionId: session == null || session.isEmpty ? null : session,
      reason: reason == null || reason.trim().isEmpty ? null : reason.trim(),
    );
  }

  static List<ScheduleRun> listFromJson(dynamic j) => asList(j).map(fromJson).whereType<ScheduleRun>().toList();
}

/// Channel names of the org's integrations by channel id, for a schedule's
/// "Post to" (`GET /orgs/{org}/integrations`: `[{id, agentId, channels[{channelId, name}]}]`).
/// Limited to [integrationId] when the schedule names one, else to [agentId]'s.
String? integrationChannelName(dynamic j, String channelId, {String? integrationId, String? agentId}) {
  for (final i in asList(j)) {
    final m = asMap(i);
    if (integrationId != null ? asStr(m['id']) != integrationId : asStr(m['agentId']) != agentId) continue;
    for (final c in asList(m['channels'])) {
      final ch = asMap(c);
      if (asStr(ch['channelId']) != channelId) continue;
      final name = asStr(ch['name'])?.trim();
      if (name != null && name.isNotEmpty) return name;
    }
  }
  return null;
}
