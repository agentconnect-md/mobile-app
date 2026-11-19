import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// True on iPhone and iPad. The iOS build follows Apple's Human Interface
/// Guidelines (tab bar, alerts, action sheets, SF-style icons, haptics); every
/// other platform keeps the Material look, so each iOS branch is behind this.
bool get isIOS => defaultTargetPlatform == TargetPlatform.iOS;

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
