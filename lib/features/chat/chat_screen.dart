import 'package:flutter/material.dart';

import '../../core/api/models.dart';
import 'chat_composer.dart';

/// A brand-new conversation with one agent. The ChatComposer shows the
/// in-memory transcript; nothing is stored.
class ChatScreen extends StatelessWidget {
  const ChatScreen({super.key, required this.agent});
  final Agent agent;
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(agent.label)),
      body: Column(children: [
        const Spacer(),
        ChatComposer(agentId: agent.id, agentName: agent.label),
      ]),
    );
  }
}
