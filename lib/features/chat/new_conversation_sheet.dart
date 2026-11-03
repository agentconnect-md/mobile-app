import 'package:flutter/material.dart';

import '../../core/api/models.dart';
import '../../core/auth/app_state.dart';
import '../../l10n/app_localizations.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import 'chat_screen.dart';

Future<void> showNewConversationSheet(BuildContext context) {
  final app = AppScope.read(context);
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (c) => AppScope(state: app, child: const _AgentPicker()),
  );
}

class _AgentPicker extends StatefulWidget {
  const _AgentPicker();
  @override
  State<_AgentPicker> createState() => _AgentPickerState();
}

class _AgentPickerState extends State<_AgentPicker> {
  List<Agent>? _agents;
  bool _failed = false;
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_started) {
      _started = true;
      _load();
    }
  }

  Future<void> _load() async {
    final app = AppScope.read(context);
    setState(() {
      _failed = false;
      _agents = null;
    });
    try {
      final a = await app.client.agents(app.current!.orgId);
      final usable = a.where((x) => x.active && x.webchat).toList()
        ..sort((x, y) => x.label.toLowerCase().compareTo(y.label.toLowerCase()));
      if (mounted) setState(() => _agents = usable);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final p = context.pal;
    final h = MediaQuery.sizeOf(context).height * 0.7;
    Widget body;
    if (_failed) {
      body = StateView(
          icon: Icons.error_outline,
          title: l.startErrorTitle,
          body: l.startErrorBody,
          actionLabel: l.tryAgain,
          onAction: _load);
    } else if (_agents == null) {
      body = const Center(child: CircularProgressIndicator());
    } else if (_agents!.isEmpty) {
      body = StateView(
          icon: Icons.smart_toy_outlined,
          title: l.noAgentsTitle,
          body: l.noAgentsBody);
    } else {
      body = ListView.separated(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        itemCount: _agents!.length,
        separatorBuilder: (_, _) => const SizedBox(height: 8),
        itemBuilder: (c, i) {
          final a = _agents![i];
          return AppCard(
            onTap: () {
              final nav = Navigator.of(context);
              final app = AppScope.read(context);
              nav.pop();
              nav.push(MaterialPageRoute(
                  builder: (_) => AppScope(state: app, child: ChatScreen(agent: a))));
            },
            child: Row(children: [
              Icon(Icons.smart_toy_outlined, color: p.accent),
              const SizedBox(width: 12),
              Expanded(
                  child: Text(a.label,
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600))),
              Icon(Icons.chevron_right, color: p.secondary),
            ]),
          );
        },
      );
    }
    return SizedBox(
      height: h,
      child: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(l.newConversation,
                  style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
              Text(l.chooseAgent, style: TextStyle(color: p.secondary)),
            ]),
          ),
        ),
        Expanded(child: body),
      ]),
    );
  }
}
