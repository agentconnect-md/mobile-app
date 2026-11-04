import 'package:flutter/material.dart';

import '../../core/api/approvals.dart';
import '../../core/api/models.dart';
import '../../core/auth/app_state.dart';
import '../../l10n/app_localizations.dart';
import '../../ui/format.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import '../../core/approvals_controller.dart';

/// One approval request: who asks, what (secret-masked by the server), where,
/// and the options the server offers (labels shown as given).
class ApprovalCard extends StatelessWidget {
  const ApprovalCard({
    super.key,
    required this.approval,
    required this.controller,
    this.onOpenSession,
    this.onDismiss,
    this.decided = false,
  });
  final Approval approval;
  final ApprovalsController controller;

  /// Opens the conversation (null inside that conversation).
  final VoidCallback? onOpenSession;

  /// Close button (Home preview only).
  final VoidCallback? onDismiss;

  /// A request from the Decided list (no buttons).
  final bool decided;

  Future<void> _choose(BuildContext context, ApprovalOption o) async {
    final l = AppLocalizations.of(context);
    final app = AppScope.read(context);
    final a = approval;
    if (o.isAlways) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: Text(l.alwaysAllowTitle),
          content: Text(l.alwaysAllowBody(a.agentName)),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: Text(l.cancel)),
            TextButton(onPressed: () => Navigator.pop(c, true), child: Text(l.alwaysAllow)),
          ],
        ),
      );
      if (ok != true) return;
      // Face ID / passcode before "always allow" only.
      if (!await app.biometrics.confirm(l.biometricReason)) return;
    }
    await controller.decide(a, o);
  }

  /// Reject options first, then "always", then "once" (the design's order).
  List<ApprovalOption> _ordered() {
    int rank(ApprovalOption o) => switch (o.kind) {
          'reject_once' || 'reject_always' => 0,
          'allow_always' => 1,
          'allow_once' => 2,
          _ => 1,
        };
    final l = [...approval.options];
    l.sort((a, b) => rank(a).compareTo(rank(b)));
    return l;
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => _card(context),
    );
  }

  Widget _card(BuildContext context) {
    final l = AppLocalizations.of(context);
    final p = context.pal;
    final a = approval;
    final st = controller.stateOf(a.id);
    final sending = st.phase == CardPhase.sending;
    final localDone = st.phase == CardPhase.done;
    final exp = a.expiresAt;
    final expired = exp != null && exp.isBefore(DateTime.now());

    String? result;
    if (localDone) {
      result = switch (st.resultKind) {
        'allow_once' => l.allowedOnce,
        'allow_always' => l.alwaysAllowed,
        'expired' => l.approvalExpired,
        _ => l.denied,
      };
    } else if (decided || !a.pending) {
      result = switch (a.status) {
        'allowed' => l.allowed,
        'denied' => l.denied,
        'expired' => l.expired,
        _ => a.status,
      };
      if (a.resolvedBy != null && a.resolvedBy!.isNotEmpty && a.status != 'expired') {
        result = l.decidedBy(result, a.resolvedBy!);
      }
    }
    final positive = localDone
        ? st.resultKind == 'allow_once' || st.resultKind == 'allow_always'
        : a.status == 'allowed';
    final notice = switch (st.notice) {
      'answered' => l.alreadyAnswered,
      'offline' => l.agentOffline(a.agentName),
      'error' => l.genericError,
      'readOnly' => l.readOnlyGrant,
      _ => null,
    };
    final agent = AppScope.of(context).orgData?.agent(a.agentId);
    final source = sourceOf(a.platform ?? '');
    final where = [
      if (a.channel != null && a.channel!.isNotEmpty) a.channel!,
      if (a.conversationTitle != null && a.conversationTitle!.isNotEmpty) a.conversationTitle!,
    ].join(' · ');

    return AppCard(
      leftBar: p.paused,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          AgentAvatar(
              iconUrl: agent?.iconUrl,
              runtime: agent?.runtime,
              name: a.agentName,
              size: 18,
              showDot: false),
          const SizedBox(width: 8),
          Flexible(
            child: Text(a.agentName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
          ),
          const SizedBox(width: 6),
          Text(l.ago(relativeTime(a.createdAt)), style: mono(context, size: 12)),
          const Spacer(),
          if (a.isJoin) Pill(l.joinPill, fg: p.info, bg: p.infoSoft),
          if (onDismiss != null)
            Semantics(
              label: l.hide,
              button: true,
              child: InkResponse(
                onTap: onDismiss,
                radius: 20,
                child: Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: Icon(Icons.close, size: 18, color: p.tertiary),
                ),
              ),
            ),
        ]),
        const SizedBox(height: 10),
        if (a.isJoin) ...[
          Text(l.joinTitle(a.requester.isEmpty ? l.someone : a.requester),
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500)),
          const SizedBox(height: 8),
        ],
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(color: p.sunken, borderRadius: BorderRadius.circular(6)),
          child: Text(a.command,
              maxLines: 6,
              overflow: TextOverflow.ellipsis,
              style: mono(context, size: 13, color: p.ink)),
        ),
        if (where.isNotEmpty || onOpenSession != null) ...[
          const SizedBox(height: 6),
          InkWell(
            onTap: onOpenSession,
            borderRadius: BorderRadius.circular(6),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 32),
              child: Row(children: [
                SourceGlyph(source, size: 11),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(where.isEmpty ? l.openConversation : where,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: mono(context, size: 12, color: p.secondary)),
                ),
                if (onOpenSession != null) Icon(Icons.chevron_right, size: 16, color: p.tertiary),
              ]),
            ),
          ),
        ],
        if (notice != null) ...[
          const SizedBox(height: 6),
          Semantics(
              liveRegion: true,
              child: Text(notice, style: TextStyle(color: p.paused, fontSize: 13))),
        ],
        const SizedBox(height: 8),
        if (result != null)
          Semantics(
            liveRegion: true,
            child: Row(children: [
              Icon(positive ? Icons.check_circle_outline : Icons.block,
                  size: 16, color: positive ? p.online : p.secondary),
              const SizedBox(width: 6),
              Expanded(
                child: Text(result,
                    style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        color: positive ? p.online : p.secondary)),
              ),
            ]),
          )
        else if (expired)
          Text(l.approvalExpired, style: TextStyle(color: p.secondary, fontSize: 14))
        else if (sending)
          Row(children: [
            const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
            const SizedBox(width: 8),
            Text(l.sent, style: TextStyle(color: p.secondary)),
          ])
        else
          _buttons(context, p),
      ]),
    );
  }

  Widget _buttons(BuildContext context, Palette p) {
    final opts = _ordered();
    Widget button(ApprovalOption o) {
      final label = Text(o.name, maxLines: 1, overflow: TextOverflow.ellipsis);
      if (o.kind == 'allow_once') {
        return FilledButton(
          style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 8)),
          onPressed: () => _choose(context, o),
          child: label,
        );
      }
      return OutlinedButton(
        style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 8)),
        onPressed: () => _choose(context, o),
        child: label,
      );
    }

    if (opts.length <= 3) {
      return Row(children: [
        for (var i = 0; i < opts.length; i++) ...[
          if (i > 0) const SizedBox(width: 6),
          Expanded(child: button(opts[i])),
        ],
      ]);
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (final o in opts) Padding(padding: const EdgeInsets.only(bottom: 6), child: button(o)),
    ]);
  }
}

/// Session row for an approval, to open its conversation.
SessionRow sessionOfApproval(Approval a) => SessionRow(
      sessionId: a.sessionId,
      agentId: a.agentId,
      agentName: a.agentName,
      platform: a.platform ?? '',
      title: a.conversationTitle,
      channelName: a.channel,
    );
