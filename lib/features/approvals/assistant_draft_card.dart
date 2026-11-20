import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../core/api/assistant_drafts.dart';
import '../../core/api/models.dart';
import '../../core/assistant_drafts_controller.dart';
import '../../l10n/app_localizations.dart';
import '../../ui/adaptive.dart';
import '../../ui/format.dart';
import '../../ui/icons.dart';
import '../../ui/platform.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';

/// Where a draft would post, or a proposal report back: "DM with Ada",
/// "#support", or the platform and channel when the place has no name.
String draftPlace(AppLocalizations l, AssistantDraft d) {
  final name = d.targetName;
  if (name != null && name.isNotEmpty) {
    return d.dm ? l.draftDmWith(name) : (name.startsWith('@') || name.startsWith('#') ? name : '#$name');
  }
  final source = sourceOf(d.platform);
  if (source == 'chat') return l.webChat;
  final platform = sourceName(l, source);
  return '${platform.isEmpty ? d.platform : platform} · ${d.channel}';
}

/// "2:14 PM" today, otherwise "Oct 10, 2:14 PM".
String _shortTime(DateTime t) {
  final local = t.toLocal();
  final now = DateTime.now();
  final today = local.year == now.year && local.month == now.month && local.day == now.day;
  return today ? DateFormat.jm().format(local) : DateFormat.MMMd().add_jm().format(local);
}

/// The sections of the Approvals screen for what assistant-mode agents wait
/// on: messages to post, then suggested tasks and follow-ups.
class AssistantDraftsSection extends StatelessWidget {
  const AssistantDraftsSection({super.key, required this.controller, this.agentOf});
  final AssistantDraftsController controller;

  /// The agent a draft belongs to, for its avatar.
  final Agent? Function(String agentId)? agentOf;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final p = context.pal;
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final rows = controller.rows;
        if (rows.isEmpty) return const SizedBox.shrink();
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(2, 4, 2, 10),
            child: Text(l.assistantWaiting,
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: p.secondary)),
          ),
          for (final d in rows)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: AssistantDraftCard(
                  key: ValueKey('draft:${d.key}'), draft: d, controller: controller, agent: agentOf?.call(d.agentId)),
            ),
          if (controller.truncated)
            Padding(
              padding: const EdgeInsets.fromLTRB(2, 0, 2, 12),
              child: Text(l.assistantMore, style: TextStyle(fontSize: 13, color: p.secondary)),
            ),
        ]);
      },
    );
  }
}

/// One draft or proposal: what it would do, where, and Approve / Discard (a
/// message) or Approve / Deny (a suggested task or follow-up). Decided here,
/// it shows what the decision did until it is dismissed.
class AssistantDraftCard extends StatelessWidget {
  const AssistantDraftCard({super.key, required this.draft, required this.controller, this.agent});
  final AssistantDraft draft;
  final AssistantDraftsController controller;
  final Agent? agent;

  Future<void> _decide(BuildContext context, {required bool approve}) async {
    final l = AppLocalizations.of(context);
    final d = draft;
    final place = draftPlace(l, d);
    final (title, body) = d.isProposal
        ? !approve
            ? (l.proposalDenyTitle, l.proposalDenyBody)
            : d.isFollowUp
                ? (l.proposalTakeTitle, l.proposalTakeBody(place))
                : (l.proposalApproveTitle, l.proposalApproveBody(place))
        : approve
            ? (l.draftApproveTitle, l.draftApproveBody(place))
            : (l.draftDiscardTitle, l.draftDiscardBody);
    final ok = await confirmDialog(
      context,
      title: title,
      body: body,
      cancel: l.cancel,
      confirm: approve
          ? l.approve
          : d.isProposal
              ? l.deny
              : l.draftDiscard,
      destructive: !approve,
    );
    if (ok != true) return;
    Haptics.medium();
    await controller.decide(d, approve: approve);
  }

