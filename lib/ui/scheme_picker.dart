// The colour-scheme picker: a grid of small previews of each scheme (a mock
// screen in its colours), the current one outlined in the accent colour.

import 'package:flutter/material.dart';

import 'theme.dart';

class SchemePicker extends StatelessWidget {
  const SchemePicker(
      {required this.selected, required this.onSelected, super.key});

  final String selected;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      const gap = 12.0;
      final columns = constraints.maxWidth > 520 ? 3 : 2;
      final width = (constraints.maxWidth - gap * (columns - 1)) / columns;
      return Wrap(
        spacing: gap,
        runSpacing: 16,
        children: [
          for (final s in ucSchemes)
            SizedBox(
              width: width,
              child: _Swatch(
                scheme: s,
                selected: s.id == selected,
                onTap: () => onSelected(s.id),
              ),
            ),
        ],
      );
    });
  }
}

class _Swatch extends StatelessWidget {
  const _Swatch(
      {required this.scheme, required this.selected, required this.onTap});

  final UcScheme scheme;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final preview = scheme.id == 'system'
        ? Row(children: [
            Expanded(child: _Mock(ucSchemePreview('dark', Brightness.dark))),
            Expanded(child: _Mock(ucSchemePreview('light', Brightness.light))),
          ])
        : _Mock(ucSchemePreview(scheme.id, Brightness.dark));

    return Semantics(
      button: true,
      selected: selected,
      label: scheme.label,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Column(
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              padding: const EdgeInsets.all(3),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: selected ? UcColors.accent : UcColors.border,
                  width: selected ? 2.5 : 1,
                ),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: AspectRatio(aspectRatio: 1.3, child: preview),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (selected) ...[
                  Icon(Icons.check_circle, size: 16, color: UcColors.accent),
                  const SizedBox(width: 5),
                ],
                Flexible(
                  child: Text(
                    scheme.label,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                      color: selected ? UcColors.text : UcColors.textSecondary,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// A tiny mock app screen drawn in one scheme's colours: a top bar, two lines
/// of text, a card and an accent button.
class _Mock extends StatelessWidget {
  const _Mock(this.c);

  final UcSchemePreview c;

  Widget _bar(double widthFactor, Color color, {double height = 5}) =>
      FractionallySizedBox(
        widthFactor: widthFactor,
        alignment: Alignment.centerLeft,
        child: Container(
          height: height,
          decoration: BoxDecoration(
              color: color, borderRadius: BorderRadius.circular(3)),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return Container(
      color: c.canvas,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            height: 16,
            color: c.panel,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            alignment: Alignment.centerLeft,
            child: _bar(0.45, c.text.withValues(alpha: 0.7), height: 4),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _bar(0.8, c.text.withValues(alpha: 0.85)),
                  const SizedBox(height: 5),
                  _bar(0.55, c.textSecondary.withValues(alpha: 0.8)),
                  const SizedBox(height: 8),
                  Expanded(
                    child: Container(
                      decoration: BoxDecoration(
                        color: c.panel,
                        borderRadius: BorderRadius.circular(5),
                        border: Border.all(color: c.border),
                      ),
                      padding: const EdgeInsets.all(5),
                      child: Align(
                        alignment: Alignment.bottomRight,
                        child: Container(
                          width: 26,
                          height: 10,
                          decoration: BoxDecoration(
                              color: c.accent,
                              borderRadius: BorderRadius.circular(5)),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
