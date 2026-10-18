import 'package:flutter/material.dart';

/// Design tokens from the approved tablet mockup. Chrome stays light; only the
/// canvas follows the chosen canvas theme.
abstract final class Tokens {
  static const sans = 'IBM Plex Sans';
  static const mono = 'IBM Plex Mono';

  static const chrome = Color(0xFFF7F8F9);
  static const chromeAlt = Color(0xFFEEF1F4);
  static const border = Color(0xFFD4D9E0);
  static const control = Color(0xFFC3CAD3);
  static const windowBorder = Color(0xFFB7BFCA);
  static const ink = Color(0xFF1B2129);
  static const text = Color(0xFF2B323C);
  static const muted = Color(0xFF5B6573);
  static const faint = Color(0xFF6B7480);
  static const accent = Color(0xFF1F5FD1);
  static const accentText = Color(0xFF1D4FA8);
  static const selected = Color(0xFFE1E8F3);
  static const terminal = Color(0xFF10151C);
  static const terminalText = Color(0xFFD3DAE3);
  static const terminalPrompt = Color(0xFF8FA3BC);

  static const linkUp = Color(0xFF1A9E5A);
  static const linkStarting = Color(0xFFD98A00);
  static const linkDown = Color(0xFFC8322B);

  static const radius = 4.0;
}

enum CanvasPattern { grid, dots, plain }

enum CanvasTheme { light, blueprint, dark }

/// Colours that depend on the canvas theme.
class CanvasColors {
  const CanvasColors({
    required this.background,
    required this.minor,
    required this.major,
    required this.cable,
    required this.serial,
    required this.console,
    required this.icon,
    required this.label,
    required this.subLabel,
  });

  factory CanvasColors.of(CanvasTheme theme) => switch (theme) {
    CanvasTheme.light => const CanvasColors(
      background: Color(0xFFF1F3F6),
      minor: Color(0xFFE2E6EB),
      major: Color(0xFFCCD3DB),
      cable: Color(0xFF4A5563),
      serial: Color(0xFFC2410C),
      console: Color(0xFF0E7490),
      icon: Color(0xFF1A7CF0),
      label: Color(0xFF1B2129),
      subLabel: Color(0xFF4A5563),
    ),
    CanvasTheme.blueprint => const CanvasColors(
      background: Color(0xFF123459),
      minor: Color(0x12FFFFFF),
      major: Color(0x2BFFFFFF),
      cable: Color(0xFFB7CBE6),
      serial: Color(0xFFF08A5D),
      console: Color(0xFF5CC8E0),
      icon: Color(0xFF5AA9FF),
      label: Color(0xFFE6EBF1),
      subLabel: Color(0xFFAEB8C5),
    ),
    CanvasTheme.dark => const CanvasColors(
      background: Color(0xFF161B22),
      minor: Color(0xFF1F262F),
      major: Color(0xFF2C3542),
      cable: Color(0xFF9AA6B6),
      serial: Color(0xFFF08A5D),
      console: Color(0xFF5CC8E0),
      icon: Color(0xFF5AA9FF),
      label: Color(0xFFE6EBF1),
      subLabel: Color(0xFFAEB8C5),
    ),
  };

  final Color background;
  final Color minor;
  final Color major;
  final Color cable;
  final Color serial;
  final Color console;
  final Color icon;
  final Color label;
  final Color subLabel;

  /// Text shadows that lift labels off cables and grid lines.
  List<Shadow> get halo => [
    for (final blur in const [2.0, 2.0, 3.0, 4.0])
      Shadow(color: background, blurRadius: blur),
  ];
}

ThemeData buildTheme() {
  const base = TextStyle(fontFamily: Tokens.sans, color: Tokens.ink);
  return ThemeData(
    useMaterial3: true,
    fontFamily: Tokens.sans,
    colorScheme: ColorScheme.fromSeed(
      seedColor: Tokens.accent,
      primary: Tokens.accent,
      surface: Colors.white,
    ),
    scaffoldBackgroundColor: Tokens.chrome,
    textTheme: const TextTheme(
      bodyMedium: TextStyle(fontSize: 13),
      bodySmall: TextStyle(fontSize: 12),
      labelLarge: TextStyle(fontSize: 13),
    ).apply(fontFamily: base.fontFamily, bodyColor: Tokens.ink),
    dividerColor: Tokens.border,
    menuTheme: const MenuThemeData(
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(Colors.white),
        elevation: WidgetStatePropertyAll(4),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(Tokens.radius)),
            side: BorderSide(color: Tokens.windowBorder),
          ),
        ),
        padding: WidgetStatePropertyAll(EdgeInsets.symmetric(vertical: 4)),
      ),
    ),
    menuButtonTheme: const MenuButtonThemeData(
      style: ButtonStyle(
        textStyle: WidgetStatePropertyAll(
          TextStyle(fontFamily: Tokens.sans, fontSize: 13),
        ),
        minimumSize: WidgetStatePropertyAll(Size(180, 34)),
        padding: WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 12)),
        shape: WidgetStatePropertyAll(RoundedRectangleBorder()),
      ),
    ),
    tooltipTheme: const TooltipThemeData(
      decoration: BoxDecoration(
        color: Tokens.ink,
        borderRadius: BorderRadius.all(Radius.circular(Tokens.radius)),
      ),
      textStyle: TextStyle(fontSize: 12, color: Colors.white),
    ),
  );
}
