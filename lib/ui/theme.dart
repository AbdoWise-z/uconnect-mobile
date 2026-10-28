// Colours and metrics. The default palette is modelled on the JetBrains
// "New UI" dark theme, the same family as uconnect-desktop's Theme.qml. Several
// alternate schemes are offered (dark, darker, light, colorful, follow-system);
// the chosen one is stored as AppStore.colorScheme and applied with
// UcColors.applyScheme before the app's ThemeData is built.

import 'package:flutter/material.dart';

/// One complete colour scheme: the same roles for every palette.
class _Palette {
  const _Palette({
    required this.dark,
    required this.canvas,
    required this.panel,
    required this.popup,
    required this.divider,
    required this.border,
    required this.popupBorder,
    required this.hover,
    required this.pressed,
    required this.selection,
    required this.selectionInactive,
    required this.input,
    required this.inputBorder,
    required this.focus,
    required this.text,
    required this.textSecondary,
    required this.textDisabled,
    required this.link,
    required this.accent,
    required this.accentHover,
    required this.accentPressed,
    required this.success,
    required this.warning,
    required this.error,
    required this.errorBackground,
    required this.infoBackground,
  });

  final bool dark;
  final Color canvas;
  final Color panel;
  final Color popup;
  final Color divider;
  final Color border;
  final Color popupBorder;
  final Color hover;
  final Color pressed;
  final Color selection;
  final Color selectionInactive;
  final Color input;
  final Color inputBorder;
  final Color focus;
  final Color text;
  final Color textSecondary;
  final Color textDisabled;
  final Color link;
  final Color accent;
  final Color accentHover;
  final Color accentPressed;
  final Color success;
  final Color warning;
  final Color error;
  final Color errorBackground;
  final Color infoBackground;
}

const _dark = _Palette(
  dark: true,
  canvas: Color(0xFF1E1F22),
  panel: Color(0xFF2B2D30),
  popup: Color(0xFF2B2D30),
  divider: Color(0xFF1E1F22),
  border: Color(0xFF393B40),
  popupBorder: Color(0xFF43454A),
  hover: Color(0xFF393B40),
  pressed: Color(0xFF43454A),
  selection: Color(0xFF2E436E),
  selectionInactive: Color(0xFF43454A),
  input: Color(0xFF2B2D30),
  inputBorder: Color(0xFF4E5157),
  focus: Color(0xFF3574F0),
  text: Color(0xFFDFE1E5),
  textSecondary: Color(0xFF868A91),
  textDisabled: Color(0xFF5A5D63),
  link: Color(0xFF548AF7),
  accent: Color(0xFF3574F0),
  accentHover: Color(0xFF366ACE),
  accentPressed: Color(0xFF2F5EB8),
  success: Color(0xFF5FB865),
  warning: Color(0xFFF2C55C),
  error: Color(0xFFDB5C5C),
  errorBackground: Color(0xFF402929),
  infoBackground: Color(0xFF25324D),
);

// A deeper, near-black dark for low-light use.
const _darker = _Palette(
  dark: true,
  canvas: Color(0xFF121316),
  panel: Color(0xFF1A1B1E),
  popup: Color(0xFF1A1B1E),
  divider: Color(0xFF0D0E10),
  border: Color(0xFF2A2C30),
  popupBorder: Color(0xFF34363B),
  hover: Color(0xFF26282C),
  pressed: Color(0xFF303236),
  selection: Color(0xFF26406B),
  selectionInactive: Color(0xFF303236),
  input: Color(0xFF17181B),
  inputBorder: Color(0xFF3A3D43),
  focus: Color(0xFF3574F0),
  text: Color(0xFFE6E8EC),
  textSecondary: Color(0xFF7E828A),
  textDisabled: Color(0xFF4E5157),
  link: Color(0xFF548AF7),
  accent: Color(0xFF3574F0),
  accentHover: Color(0xFF366ACE),
  accentPressed: Color(0xFF2F5EB8),
  success: Color(0xFF5FB865),
  warning: Color(0xFFF2C55C),
  error: Color(0xFFDB5C5C),
  errorBackground: Color(0xFF3A2525),
  infoBackground: Color(0xFF1E2A42),
);

