// Building blocks for the settings screens: grouped sections of rows, rows with
// an icon chip, switch rows, and a sub-page scaffold that rebuilds when the
// app state changes. A sub-page opened from settings search scrolls to the
// setting it was opened for and makes it glow (SettingsHighlight).

import 'package:flutter/material.dart';

import '../app/app_state.dart';
import 'adaptive.dart';
import 'theme.dart';

/// A titled group of rows drawn as one rounded panel, with an optional
/// explanatory footer underneath.
class SettingsSection extends StatelessWidget {
  const SettingsSection(
      {this.title, required this.children, this.footer, super.key});

  final String? title;
  final List<Widget> children;
  final String? footer;

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      if (i > 0) {
        rows.add(Divider(
            height: 1, thickness: 1, indent: 16, color: UcColors.border));
      }
      rows.add(children[i]);
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (title != null)
            SettingsGlow(
              active: SettingsHighlight.of(context) == title,
              child: Padding(
                padding: const EdgeInsets.only(left: 4, bottom: 8),
                child: Text(title!.toUpperCase(),
                    style: TextStyle(
                        fontSize: 11.5,
                        letterSpacing: 0.8,
                        fontWeight: FontWeight.w600,
                        color: UcColors.textSecondary)),
              ),
            ),
          Container(
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: UcColors.panel,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: UcColors.border),
            ),
            child: Column(children: rows),
          ),
          if (footer != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
              child: Text(footer!,
                  style:
                      TextStyle(fontSize: 12, color: UcColors.textSecondary)),
            ),
        ],
      ),
    );
  }
}

/// A rounded, tinted square holding an icon, leading a settings row.
class SettingsIcon extends StatelessWidget {
  const SettingsIcon(this.icon, {this.color, super.key});
  final IconData icon;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final tint = color ?? UcColors.accent;
    return Container(
      width: 34,
      height: 34,
      decoration: BoxDecoration(
        color: tint.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(9),
      ),
      child: Icon(icon, size: 19, color: tint),
    );
  }
}

/// One settings row: optional icon chip, a title and a status line, and a
/// trailing widget (a chevron by default when it can be opened).
class SettingsTile extends StatelessWidget {
  const SettingsTile({
    required this.title,
    this.subtitle,
    this.icon,
    this.iconColor,
    this.trailing,
    this.onTap,
    this.enabled = true,
    this.selected = false,
    super.key,
  });

  final String title;
  final String? subtitle;
  final IconData? icon;
  final Color? iconColor;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool enabled;
  final bool selected; // the row whose page is open beside the list

  @override
  Widget build(BuildContext context) {
    return SettingsGlow(
      active: SettingsHighlight.of(context) == title,
      child: _row(),
    );
  }

  Widget _row() {
    return Material(
      color: selected ? UcColors.selection : Colors.transparent,
      child: InkWell(
        onTap: enabled ? onTap : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              if (icon != null) ...[
                SettingsIcon(icon!,
                    color: enabled ? iconColor : UcColors.textDisabled),
                const SizedBox(width: 14),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w500,
                            color: enabled
                                ? UcColors.text
                                : UcColors.textDisabled)),
                    if (subtitle != null && subtitle!.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(subtitle!,
                          style: TextStyle(
                              fontSize: 12.5, color: UcColors.textSecondary)),
                    ],
                  ],
                ),
              ),
              if (trailing != null) ...[
                const SizedBox(width: 10),
                trailing!,
              ] else if (onTap != null && enabled) ...[
                const SizedBox(width: 6),
                Icon(Icons.chevron_right, color: UcColors.textDisabled),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// A settings row with a switch; tapping anywhere on the row toggles it.
class SettingsSwitchTile extends StatelessWidget {
  const SettingsSwitchTile({
    required this.title,
    required this.value,
    required this.onChanged,
    this.subtitle,
    this.icon,
    this.iconColor,
    super.key,
  });

  final String title;
  final String? subtitle;
  final IconData? icon;
  final Color? iconColor;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) => SettingsTile(
        title: title,
        subtitle: subtitle,
        icon: icon,
        iconColor: iconColor,
        enabled: onChanged != null,
        onTap: onChanged == null ? null : () => onChanged!(!value),
        trailing: Switch(value: value, onChanged: onChanged),
      );
}

/// A section title or row found by settings search.
class SettingHit {
  SettingHit(this.text, this.where, this.open);
  final String text;
  final String where; // page (and section) it is on
  final VoidCallback open;
}

