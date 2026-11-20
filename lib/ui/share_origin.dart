import 'package:flutter/widgets.dart';

/// Where a share sheet should point: the widget `context` belongs to, in
/// global coordinates. An iPad presents the sheet as a popover and refuses to
/// show it without a non-empty anchor; phones ignore it.
Rect? shareOrigin(BuildContext context) {
  final box = context.findRenderObject();
  if (box is! RenderBox || !box.hasSize || box.size.isEmpty) return null;
  return box.localToGlobal(Offset.zero) & box.size;
}
