import 'package:flutter/material.dart';

/// Design tokens that Material's ColorScheme has no slot for.
@immutable
class Palette extends ThemeExtension<Palette> {
  const Palette({
    required this.canvas,
    required this.surface,
    required this.sunken,
    required this.hairline,
    required this.accent,
    required this.ink,
    required this.secondary,
    required this.amberBar,
    required this.amberText,
    required this.amberBg,
    required this.success,
    required this.error,
  });
  final Color canvas, surface, sunken, hairline, accent, ink, secondary;
  final Color amberBar, amberText, amberBg, success, error;

  static const light = Palette(
    canvas: Color(0xFFF3EBDC),
    surface: Color(0xFFFDFAF3),
    sunken: Color(0xFFF8F2E7),
    hairline: Color(0xFFE3D9C5),
    accent: Color(0xFFC62A78),
    ink: Color(0xFF1A212B),
    secondary: Color(0xFF525D6B),
    amberBar: Color(0xFFE0A526),
    amberText: Color(0xFF8A5A00),
    amberBg: Color(0xFFFBEACB),
    success: Color(0xFF1E9E6A),
    error: Color(0xFFB3261E),
  );
  static const dark = Palette(
    canvas: Color(0xFF14110F),
    surface: Color(0xFF211C18),
    sunken: Color(0xFF2C2620),
    hairline: Color(0xFF3A322A),
    accent: Color(0xFFE8509A),
    ink: Color(0xFFF3EBDC),
    secondary: Color(0xFFB3A6C2),
    amberBar: Color(0xFFE0A526),
    amberText: Color(0xFFF2C46B),
    amberBg: Color(0xFF3A2E12),
    success: Color(0xFF3CC48C),
    error: Color(0xFFF2766E),
  );

  @override
  Palette copyWith() => this;
  @override
  Palette lerp(ThemeExtension<Palette>? other, double t) => this;
}

extension PaletteX on BuildContext {
  Palette get pal => Theme.of(this).extension<Palette>()!;
}

const monoFamily = 'Menlo';
const monoFallback = ['Courier', 'monospace'];

ThemeData buildTheme(Brightness b) {
  final p = b == Brightness.light ? Palette.light : Palette.dark;
  final onAccent = b == Brightness.light ? Colors.white : const Color(0xFF14110F);
  final scheme = ColorScheme(
    brightness: b,
    primary: p.accent,
    onPrimary: onAccent,
    secondary: p.ink,
    onSecondary: p.canvas,
    error: p.error,
    onError: Colors.white,
    surface: p.surface,
    onSurface: p.ink,
    onSurfaceVariant: p.secondary,
    outline: p.hairline,
    outlineVariant: p.hairline,
    surfaceContainerHighest: p.sunken,
    surfaceContainerHigh: p.sunken,
    surfaceContainer: p.surface,
    surfaceContainerLow: p.surface,
    surfaceContainerLowest: p.canvas,
  );
  final shape14 = RoundedRectangleBorder(borderRadius: BorderRadius.circular(14));
  const minSize = Size(64, 48);
  return ThemeData(
    useMaterial3: true,
    brightness: b,
    colorScheme: scheme,
    scaffoldBackgroundColor: p.canvas,
    extensions: [p],
    dividerColor: p.hairline,
    appBarTheme: AppBarTheme(
      backgroundColor: p.canvas,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      foregroundColor: p.ink,
      titleTextStyle: TextStyle(
          color: p.ink, fontSize: 20, fontWeight: FontWeight.w700),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: p.surface,
      surfaceTintColor: Colors.transparent,
      indicatorColor: p.accent.withValues(alpha: 0.14),
      iconTheme: WidgetStateProperty.resolveWith((s) => IconThemeData(
          color: s.contains(WidgetState.selected) ? p.accent : p.secondary)),
      labelTextStyle: WidgetStateProperty.resolveWith((s) => TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: s.contains(WidgetState.selected) ? p.accent : p.secondary)),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: minSize,
        shape: shape14,
        backgroundColor: p.accent,
        foregroundColor: onAccent,
        textStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: minSize,
        shape: shape14,
        foregroundColor: p.ink,
        side: BorderSide(color: p.hairline),
        textStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        minimumSize: const Size(48, 48),
        shape: shape14,
        foregroundColor: p.accent,
        textStyle: const TextStyle(fontWeight: FontWeight.w600),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: p.surface,
      border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: p.hairline)),
      enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: p.hairline)),
      focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: p.accent, width: 2)),
      hintStyle: TextStyle(color: p.secondary.withValues(alpha: 0.7)),
    ),
    switchTheme: SwitchThemeData(
      trackColor: WidgetStateProperty.resolveWith((s) =>
          s.contains(WidgetState.selected) ? p.accent : p.sunken),
      thumbColor: WidgetStateProperty.resolveWith((s) =>
          s.contains(WidgetState.selected) ? onAccent : p.secondary),
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
  );
}
