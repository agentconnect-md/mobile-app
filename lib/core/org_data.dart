import 'dart:async';

import 'package:flutter/foundation.dart';

import 'api/api_client.dart';
import 'api/models.dart';
import 'api/schedules.dart';
import 'streaming/live_updates.dart';

/// Org-wide lists shared by Home, Agents and Infra: agents, machines and the
/// most recent conversations. Refreshed on every live event (debounced) and on
/// every (re)connect of the stream.
class OrgData extends ChangeNotifier {
  OrgData(this.client, this.orgId, this.live) {
    _sub = live?.events.listen((e) {
      _debounce?.cancel();
      _debounce = Timer(const Duration(milliseconds: 800), () => refresh(silent: true));
    });
  }
  final ApiClient client;
  final String orgId;
  final LiveUpdates? live;
  StreamSubscription<LiveEvent>? _sub;
  Timer? _debounce;
  bool _disposed = false;

  List<Agent>? agents;
  List<Machine>? machines;
  List<Conversation>? recent;

  /// Scheduled runs this sign-in can see; null until first read.
  List<Schedule>? schedules;
  Object? schedulesError;

  /// Newest session activity per agent id, from the newest 200 sessions (the
  /// agents API has no such field). Agents missing here had none recently.
  Map<String, DateTime> lastSessionAt = const {};
  bool degraded = false;
  Object? agentsError;
  Object? machinesError;
  Object? recentError;

  /// Machines can't be read with this sign-in (403): Infra shows a note.
  bool machinesForbidden = false;

  Agent? agent(String id) {
    for (final a in agents ?? const <Agent>[]) {
      if (a.id == id) return a;
    }
    return null;
  }

  int get agentsOnline => (agents ?? const []).where((a) => a.health == AgentHealth.online).length;
  /// What Infra lists: the cloud pool as one row, then self-hosted machines.
  List<Machine>? get fleet {
    final m = machines;
    if (m == null) return null;
    final cloud = m.where((x) => x.cloud).toList();
    return [if (cloud.isNotEmpty) Machine.pool(cloud), ...m.where((x) => !x.cloud)];
  }

  int get machinesUp => (fleet ?? const []).where((m) => m.state == AgentHealth.online).length;
  int get runningNow => (recent ?? const [])
      .where((c) => c.state != ActivityState.idle)
      .length;
  List<Machine> get offlineMachines =>
      (machines ?? const []).where((m) => !m.cloud && m.state == AgentHealth.offline).toList();

  Future<void> refresh({bool silent = false}) async {
    await Future.wait([_agents(), _machines(), _recent(), _lastSessions(), refreshSchedules()]);
  }

  Schedule? schedule(String id) {
    for (final s in schedules ?? const <Schedule>[]) {
      if (s.id == id) return s;
    }
    return null;
  }

  Future<void> refreshSchedules() async {
    try {
      schedules = await client.schedules(orgId);
      schedulesError = null;
    } catch (e) {
      schedulesError = e;
    }
    _notify();
  }

  /// Puts a schedule the server just returned (after a change) in the list.
  void putSchedule(Schedule saved) {
    final list = schedules;
    if (list == null) return;
    schedules = [for (final s in list) s.id == saved.id ? saved : s];
    _notify();
  }

  Future<void> _lastSessions() async {
    try {
      final rows = await client.sessionRows(orgId, limit: 200);
      final last = <String, DateTime>{};
      for (final r in rows) {
        final t = r.lastActivityAt;
        if (t == null || r.agentId.isEmpty) continue;
        final seen = last[r.agentId];
        if (seen == null || t.isAfter(seen)) last[r.agentId] = t;
      }
      lastSessionAt = last;
    } catch (_) {
      // The list keeps its previous times; sorting falls back to names.
    }
    _notify();
  }

  Future<void> _agents() async {
    try {
      final a = await client.agents(orgId);
      a.sort((x, y) => x.label.toLowerCase().compareTo(y.label.toLowerCase()));
      agents = a;
      agentsError = null;
    } catch (e) {
      agentsError = e;
    }
    _notify();
  }

  Future<void> _machines() async {
    try {
      final m = await client.machines(orgId);
      m.sort((x, y) {
        if (x.cloud != y.cloud) return x.cloud ? -1 : 1;
        return x.name.toLowerCase().compareTo(y.name.toLowerCase());
      });
      machines = m;
      machinesError = null;
      machinesForbidden = false;
    } on ApiException catch (e) {
      machinesForbidden = e.status == 403;
      machinesError = e;
    } catch (e) {
      machinesError = e;
    }
    _notify();
  }

  Future<void> _recent() async {
    try {
      final page = await client.conversations(orgId, limit: 30, filters: const SessionFilters(showTasks: true));
      recent = page.conversations;
      degraded = page.degraded;
      recentError = null;
    } catch (e) {
      recentError = e;
    }
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _sub?.cancel();
    _debounce?.cancel();
    super.dispose();
  }
}

/// Last agent reply per session, for list previews. Memory only; fetched for
/// rows that are shown, at most once per session per activity time.
class PreviewCache extends ChangeNotifier {
  PreviewCache(this.client, this.orgId);
  final ApiClient client;
  final String orgId;
  final Map<String, String?> _text = {};
  final Map<String, DateTime?> _at = {};
  final Set<String> _inflight = {};
  bool _disposed = false;

  /// Null when unknown (not loaded yet, offline, or no reply).
  String? of(SessionRow s) {
    final have = _at.containsKey(s.sessionId);
    if (!have || _at[s.sessionId] != s.lastActivityAt) _load(s);
    return _text[s.sessionId];
  }

  Future<void> _load(SessionRow s) async {
    if (!_inflight.add(s.sessionId)) return;
    _at[s.sessionId] = s.lastActivityAt;
    try {
      final page = await client.messages(orgId, s.sessionId, limit: 8);
      String? last;
      for (final m in page.messages.reversed) {
        if (m.kind == 'text' && m.sender == s.agentId && m.text.trim().isNotEmpty) {
          last = m.text.trim();
          break;
        }
      }
      last ??= page.messages.reversed
          .where((m) => m.kind == 'text' && m.text.trim().isNotEmpty)
          .map((m) => m.text.trim())
          .firstOrNull;
      _text[s.sessionId] = last?.replaceAll(RegExp(r'\s+'), ' ');
    } catch (_) {
      // 503 (machine offline) or no access: no preview.
    } finally {
      _inflight.remove(s.sessionId);
      if (!_disposed) notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
