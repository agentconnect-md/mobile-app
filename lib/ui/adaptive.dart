import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'platform.dart';
import 'theme.dart';

/// Indeterminate progress. iOS: the system activity indicator, sized to the
/// box around it (20 pt when unconstrained). Elsewhere: the Material ring.
class Spinner extends StatelessWidget {
  const Spinner({super.key, this.strokeWidth, this.color, this.onAccent = false});
  final double? strokeWidth;
  final Color? color;

  /// Inside a filled (brand-colored) button: white on iOS, where the system
  /// indicator's default gray would not read. Elsewhere unchanged.
  final bool onAccent;

  @override
  Widget build(BuildContext context) {
    if (!isIOS) return CircularProgressIndicator(strokeWidth: strokeWidth, color: color);
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

/// A short list of actions to pick from; returns the picked value, or null
/// when dismissed. iOS: an action sheet with a Cancel button. Elsewhere: a
/// bottom sheet of rows with icons. [note] is a line of explanation.
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
