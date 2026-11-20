import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// True on iPhone and iPad. The iOS build follows Apple's Human Interface
/// Guidelines (tab bar, alerts, action sheets, SF-style icons, haptics); every
/// other platform keeps the Material look, so each iOS branch is behind this.
bool get isIOS => defaultTargetPlatform == TargetPlatform.iOS;

/// True on the Mac. The desktop build has its own shell (sidebar, list and
/// detail side by side, a menu bar, keyboard shortcuts, pointer behavior);
/// every Mac-only choice is behind this, as iOS ones are behind [isIOS].
bool get isMacOS => defaultTargetPlatform == TargetPlatform.macOS;

/// iOS or the Mac: where the SF-style glyphs and the system activity
/// indicator are at home.
bool get isApple => isIOS || isMacOS;

/// Haptic feedback, iOS only (Android keeps its own touch feedback).
abstract final class Haptics {
  /// A selection changed: tab, segment, option.
  static void selection() {
    if (isIOS) HapticFeedback.selectionClick();
  }

  /// A small physical action: sending a message.
  static void light() {
    if (isIOS) HapticFeedback.lightImpact();
  }

  /// A heavier action: a long-press menu opening, a decision.
  static void medium() {
    if (isIOS) HapticFeedback.mediumImpact();
  }
}
