import 'package:flutter/material.dart';

import '../core/api/models.dart';
import 'theme.dart';
import 'icons.dart';
import 'platform.dart';

/// White card with a subtle border, as in the design (radius 12).
class AppCard extends StatelessWidget {
  const AppCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(14),
    this.onTap,
    this.leftBar,
  });
  final Widget child;
  final EdgeInsets padding;
  final VoidCallback? onTap;

  /// Accent bar on the left edge (approval cards).
  final Color? leftBar;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return Container(
      decoration: BoxDecoration(
        color: p.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: p.border),
        boxShadow: [BoxShadow(color: p.shadow, blurRadius: 2, offset: const Offset(0, 1))],
      ),
      clipBehavior: Clip.antiAlias,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          child: IntrinsicHeight(
            child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              if (leftBar != null) Container(width: 3, color: leftBar),
              Expanded(child: Padding(padding: padding, child: child)),
            ]),
          ),
        ),
      ),
    );
  }
}

/// Rows inside one card, separated by hairlines (the design's lists).
class GroupCard extends StatelessWidget {
  const GroupCard({super.key, required this.children});
  final List<Widget> children;
  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return Container(
      decoration: BoxDecoration(
        color: p.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: p.border),
        boxShadow: [BoxShadow(color: p.shadow, blurRadius: 2, offset: const Offset(0, 1))],
      ),
      clipBehavior: Clip.antiAlias,
      child: Material(
        color: Colors.transparent,
        child: Column(children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0) Divider(height: 1, thickness: 1, color: p.hairline),
            children[i],
          ],
        ]),
      ),
    );
  }
}

/// "Recent sessions          All >" — a section title with an optional link.
class SectionHeader extends StatelessWidget {
  const SectionHeader(this.title, {super.key, this.trailing, this.action, this.onAction, this.leading});
  final String title;
  final Widget? leading;

  /// Plain trailing text (mono), e.g. "4 daemons".
  final String? trailing;
  final String? action;
  final VoidCallback? onAction;
  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 18, 2, 8),
      child: Row(children: [
        if (leading != null) ...[leading!, const SizedBox(width: 6)],
        Expanded(
          child: Semantics(
            header: true,
            child: Text(title,
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: p.secondary)),
          ),
        ),
        if (trailing != null) Text(trailing!, style: mono(context, size: 12)),
        if (action != null)
          InkWell(
            onTap: onAction,
            borderRadius: BorderRadius.circular(6),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 32, minWidth: 44),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Text(action!,
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: p.brandText)),
                Icon(AppIcons.chevronRight, size: 18, color: p.brandText),
              ]),
            ),
          ),
      ]),
    );
  }
}

/// Old upper-case label, kept for Settings.
class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key});
  final String text;
  @override
  Widget build(BuildContext context) => SectionHeader(text);
}

/// Small rounded label: "Bash", "online", "Built-in".
class Pill extends StatelessWidget {
  const Pill(this.text, {super.key, this.fg, this.bg, this.monoText = false});
  final String text;
  final Color? fg;
  final Color? bg;
  final bool monoText;
  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final style = monoText
        ? mono(context, size: 11, color: fg ?? p.secondary, weight: FontWeight.w500)
        : TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: fg ?? p.secondary);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(color: bg ?? p.sunken, borderRadius: BorderRadius.circular(999)),
      child: Text(text, style: style),
    );
  }
}

/// Kept name for older call sites.
class Chip8 extends StatelessWidget {
  const Chip8(this.text, {super.key, this.fg, this.bg});
  final String text;
  final Color? fg;
  final Color? bg;
  @override
  Widget build(BuildContext context) => Pill(text, fg: fg, bg: bg);
}

Color healthColor(Palette p, AgentHealth h) => switch (h) {
      AgentHealth.online => p.online,
      AgentHealth.paused => p.paused,
      AgentHealth.offline => p.error,
    };

/// Status pill of a machine: online / paused / offline.
class HealthPill extends StatelessWidget {
  const HealthPill(this.health, this.label, {super.key});
  final AgentHealth health;
  final String label;
  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final (fg, bg) = switch (health) {
      AgentHealth.online => (p.online, p.onlineSoft),
      AgentHealth.paused => (p.paused, p.pausedSoft),
      AgentHealth.offline => (p.error, p.errorSoft),
    };
    return Pill(label, fg: fg, bg: bg);
  }
}

