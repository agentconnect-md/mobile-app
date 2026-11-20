import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/api/api_client.dart';
import '../../core/auth/app_state.dart';
import '../../l10n/app_localizations.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import '../nav.dart';
import 'approval_card.dart';
import 'assistant_draft_card.dart';
import '../../core/assistant_drafts_controller.dart';
import '../../core/org_data.dart';
import '../../ui/icons.dart';
import '../../ui/adaptive.dart';

/// Every approval waiting for you across agents, and the ones already decided.
class ApprovalsScreen extends StatefulWidget {
  const ApprovalsScreen({super.key});
  @override
  State<ApprovalsScreen> createState() => _ApprovalsScreenState();
}

class _ApprovalsScreenState extends State<ApprovalsScreen> {
  bool _decided = false;

  /// What assistant-mode agents wait on (drafts, suggested tasks and
  /// follow-ups): read while this screen is open.
  AssistantDraftsController? _drafts;
  OrgData? _org;
  Timer? _poll;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final app = AppScope.of(context);
    final account = app.current;
    if (_drafts != null || account == null) return;
    final drafts = AssistantDraftsController(app.client, account.orgId, () => app.orgData?.agents ?? const [])
      ..refresh();
    _drafts = drafts;
    // The agents may load after this screen opens.
    _org = app.orgData?..addListener(drafts.agentsChanged);
    _poll = Timer.periodic(const Duration(seconds: 45), (_) => drafts.refresh());
  }

  @override
  void dispose() {
    _poll?.cancel();
    final drafts = _drafts;
    if (drafts != null) {
      _org?.removeListener(drafts.agentsChanged);
      drafts.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final p = context.pal;
    final app = AppScope.of(context);
    final c = app.approvals;
    final drafts = _drafts;
    return Scaffold(
      appBar: AppBar(title: Text(l.approvalsTitle)),
      body: c == null
          ? const SizedBox()
          : ListenableBuilder(
              listenable: drafts == null ? c : Listenable.merge([c, drafts]),
              builder: (context, _) {
                final list = _decided ? c.decided : c.pending;
                Widget body;
                if (c.loading && c.approvals.isEmpty && !_decided) {
                  body = const Padding(
                      padding: EdgeInsets.all(40), child: Center(child: Spinner()));
                } else if (c.error != null && c.approvals.isEmpty && !_decided) {
                  body = StateView(
                    icon: AppIcons.cloudOff,
                    title: l.inboxErrorTitle,
                    body: c.error is NetworkException ? l.errNetwork : l.pullToRetry,
                    actionLabel: l.tryAgain,
                    onAction: c.refresh,
                  );
                } else if (list.isEmpty && !_decided && (drafts?.rows.isNotEmpty ?? false)) {
                  // Nothing from running sessions, but assistants wait below.
                  body = const SizedBox.shrink();
                } else if (list.isEmpty) {
                  body = StateView(
                    icon: _decided ? AppIcons.history : AppIcons.checkCircleOutline,
                    title: _decided ? l.decidedEmptyTitle : l.pendingEmptyTitle,
                    body: _decided ? l.decidedEmptyBody : l.pendingEmptyBody,
                  );
                } else {
                  body = Column(children: [
                    for (final a in list)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: ApprovalCard(
                          key: ValueKey('${_decided ? 'd' : 'p'}${a.id}'),
                          approval: a,
                          controller: c,
                          decided: _decided,
                          onOpenSession: () => openSession(context, sessionOfApproval(a)),
                        ),
                      ),
                  ]);
                }
                return RefreshIndicator.adaptive(
                  onRefresh: () => Future.wait([c.refresh(), ?drafts?.refresh()]),
                  child: ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: readablePadding(context, const EdgeInsets.fromLTRB(16, 14, 16, 24)),
                    children: [
                      Segmented<bool>(
                        items: [
                          (false, l.pendingCount(c.pendingCount + (drafts?.waitingCount ?? 0))),
                          (true, l.decidedTab),
                        ],
                        value: _decided,
                        onChanged: (v) => setState(() => _decided = v),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(2, 12, 2, 12),
                        child: Text(l.approvalsIntro,
                            style: TextStyle(fontSize: 13, color: p.secondary, height: 1.4)),
                      ),
                      body,
                      if (!_decided && drafts != null)
                        AssistantDraftsSection(controller: drafts, agentOf: (id) => app.orgData?.agent(id)),
                    ],
                  ),
                );
              },
            ),
    );
  }
}
