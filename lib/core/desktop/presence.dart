import 'dart:async';
import 'dart:convert';
import 'dart:ui' show Locale, PlatformDispatcher;

import '../../l10n/app_localizations.dart';
import '../approvals_controller.dart';
import '../auth/native.dart';
import '../org_data.dart';
import 'attention.dart';

/// The Mac app outside its window: keeps the menu bar item current and posts
/// a notification when something starts needing the person. It listens to
/// the same [OrgData] and [ApprovalsController] the screens use (no requests
/// of its own) and goes on while the window is closed.
class DesktopPresence {
  DesktopPresence({required this.alertsOn});

  /// The person's choice (Settings > Notifications): nothing is posted while off.
  final bool Function() alertsOn;

  OrgData? _org;
  ApprovalsController? _approvals;
  String? _orgName;
  String? _userId;

  /// Sessions the person sent a message in from this app, this run.
  final Set<String> _touched = {};
  final _watcher = AttentionWatcher();
  Timer? _due;
  String? _pushed;

  /// Session ids of the conversation open in the window; while the window is
  /// in front nothing is announced for it. Set by the desktop shell.
  Set<String> get reading => _reading;
  Set<String> _reading = const {};
  set reading(Set<String> ids) {
    _reading = ids;
    // What was announced about it has been seen now.
    if (ids.isNotEmpty) Native.clearNotifications([for (final id in ids) 'conv:$id']);
  }

  /// The person sent a message in [sessionId] from this app: that
  /// conversation is theirs for "finished" notifications.
  void noteSent(String? sessionId) {
    if (sessionId != null && sessionId.isNotEmpty) _touched.add(sessionId);
  }

  /// Follows [org] and [approvals] of the organization [orgName], signed in
  /// as [userId]; all null when nobody is signed in.
  void attach(OrgData? org, ApprovalsController? approvals, {String? orgName, String? userId}) {
    _org?.removeListener(_changed);
    _approvals?.removeListener(_changed);
    _org = org;
    _approvals = approvals;
    _orgName = orgName;
    _userId = userId;
    _touched.clear();
    _watcher.reset();
    _org?.addListener(_changed);
    _approvals?.addListener(_changed);
    _changed();
  }

  /// Debug builds: draws the menu bar item from [sample] instead of the live
  /// lists (to look at a state that isn't there right now); null goes back
  /// to the live state.
  void debugShow(AttentionState? sample) {
    _pushed = null;
    _sampleShown = sample != null;
    if (sample == null) return _changed();
    Native.setStatusItem(menuBarSnapshot(sample, org: _orgName, text: menuBarText(_strings())));
  }

  bool _sampleShown = false;

  static AppLocalizations _strings() {
    try {
      return lookupAppLocalizations(PlatformDispatcher.instance.locale);
    } catch (_) {
      return lookupAppLocalizations(const Locale('en'));
    }
  }

  void _changed() {
    final l = _strings();
    final org = _org;
    final state =
        org == null ? null : AttentionState.of(org, _approvals, userId: _userId, touched: _touched);
    final snapshot = menuBarSnapshot(state, org: _orgName, text: menuBarText(l));
    // The lists notify far more often than what the menu shows changes.
    final encoded = jsonEncode(snapshot);
    if (encoded != _pushed && !_sampleShown) {
      _pushed = encoded;
      Native.setStatusItem(snapshot);
    }
    if (state == null) return;
    final notices = _watcher.advance(
      state,
      now: DateTime.now(),
      reading: Native.windowFront.value ? _reading : const {},
    );
    if (alertsOn()) {
      for (final n in notices) {
        _post(l, n);
      }
    }
    // A "waiting" held back for its approval request comes due without any
    // list changing: look again then.
    _due?.cancel();
    final due = _watcher.nextDue;
    if (due != null) {
      final wait = due.difference(DateTime.now());
      _due = Timer(wait.isNegative ? Duration.zero : wait + const Duration(milliseconds: 50), _changed);
    }
  }

  void _post(AppLocalizations l, Notice n) {
    final (title, body) = noticeText(l, n);
    Native.notify(
      id: n.id,
      title: title,
      body: body,
      target: n.sessionId != null ? OpenTarget('conversation', n.sessionId!) : OpenTarget('agent', n.agentId ?? ''),
      group: n.id,
    );
  }

  void dispose() {
    _due?.cancel();
    _org?.removeListener(_changed);
    _approvals?.removeListener(_changed);
  }
}

/// Title and body of a notification. They name the agent and the
/// conversation's title; never message text or what an agent asked to run.
(String, String) noticeText(AppLocalizations l, Notice n) {
  final agent = n.agentName.isEmpty ? l.appName : n.agentName;
  final conversation = n.title == null || n.title!.trim().isEmpty ? l.untitled : n.title!.trim();
  return switch (n.kind) {
    NoticeKind.waiting => (l.noticeWaitingTitle(agent), conversation),
    NoticeKind.approval => (l.noticeApprovalTitle(agent), conversation),
    NoticeKind.finished => (l.noticeFinishedTitle(agent), conversation),
    NoticeKind.agentOffline => (l.noticeOfflineTitle(agent), l.noticeOfflineBody),
  };
}

MenuBarText menuBarText(AppLocalizations l) => MenuBarText(
      appName: l.appName,
      signedOut: l.menuBarSignedOut,
      allQuiet: l.menuBarAllQuiet,
      needYou: l.menuBarNeedYou,
      running: l.menuBarRunning,
      needsTitle: l.menuBarNeedsTitle,
      needsEmpty: l.menuBarNeedsEmpty,
      needsMore: l.menuBarNeedsMore,
      approvalRow: l.menuBarApprovalRow,
      waitingRow: l.menuBarWaitingRow,
      untitled: l.untitled,
      agentsTitle: l.tabAgents,
      agentsEmpty: l.noAgentsTitle,
      agentsMore: l.menuBarAgentsMore,
      online: l.online,
      paused: l.paused,
      offline: l.offline,
      working: l.menuBarWorking,
      open: l.menuBarOpen,
      quit: l.menuBarQuit,
    );