// A bright, clean light theme.
const _light = _Palette(
  dark: false,
  canvas: Color(0xFFFFFFFF),
  panel: Color(0xFFF7F8FA),
  popup: Color(0xFFFFFFFF),
  divider: Color(0xFFEBECF0),
  border: Color(0xFFD3D5DB),
  popupBorder: Color(0xFFC9CCD6),
  hover: Color(0xFFEDEEF2),
  pressed: Color(0xFFE0E2E8),
  selection: Color(0xFFD4E2FF),
  selectionInactive: Color(0xFFE3E5E9),
  input: Color(0xFFFFFFFF),
  inputBorder: Color(0xFFBCBFC7),
  focus: Color(0xFF3574F0),
  text: Color(0xFF1E1F22),
  textSecondary: Color(0xFF6C707A),
  textDisabled: Color(0xFFA8ADB5),
  link: Color(0xFF2E6CE6),
  accent: Color(0xFF3574F0),
  accentHover: Color(0xFF2F68DD),
  accentPressed: Color(0xFF2A5FCC),
  success: Color(0xFF3F9142),
  warning: Color(0xFFB07D16),
  error: Color(0xFFD13C3C),
  errorBackground: Color(0xFFFBE9E9),
  infoBackground: Color(0xFFE7EFFD),
);

// A vibrant, tinted dark with an indigo canvas and violet accent.
const _colorful = _Palette(
  dark: true,
  canvas: Color(0xFF1B1A2E),
  panel: Color(0xFF252442),
  popup: Color(0xFF252442),
  divider: Color(0xFF15142A),
  border: Color(0xFF3A3860),
  popupBorder: Color(0xFF45426F),
  hover: Color(0xFF302E52),
  pressed: Color(0xFF3A3763),
  selection: Color(0xFF3D3A7A),
  selectionInactive: Color(0xFF3A3763),
  input: Color(0xFF221F3D),
  inputBorder: Color(0xFF4A4775),
  focus: Color(0xFF8B7CFF),
  text: Color(0xFFECEAFF),
  textSecondary: Color(0xFFA6A0D0),
  textDisabled: Color(0xFF6E699A),
  link: Color(0xFF9D8BFF),
  accent: Color(0xFF7C6CFF),
  accentHover: Color(0xFF6C5CF0),
  accentPressed: Color(0xFF5D4EDB),
  success: Color(0xFF46C8A0),
  warning: Color(0xFFF2B84C),
  error: Color(0xFFFF6B8A),
  errorBackground: Color(0xFF3A2238),
  infoBackground: Color(0xFF262450),
);

/// A colour scheme offered in Settings.
class UcScheme {
  const UcScheme(this.id, this.label);
  final String id;
  final String label;
}

/// The schemes offered, in display order.
const ucSchemes = <UcScheme>[
  UcScheme('system', 'Follow system'),
  UcScheme('dark', 'Dark'),
  UcScheme('darker', 'Darker'),
  UcScheme('light', 'Light'),
  UcScheme('colorful', 'Colorful'),
];

/// A few colours of a scheme, for drawing its preview swatch in Settings.
class UcSchemePreview {
  const UcSchemePreview(this.canvas, this.panel, this.accent, this.text,
      this.textSecondary, this.border);
  final Color canvas;
  final Color panel;
  final Color accent;
  final Color text;
  final Color textSecondary;
  final Color border;
}

UcSchemePreview ucSchemePreview(String id, Brightness platform) {
  final p = _paletteFor(id, platform);
  return UcSchemePreview(
      p.canvas, p.panel, p.accent, p.text, p.textSecondary, p.border);
}

_Palette _paletteFor(String id, Brightness platform) {
  switch (id) {
    case 'system':
      return platform == Brightness.light ? _light : _dark;
    case 'darker':
      return _darker;
    case 'light':
      return _light;
    case 'colorful':
      return _colorful;
    case 'dark':
    default:
      return _dark;
  }
}

/// The active palette's colours. These are plain mutable fields rather than
/// `const`, so switching schemes (via [UcColors.applyScheme]) and rebuilding
/// the app restyles everything. Call sites must therefore not wrap a
/// `UcColors.*` value in a `const` expression.
class UcColors {
  static bool isDark = _dark.dark;
  static Color canvas = _dark.canvas;
  static Color panel = _dark.panel;
  static Color popup = _dark.popup;
  static Color divider = _dark.divider;
  static Color border = _dark.border;
  static Color popupBorder = _dark.popupBorder;
  static Color hover = _dark.hover;
  static Color pressed = _dark.pressed;
  static Color selection = _dark.selection;
  static Color selectionInactive = _dark.selectionInactive;
  static Color input = _dark.input;
  static Color inputBorder = _dark.inputBorder;
  static Color focus = _dark.focus;
  static Color text = _dark.text;
  static Color textSecondary = _dark.textSecondary;
  static Color textDisabled = _dark.textDisabled;
  static Color link = _dark.link;
  static Color accent = _dark.accent;
  static Color accentHover = _dark.accentHover;
  static Color accentPressed = _dark.accentPressed;
  static Color success = _dark.success;
  static Color warning = _dark.warning;
  static Color error = _dark.error;
  static Color errorBackground = _dark.errorBackground;
  static Color infoBackground = _dark.infoBackground;