/// Dot in the corner of an avatar. [color] null = idle gray.
class StatusDot extends StatelessWidget {
  const StatusDot({super.key, this.color, this.size = 9});
  final Color? color;
  final double size;
  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color ?? p.idle,
        shape: BoxShape.circle,
        border: Border.all(color: p.surface, width: 1.5),
      ),
    );
  }
}

/// Agent avatar: its icon when the server has one, otherwise a mark for the
/// runtime, with an optional status dot.
class AgentAvatar extends StatelessWidget {
  const AgentAvatar({
    super.key,
    this.iconUrl,
    this.runtime,
    this.name = '',
    this.size = 34,
    this.dot,
    this.showDot = true,
  });
  final String? iconUrl;
  final String? runtime;
  final String name;
  final double size;

  /// Status dot color; null = idle.
  final Color? dot;
  final bool showDot;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    Widget fallback() => RuntimeMark(runtime: runtime, name: name, size: size);
    final url = iconUrl;
    final inner = ClipRRect(
      borderRadius: BorderRadius.circular(size * 0.24),
      child: SizedBox(
        width: size,
        height: size,
        child: url != null && url.startsWith('https://')
            ? Image.network(url,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => fallback(),
                // Icons are public images; no credential is sent.
                headers: const {'User-Agent': 'AgentConnect-iOS/1.0'})
            : fallback(),
      ),
    );
    return SizedBox(
      width: size + 3,
      height: size + 3,
      child: Stack(clipBehavior: Clip.none, children: [
        Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(size * 0.24),
            border: Border.all(color: p.border),
          ),
          child: inner,
        ),
        if (showDot)
          Positioned(right: 0, bottom: 0, child: StatusDot(color: dot, size: size * 0.28)),
      ]),
    );
  }
}

/// Generic mark per runtime family (not a vendor logo): a coral starburst for
/// Claude runtimes, a dark tile with a ring for Codex, otherwise the initial.
class RuntimeMark extends StatelessWidget {
  const RuntimeMark({super.key, this.runtime, this.name = '', this.size = 34});
  final String? runtime;
  final String name;
  final double size;
  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final r = (runtime ?? '').toLowerCase();
    if (r.contains('claude')) {
      return ColoredBox(
        color: p.surface,
        child: CustomPaint(painter: _BurstPainter(const Color(0xFFE8624C))),
      );
    }
    if (r.contains('codex')) {
      return ColoredBox(
        color: const Color(0xFF11161D),
        child: Center(
          child: Icon(AppIcons.blurCircular, size: size * 0.62, color: Colors.white),
        ),
      );
    }
    final initial = name.isEmpty ? '?' : name.characters.first.toUpperCase();
    return ColoredBox(
      color: p.brandSoft,
      child: Center(
        child: Text(initial,
            style: TextStyle(
                fontSize: size * 0.45, fontWeight: FontWeight.w700, color: p.brandText)),
      ),
    );
  }
}

class _BurstPainter extends CustomPainter {
  _BurstPainter(this.color);
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.shortestSide * 0.36;
    final paint = Paint()
      ..color = color
      ..strokeWidth = size.shortestSide * 0.075
      ..strokeCap = StrokeCap.round;
    for (var i = 0; i < 12; i++) {
      final a = i * 3.14159265 / 6;
      final len = i.isEven ? r : r * 0.78;
      canvas.drawLine(c, c + Offset.fromDirection(a, len), paint);
    }
  }

  @override
  bool shouldRepaint(_BurstPainter o) => o.color != color;
}

/// The AgentConnect diamond (four colored facets).
class BrandMark extends StatelessWidget {
  const BrandMark({super.key, this.size = 22});
  final double size;
  @override
  Widget build(BuildContext context) =>
      SizedBox(width: size, height: size, child: CustomPaint(painter: _DiamondPainter()));
}

