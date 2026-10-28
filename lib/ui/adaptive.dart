// How wide the window is, in the three classes Material uses, and the one
// layout rule every page shares: reading-width content stays about 760 dp
// wide and centred, so a phone layout does not stretch across a tablet.
//
// compact  (< 600 dp): phones. Bottom navigation, one page at a time.
// medium   (600-839):  small tablets, phones in landscape. A navigation rail;
//                      pages keep their width in check.
// expanded (>= 840):   tablets. The rail plus two panes where a list opens
//                      details: devices and their page, settings and the
//                      page a row opens.

import 'package:flutter/material.dart';

enum Breadth { compact, medium, expanded }

Breadth breadthOf(BuildContext context) {
  final width = MediaQuery.sizeOf(context).width;
  if (width < 600) return Breadth.compact;
  if (width < 840) return Breadth.medium;
  return Breadth.expanded;
}

/// Reading width for lists of settings rows, cards and text.
const double kContentWidth = 760;

/// Width of the list pane when a page shows a list beside what it opens.
const double kListPaneWidth = 340;

/// Keeps [child] at most [maxWidth] wide and centred; narrower windows are
/// unaffected. Scrolling children keep the full height.
class ContentWidth extends StatelessWidget {
  const ContentWidth({required this.child, this.maxWidth = kContentWidth, super.key});
  final Widget child;
  final double maxWidth;

  @override
  Widget build(BuildContext context) => Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth),
          child: child,
        ),
      );
}

/// What the detail pane shows before anything is chosen in the list pane.
class PanePlaceholder extends StatelessWidget {
  const PanePlaceholder({required this.icon, required this.text, super.key});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.45);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 48, color: muted),
          const SizedBox(height: 12),
          Text(text, textAlign: TextAlign.center, style: TextStyle(color: muted)),
        ],
      ),
    );
  }
}

/// The title row of an embedded detail pane: the page's title where an app
/// bar would be, with optional actions.
class PaneHeader extends StatelessWidget implements PreferredSizeWidget {
  const PaneHeader({required this.title, this.actions = const [], super.key});
  final Widget title;
  final List<Widget> actions;

  @override
  Size get preferredSize => const Size.fromHeight(56);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context).appBarTheme;
    return Material(
      color: theme.backgroundColor,
      child: SizedBox(
        height: 56,
        child: Row(children: [
          const SizedBox(width: 20),
          Expanded(
            child: DefaultTextStyle(
              style: theme.titleTextStyle ?? const TextStyle(fontSize: 17),
              overflow: TextOverflow.ellipsis,
              child: title,
            ),
          ),
          ...actions,
          const SizedBox(width: 8),
        ]),
      ),
    );
  }
}
