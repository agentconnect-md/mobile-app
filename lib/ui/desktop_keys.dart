import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'platform.dart';

/// On the Mac, Return in the message box [child] sends and Shift-Return (or
/// Option- / Control-Return) makes a new line. Elsewhere [child] itself: the
/// phone keyboard's Return stays a new line.
Widget sendOnReturn({required TextEditingController text, required VoidCallback onSend, required Widget child}) {
  if (!isMacOS) return child;
  return Focus(
    canRequestFocus: false,
    skipTraversal: true,
    onKeyEvent: (_, event) => returnKey(event, text, onSend),
    child: child,
  );
}

/// What Return does in a message box on the Mac (see [sendOnReturn]).
KeyEventResult returnKey(KeyEvent event, TextEditingController text, VoidCallback onSend) {
  final key = event.logicalKey;
  if (key != LogicalKeyboardKey.enter && key != LogicalKeyboardKey.numpadEnter) return KeyEventResult.ignored;
  final keys = HardwareKeyboard.instance;
  if (keys.isShiftPressed || keys.isAltPressed || keys.isControlPressed) return KeyEventResult.ignored;
  // An input method is composing (Pinyin with its candidates showing, say):
  // Return belongs to it, to confirm what was typed.
  final composing = text.value.composing;
  if (composing.isValid && !composing.isCollapsed) return KeyEventResult.ignored;
  if (event is KeyDownEvent) onSend();
  return KeyEventResult.handled;
}