  /// What a decision made here did, in words, and whether it went well.
  (String, bool?) _outcome(AppLocalizations l, DraftResult r, String place) {
    final d = draft;
    final proposal = d.isProposal;
    if (r.refusal != null) {
      return switch (r.refusal) {
        'unconfirmed' => (
            controller.isWaiting(d)
                ? l.draftOutUnconfirmedWaiting
                : proposal
                    ? l.proposalOutUnconfirmedGone(place)
                    : l.draftOutUnconfirmedGone,
            null
          ),
        'expired' => (proposal ? l.proposalOutExpired : l.draftOutExpired, null),
        'decided' => (l.draftOutDecided, null),
        _ => (l.draftOutGone, null),
      };
    }
    final o = r.outcome!;
    final reason = (o.failure ?? '').isEmpty ? l.draftOutUnknownReason : o.failure!;
    if (d.isFollowUp) {
      return switch (o.status) {
        'failed' => (l.proposalOutNotTaken(reason), false),
        'denied' => (l.proposalOutDeniedFollowUp, null),
        _ => (l.proposalOutTaken(place), true),
      };
    }
    if (proposal) {
      return switch (o.status) {
        'failed' => (l.proposalOutFailed(reason), false),
        'denied' => (l.proposalOutDenied, null),
        'succeeded' => (l.proposalOutSucceeded(place), true),
        'outcome_unknown' => (l.proposalOutUnknown(place), null),
        'expired' => (l.proposalOutExpired, null),
        _ => (l.proposalOutExecuting(place), true),
      };
    }
    return switch (o.status) {
      'succeeded' => (l.draftOutSucceeded, true),
      'denied' => (l.draftOutDenied, null),
      'failed' => (l.draftOutFailed(reason), false),
      'outcome_unknown' => (l.draftOutUnknown, null),
      'expired' => (l.draftOutExpired, null),
      _ => (l.draftOutUnconfirmedWaiting, null),
    };
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(listenable: controller, builder: (context, _) => _card(context));

  Widget _card(BuildContext context) {
    final l = AppLocalizations.of(context);
    final p = context.pal;
    final d = draft;
    final st = controller.stateOf(d);
    final proposal = d.proposal;
    final isProposal = d.isProposal;
    final place = draftPlace(l, d);
    final canDecide = controller.canDecide(d);
    final hint = TextStyle(color: p.secondary, fontSize: 13, height: 1.4);
    final approves = d.inConversation
        ? l.draftInConversationApproves
        : !d.hasApprover
            ? l.draftNoApprover
            : l.draftApproves(d.approverKind == 'conversation'
                ? place
                : (d.approverName ?? d.approverUserId ?? l.someone));
    final expires = d.expiresAt == null ? null : l.draftExpires(_shortTime(d.expiresAt!));
    final notice = switch (st.notice) {
      'busy' => l.draftBusy,
      'upgrade' => l.draftUpgradeDaemon,
      'offline' => l.agentOffline(d.agentName),
      'readOnly' => l.readOnlyGrant,
      'failed' => l.draftDecideFailed,
      _ => null,
    };
    final result = st.result;
    final (outText, outGood) = result == null ? (null, null) : _outcome(l, result, place);
    final followUp = proposal?.followUp;
    return AppCard(
      leftBar: canDecide ? p.paused : null,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          AgentAvatar(
              iconUrl: agent?.iconUrl, runtime: agent?.runtime, name: d.agentName, size: 18, showDot: false),
          const SizedBox(width: 8),
          Expanded(
            child: Text(d.agentName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
          ),
          if (d.external) ...[
            Pill(l.draftExternal, fg: p.paused, bg: p.pausedSoft),
            const SizedBox(width: 6),
          ],
          Pill(
              !isProposal
                  ? l.draftKind
                  : d.isFollowUp
                      ? l.draftKindFollowUp
                      : l.draftKindTask,
              fg: p.info,
              bg: p.infoSoft),
        ]),
        const SizedBox(height: 10),
        Text(
            isProposal
                ? proposal!.sentence
                : d.thread == null
                    ? l.draftTo(place)
                    : '${l.draftTo(place)} · ${l.draftInThread}',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500, color: p.ink, height: 1.4)),
        if (isProposal) ...[
          if ((proposal!.why).isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(l.proposalWhy(proposal.why), style: hint),
          ],
          if ((proposal.itemTitle ?? '').isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(l.proposalItem(proposal.itemTitle!), style: hint),
          ],
        ],
        const SizedBox(height: 8),
        // The exact text that would be posted, or the task that would run.
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(color: p.sunken, borderRadius: BorderRadius.circular(6)),
          child: followUp == null
              ? Text(d.text,
                  maxLines: 12, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 14, color: p.ink, height: 1.4))
              : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(l.followUpTakes, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: p.tertiary)),
                  const SizedBox(height: 2),
                  Text(followUp.title, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: p.ink)),
                  if (followUp.doneWhen.isNotEmpty) Text(followUp.doneWhen, style: hint),
                  if ((followUp.watch ?? '').isNotEmpty) Text(l.followUpWatches(followUp.watch!), style: hint),
                  Text(
                      followUp.nextCheck == null
                          ? l.followUpNoCheck
                          : l.followUpFirstCheck(_shortTime(followUp.nextCheck!)),
                      style: hint),
                ]),
        ),
        const SizedBox(height: 6),
        Text(
            [
              if (isProposal) place else approves,
              ?expires,
            ].join(' · '),
            style: mono(context, size: 12, color: p.secondary)),
        if (notice != null) ...[
          const SizedBox(height: 6),
          Semantics(liveRegion: true, child: Text(notice, style: TextStyle(color: p.paused, fontSize: 13))),
        ],
        if (outText != null) ...[
          const SizedBox(height: 8),
          Semantics(
            liveRegion: true,
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Icon(
                    outGood == true
                        ? AppIcons.checkCircleOutline
                        : outGood == false
                            ? AppIcons.errorOutline
                            : AppIcons.block,
                    size: 16,
                    color: outGood == true
                        ? p.online
                        : outGood == false
                            ? p.error
                            : p.secondary),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(outText,
                    style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        height: 1.4,
                        color: outGood == true
                            ? p.online
                            : outGood == false
                                ? p.error
                                : p.secondary)),
              ),
            ]),
          ),
        ],
        const SizedBox(height: 10),
        if (st.sending)
          Row(children: [
            const SizedBox(width: 16, height: 16, child: Spinner(strokeWidth: 2)),
            const SizedBox(width: 8),
            Text(l.sent, style: TextStyle(color: p.secondary)),
          ])
        else if (canDecide)
          Row(children: [
            Expanded(
              child: OutlinedButton(
                onPressed: () => _decide(context, approve: false),
                child: Text(isProposal ? l.deny : l.draftDiscard),
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: FilledButton(onPressed: () => _decide(context, approve: true), child: Text(l.approve)),
            ),
          ])
        else
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: OutlinedButton(onPressed: () => controller.dismiss(d), child: Text(l.draftDismiss)),
          ),
      ]),
    );
  }
}
