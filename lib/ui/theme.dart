import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'platform.dart';

/// Design tokens of the "AgentConnect Mobile Lite" design (gray scale,
/// magenta brand, status colors; dark mode is the console's plum tone).
@immutable
class Palette extends ThemeExtension<Palette> {
  const Palette({
    required this.canvas,
    required this.surface,
    required this.sunken,
    required this.hover,
    required this.hairline,
    required this.border,
    required this.borderStrong,
    required this.accent,
    required this.accentPressed,
    required this.brandSoft,
    required this.brandText,
    required this.ink,
    required this.secondary,
    required this.tertiary,
    required this.link,
    required this.online,
    required this.onlineSoft,
    required this.paused,
    required this.pausedSoft,
    required this.error,
    required this.errorSoft,
    required this.idle,
    required this.idleSoft,
    required this.info,
    required this.infoSoft,
    required this.agentBubble,
    required this.agentBubbleBorder,
    required this.agentName,
    required this.shadow,
  });

  /// App background (`--surface-app`).
  final Color canvas;

  /// Cards (`--surface-card`).
  final Color surface;

  /// Code boxes, segmented tracks (`--surface-sunken`).
  final Color sunken;
  final Color hover;

  /// Dividers inside cards (`--border-subtle`).
  final Color hairline;

  /// Card and control borders (`--border-default`).
  final Color border;
  final Color borderStrong;
  final Color accent, accentPressed, brandSoft, brandText;
  final Color ink, secondary, tertiary, link;
  final Color online, onlineSoft, paused, pausedSoft, error, errorSoft;
  final Color idle, idleSoft, info, infoSoft;
  final Color agentBubble, agentBubbleBorder, agentName;
  final Color shadow;

  // Older names kept for widgets that use them.
  Color get success => online;
  Color get amberBar => paused;
  Color get amberText => paused;
  Color get amberBg => pausedSoft;

  static const light = Palette(
    canvas: Color(0xFFFAFBFC),
    surface: Color(0xFFFFFFFF),
    sunken: Color(0xFFF4F6F8),
    hover: Color(0xFFF4F6F8),
    hairline: Color(0xFFE4E8ED),
    border: Color(0xFFDBE0E6),
    borderStrong: Color(0xFFC5CDD6),
    accent: Color(0xFFC62A78),
    accentPressed: Color(0xFFA82165),
    brandSoft: Color(0xFFFCEBF3),
    brandText: Color(0xFF8A1A53),
    ink: Color(0xFF1A212B),
    secondary: Color(0xFF525D6B),
    tertiary: Color(0xFF6F7B8A),
    link: Color(0xFF2F6FED),
    online: Color(0xFF15A661),
    onlineSoft: Color(0xFFE9F9F0),
    paused: Color(0xFFE0930F),
    pausedSoft: Color(0xFFFDF5E3),
    error: Color(0xFFDC4B4B),
    errorSoft: Color(0xFFFDECEC),
    idle: Color(0xFF9AA4B1),
    idleSoft: Color(0xFFECEFF3),
    info: Color(0xFF2F6FED),
    infoSoft: Color(0xFFEBF1FE),
    agentBubble: Color(0xFFEBF1FE),
    agentBubbleBorder: Color(0xFFC9DAFB),
    agentName: Color(0xFF1E4FB8),
    shadow: Color(0x0F11161D),
  );

  static const dark = Palette(
    canvas: Color(0xFF17101F),
    surface: Color(0xFF211829),
    sunken: Color(0xFF120C1A),
    hover: Color(0xFF271D34),
    hairline: Color(0xFF2A2137),
    border: Color(0xFF372B47),
    borderStrong: Color(0xFF493A5D),
    accent: Color(0xFFC62A78),
    accentPressed: Color(0xFFA82165),
    brandSoft: Color(0x29C62A78),
    brandText: Color(0xFFF4B8D3),
    ink: Color(0xFFEDEFF3),
    secondary: Color(0xFFA6AFBC),
    tertiary: Color(0xFF7E8996),
    link: Color(0xFF7AA7FF),
    online: Color(0xFF2EC27E),
    onlineSoft: Color(0x292EC27E),
    paused: Color(0xFFEAA93A),
    pausedSoft: Color(0x29EAA93A),
    error: Color(0xFFEF6B6B),
    errorSoft: Color(0x29EF6B6B),
    idle: Color(0xFF6B7684),
    idleSoft: Color(0x0FFFFFFF),
    info: Color(0xFF6A97F5),
    infoSoft: Color(0x296A97F5),
    agentBubble: Color(0x296A97F5),
    agentBubbleBorder: Color(0x406A97F5),
    agentName: Color(0xFF8FB2FA),
    shadow: Color(0x66000000),
  );

