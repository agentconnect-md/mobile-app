import 'package:flutter/material.dart';

import '../../core/api/models.dart';
import '../../core/auth/app_state.dart';
import '../../core/webchat/chat_controller.dart';
import '../../core/webchat/frames.dart';
import '../../l10n/app_localizations.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import '../../ui/icons.dart';

/// Display name and description for a runtime permission preset id.
(String, String?) permissionLabel(AppLocalizations l, String id) => switch (id) {
      'default' || 'manual' => (l.permManual, l.permManualBody),
      'acceptEdits' || 'accept_edits' => (l.permAcceptEdits, l.permAcceptEditsBody),
      'plan' => (l.permPlan, l.permPlanBody),
      'auto' => (l.permAuto, l.permAutoBody),
      'bypassPermissions' || 'bypass' => (l.permBypass, l.permBypassBody),
      _ => (id, null),
    };

String effortLabel(AppLocalizations l, String id) => switch (id) {
      'low' => l.effortLow,
      'medium' => l.effortMedium,
      'high' => l.effortHigh,
      _ => id.isEmpty ? id : id[0].toUpperCase() + id.substring(1),
    };

/// What the composer shows before the session reports a snapshot.
class RunDefaults {
  const RunDefaults({this.model, this.effort, this.permissionMode, this.agent});
  final String? model;
  final String? effort;
  final String? permissionMode;
  final Agent? agent;
}

/// "claude-sonnet… · high" and "Auto" chips under the message box.
class RunChips extends StatelessWidget {
  const RunChips({super.key, required this.chat, required this.defaults, required this.onOpen});
  final ChatController? chat;
  final RunDefaults defaults;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final p = context.pal;
    final run = chat?.run;
    final model = run?.model ?? defaults.model;
    final effort = run?.effort ?? defaults.effort;
    final perm = run?.permissionMode ?? defaults.permissionMode;
    Widget chip(Widget child) => InkWell(
          onTap: onOpen,
          borderRadius: BorderRadius.circular(999),
          child: Container(
            constraints: const BoxConstraints(minHeight: 32),
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(color: p.sunken, borderRadius: BorderRadius.circular(999)),
            child: child,
          ),
        );
    return Semantics(
      button: true,
      label: l.runSettingsTooltip,
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (model != null)
          Flexible(
            child: chip(Row(mainAxisSize: MainAxisSize.min, children: [
              AgentAvatar(
                  iconUrl: defaults.agent?.iconUrl,
                  runtime: defaults.agent?.runtime,
                  name: defaults.agent?.label ?? '',
                  size: 14,
                  showDot: false),
              const SizedBox(width: 6),
              Flexible(
                child: Text([model, if (effort != null) effortLabel(l, effort).toLowerCase()].join(' · '),
                    maxLines: 1, overflow: TextOverflow.ellipsis, style: mono(context, size: 12, color: p.ink)),
              ),
            ])),
          ),
        if (perm != null) ...[
          const SizedBox(width: 6),
          chip(Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(AppIcons.shieldOutlined, size: 14, color: p.secondary),
            const SizedBox(width: 4),
            Text(permissionLabel(l, perm).$1, style: mono(context, size: 12, color: p.ink)),
          ])),
        ],
      ]),
    );
  }
}

/// Model / Effort / Permission for the session's next turn, from what the
/// session reports (no invented options). Changes go over the live chat.
Future<void> showRunSettings(BuildContext context,
    {required ChatController chat, required RunDefaults defaults, List<String> fallbackModels = const []}) {
  final app = AppScope.read(context);
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => AppScope(
      state: app,
      child: _RunSheet(chat: chat, defaults: defaults, fallbackModels: fallbackModels),
    ),
  );
}

class _RunSheet extends StatelessWidget {
  const _RunSheet({required this.chat, required this.defaults, required this.fallbackModels});
  final ChatController chat;
  final RunDefaults defaults;
  final List<String> fallbackModels;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final p = context.pal;
    return ListenableBuilder(
      listenable: chat,
      builder: (context, _) {
        final RunStatus? run = chat.run;
        final model = run?.model ?? defaults.model;
        final effort = run?.effort ?? defaults.effort;
        final perm = run?.permissionMode ?? defaults.permissionMode;
        final models = run?.models ?? (fallbackModels.isEmpty ? null : fallbackModels);
        final efforts = run?.efforts;
        final perms = run?.permissionModes;
        Widget radioRow(String title, String? sub, bool selected, VoidCallback onTap, {bool monoTitle = false, Color? color}) =>
            InkWell(
              onTap: onTap,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                child: Row(children: [
                  Icon(selected ? AppIcons.radioButtonChecked : AppIcons.radioButtonOff,
                      size: 22, color: selected ? p.accent : p.borderStrong),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(title,
                          style: monoTitle
                              ? mono(context, size: 14, color: color ?? p.ink, weight: FontWeight.w500)
                              : TextStyle(fontSize: 15, fontWeight: FontWeight.w500, color: color ?? p.ink)),
                      if (sub != null) Text(sub, style: TextStyle(fontSize: 13, color: p.secondary)),
                    ]),
                  ),
                ]),
              ),
            );
        return SizedBox(
          height: MediaQuery.sizeOf(context).height * 0.8,
          child: ListView(padding: const EdgeInsets.fromLTRB(16, 0, 16, 24), children: [
            Row(children: [
              Expanded(child: Text(l.runSettings, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600))),
              IconButton(onPressed: () => Navigator.pop(context), icon: Icon(AppIcons.close)),
            ]),
            if (models == null && efforts == null && perms == null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(l.runSettingsWaiting, style: TextStyle(color: p.secondary, fontSize: 14)),
              ),
            if (models != null && models.isNotEmpty) ...[
              SectionHeader(l.fieldModel, trailing: defaults.agent?.runtime),
              GroupCard(children: [
                for (final m in models) radioRow(m, null, m == model, () => chat.setModel(m), monoTitle: true),
              ]),
            ],
            if (efforts != null && efforts.isNotEmpty) ...[
              SectionHeader(l.effort),
              Segmented<String>(
                items: [for (final e in efforts) (e, effortLabel(l, e))],
                value: efforts.contains(effort) ? effort! : efforts.first,
                onChanged: chat.setEffort,
              ),
            ],
            if (perms != null && perms.isNotEmpty) ...[
              SectionHeader(l.permission),
              GroupCard(children: [
                for (final m in perms)
                  () {
                    final (t, sub) = permissionLabel(l, m);
                    final risky = m == 'bypassPermissions' || m == 'bypass';
                    return radioRow(t, sub, m == perm, () => chat.setPermissionMode(m), color: risky ? p.paused : null);
                  }(),
              ]),
            ],
            Padding(
              padding: const EdgeInsets.fromLTRB(2, 14, 2, 0),
              child: Text(l.runSettingsFooter, style: TextStyle(fontSize: 13, color: p.secondary, height: 1.4)),
            ),
          ]),
        );
      },
    );
  }
}
