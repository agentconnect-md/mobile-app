import 'package:flutter/material.dart';

import 'app.dart';
import 'core/auth/app_state.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final state = AppState();
  runApp(AgentConnectApp(state: state));
  await state.init();
}
