import 'package:flutter/material.dart';

import '../../ui/icons.dart';
import '../../ui/theme.dart';

final Set<String> _open = {};

/// A screen as a panel in the middle of the window, with a navigator of its
/// own so what it pushes stays in the panel: Settings on the Mac, and a page
/// opened from a dialog (a file from the workspace), which would otherwise
/// cover the whole window, sidebar included. Closes with Esc, a click outside
/// it or its close button. A second request for the panel [id] while it is up
/// does nothing.
Future<T?> showDesktopPanel<T>(BuildContext context, {String? id, required Widget page, bool wide = false}) async {
  if (id != null && !_open.add(id)) return null;
  try {
    return await showDialog<T>(
      context: context,
      builder: (c) {
        final p = c.pal;
        final window = MediaQuery.sizeOf(c);
        return Dialog(
          backgroundColor: p.canvas,
          surfaceTintColor: Colors.transparent,
          clipBehavior: Clip.antiAlias,
          insetPadding: const EdgeInsets.all(28),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14), side: BorderSide(color: p.border)),
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: wide ? 900 : 560, maxHeight: wide ? window.height : 680),
            child: Column(children: [
              // A strip of its own for the close button, clear of the page's toolbar.
              Container(
                height: 34,
                color: p.sunken,
                padding: const EdgeInsets.symmetric(horizontal: 6),
                alignment: Alignment.centerLeft,
                child: IconButton(
                  tooltip: MaterialLocalizations.of(c).closeButtonTooltip,
                  visualDensity: VisualDensity.compact,
                  onPressed: () => Navigator.of(c).maybePop(),
                  icon: Icon(AppIcons.close, size: 15, color: p.secondary),
                ),
              ),
              Expanded(
                child: ScaffoldMessenger(
                  child: Navigator(onGenerateRoute: (_) => MaterialPageRoute<void>(builder: (_) => page)),
                ),
              ),
            ]),
          ),
        );
      },
    );
  } finally {
    if (id != null) _open.remove(id);
  }
}