  @override
  Palette copyWith() => this;
  @override
  Palette lerp(ThemeExtension<Palette>? other, double t) =>
      t < 0.5 ? this : (other as Palette? ?? this);
}

extension PaletteX on BuildContext {
  Palette get pal => Theme.of(this).extension<Palette>()!;
}

const sansFamily = 'Geist';
const monoFamily = 'GeistMono';
const monoFallback = ['Menlo', 'Courier', 'monospace'];

/// Monospaced meta text (times, sources, models), like the design's `--font-mono`.
TextStyle mono(BuildContext c, {double size = 12, Color? color, FontWeight? weight}) =>
    TextStyle(
      fontFamily: monoFamily,
      fontFamilyFallback: monoFallback,
      fontSize: size,
      fontWeight: weight,
      color: color ?? c.pal.tertiary,
    );

ThemeData buildTheme(Brightness b) {
  final p = b == Brightness.light ? Palette.light : Palette.dark;
  final scheme = ColorScheme(
    brightness: b,
    primary: p.accent,
    onPrimary: Colors.white,
    secondary: p.ink,
    onSecondary: p.canvas,
    error: p.error,
    onError: Colors.white,
    surface: p.surface,
    onSurface: p.ink,
    onSurfaceVariant: p.secondary,
    outline: p.border,
    outlineVariant: p.hairline,
    surfaceContainerHighest: p.sunken,
    surfaceContainerHigh: p.sunken,
    surfaceContainer: p.surface,
    surfaceContainerLow: p.surface,
    surfaceContainerLowest: p.canvas,
  );
  final r10 = RoundedRectangleBorder(borderRadius: BorderRadius.circular(10));
  final base = ThemeData(useMaterial3: true, brightness: b, fontFamily: sansFamily);
  // iOS follows the Human Interface Guidelines where they differ from Material:
  // no ink ripple (a pressed row dims instead), a 44 pt navigation bar with a
  // centered 17 pt title, and a floating notice in place of the full-width bar.
  final ios = isIOS;
  // The Mac is a pointer platform: no ripple either (rows show hover and
  // dim when pressed), a compact toolbar under the window's title bar,
  // smaller controls than a finger needs, and no page slide.
  final mac = isMacOS;
  return base.copyWith(
    colorScheme: scheme,
    scaffoldBackgroundColor: p.canvas,
    extensions: [p],
    dividerColor: p.hairline,
    textTheme: base.textTheme.apply(bodyColor: p.ink, displayColor: p.ink),
    splashFactory: ios || mac ? NoSplash.splashFactory : InkSparkle.splashFactory,
    splashColor: ios || mac ? Colors.transparent : null,
    highlightColor: ios || mac ? p.ink.withValues(alpha: 0.06) : null,
    hoverColor: mac ? p.ink.withValues(alpha: 0.04) : null,
    pageTransitionsTheme: mac
        ? const PageTransitionsTheme(builders: {TargetPlatform.macOS: _NoPageTransition()})
        : null,
    tooltipTheme: mac ? const TooltipThemeData(waitDuration: Duration(milliseconds: 600)) : null,
    appBarTheme: AppBarTheme(
      backgroundColor: p.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      foregroundColor: p.ink,
      centerTitle: ios,
      toolbarHeight: ios ? 44 : (mac ? desktopToolbarHeight : null),
      shape: Border(bottom: BorderSide(color: p.hairline)),
      titleTextStyle: TextStyle(
          fontFamily: sansFamily,
          color: p.ink,
          fontSize: ios ? 17 : (mac ? 15 : 20),
          fontWeight: FontWeight.w600,
          letterSpacing: ios ? -0.4 : -0.2),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: p.surface,
      surfaceTintColor: Colors.transparent,
      indicatorColor: Colors.transparent,
      height: 64,
      iconTheme: WidgetStateProperty.resolveWith((s) => IconThemeData(
          size: 24, color: s.contains(WidgetState.selected) ? p.accent : p.secondary)),
      labelTextStyle: WidgetStateProperty.resolveWith((s) => TextStyle(
          fontFamily: sansFamily,
          fontSize: 12,
          fontWeight: FontWeight.w500,
          color: s.contains(WidgetState.selected) ? p.accent : p.secondary)),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: Size(64, mac ? 34 : 44),
        shape: r10,
        backgroundColor: p.accent,
        foregroundColor: Colors.white,
        disabledBackgroundColor: p.accent.withValues(alpha: 0.4),
        disabledForegroundColor: Colors.white,
        textStyle: const TextStyle(
            fontFamily: sansFamily, fontWeight: FontWeight.w600, fontSize: 15),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: Size(64, mac ? 34 : 44),
        shape: r10,
        foregroundColor: p.ink,
        backgroundColor: p.surface,
        side: BorderSide(color: p.border),
        textStyle: const TextStyle(
            fontFamily: sansFamily, fontWeight: FontWeight.w600, fontSize: 15),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        minimumSize: mac ? const Size(44, 32) : const Size(44, 44),
        shape: r10,
        foregroundColor: p.brandText,
        textStyle: const TextStyle(fontFamily: sansFamily, fontWeight: FontWeight.w500),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: p.surface,
      border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: p.border)),
      enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: p.border)),
      focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: p.accent, width: 1.5)),
      hintStyle: TextStyle(color: p.tertiary),
    ),
    switchTheme: SwitchThemeData(
      trackColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? p.accent : p.sunken),
      thumbColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? Colors.white : p.secondary),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: p.canvas,
      surfaceTintColor: Colors.transparent,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: p.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: p.accent),
    snackBarTheme: ios
        ? SnackBarThemeData(
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          )
        : mac
            // A small notice in the pane it belongs to, not a bar across the window.
            ? SnackBarThemeData(
                behavior: SnackBarBehavior.floating,
                width: 320,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              )
            : null,
    badgeTheme: BadgeThemeData(
      backgroundColor: p.paused,
      textColor: Colors.white,
      textStyle: const TextStyle(
          fontFamily: sansFamily, fontSize: 10, fontWeight: FontWeight.w700),
    ),
  );
}

