import 'package:flutter/foundation.dart';

import 'api/api_client.dart';
import 'api/assistant_drafts.dart';
import 'api/models.dart';

/// How a decision made here ended.
class DraftResult {
  const DraftResult.outcome(DraftOutcome this.outcome) : refusal = null;

  /// `expired`, `decided` (by someone else), `gone` (no longer waiting) or
  /// `unconfirmed` (sent, but the answer was lost).
  const DraftResult.refused(String this.refusal) : outcome = null;
  final DraftOutcome? outcome;
  final String? refusal;

  bool get unconfirmed => refusal == 'unconfirmed';
}

class DraftCardState {
  bool sending = false;
  DraftResult? result;

  /// Why the last try decided nothing: busy, upgrade, offline, readOnly or failed.
  String? notice;
}

/// The messages and proposals assistant-mode agents wait on a person for,
/// across the org's agents this account may edit. Read over REST per agent
/// (at most 50 each, soonest to lapse first); nothing is cached to disk.
class AssistantDraftsController extends ChangeNotifier {
  AssistantDraftsController(this.client, this.orgId, this.agents);
  final ApiClient client;
  final String orgId;

  /// The org's agents as known now.
  final List<Agent> Function() agents;

  /// What the servers list as waiting.
  List<AssistantDraft> drafts = [];
  final Map<String, DraftCardState> _states = {};

  /// Decided here: kept until dismissed, so the outcome stays readable.
  final Map<String, AssistantDraft> _decided = {};
  bool truncated = false;
  bool loading = false;
  bool _disposed = false;
  Set<String> _asked = const {};

  DraftCardState stateOf(AssistantDraft d) => _states.putIfAbsent(d.key, DraftCardState.new);

  bool isWaiting(AssistantDraft d) => drafts.any((x) => x.key == d.key);

  /// The buttons show: undecided, or a try that decided nothing.
  bool canDecide(AssistantDraft d) {
    final r = _states[d.key]?.result;
    return r == null || (r.unconfirmed && isWaiting(d));
  }

  /// Messages first, then proposals; what was decided here stays in place.
  List<AssistantDraft> get rows {
    final listed = {for (final d in drafts) d.key};
    final all = [...drafts, ..._decided.values.where((d) => !listed.contains(d.key))];
    int rank(AssistantDraft d) => d.kind == 'task' ? 1 : 0;
    final far = DateTime(9999);
    all.sort((a, b) {
      final r = rank(a).compareTo(rank(b));
      return r != 0 ? r : (a.expiresAt ?? far).compareTo(b.expiresAt ?? far);
    });
    return all;
  }

  /// How many still wait for a decision.
  int get waitingCount => drafts.where(canDecide).length;

  Iterable<Agent> get _assistants => agents().where((a) => a.assistant);

  /// Asks again when the set of assistant-mode agents changed (they load after the screen).
  void agentsChanged() {
    final now = {for (final a in _assistants) a.id};
    if (!setEquals(now, _asked)) refresh();
  }

  Future<void> refresh() async {
    final list = _assistants.toList();
    _asked = {for (final a in list) a.id};
    loading = true;
    final found = <AssistantDraft>[];
    var cut = false;
    var failed = false;
    await Future.wait([
      for (final a in list)
        () async {
          try {
            final page = await client.assistantDrafts(orgId, a.id);
            for (final d in page.drafts) {
              d
                ..agentId = a.id
                ..agentName = a.label;
              found.add(d);
            }
            cut = cut || page.truncated;
          } on ApiException {
            // Not an editor (403), mode off or an older daemon (409), offline (503): nothing to decide there.
          } catch (_) {
            failed = true;
          }
        }(),
    ]);
    if (_disposed) return;
    loading = false;
    // A network failure keeps what was listed rather than emptying the screen.
    if (!(failed && found.isEmpty && drafts.isNotEmpty)) {
      drafts = found;
      truncated = cut;
    }
    notifyListeners();
  }

  Future<void> decide(AssistantDraft d, {required bool approve}) async {
    final st = stateOf(d);
    if (st.sending) return;
    st.sending = true;
    st.notice = null;
    notifyListeners();
    void settle(DraftResult r) {
      st.result = r;
      _decided[d.key] = d;
    }

    try {
      settle(DraftResult.outcome(await client.decideAssistantDraft(orgId, d.agentId, d.id, approve: approve)));
    } on ApiException catch (e) {
      switch (e.code) {
        case 'DRAFT_EXPIRED':
          settle(const DraftResult.refused('expired'));
        case 'DRAFT_ALREADY_DECIDED':
          settle(const DraftResult.refused('decided'));
        case 'SUBSESSION_LIMIT':
          st.notice = 'busy';
        case 'DECISION_UNCONFIRMED':
          // Sent, but not confirmed: the list says whether it still waits.
          settle(const DraftResult.refused('unconfirmed'));
          await refresh();
        case 'DAEMON_FEATURE_MISSING':
          st.notice = 'upgrade';
        default:
          if (e.status == 404) {
            settle(const DraftResult.refused('gone'));
          } else {
            st.notice = e.readOnlyGrant
                ? 'readOnly'
                : e.status == 503
                    ? 'offline'
                    : 'failed';
          }
      }
    } catch (_) {
      st.notice = 'failed';
    }
    if (_disposed) return;
    st.sending = false;
    notifyListeners();
  }

  /// Takes a decided row off the screen.
  void dismiss(AssistantDraft d) {
    _decided.remove(d.key);
    if (!isWaiting(d)) _states.remove(d.key);
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
