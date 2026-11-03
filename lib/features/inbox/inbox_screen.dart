import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/api/api_client.dart';
import '../../core/api/approvals.dart';
import '../../core/auth/app_state.dart';
import '../../l10n/app_localizations.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import '../chat/new_conversation_sheet.dart';
import 'approvals_controller.dart';

class InboxScreen extends StatelessWidget {
  const InboxScreen({super.key, required this.controller});
  final ApprovalsController controller;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(l.inboxTitle),
        actions: [
          IconButton(
            tooltip: l.newConversation,
            icon: const Icon(Icons.edit_square),
            onPressed: () => showNewConversationSheet(context),
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          final c = controller;
          if (c.loading && c.approvals.isEmpty) {
            return const Center(child: CircularProgressIndicator());
          }
          if (c.error != null && c.approvals.isEmpty) {
            return RefreshIndicator(
              onRefresh: c.refresh,
              child: LayoutBuilder(
                builder: (_, box) => ListView(children: [
                  SizedBox(
                    height: box.maxHeight,
                    child: StateView(
                      icon: Icons.cloud_off,
                      title: l.inboxErrorTitle,
                      body: c.error is NetworkException ? l.errNetwork : l.pullToRetry,
                      actionLabel: l.tryAgain,
                      onAction: c.refresh,
                    ),
                  ),
                ]),
              ),
            );
          }
          if (c.approvals.isEmpty) {
            return RefreshIndicator(
              onRefresh: c.refresh,
              child: LayoutBuilder(
                builder: (_, box) => ListView(children: [
                  SizedBox(
                    height: box.maxHeight,
                    child: StateView(
                      icon: Icons.check_circle_outline,
                      title: l.inboxEmptyTitle,
                      body: l.inboxEmptyBody,
                    ),
                  ),
                ]),
              ),
            );
          }
          return RefreshIndicator(
            onRefresh: c.refresh,
            child: ListView.separated(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
              itemCount: c.approvals.length,
              separatorBuilder: (_, _) => const SizedBox(height: 12),
              itemBuilder: (_, i) =>
                  ApprovalCard(key: ValueKey(c.approvals[i].id), approval: c.approvals[i], controller: c),
            ),
          );
        },
      ),
    );
  }
}

class ApprovalCard extends StatefulWidget {
  const ApprovalCard({super.key, required this.approval, required this.controller});
  final Approval approval;
  final ApprovalsController controller;
  @override
  State<ApprovalCard> createState() => _ApprovalCardState();
}

class _ApprovalCardState extends State<ApprovalCard> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    if (widget.approval.expiresAt != null) {
      _tick = Timer.periodic(const Duration(seconds: 20), (_) {
        if (mounted) setState(() {});
      });
    }
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  Future<void> _choose(ApprovalOption o) async {
    final l = AppLocalizations.of(context);
    final app = AppScope.read(context);
    final a = widget.approval;
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
      final authed = await app.biometrics.confirm(l.biometricReason);
      if (!authed) return;
    }
    await widget.controller.decide(a, o);
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final p = context.pal;
    final a = widget.approval;
    final st = widget.controller.stateOf(a.id);
    final exp = a.expiresAt;
    final left = exp?.difference(DateTime.now());
    final expired = left != null && left.isNegative;
    final sending = st.phase == CardPhase.sending;
    final done = st.phase == CardPhase.done;

    String? resultText;
    if (done) {
      resultText = switch (st.resultKind) {
        'allow_once' => l.allowedOnce,
        'allow_always' => l.alwaysAllowed,
        'expired' => l.approvalExpired,
        _ => l.denied,
      };
    }
    final notice = switch (st.notice) {
      'answered' => l.alreadyAnswered,
      'offline' => l.agentOffline(a.agentName),
      'error' => l.genericError,
      _ => null,
    };

    return AppCard(
      leftBar: done ? null : p.amberBar,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
            child: Text(a.agentName,
                style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
          ),
          if (exp != null)
            Chip8(expired ? l.expired : l.expiresIn((left!.inMinutes + 1).clamp(1, 9999)),
                fg: p.amberText, bg: p.amberBg),
        ]),
        if (a.conversationTitle != null && a.conversationTitle!.isNotEmpty) ...[
          const SizedBox(height: 2),
          Text(a.conversationTitle!,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: p.secondary, fontSize: 14)),
        ],
        const SizedBox(height: 10),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
              color: p.sunken, borderRadius: BorderRadius.circular(10)),
          child: Text(a.command,
              maxLines: 8,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontFamily: monoFamily,
                  fontFamilyFallback: monoFallback,
                  fontSize: 13,
                  color: p.ink)),
        ),
        if (notice != null) ...[
          const SizedBox(height: 10),
          Semantics(
              liveRegion: true,
              child: Text(notice, style: TextStyle(color: p.amberText, fontSize: 14))),
        ],
        const SizedBox(height: 12),
        if (done)
          Row(children: [
            Icon(Icons.check_circle, color: p.success, size: 20),
            const SizedBox(width: 8),
            Expanded(
                child: Text(resultText!,
                    style: const TextStyle(fontWeight: FontWeight.w600))),
          ])
        else if (expired)
          Text(l.approvalExpired, style: TextStyle(color: p.secondary))
        else if (sending)
          Row(children: [
            const SizedBox(
                width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
            const SizedBox(width: 10),
            Text(l.sent),
          ])
        else
          Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            for (final o in a.options)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: _optionButton(o, p),
              ),
          ]),
      ]),
    );
  }

  Widget _optionButton(ApprovalOption o, Palette p) {
    final label = Text(o.name, textAlign: TextAlign.center);
    if (o.kind == 'allow_once') {
      return FilledButton(onPressed: () => _choose(o), child: label);
    }
    if (o.isAlways) {
      return FilledButton.icon(
        style: FilledButton.styleFrom(
            backgroundColor: p.accent.withValues(alpha: 0.14), foregroundColor: p.accent),
        onPressed: () => _choose(o),
        icon: const Icon(Icons.lock_outline, size: 18),
        label: label,
      );
    }
    return FilledButton(
      style: FilledButton.styleFrom(backgroundColor: p.ink, foregroundColor: p.canvas),
      onPressed: () => _choose(o),
      child: label,
    );
  }
}
