import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'icons.dart';
import 'platform.dart';
import 'theme.dart';

/// Indeterminate progress. iOS and the Mac: the system activity indicator,
/// sized to the box around it (20 pt when unconstrained). Elsewhere: the
/// Material ring.
class Spinner extends StatelessWidget {
  const Spinner({super.key, this.strokeWidth, this.color, this.onAccent = false});
  final double? strokeWidth;
  final Color? color;

  /// Inside a filled (brand-colored) button: white on iOS, where the system
  /// indicator's default gray would not read. Elsewhere unchanged.
  final bool onAccent;

  @override
  Widget build(BuildContext context) {
    if (!isApple) return CircularProgressIndicator(strokeWidth: strokeWidth, color: color);
    return LayoutBuilder(builder: (context, box) {
      final side = box.biggest.shortestSide;
      final radius = side.isFinite ? math.min(side / 2, 10.0) : 10.0;
      return Center(child: CupertinoActivityIndicator(radius: radius, color: color ?? (onAccent ? Colors.white : null)));
    });
  }
}

/// A two-button confirmation. iOS: a system alert (not dismissed by tapping
/// outside; a destructive confirm is red). Elsewhere: the Material dialog.
Future<bool?> confirmDialog(
  BuildContext context, {
  required String title,
  required String body,
  required String cancel,
  required String confirm,
  bool destructive = false,
}) {
  if (isIOS) {
    return showCupertinoDialog<bool>(
      context: context,
      builder: (c) => CupertinoAlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          CupertinoDialogAction(
            isDefaultAction: true,
            onPressed: () => Navigator.pop(c, false),
            child: Text(cancel),
          ),
          CupertinoDialogAction(
            isDestructiveAction: destructive,
            onPressed: () => Navigator.pop(c, true),
            child: Text(confirm),
          ),
        ],
      ),
    );
  }
  return showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text(title),
      content: Text(body),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: Text(cancel)),
        TextButton(
          onPressed: () => Navigator.pop(c, true),
          child: destructive ? Text(confirm, style: TextStyle(color: c.pal.error)) : Text(confirm),
        ),
      ],
    ),
  );
}

/// One choice of [showActionMenu].
class MenuAction<T> {
  const MenuAction(this.value, this.icon, this.label);
  final T value;
  final IconData icon;
  final String label;
}

/// Where the pointer last went down, for menus that open at the pointer on
/// the Mac. Kept by [PointerTracker].
Offset? lastPointerPosition;

/// Remembers where the pointer last went down (Mac only; see [showActionMenu]).
class PointerTracker extends StatelessWidget {
  const PointerTracker({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (e) => lastPointerPosition = e.position,
        child: child,
      );
}

/// A short list of actions to pick from; returns the picked value, or null
/// when dismissed. iOS: an action sheet with a Cancel button. The Mac: a menu
/// at the pointer (what a right-click or a "+" button opens there).
/// Elsewhere: a bottom sheet of rows with icons. [note] is a line of
/// explanation.
Future<T?> showActionMenu<T>(
  BuildContext context, {
  required List<MenuAction<T>> actions,
  required String cancel,
  String? note,
}) {
  if (isIOS) {
    return showCupertinoModalPopup<T>(
      context: context,
      builder: (ctx) => CupertinoActionSheet(
        message: note == null ? null : Text(note),
        actions: [
          for (final a in actions)
            CupertinoActionSheetAction(onPressed: () => Navigator.pop(ctx, a.value), child: Text(a.label)),
        ],
        cancelButton: CupertinoActionSheetAction(
          isDefaultAction: true,
          onPressed: () => Navigator.pop(ctx),
          child: Text(cancel),
        ),
      ),
    );
  }
  if (isMacOS) {
    final p = context.pal;
    final overlay = Navigator.of(context, rootNavigator: true).overlay!.context.findRenderObject() as RenderBox;
    final at = lastPointerPosition ?? overlay.size.center(Offset.zero);
    return showMenu<T>(
      context: context,
      useRootNavigator: true,
      position: RelativeRect.fromRect(at & Size.zero, Offset.zero & overlay.size),
      color: p.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 6,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10), side: BorderSide(color: p.border)),
      menuPadding: const EdgeInsets.symmetric(vertical: 5),
      popUpAnimationStyle: AnimationStyle.noAnimation,
      items: [
        for (final a in actions)
          PopupMenuItem<T>(
            value: a.value,
            height: 30,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(a.icon, size: 16, color: p.secondary),
              const SizedBox(width: 10),
              Text(a.label, style: TextStyle(fontSize: 13.5, color: p.ink)),
            ]),
          ),
        if (note != null)
          PopupMenuItem<T>(
            enabled: false,
            height: 30,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 240),
              child: Text(note, style: TextStyle(fontSize: 12, color: p.tertiary)),
            ),
          ),
      ],
    );
  }
  return showModalBottomSheet<T>(
    context: context,
    showDragHandle: true,
    useSafeArea: true,
    builder: (ctx) => Column(mainAxisSize: MainAxisSize.min, children: [
      for (final a in actions)
        ListTile(
          leading: Icon(a.icon),
          title: Text(a.label),
          onTap: () => Navigator.pop(ctx, a.value),
        ),
      if (note != null)
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
          child: Text(note, style: TextStyle(color: ctx.pal.secondary, fontSize: 13)),
        ),
      const SizedBox(height: 8),
    ]),
  );
}

/// Content that needs room (filters, pickers, the workspace). On a phone a
/// bottom sheet, with exactly the arguments given. On the Mac a dialog in the
/// middle of the window: it closes with Esc, a click outside it, or a close
/// button, which is added here unless the content has its own ([ownClose]).
Future<T?> showAppSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool? showDragHandle,
  bool useSafeArea = false,
  bool isScrollControlled = false,
  bool ownClose = false,
}) {
  if (isMacOS) {
    return showDialog<T>(
      context: context,
      builder: (c) => Dialog(
        backgroundColor: c.pal.canvas,
        surfaceTintColor: Colors.transparent,
        clipBehavior: Clip.antiAlias,
        insetPadding: const EdgeInsets.symmetric(horizontal: 40, vertical: 32),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14), side: BorderSide(color: c.pal.border)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Stack(children: [
            // The room a sheet's drag handle takes, so its content sits as designed.
            Padding(padding: const EdgeInsets.only(top: 28), child: builder(c)),
            if (!ownClose)
              Positioned(
                top: 6,
                right: 6,
                child: IconButton(
                  tooltip: MaterialLocalizations.of(c).closeButtonTooltip,
                  visualDensity: VisualDensity.compact,
                  onPressed: () => Navigator.of(c).maybePop(),
                  icon: Icon(AppIcons.close, size: 16, color: c.pal.secondary),
                ),
              ),
          ]),
        ),
      ),
    );
  }
  return showModalBottomSheet<T>(
    context: context,
    showDragHandle: showDragHandle,
    useSafeArea: useSafeArea,
    isScrollControlled: isScrollControlled,
    builder: builder,
  );
}
