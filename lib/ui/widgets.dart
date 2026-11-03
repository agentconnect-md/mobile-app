import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../l10n/app_localizations.dart';
import 'theme.dart';

class AppCard extends StatelessWidget {
  const AppCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.onTap,
    this.leftBar,
  });
  final Widget child;
  final EdgeInsets padding;
  final VoidCallback? onTap;
  final Color? leftBar;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final shadow = Theme.of(context).brightness == Brightness.light
        ? const Color(0x141A212B)
        : const Color(0x66000000);
    return Container(
      decoration: BoxDecoration(
        color: p.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: p.hairline),
        boxShadow: [BoxShadow(color: shadow, blurRadius: 12, offset: const Offset(0, 3))],
      ),
      clipBehavior: Clip.antiAlias,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          child: IntrinsicHeight(
            child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              if (leftBar != null) Container(width: 4, color: leftBar),
              Expanded(child: Padding(padding: padding, child: child)),
            ]),
          ),
        ),
      ),
    );
  }
}

class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key});
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 20, 4, 8),
        child: Text(
          text.toUpperCase(),
          style: TextStyle(
            fontFamily: monoFamily,
            fontFamilyFallback: monoFallback,
            fontSize: 12,
            letterSpacing: 1.4,
            fontWeight: FontWeight.w600,
            color: context.pal.secondary,
          ),
        ),
      );
}

class Chip8 extends StatelessWidget {
  const Chip8(this.text, {super.key, this.fg, this.bg});
  final String text;
  final Color? fg;
  final Color? bg;
  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
          color: bg ?? p.sunken, borderRadius: BorderRadius.circular(8)),
      child: Text(text,
          style: TextStyle(
              fontSize: 12, fontWeight: FontWeight.w600, color: fg ?? p.secondary)),
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
          Icon(icon, size: 44, color: p.secondary),
          const SizedBox(height: 16),
          Text(title,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
          if (body != null) ...[
            const SizedBox(height: 8),
            Text(body!,
                textAlign: TextAlign.center,
                style: TextStyle(color: p.secondary, fontSize: 15)),
          ],
          if (actionLabel != null) ...[
            const SizedBox(height: 20),
            FilledButton(onPressed: onAction, child: Text(actionLabel!)),
          ],
        ]),
      ),
    );
  }
}

/// The "Made with AirBuild" credit. The logo is the template's SVG path,
/// drawn by hand (it only uses M, C, H, V and Z commands).
class MadeWithAirBuild extends StatefulWidget {
  const MadeWithAirBuild({super.key});
  @override
  State<MadeWithAirBuild> createState() => _MadeWithAirBuildState();
}

class _MadeWithAirBuildState extends State<MadeWithAirBuild> {
  Path? _path;

  @override
  void initState() {
    super.initState();
    rootBundle.loadString('assets/MadeWithAirBuild.svg').then((s) {
      final m = RegExp(r'd="([^"]+)"').firstMatch(s);
      if (m != null && mounted) setState(() => _path = parseSimplePath(m.group(1)!));
    });
  }

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final text = AppLocalizations.of(context).madeWithAirBuild;
    return Semantics(
      link: true,
      label: text,
      child: InkWell(
        onTap: () => launchUrl(
            Uri.parse(
                'https://air.build/?utm_source=made-with-airbuild&utm_medium=ios-app'),
            mode: LaunchMode.externalApplication),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 44),
          child: Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                SizedBox(
                  width: 24,
                  height: 24,
                  child: _path == null
                      ? null
                      : CustomPaint(painter: _LogoPainter(_path!, p.secondary)),
                ),
                const SizedBox(height: 6),
                ExcludeSemantics(
                  child: Text(text,
                      style: TextStyle(fontSize: 13, color: p.secondary)),
                ),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

class _LogoPainter extends CustomPainter {
  _LogoPainter(this.path, this.color);
  final Path path;
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 256, size.height / 256);
    canvas.drawPath(path, Paint()..color = color);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_LogoPainter o) => o.path != path || o.color != color;
}

/// Parses an SVG path using only M, C, H, V, Z (absolute commands).
Path parseSimplePath(String d) {
  final path = Path()..fillType = PathFillType.evenOdd;
  final tokens = RegExp(r'[MCHVZ]|-?\d*\.?\d+(?:e-?\d+)?').allMatches(d).map((m) => m.group(0)!).toList();
  var i = 0;
  var cmd = '';
  double x = 0, y = 0;
  double n() => double.parse(tokens[i++]);
  while (i < tokens.length) {
    final t = tokens[i];
    if (RegExp(r'[MCHVZ]').hasMatch(t)) {
      cmd = t;
      i++;
      if (cmd == 'Z') {
        path.close();
        continue;
      }
    }
    switch (cmd) {
      case 'M':
        x = n();
        y = n();
        path.moveTo(x, y);
        cmd = 'L';
      case 'L':
        x = n();
        y = n();
        path.lineTo(x, y);
      case 'H':
        x = n();
        path.lineTo(x, y);
      case 'V':
        y = n();
        path.lineTo(x, y);
      case 'C':
        final x1 = n(), y1 = n(), x2 = n(), y2 = n();
        x = n();
        y = n();
        path.cubicTo(x1, y1, x2, y2, x, y);
      default:
        i++;
    }
  }
  return path;
}
