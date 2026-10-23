import 'package:flutter/material.dart';

/// Asks before leaving the topic; true when the user confirms.
Future<bool> confirmLeaveTopic(BuildContext context) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.logout),
        title: const Text('Leave this topic?'),
        content: const Text(
            'This phone goes offline: your devices no longer see it, and '
            'sharing and folder sync stop. Its rules and synced folders are '
            'kept, and you can rejoin from the next screen.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Leave')),
        ],
      ),
    ) ==
    true;

/// Shows a single-text-field prompt dialog and returns the trimmed text, or
/// null if cancelled.
Future<String?> askText(BuildContext context, String title,
        {String initial = ''}) =>
    showDialog<String>(
      context: context,
      builder: (context) => PromptDialog(title: title, initial: initial),
    );

/// A single-text-field prompt dialog. It owns its [TextEditingController] so the
/// controller is disposed only when this widget leaves the tree. Disposing it
/// right after `showDialog` returns (while the dialog is still animating out)
/// leaves the field using a dead controller and crashes the next rebuild.
class PromptDialog extends StatefulWidget {
  const PromptDialog({super.key, required this.title, this.initial = ''});

  final String title;
  final String initial;

  @override
  State<PromptDialog> createState() => _PromptDialogState();
}

class _PromptDialogState extends State<PromptDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() => Navigator.pop(context, _controller.text.trim());

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(widget.title, style: const TextStyle(fontSize: 15)),
        content: TextField(
          controller: _controller,
          autofocus: true,
          onSubmitted: (_) => _submit(),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          FilledButton(onPressed: _submit, child: const Text('OK')),
        ],
      );
}