class _DiamondPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size s) {
    final c = s.center(Offset.zero);
    final top = Offset(c.dx, 0), right = Offset(s.width, c.dy);
    final bottom = Offset(c.dx, s.height), left = Offset(0, c.dy);
    void tri(Offset a, Offset b, Color col) =>
        canvas.drawPath(Path()..moveTo(a.dx, a.dy)..lineTo(b.dx, b.dy)..lineTo(c.dx, c.dy)..close(),
            Paint()..color = col);
    tri(left, top, const Color(0xFFC62A78));
    tri(top, right, const Color(0xFFE0A30F));
    tri(right, bottom, const Color(0xFFE8624C));
    tri(bottom, left, const Color(0xFF7D46C0));
  }

  @override
  bool shouldRepaint(_DiamondPainter o) => false;
}

/// Small glyph for where a conversation lives.
class SourceGlyph extends StatelessWidget {
  const SourceGlyph(this.source, {super.key, this.size = 12});
  final String source;
  final double size;
  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return switch (source) {
      'chat' => BrandMark(size: size),
      'slack' => Icon(AppIcons.tag, size: size + 1, color: const Color(0xFF4A154B)),
      'telegram' => Icon(AppIcons.send, size: size, color: const Color(0xFF229ED9)),
      'discord' => Icon(AppIcons.headsetMic, size: size, color: const Color(0xFF5865F2)),
      'github' => Icon(AppIcons.code, size: size + 1, color: p.ink),
      _ => Icon(AppIcons.forumOutlined, size: size, color: p.tertiary),
    };
  }
}

/// iOS-style segmented control on a sunken track.
class Segmented<T> extends StatelessWidget {
  const Segmented({super.key, required this.items, required this.value, required this.onChanged});
  final List<(T, String)> items;
  final T value;
  final ValueChanged<T> onChanged;
  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
          color: p.sunken,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: p.hairline)),
      child: Row(children: [
        for (final (v, label) in items)
          Expanded(
            child: Semantics(
              selected: v == value,
              button: true,
              child: GestureDetector(
                onTap: () {
                  if (v != value) Haptics.selection();
                  onChanged(v);
                },
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  height: 36,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: v == value ? p.surface : Colors.transparent,
                    borderRadius: BorderRadius.circular(8),
                    boxShadow: v == value
                        ? [BoxShadow(color: p.shadow, blurRadius: 3, offset: const Offset(0, 1))]
                        : null,
                  ),
                  child: Text(label,
                      style: TextStyle(
                          fontSize: 14,
                          fontWeight: v == value ? FontWeight.w600 : FontWeight.w500,
                          color: v == value ? p.ink : p.secondary)),
                ),
              ),
            ),
          ),
      ]),
    );
  }
}

/// Thin usage bar (CPU). Amber above 60 %, red above 85 %.
class UsageBar extends StatelessWidget {
  const UsageBar({super.key, this.value});

  /// 0–100, null = no signal.
  final double? value;
  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final v = (value ?? 0).clamp(0, 100) / 100;
    final color = (value ?? 0) > 85
        ? p.error
        : (value ?? 0) > 60
            ? p.paused
            : p.online;
    return ClipRRect(
      borderRadius: BorderRadius.circular(999),
      child: SizedBox(
        height: 6,
        child: Stack(children: [
          Positioned.fill(child: ColoredBox(color: p.sunken)),
          FractionallySizedBox(
            alignment: Alignment.centerLeft,
            widthFactor: v.toDouble(),
            heightFactor: 1,
            child: ColoredBox(color: color),
          ),
        ]),
      ),
    );
  }
}

class StateView extends StatelessWidget {
  const StateView({
    super.key,
    required this.icon,
    required this.title,
    this.body,
    this.actionLabel,
    this.onAction,
  });
  final IconData icon;
  final String title;
  final String? body;
  final String? actionLabel;
  final VoidCallback? onAction;
  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return Center(
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 40, color: p.tertiary),
          const SizedBox(height: 14),
          Text(title,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
          if (body != null) ...[
            const SizedBox(height: 6),
            Text(body!, textAlign: TextAlign.center, style: TextStyle(color: p.secondary, fontSize: 14)),
          ],
          if (actionLabel != null) ...[
            const SizedBox(height: 18),
            OutlinedButton(onPressed: onAction, child: Text(actionLabel!)),
          ],
        ]),
      ),
    );
  }
}
