import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/api/models.dart';
import '../../core/auth/app_state.dart';
import '../../core/console_links.dart';
import '../../core/share_links.dart';
import '../../l10n/app_localizations.dart';
import '../../ui/adaptive.dart';
import '../../ui/format.dart';
import '../../ui/icons.dart';
import '../../ui/platform.dart';
import '../../ui/theme.dart';

/// Shares a session as the web console's Share dialog does: who can see it
/// (its owner switches between everyone and private, confirming before it
/// is made private), and its link to copy or send.
Future<void> showShareSession(
  BuildContext context, {
  required SessionRow session,
  required String title,
  Agent? agent,
}) {
  final app = AppScope.read(context);
  final messenger = ScaffoldMessenger.maybeOf(context);
  return showAppSheet<void>(
    context: context,
    showDragHandle: true,
    useSafeArea: true,
    isScrollControlled: true,
    builder: (_) => AppScope(
      state: app,
      child: _ShareSheet(session: session, title: title, agent: agent, messenger: messenger),
    ),
  );
}

class _ShareSheet extends StatefulWidget {
  const _ShareSheet({required this.session, required this.title, this.agent, this.messenger});
  final SessionRow session;
  final String title;
  final Agent? agent;
  final ScaffoldMessengerState? messenger;
  @override
  State<_ShareSheet> createState() => _ShareSheetState();
}

class _ShareSheetState extends State<_ShareSheet> {
  Uri? _link;
  SessionAccess? _access;
  bool _loading = true;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final app = AppScope.read(context);
    final org = app.current!.orgId;
    final id = widget.session.sessionId;
    final results = await Future.wait<Object?>([
      currentOrgSlug(app),
      app.client.sessionAccess(org, id).then<SessionAccess?>((a) => a).catchError((_) => null),
    ]);
    if (!mounted) return;
    setState(() {
      _link = sessionLink(app, results[0]! as String, id);
      _access = results[1] as SessionAccess?;
      _loading = false;
    });
  }

  Future<void> _pick(String visibility) async {
    final l = AppLocalizations.of(context);
    final access = _access;
    if (access == null || _busy || access.effective == visibility) return;
    if (visibility == 'private') {
      final ok = await confirmDialog(
        context,
        title: l.makePrivateTitle,
        body: widget.agent?.memoryProvider == 'native' ? l.makePrivateNativeMemory : l.makePrivateManagedMemory,
        cancel: l.cancel,
        confirm: l.makePrivate,
      );
      if (ok != true || !mounted) return;
    }
    Haptics.selection();
    final app = AppScope.read(context);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final answer = await app.client.setSessionVisibility(app.current!.orgId, widget.session.sessionId, visibility);
      if (mounted) setState(() => _access = access.changed(answer));
    } catch (_) {
      if (mounted) setState(() => _error = l.visibilityChangeFailed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final p = context.pal;
    final link = _link;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            l.shareTitle(widget.title),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 16),
          if (_loading)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Center(child: Spinner()),
            )
          else ...[
            if (_access != null) ...[
              Text(
                l.whoCanSee,
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: p.secondary),
              ),
              const SizedBox(height: 8),
              ..._audience(context, _access!),
              if (_access!.pending)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Row(
                    children: [
                      const SizedBox.square(dimension: 12, child: Spinner(strokeWidth: 1.5)),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(l.visibilityWaiting, style: TextStyle(fontSize: 12, color: p.tertiary)),
                      ),
                    ],
                  ),
                ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(_error!, style: TextStyle(fontSize: 12, color: p.error)),
                ),
              const SizedBox(height: 16),
            ],
            if (link != null) ...[
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(color: p.sunken, borderRadius: BorderRadius.circular(8)),
                child: SelectableText(link.toString(), style: mono(context, size: 12, color: p.ink)),
              ),
              const SizedBox(height: 14),
              FilledButton.icon(
                icon: Icon(AppIcons.link, size: 18),
                label: Text(l.copyLink),
                onPressed: _busy
                    ? null
                    : () async {
                        final nav = Navigator.of(context);
                        await Clipboard.setData(ClipboardData(text: link.toString()));
                        if (mounted) nav.pop();
                        widget.messenger?.showSnackBar(SnackBar(content: Text(l.copied)));
                      },
              ),
              const SizedBox(height: 6),
              Builder(
                builder: (btn) => OutlinedButton.icon(
                  icon: Icon(AppIcons.iosShare, size: 18),
                  label: Text(l.shareVia),
                  onPressed: () {
                    // iPad shows the share sheet as a popover: anchor it on this button,
                    // measured before the sheet closes.
                    final box = btn.findRenderObject() as RenderBox?;
                    final origin = box != null && box.hasSize ? box.localToGlobal(Offset.zero) & box.size : null;
                    Navigator.pop(context);
                    SharePlus.instance.share(ShareParams(uri: link, sharePositionOrigin: origin));
                  },
                ),
              ),
            ],
          ],
        ],
      ),
    );
  }

  /// The owner picks between everyone and private; anyone else reads the one that holds.
  List<Widget> _audience(BuildContext context, SessionAccess a) {
    final l = AppLocalizations.of(context);
    final effective = a.effective;
    if (effective == 'external') {
      final provider = sourceName(l, a.externalProvider ?? '');
      final name = provider.isEmpty ? (a.externalProvider ?? '') : provider;
      final body = !a.settled
          ? l.visibilityUnverified(name)
          : switch (a.externalProvider) {
              'github' => l.visibilityRepo,
              'slack' => l.visibilityChannel,
              _ => l.visibilityConversation,
            };
      return [_Choice(icon: AppIcons.groupOutlined, label: l.visibilityExternal(name), body: body, selected: true)];
    }
    if (effective == 'editors') {
      return [
        _Choice(icon: AppIcons.lockOutline, label: l.visibilityEditors, body: l.visibilityEditorsBody, selected: true),
      ];
    }
    final choices = [
      ('org', AppIcons.public, l.visibilityEveryone, l.visibilityEveryoneBody),
      ('private', AppIcons.lockOutline, l.visibilityPrivate, l.visibilityPrivateBody),
    ];
    return [
      for (final (value, icon, label, body) in choices)
        if (a.canChange || value == effective)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: _Choice(
              icon: icon,
              label: label,
              body: body,
              selected: value == effective,
              busy: _busy && value != effective,
              onTap: a.canChange && !_busy ? () => _pick(value) : null,
            ),
          ),
    ];
  }
}

/// One audience: icon, name and what it means; the one that holds is marked
/// with a check (not color alone).
class _Choice extends StatelessWidget {
  const _Choice({
    required this.icon,
    required this.label,
    required this.body,
    required this.selected,
    this.busy = false,
    this.onTap,
  });
  final IconData icon;
  final String label;
  final String body;
  final bool selected;
  final bool busy;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return Semantics(
      inMutuallyExclusiveGroup: onTap != null,
      checked: onTap != null ? selected : null,
      button: onTap != null,
      child: Material(
        color: selected ? p.brandSoft : p.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(color: selected ? p.brandText : p.border),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 44),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
              child: Row(
                children: [
                  Icon(icon, size: 18, color: selected ? p.brandText : p.secondary),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(label, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                        const SizedBox(height: 2),
                        Text(body, style: TextStyle(fontSize: 12.5, color: p.secondary, height: 1.35)),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  if (busy)
                    const SizedBox.square(dimension: 14, child: Spinner(strokeWidth: 1.5))
                  else if (selected)
                    Icon(AppIcons.check, size: 16, color: p.brandText),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
