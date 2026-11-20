import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../ui/format.dart';
import '../../ui/theme.dart';

/// Percent of a context window in use, 0–100; null when either number is
/// missing or the size is not positive.
int? contextPercent(int? used, int? size) =>
    used == null || size == null || size <= 0 ? null : math.min(100, math.max(0, (used / size * 100).round()));

/// How full the session's context window is: a small ring by the message
/// box. Tapping it says the percentage and the token counts.
class ContextRing extends StatelessWidget {
  const ContextRing({super.key, required this.used, required this.size});

  /// Tokens in the window now; null until the session reports them.
  final int? used;
  final int size;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final p = context.pal;
    final percent = contextPercent(used, size);
    final lines = [
      '${l.contextWindow}:',
      percent == null ? l.contextUsageUnavailable : l.contextPercent(percent, 100 - percent),
      if (used != null) l.contextTokensOfSize(compactCount(used!), compactCount(size)),
    ];
    return Tooltip(
      message: lines.join('\n'),
      triggerMode: TooltipTriggerMode.tap,
      showDuration: const Duration(seconds: 4),
      textAlign: TextAlign.center,
      child: Semantics(
        label: lines.join(' '),
        child: SizedBox(
          width: 44,
          height: 44,
          child: Center(
            child: CustomPaint(
              size: const Size.square(18),
              painter: _RingPainter(fraction: (percent ?? 0) / 100, track: p.border, fill: p.secondary),
            ),
          ),
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  const _RingPainter({required this.fraction, required this.track, required this.fill});
  final double fraction;
  final Color track;
  final Color fill;

  @override
  void paint(Canvas canvas, Size size) {
    const stroke = 3.0;
    final rect = (Offset.zero & size).deflate(stroke / 2);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..color = track;
    canvas.drawArc(rect, 0, 2 * math.pi, false, paint);
    if (fraction > 0) canvas.drawArc(rect, -math.pi / 2, 2 * math.pi * fraction, false, paint..color = fill);
  }

  @override
  bool shouldRepaint(_RingPainter old) => old.fraction != fraction || old.track != track || old.fill != fill;
}
