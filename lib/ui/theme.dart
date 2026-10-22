// Colours and metrics modelled on the JetBrains "New UI" dark theme, the same
// palette as uconnect-desktop's Theme.qml, so the two apps read as one family.

import 'package:flutter/material.dart';

class UcColors {
  // Surfaces
  static const canvas = Color(0xFF1E1F22);
  static const panel = Color(0xFF2B2D30);
  static const popup = Color(0xFF2B2D30);
  static const divider = Color(0xFF1E1F22);
  static const border = Color(0xFF393B40);
  static const popupBorder = Color(0xFF43454A);
  static const hover = Color(0xFF393B40);
  static const pressed = Color(0xFF43454A);
  static const selection = Color(0xFF2E436E);
  static const selectionInactive = Color(0xFF43454A);

  // Inputs
  static const input = Color(0xFF2B2D30);
  static const inputBorder = Color(0xFF4E5157);
  static const focus = Color(0xFF3574F0);

  // Text
  static const text = Color(0xFFDFE1E5);
  static const textSecondary = Color(0xFF868A91);
  static const textDisabled = Color(0xFF5A5D63);
  static const link = Color(0xFF548AF7);

  // Accents
  static const accent = Color(0xFF3574F0);
  static const accentHover = Color(0xFF366ACE);
  static const accentPressed = Color(0xFF2F5EB8);
  static const success = Color(0xFF5FB865);
  static const warning = Color(0xFFF2C55C);
  static const error = Color(0xFFDB5C5C);
  static const errorBackground = Color(0xFF402929);
  static const infoBackground = Color(0xFF25324D);
}

/// Colour of a peer-state dot, mirroring the desktop's StatusDot.
Color stateColor(int stateCode) => switch (stateCode) {
      3 => UcColors.success, // connected
      1 || 2 => UcColors.warning, // probing, handshaking
      4 => UcColors.error, // failed
      _ => UcColors.textDisabled, // unknown, closed
    };

ThemeData ucTheme() {
  const scheme = ColorScheme.dark(
    primary: UcColors.accent,
    onPrimary: Colors.white,
    secondary: UcColors.accent,
    onSecondary: Colors.white,
    surface: UcColors.panel,
    onSurface: UcColors.text,
    error: UcColors.error,
    onError: Colors.white,
    outline: UcColors.border,
  );
  final base = ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: UcColors.canvas,
    canvasColor: UcColors.canvas,
    dividerColor: UcColors.border,
    fontFamily: null,
  );
  return base.copyWith(
    appBarTheme: const AppBarTheme(
      backgroundColor: UcColors.panel,
      foregroundColor: UcColors.text,
      elevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
        color: UcColors.text,
        fontSize: 17,
        fontWeight: FontWeight.w600,
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: UcColors.panel,
      indicatorColor: UcColors.selection,
      labelTextStyle: WidgetStateProperty.all(
          const TextStyle(fontSize: 12, color: UcColors.textSecondary)),
      iconTheme: WidgetStateProperty.resolveWith((states) => IconThemeData(
          color: states.contains(WidgetState.selected)
              ? UcColors.text
              : UcColors.textSecondary)),
    ),
    cardTheme: CardThemeData(
      color: UcColors.panel,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: const BorderSide(color: UcColors.border),
      ),
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
    ),
    listTileTheme: const ListTileThemeData(
      textColor: UcColors.text,
      iconColor: UcColors.textSecondary,
      dense: true,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: UcColors.input,
      isDense: true,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(6),
        borderSide: const BorderSide(color: UcColors.inputBorder),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(6),
        borderSide: const BorderSide(color: UcColors.inputBorder),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(6),
        borderSide: const BorderSide(color: UcColors.focus, width: 2),
      ),
      labelStyle: const TextStyle(color: UcColors.textSecondary),
      hintStyle: const TextStyle(color: UcColors.textDisabled),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: UcColors.accent,
        foregroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: UcColors.link),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: UcColors.text,
        side: const BorderSide(color: UcColors.inputBorder),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
      ),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((states) =>
          states.contains(WidgetState.selected) ? Colors.white : UcColors.textSecondary),
      trackColor: WidgetStateProperty.resolveWith((states) =>
          states.contains(WidgetState.selected)
              ? UcColors.accent
              : UcColors.border),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: UcColors.popup,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: const BorderSide(color: UcColors.popupBorder),
      ),
      titleTextStyle: const TextStyle(
          color: UcColors.text, fontSize: 16, fontWeight: FontWeight.w600),
      contentTextStyle: const TextStyle(color: UcColors.text, fontSize: 14),
    ),
    snackBarTheme: const SnackBarThemeData(
      backgroundColor: UcColors.popup,
      contentTextStyle: TextStyle(color: UcColors.text),
    ),
    progressIndicatorTheme:
        const ProgressIndicatorThemeData(color: UcColors.accent),
  );
}
