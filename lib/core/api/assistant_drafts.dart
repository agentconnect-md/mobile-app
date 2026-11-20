import 'models.dart';

/// The follow-up an approved follow-up form takes, in place of a task
/// (`AssistantActivityProposalFollowUp`).
class ProposalFollowUp {
  const ProposalFollowUp({required this.title, this.doneWhen = '', this.nextCheck, this.watch});
  final String title;
  final String doneWhen;

  /// Its first check; null waits until it is messaged.
  final DateTime? nextCheck;

  /// The URL it would watch.
  final String? watch;
}

/// What a suggested task or follow-up would do and why (`AssistantActivityProposal`).
class DraftProposal {
  const DraftProposal({required this.sentence, this.why = '', this.itemTitle, this.followUp});
  final String sentence;
  final String why;

  /// The follow-up it came from, as last seen; null once that is gone.
  final String? itemTitle;

  /// Present on a follow-up form: approving takes this follow-up.
  final ProposalFollowUp? followUp;
}

/// Something an assistant-mode agent wants to do and waits for a person on
/// (`AssistantActivityDraft`): a message it would post (`reply`,
/// `elsewhere`), or a proposal (`task`) it would run or follow up.
class AssistantDraft {
  AssistantDraft({
    required this.id,
    required this.kind,
    required this.platform,
    required this.channel,
    required this.text,
    this.thread,
    this.targetName,
    this.dm = false,
    this.external = false,
    this.hasApprover = false,
    this.approverKind,
    this.approverName,
    this.approverUserId,
    this.proposal,
    this.inConversation = false,
    this.createdAt,
    this.expiresAt,
  });
  final String id;

  /// reply, elsewhere or task.
  final String kind;
  final String platform;
  final String channel;
  final String? thread;

  /// The conversation's name, or the direct message recipient's.
  final String? targetName;
  final bool dm;

  /// The destination includes people outside the organization.
  final bool external;

  /// The exact text that would be posted; a proposal's task (or its
  /// follow-up's title).
  final String text;
  final bool hasApprover;

  /// member or conversation.
  final String? approverKind;
  final String? approverName;
  final String? approverUserId;
  final DraftProposal? proposal;

  /// A webchat proposal, decided by whoever may continue its conversation.
  final bool inConversation;
  final DateTime? createdAt;
  final DateTime? expiresAt;

  /// Set by whoever lists it: the agent it belongs to.
  String agentId = '';
  String agentName = '';

  bool get isProposal => kind == 'task' && proposal != null;
  bool get isFollowUp => isProposal && proposal!.followUp != null;

  /// Unique across agents.
  String get key => '$agentId/$id';

  static AssistantDraft? fromJson(dynamic j) {
    final m = asMap(j);
    final id = asStr(m['id']);
    final kind = asStr(m['kind']);
    final text = asStr(m['text']);
    if (id == null || id.isEmpty || kind == null || text == null) return null;
    final t = asMap(m['target']);
    final a = m['approver'] is Map ? asMap(m['approver']) : null;
    final p = m['proposal'] is Map ? asMap(m['proposal']) : null;
    final f = p != null && p['followUp'] is Map ? asMap(p['followUp']) : null;
    final sentence = asStr(p?['sentence']);
    return AssistantDraft(
      id: id,
      kind: kind,
      platform: asStr(t['platform']) ?? '',
      channel: asStr(t['channel']) ?? '',
      thread: asStr(t['thread']),
      targetName: asStr(t['name']),
      dm: t['dm'] == true,
      external: t['external'] == true,
      text: text,
      hasApprover: a != null,
      approverKind: asStr(a?['kind']),
      approverName: asStr(a?['name']),
      approverUserId: asStr(a?['userId']),
      proposal: sentence == null
          ? null
          : DraftProposal(
              sentence: sentence,
              why: asStr(p?['why']) ?? '',
              itemTitle: asStr(p?['itemTitle']),
              followUp: f == null || asStr(f['title']) == null
                  ? null
                  : ProposalFollowUp(
                      title: asStr(f['title'])!,
                      doneWhen: asStr(f['doneWhen']) ?? '',
                      nextCheck: asDate(f['nextCheck']),
                      watch: asStr(f['watch']),
                    ),
            ),
      inConversation: m['inConversation'] == true,
      createdAt: asDate(m['createdAt']),
      expiresAt: asDate(m['expiresAt']),
    );
  }
}

/// What a decision did (`DraftDecisionDto`): `succeeded` posted (or took the
/// follow-up), `denied` discarded, `failed` did nothing, `outcome_unknown`
/// may have posted and is never retried; an approved task is `executing`.
class DraftOutcome {
  const DraftOutcome(this.status, [this.failure]);
  final String status;
  final String? failure;

  static DraftOutcome? fromJson(dynamic j) {
    final m = asMap(j);
    final status = asStr(m['status']);
    return status == null ? null : DraftOutcome(status, asStr(m['failure']));
  }
}