/// Title of a root tab screen. iOS shows it as a large, left-aligned title
/// (see [rootAppBarHeight]); elsewhere it is the app bar's normal title.
Widget rootTitle(String text) => isIOS
    ? Text(text, style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w700, letterSpacing: -0.6))
    : Text(text);

/// Toolbar height for a root tab screen's large title (iOS only).
double? get rootAppBarHeight => isIOS ? 52 : null;

/// Alignment of a two-line navigation title: centered on iOS, like its
/// one-line titles; left-aligned elsewhere.
CrossAxisAlignment get navTitleAlign => isIOS ? CrossAxisAlignment.center : CrossAxisAlignment.start;

/// Height of a screen's toolbar on the Mac, under the window's title bar.
const double desktopToolbarHeight = 46;

/// Screens change in place on the Mac, as they do in its own apps.
class _NoPageTransition extends PageTransitionsBuilder {
  const _NoPageTransition();
  @override
  Widget buildTransitions<T>(PageRoute<T> route, BuildContext context, Animation<double> animation,
          Animation<double> secondaryAnimation, Widget child) =>
      child;
}

/// Padding of a scrolling column. On a phone, [base] itself. On the Mac the
/// side padding grows so the content keeps a readable width ([max]) in the
/// middle of a wide pane, while the scroll area (and its scrollbar) still
/// spans the pane.
EdgeInsets readablePadding(BuildContext context, EdgeInsets base, {double max = 780}) {
  if (!isMacOS) return base;
  final side = math.max(0.0, (MediaQuery.sizeOf(context).width - max) / 2);
  return base.copyWith(left: math.max(base.left, side), right: math.max(base.right, side));
}

/// Space before a navigation title that normally follows a back button. On
/// the Mac a detail page beside its list has no back button, so the title
/// gets the usual margin instead of sitting on the divider.
double navTitleSpacing(BuildContext context) =>
    isMacOS && !(ModalRoute.of(context)?.canPop ?? false) ? 16 : 0;
