import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../ui/theme.dart';

/// The line above the first message that arrived since the conversation was
/// last read on this device: the word "New" and a rule.
class NewDivider extends StatelessWidget {
  const NewDivider({super.key});

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final p = context.pal;
    return Semantics(
      container: true,
      label: l.newSinceLastRead,
      child: ExcludeSemantics(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(children: [
            Text(l.newDivider.toUpperCase(),
                style: mono(context, size: 12, color: p.brandText, weight: FontWeight.w600).copyWith(letterSpacing: 1)),
            const SizedBox(width: 12),
            Expanded(child: Container(height: 1, color: p.accent.withValues(alpha: 0.5))),
          ]),
        ),
      ),
    );
  }
}
