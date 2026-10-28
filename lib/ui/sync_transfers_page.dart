// Everything folder sync is fetching right now, across folders, with speed,
// and what waits its turn.

import 'package:flutter/material.dart';

import '../app/app_state.dart';
import 'format.dart';
import 'settings_widgets.dart';
import 'theme.dart';

class SyncTransfersPage extends StatelessWidget {
  const SyncTransfersPage({required this.state, super.key});
  final AppState state;

  String _folderLabel(String id) {
    final c = state.syncFolder(id);
    return c == null || c.label.isEmpty ? 'Synced folder' : c.label;
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final all = state.sync.transfers();
        final active = all.where((t) => t['active'] == true).toList();
        final queued = all.where((t) => t['active'] != true).toList();
        final rate = state.sync.receiveRate();
        return Scaffold(
          backgroundColor: UcColors.canvas,
          appBar: AppBar(title: const Text('Sync transfers')),
          body: ListView(padding: const EdgeInsets.only(bottom: 28), children: [
            SettingsSection(
              title: 'Receiving · ${formatRate(rate)}',
              children: [
                if (active.isEmpty)
                  SettingsTile(
                    icon: Icons.check_circle_outline,
                    iconColor: UcColors.success,
                    title: 'Nothing being fetched',
                    subtitle: 'Every synced folder is as far along as its devices allow.',
                  ),
                for (final t in active)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('${t['path']}',
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 14.5, color: UcColors.text)),
                      const SizedBox(height: 2),
                      Text(
                        '${_folderLabel('${t['folder']}')} · '
                        '${formatBytes((t['done'] as num?) ?? 0)} of ${formatBytes((t['size'] as num?) ?? 0)}'
                        '${'${t['key']}'.isEmpty ? '' : ' · from ${state.deviceNameForKey('${t['key']}')}'}',
                        style: TextStyle(fontSize: 12, color: UcColors.textSecondary),
                      ),
                      const SizedBox(height: 6),
                      LinearProgressIndicator(
                        value: ((t['size'] as num?) ?? 0) > 0
                            ? ((t['done'] as num?) ?? 0) / ((t['size'] as num?) ?? 1)
                            : null,
                        backgroundColor: UcColors.border,
                      ),
                    ]),
                  ),
              ],
            ),
            if (queued.isNotEmpty)
              SettingsSection(
                title: 'Waiting its turn (${queued.length})',
                children: [
                  for (final t in queued.take(100))
                    SettingsTile(
                      icon: Icons.schedule,
                      iconColor: UcColors.textDisabled,
                      title: '${t['path']}',
                      subtitle:
                          '${_folderLabel('${t['folder']}')} · ${formatBytes((t['size'] as num?) ?? 0)}',
                    ),
                  if (queued.length > 100)
                    SettingsTile(title: '…and ${queued.length - 100} more'),
                ],
              ),
          ]),
        );
      },
    );
  }
}