  /// Switches the active palette. `platform` resolves the "system" scheme to
  /// the OS light/dark preference. Call before building the app's ThemeData.
  static void applyScheme(String id, Brightness platform) {
    final p = _paletteFor(id, platform);
    isDark = p.dark;
    canvas = p.canvas;
    panel = p.panel;
    popup = p.popup;
    divider = p.divider;
    border = p.border;
    popupBorder = p.popupBorder;
    hover = p.hover;
    pressed = p.pressed;
    selection = p.selection;
    selectionInactive = p.selectionInactive;
    input = p.input;
    inputBorder = p.inputBorder;
    focus = p.focus;
    text = p.text;
    textSecondary = p.textSecondary;
    textDisabled = p.textDisabled;
    link = p.link;
    accent = p.accent;
    accentHover = p.accentHover;
    accentPressed = p.accentPressed;
    success = p.success;
    warning = p.warning;
    error = p.error;
    errorBackground = p.errorBackground;
    infoBackground = p.infoBackground;
  }
}

/// Colour of a peer-state dot, mirroring the desktop's StatusDot.
Color stateColor(int stateCode) => switch (stateCode) {
      3 => UcColors.success, // connected
      1 || 2 => UcColors.warning, // probing, handshaking
      4 => UcColors.error, // failed
      _ => UcColors.textDisabled, // unknown, closed
    };

ThemeData ucTheme() {
  final scheme = ColorScheme(
    brightness: UcColors.isDark ? Brightness.dark : Brightness.light,
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
    appBarTheme: AppBarTheme(
      backgroundColor: UcColors.panel,
      foregroundColor: UcColors.text,
      elevation: 0,
      // Flat: no tint when content scrolls under it. With several lists
      // built at once (the tabs, two panes) their scroll notifications would
      // flip the tint back and forth and the bar flickered.
      scrolledUnderElevation: 0,
      surfaceTintColor: Colors.transparent,
      shadowColor: Colors.transparent,
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
          TextStyle(fontSize: 12, color: UcColors.textSecondary)),
      iconTheme: WidgetStateProperty.resolveWith((states) => IconThemeData(
          color: states.contains(WidgetState.selected)
              ? UcColors.text
              : UcColors.textSecondary)),
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: UcColors.panel,
      indicatorColor: UcColors.selection,
      selectedLabelTextStyle: TextStyle(fontSize: 12, color: UcColors.text),
      unselectedLabelTextStyle: TextStyle(fontSize: 12, color: UcColors.textSecondary),
      selectedIconTheme: IconThemeData(color: UcColors.text),
      unselectedIconTheme: IconThemeData(color: UcColors.textSecondary),
    ),
    cardTheme: CardThemeData(
      color: UcColors.panel,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: UcColors.border),
      ),
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
    ),
    listTileTheme: ListTileThemeData(
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
        borderSide: BorderSide(color: UcColors.inputBorder),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(6),
        borderSide: BorderSide(color: UcColors.inputBorder),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(6),
        borderSide: BorderSide(color: UcColors.focus, width: 2),
      ),
      labelStyle: TextStyle(color: UcColors.textSecondary),
      hintStyle: TextStyle(color: UcColors.textDisabled),
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
        side: BorderSide(color: UcColors.inputBorder),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
      ),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((states) =>
          states.contains(WidgetState.selected)
              ? Colors.white
              : UcColors.textSecondary),
      trackColor: WidgetStateProperty.resolveWith((states) =>
          states.contains(WidgetState.selected)
              ? UcColors.accent
              : UcColors.border),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: UcColors.popup,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: UcColors.popupBorder),
      ),
      titleTextStyle: TextStyle(
          color: UcColors.text, fontSize: 16, fontWeight: FontWeight.w600),
      contentTextStyle: TextStyle(color: UcColors.text, fontSize: 14),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: UcColors.popup,
      contentTextStyle: TextStyle(color: UcColors.text),
    ),
    progressIndicatorTheme:
        ProgressIndicatorThemeData(color: UcColors.accent),
  );
}
