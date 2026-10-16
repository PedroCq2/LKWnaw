import 'package:flutter/material.dart';

/// Barvy LKWnav: grafitová kabina + signální jantarová.
class Lkw {
  static const graphite = Color(0xFF15181D);
  static const panel = Color(0xFF20252C);
  static const panelHi = Color(0xFF2B313A);
  static const amber = Color(0xFFFFB000);
  static const amberDark = Color(0xFF8A5E00);
  static const text = Colors.white;
  static const muted = Color(0xFF9AA3AE);
  static const danger = Color(0xFFE53935);
  static const ok = Color(0xFF43C46B);

  static const routeLine = '#FFB000';
  static const routeCasing = '#6B4500';
  static const altLine = '#8C97A6';
  static const altCasing = '#4A535F';

  static ThemeData theme() {
    final scheme = ColorScheme.fromSeed(seedColor: amber, brightness: Brightness.dark).copyWith(
      primary: amber,
      onPrimary: Colors.black,
      secondary: amber,
      surface: panel,
      onSurface: text,
      surfaceContainerHighest: panelHi,
      secondaryContainer: panelHi,
      onSecondaryContainer: text,
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: graphite,
      appBarTheme: const AppBarTheme(backgroundColor: graphite, foregroundColor: text),
      snackBarTheme: const SnackBarThemeData(
        backgroundColor: panelHi,
        contentTextStyle: TextStyle(color: text, fontSize: 15),
        behavior: SnackBarBehavior.floating,
      ),
      chipTheme: const ChipThemeData(
        backgroundColor: panelHi,
        side: BorderSide.none,
        labelStyle: TextStyle(color: text),
      ),
      bottomSheetTheme: const BottomSheetThemeData(backgroundColor: panel),
      dialogTheme: const DialogThemeData(backgroundColor: panel),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: amber,
          foregroundColor: Colors.black,
          textStyle: const TextStyle(fontWeight: FontWeight.w800, fontSize: 18),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: text,
          side: const BorderSide(color: panelHi, width: 2),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        ),
      ),
    );
  }
}