/// One setting on a page, as search reads it: a section title or a row.
class SettingEntry {
  SettingEntry(this.text, this.section, this.detail, this.row);
  final String text;
  final String? section;
  final String? detail; // a row's status line, searched too
  final Widget? row;

  bool matches(String query) =>
      query.isNotEmpty &&
      (text.toLowerCase().contains(query) ||
          (detail?.toLowerCase().contains(query) ?? false));
}

/// The sections and rows among a page's widgets.
List<SettingEntry> settingsIn(List<Widget> page) {
  final out = <SettingEntry>[];
  for (final w in page) {
    if (w is! SettingsSection) continue;
    if (w.title != null) out.add(SettingEntry(w.title!, null, w.footer, null));
    for (final row in w.children) {
      if (row is SettingsTile) {
        out.add(SettingEntry(row.title, w.title, row.subtitle, row));
      } else if (row is SettingsSwitchTile) {
        out.add(SettingEntry(row.title, w.title, row.subtitle, row));
      }
    }
  }
  return out;
}

/// The title of the setting a sub-page was opened for from search: its row
/// (or section) scrolls into view and glows.
class SettingsHighlight extends InheritedWidget {
  const SettingsHighlight({required this.text, required super.child, super.key});

  final String? text;

  static String? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<SettingsHighlight>()?.text;

  @override
  bool updateShouldNotify(SettingsHighlight oldWidget) => text != oldWidget.text;
}

/// Scrolls [child] into view once and lights it up briefly when [active].
class SettingsGlow extends StatefulWidget {
  const SettingsGlow({required this.active, required this.child, super.key});

  final bool active;
  final Widget child;

  @override
  State<SettingsGlow> createState() => _SettingsGlowState();
}

class _SettingsGlowState extends State<SettingsGlow>
    with SingleTickerProviderStateMixin {
  late final AnimationController _glow = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 2600));

  @override
  void initState() {
    super.initState();
    if (!widget.active) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      Scrollable.ensureVisible(context,
          alignment: 0.3, duration: const Duration(milliseconds: 250));
      _glow.forward(from: 0);
    });
  }

  @override
  void dispose() {
    _glow.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.active) return widget.child;
    return AnimatedBuilder(
      animation: _glow,
      builder: (context, child) {
        final t = _glow.value;
        // Up quickly, held for a moment, then faded.
        final strength = t == 0
            ? 0.0
            : t < 0.06
                ? t / 0.06
                : t < 0.45
                    ? 1.0
                    : 1 - (t - 0.45) / 0.55;
        return DecoratedBox(
          decoration: BoxDecoration(
            color: UcColors.accent.withValues(alpha: 0.24 * strength),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
                color: UcColors.accent.withValues(alpha: strength), width: 1.5),
          ),
          child: child,
        );
      },
      child: widget.child,
    );
  }
}

/// A pushed settings screen. Rebuilds with the app state, so values and the
/// colour scheme stay current while it is open. Laid out in one piece (not a
/// lazy list), so a highlighted setting far down can still be scrolled to.
class SettingsSubpage extends StatelessWidget {
  const SettingsSubpage(
      {required this.title,
      required this.state,
      required this.builder,
      this.highlight,
      this.embedded = false,
      super.key});

  final String title;
  final AppState state;
  final List<Widget> Function(BuildContext context) builder;
  final String? highlight;
  /// Shown beside the settings overview rather than as its own page: a title
  /// row in place of the app bar.
  final bool embedded;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: state,
        builder: (context, _) {
          final body = SettingsHighlight(
            text: highlight,
            child: ContentWidth(
              child: SingleChildScrollView(
                padding: const EdgeInsets.only(bottom: 28),
                child: Builder(
                  builder: (context) => Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: builder(context),
                  ),
                ),
              ),
            ),
          );
          if (embedded) {
            return Material(
              color: UcColors.canvas,
              child: Column(children: [
                PaneHeader(title: Text(title)),
                Expanded(child: body),
              ]),
            );
          }
          return Scaffold(
            backgroundColor: UcColors.canvas,
            appBar: AppBar(title: Text(title)),
            body: body,
          );
        },
      );
}

/// Pushes a settings sub-page; [highlight] is the setting to point out.
void openSettingsPage(BuildContext context, AppState state, String title,
        List<Widget> Function(BuildContext context) builder,
        {String? highlight}) =>
    Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => SettingsSubpage(
            title: title, state: state, builder: builder, highlight: highlight)));
