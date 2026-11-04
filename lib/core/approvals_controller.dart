import 'dart:async';

import 'package:flutter/foundation.dart';

import 'api/api_client.dart';
import 'api/approvals.dart';
import 'api/models.dart';
import 'streaming/live_updates.dart';

enum CardPhase { idle, sending, done }

class CardState {
  CardPhase phase = CardPhase.idle;
  String? resultKind; // allow_once, allow_always, reject, expired
  String? notice; // 'answered' | 'offline' | 'expired' | 'error'
}

/// Loads pending approvals for the org and keeps them fresh from the live stream.
class ApprovalsController extends ChangeNotifier {
  ApprovalsController(this.client, this.orgId, this.live) {
    _sub = live?.events.listen((e) {
      _debounce?.cancel();
      _debounce = Timer(const Duration(milliseconds: 500), () => refresh(silent: true));
    });
    _poll = Timer.periodic(const Duration(seconds: 45), (_) => refresh(silent: true));
  }
  final ApiClient client;
  final String orgId;
  final LiveUpdates? live;
  StreamSubscription<LiveEvent>? _sub;
  Timer? _debounce;
  Timer? _poll;
  bool _disposed = false;

  List<Approval> approvals = [];

  /// Answered or expired requests the servers still report, newest first.
  List<Approval> decidedFromServer = [];

  /// Hidden from the Home preview with its close button (still in Approvals).
  final Set<String> dismissedOnHome = {};
  final Map<String, CardState> states = {};
  bool loading = true;
  Object? error;
  bool forbiddenOnly = false;

  List<Approval> get pending =>
      approvals.where((a) => a.pending && states[a.id]?.phase != CardPhase.done).toList();

  int get pendingCount => pending.length;

  /// Decided here (this run) first, then what the servers report.
  List<Approval> get decided {
    final local = approvals.where((a) => states[a.id]?.phase == CardPhase.done).toList();
    final ids = local.map((a) => a.id).toSet();
    return [...local, ...decidedFromServer.where((a) => !ids.contains(a.id))];
  }

  List<Approval> forSession(String sessionId) =>
      pending.where((a) => a.sessionId == sessionId).toList();

  CardState stateOf(String id) => states.putIfAbsent(id, CardState.new);

  Future<void> refresh({bool silent = false}) async {
    if (!silent) {
      loading = true;
      error = null;
      notifyListeners();
    }
    try {
      final sessions = await client.awaitingSessions(orgId);
      final agentIds = <String>{};
      final webchatSessions = <String, SessionRow>{};
      final titles = <String, SessionRow>{};
      for (final s in sessions) {
        titles[s.sessionId] = s;
        if (s.isWebchat) {
          webchatSessions[s.sessionId] = s;
        } else if (s.agentId.isNotEmpty) {
          agentIds.add(s.agentId);
        }
      }
      final found = <Approval>[];
      var anyOk = sessions.isEmpty;
      Object? firstError;
      final futures = <Future<void>>[];
      for (final id in agentIds) {
        futures.add(() async {
          try {
            found.addAll(await client.agentApprovals(orgId, id));
            anyOk = true;
          } on ApiException catch (e) {
            if (e.status == 403 || e.status >= 500) {
              // hide silently, retry on the next refresh
              anyOk = true;
            } else {
              firstError ??= e;
            }
          } catch (e) {
            firstError ??= e;
          }
        }());
      }
      for (final id in webchatSessions.keys) {
        futures.add(() async {
          try {
            found.addAll(await client.sessionApprovals(orgId, id));
            anyOk = true;
          } on ApiException catch (e) {
            if (e.status == 403 || e.status == 409 || e.status >= 500) {
              anyOk = true;
            } else {
              firstError ??= e;
            }
          } catch (e) {
            firstError ??= e;
          }
        }());
      }
      await Future.wait(futures);
      if (_disposed) return;
      if (!anyOk && firstError != null) throw firstError!;
      final agentNames = {for (final s in sessions) s.agentId: s.agentName};
      final live = dedupeApprovals(found.where((a) => a.pending));
      final done = dedupeApprovals(found.where((a) => !a.pending))
        ..sort((a, b) => (b.resolvedAt ?? b.createdAt ?? DateTime(1970))
            .compareTo(a.resolvedAt ?? a.createdAt ?? DateTime(1970)));
      // Keep cards that were just answered so the result stays visible.
      final keep = approvals.where((a) {
        final st = states[a.id];
        return st != null && st.phase == CardPhase.done && !live.any((n) => n.id == a.id);
      });
      for (final a in [...live, ...done]) {
        final s = titles[a.sessionId];
        a.agentName = agentNames[a.agentId] ?? s?.agentName ?? a.requester;
        a.conversationTitle = s?.title;
        a.platform = s?.platform;
        a.channel = s?.channelName;
      }
      approvals = [...live, ...keep];
      decidedFromServer = done;
      error = null;
      loading = false;
      notifyListeners();
    } catch (e) {
      if (_disposed) return;
      if (silent && approvals.isNotEmpty) return;
      error = e;
      loading = false;
      notifyListeners();
    }
  }

  /// Sends a decision. Returns false when the call needs the UI to react (no).
  Future<void> decide(Approval a, ApprovalOption o) async {
    final st = stateOf(a.id);
    st.phase = CardPhase.sending;
    st.notice = null;
    notifyListeners();
    try {
      await client.decide(orgId, a, o);
      st.phase = CardPhase.done;
      st.resultKind = o.isAlways
          ? 'allow_always'
          : o.isAllow
              ? 'allow_once'
              : 'reject';
    } on ApiException catch (e) {
      if (e.status == 409) {
        st.phase = CardPhase.idle;
        st.notice = 'answered';
        await refresh(silent: true);
      } else if (e.status == 503) {
        st.phase = CardPhase.idle;
        st.notice = 'offline';
      } else if (e.readOnlyGrant) {
        st.phase = CardPhase.idle;
        st.notice = 'readOnly';
      } else if (e.status == 404 || e.status == 410) {
        st.phase = CardPhase.done;
        st.resultKind = 'expired';
      } else {
        st.phase = CardPhase.idle;
        st.notice = 'error';
      }
    } catch (_) {
      st.phase = CardPhase.idle;
      st.notice = 'error';
    }
    notifyListeners();
  }

  void dismiss(String id) {
    approvals = approvals.where((a) => a.id != id).toList();
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _sub?.cancel();
    _debounce?.cancel();
    _poll?.cancel();
    super.dispose();
  }
}
