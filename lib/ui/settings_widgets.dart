// Building blocks for the settings screens: grouped sections of rows, rows with
// an icon chip, switch rows, and a sub-page scaffold that rebuilds when the
// app state changes.

import 'package:flutter/material.dart';

import '../app/app_state.dart';
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
            Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 8),
              child: Text(title!.toUpperCase(),
                  style: TextStyle(
                      fontSize: 11.5,
                      letterSpacing: 0.8,
                      fontWeight: FontWeight.w600,
                      color: UcColors.textSecondary)),
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
    super.key,
  });

  final String title;
  final String? subtitle;
  final IconData? icon;
  final Color? iconColor;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
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

/// A pushed settings screen. Rebuilds with the app state, so values and the
/// colour scheme stay current while it is open.
class SettingsSubpage extends StatelessWidget {
  const SettingsSubpage(
      {required this.title,
      required this.state,
      required this.builder,
      super.key});

  final String title;
  final AppState state;
  final List<Widget> Function(BuildContext context) builder;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: state,
        builder: (context, _) => Scaffold(
          backgroundColor: UcColors.canvas,
          appBar: AppBar(title: Text(title)),
          body: ListView(
            padding: const EdgeInsets.only(bottom: 28),
            children: builder(context),
          ),
        ),
      );
}

/// Pushes a settings sub-page.
void openSettingsPage(BuildContext context, AppState state, String title,
        List<Widget> Function(BuildContext context) builder) =>
    Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) =>
            SettingsSubpage(title: title, state: state, builder: builder)));
