// Files syncing set aside in a folder's .synctrash (deleted elsewhere, or
// given up in a conflict): put one back, or delete it for good.

import 'package:flutter/material.dart';

import '../app/app_state.dart';
import 'format.dart';
import 'settings_widgets.dart';
import 'adaptive.dart';
import 'theme.dart';

class SyncKeptPage extends StatefulWidget {
  const SyncKeptPage({required this.state, required this.id, super.key});
  final AppState state;
  final String id;

  @override
  State<SyncKeptPage> createState() => _SyncKeptPageState();
}

class _SyncKeptPageState extends State<SyncKeptPage> {
  List<Map<String, Object?>> _kept = const [];
  bool _listed = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    try {
      final list = await widget.state.sync.keptFiles(widget.id);
      if (mounted) {
        setState(() {
          _kept = list;
          _listed = true;
        });
      }
    } on Object {
      // sync stopped
    }
  }

  void _tell(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  @override
  Widget build(BuildContext context) {
    final c = widget.state.syncFolder(widget.id);
    return Scaffold(
      backgroundColor: UcColors.canvas,
      appBar: AppBar(
        title: Text(c == null || c.label.isEmpty ? 'Kept files' : '${c.label}: kept files'),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), tooltip: 'Refresh', onPressed: _refresh),
        ],
      ),
      body: ContentWidth(
          child: ListView(padding: const EdgeInsets.only(bottom: 28), children: [
        SettingsSection(
          title: 'In .synctrash',
          footer: 'Files that syncing deletes, or that you give up in a conflict, wait here '
              'for ${widget.state.sync.keepDays} days, then go. Restoring one puts it back '
              'where it was (beside the current file, if there is one), as your change: '
              'the other devices get it again.',
          children: [
            if (_kept.isEmpty)
              SettingsTile(
                icon: Icons.delete_sweep_outlined,
                iconColor: UcColors.textDisabled,
                title: _listed ? 'Nothing kept' : 'Listing…',
                subtitle: _listed ? 'Nothing has been removed from this folder by syncing.' : '',
              ),
            for (final k in _kept)
              SettingsTile(
                icon: Icons.history,
                title: '${k['path']}',
                subtitle: '${formatAgo((k['time'] as num?)?.toInt() ?? 0)} · '
                    '${formatBytes((k['size'] as num?) ?? 0)}',
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  IconButton(
                    icon: const Icon(Icons.restore),
                    tooltip: 'Restore',
                    onPressed: () async {
                      final ok = await widget.state.sync.restoreKept(widget.id, '${k['kept']}');
                      if (!mounted) return;
                      _tell(ok ? 'Restored ${k['path']}.' : 'Could not restore it.');
                      await _refresh();
                    },
                  ),
                  IconButton(
                    icon: const Icon(Icons.delete_outline),
                    tooltip: 'Delete for good',
                    onPressed: () async {
                      final ok = await showDialog<bool>(
                        context: context,
                        builder: (context) => AlertDialog(
                          title: const Text('Delete this kept file?'),
                          content: Text('${k['path']} goes for good; no device has it any more.'),
                          actions: [
                            TextButton(
                                onPressed: () => Navigator.pop(context, false),
                                child: const Text('Cancel')),
                            FilledButton(
                                onPressed: () => Navigator.pop(context, true),
                                child: const Text('Delete')),
                          ],
                        ),
                      );
                      if (ok != true || !mounted) return;
                      final gone = await widget.state.sync.discardKept(widget.id, '${k['kept']}');
                      if (!mounted) return;
                      if (!gone) _tell('Could not delete it.');
                      await _refresh();
                    },
                  ),
                ]),
              ),
          ],
        ),
      ])),
    );
  }
}
