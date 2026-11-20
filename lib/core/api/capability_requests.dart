import 'dart:convert';

import 'models.dart';

/// How a capability request ends (`capability_request_resolved`).
const capabilitySettledStatuses = {'completed', 'declined', 'expired', 'withdrawn'};

/// A capability request as the conversation carries it (`capability_request`
/// event, and the body of a saved `capability` row): enough to show the card
/// before the request itself is read.
class CapabilityCard {
  const CapabilityCard({
    required this.requestId,
    this.generation = 1,
    this.summary = '',
    this.reason = '',
    this.link = '',
  });
  final String requestId;

  /// Goes up each time a declined request is reopened.
  final int generation;
  final String summary;

  /// The agent's own words: untrusted, shown as plain text.
  final String reason;

  /// The request's page in the web console, as the server names it.
  final String link;

  static CapabilityCard? fromJson(Map<String, dynamic> m) {
    final id = asStr(m['requestId']);
    if (id == null || id.isEmpty) return null;
    final g = m['generation'];
    return CapabilityCard(
      requestId: id,
      generation: g is num ? g.toInt() : 1,
      summary: asStr(m['summary']) ?? '',
      reason: asStr(m['reason']) ?? '',
      link: asStr(m['link']) ?? '',
    );
  }

  /// A saved `capability` row's body: the card, and how it ended (`status`
  /// is `open` until then). Null for anything without a request id.
  static ({CapabilityCard card, String? status, String text})? fromBody(String? body) {
    if (body == null || body.isEmpty) return null;
    final Map<String, dynamic> m;
    try {
      m = asMap(jsonDecode(body));
    } catch (_) {
      return null;
    }
    final card = fromJson(m);
    if (card == null) return null;
    final status = asStr(m['status']);
    return (
      card: card,
      status: capabilitySettledStatuses.contains(status) ? status : null,
      text: asStr(m['text']) ?? '',
    );
  }
}

/// The request itself (`CapabilityRequestDto`): where it stands, and what the
/// signed-in person may do about it.
class CapabilityRequest {
  const CapabilityRequest({
    required this.id,
    required this.status,
    this.agentName = '',
    this.summary = '',
    this.reason = '',
    this.generation = 1,
    this.expiresAt,
    this.settledBy,
    this.outcome,
    this.note,
    this.canComplete = false,
    this.canDecline = false,
    this.missing,
    this.whoCan = const [],
  });
  final String id;
  final String agentName;
  final String summary;
  final String reason;

  /// open, completed, declined, expired or withdrawn.
  final String status;
  final int generation;
  final DateTime? expiresAt;

  /// Who completed or declined it.
  final String? settledBy;

  /// What changed, once completed.
  final String? outcome;

  /// The decider's note on a decline.
  final String? note;

  /// The viewer may make the change (in the web console).
  final bool canComplete;
  final bool canDecline;

  /// Why the viewer can't complete it, in the server's words.
  final String? missing;

  /// Names of the people who can complete it.
  final List<String> whoCan;

  bool get open => status == 'open';

  static CapabilityRequest? fromJson(dynamic j) {
    final m = asMap(j);
    final id = asStr(m['id']);
    final status = asStr(m['status']);
    if (id == null || id.isEmpty || status == null) return null;
    final viewer = asMap(m['viewer']);
    final g = m['generation'];
    return CapabilityRequest(
      id: id,
      status: status,
      agentName: asStr(m['agentName']) ?? '',
      summary: asStr(m['summary']) ?? '',
      reason: asStr(m['reason']) ?? '',
      generation: g is num ? g.toInt() : 1,
      expiresAt: asDate(m['expiresAt']),
      settledBy: asStr(asMap(m['settledBy'])['name']),
      outcome: asStr(m['outcome']),
      note: asStr(m['note']),
      canComplete: viewer['canComplete'] == true,
      canDecline: viewer['canDecline'] == true,
      missing: asStr(viewer['missing']),
      whoCan: [
        for (final p in asList(viewer['whoCan']))
          if (asStr(asMap(p)['name']) case final n? when n.isNotEmpty) n,
      ],
    );
  }
}
