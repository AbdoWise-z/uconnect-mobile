// Settings > Synced folders: the folders this phone syncs (protocol section
// 6), the ones other devices offer it, and creating or joining one; and a page
// per folder for its members, conflicts and state -- the mobile SyncWindow.

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../app/app_state.dart';
import '../app/storage_access.dart';
import '../core/identity.dart';
import '../core/sync/sync_folder.dart';
import 'prompt_dialog.dart';
import 'settings_widgets.dart';
import 'theme.dart';

String _bytes(num n) {
  if (n < 1024) return '$n B';
  if (n < 1024 * 1024) return '${(n / 1024).toStringAsFixed(1)} KB';
  if (n < 1024 * 1024 * 1024) return '${(n / 1024 / 1024).toStringAsFixed(1)} MB';
  return '${(n / 1024 / 1024 / 1024).toStringAsFixed(1)} GB';
}

String _stateLine(Map<String, Object?> st, FolderConfig c) {
  final state = (st['state'] as String?) ?? (c.paused ? 'paused' : 'scanning');
  final files = (st['files'] as num?)?.toInt() ?? 0;
  final bytes = (st['bytes'] as num?) ?? 0;
  final needFiles = (st['needFiles'] as num?)?.toInt() ?? 0;
  final needBytes = (st['needBytes'] as num?) ?? 0;
  final label = switch (state) {
    'paused' => 'Paused',
    'missing' => 'Folder missing',
    'syncing' => 'Syncing $needFiles file${needFiles == 1 ? '' : 's'} (${_bytes(needBytes)})',
    'scanning' => 'Scanning…',
    _ => 'Up to date',
  };
  return '$label · $files file${files == 1 ? '' : 's'}, ${_bytes(bytes)}';
}

/// Asks where a synced folder should go: the app's own folder (no permission
/// needed) or one the user picks (needs all-files access on Android).
Future<String?> _chooseLocation(BuildContext context, AppState state, String label) async {
  final suggested = await state.defaultSyncDir(label);
  if (!context.mounted) return null;
  final choice = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Where should it be on this phone?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('In uConnect\'s folder:', style: TextStyle(color: UcColors.textSecondary)),
          const SizedBox(height: 6),
          Text(suggested,
              style: TextStyle(fontFamily: 'monospace', fontSize: 12, color: UcColors.text)),
          if (Platform.isAndroid) ...[
            const SizedBox(height: 14),
            Text(
              'Or pick any folder on the phone. That needs "All files access" for '
              'uConnect, which you can turn off again in Android settings.',
              style: TextStyle(color: UcColors.textSecondary, fontSize: 12),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        if (Platform.isAndroid)
          TextButton(
              onPressed: () => Navigator.pop(context, 'pick'), child: const Text('Pick a folder')),
        FilledButton(
            onPressed: () => Navigator.pop(context, 'default'),
            child: const Text('Use uConnect\'s folder')),
      ],
    ),
  );
  if (choice == 'default') return suggested;
  if (choice != 'pick') return null;
  if (!await StorageAccess.hasAllFilesAccess()) {
    await StorageAccess.requestAllFilesAccess();
    if (!context.mounted) return null;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Allow all files access'),
        content: const Text(
            'Turn on "Allow access to manage all files" for uConnect, then come '
            'back and pick the folder again.'),
        actions: [
          FilledButton(onPressed: () => Navigator.pop(context), child: const Text('OK')),
        ],
      ),
    );
    return null;
  }
  final picked = await FilePicker.platform.getDirectoryPath();
  return picked;
}

class SyncFoldersPage extends StatelessWidget {
  const SyncFoldersPage({required this.state, super.key});
  final AppState state;

  Future<void> _create(BuildContext context) async {
    final name = await askText(context, 'Name of the synced folder', initial: 'Sync');
    if (name == null || name.trim().isEmpty || !context.mounted) return;
    final path = await _chooseLocation(context, state, name.trim());
    if (path == null || !context.mounted) return;
    final id = await state.createSyncFolder(path, name.trim());
    if (context.mounted) {
      await Navigator.of(context).push(MaterialPageRoute<void>(
          builder: (_) => SyncFolderPage(state: state, id: id)));
    }
  }

  Future<void> _join(BuildContext context, String peerKey, String id, String label) async {
    final path = await _chooseLocation(context, state, label);
    if (path == null) return;
    final ok = await state.joinSyncFolder(peerKey, id, label, path);
    if (context.mounted && !ok) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not join: the folder is already here.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final folders = state.store.syncFolders;
        final offers = <(String, String, String)>[
          for (final e in state.syncOffers.entries)
            for (final f in e.value)
              if (state.syncFolder(f['id'] ?? '') == null) (e.key, f['id'] ?? '', f['label'] ?? '')
        ];
        return Scaffold(
          backgroundColor: UcColors.canvas,
          appBar: AppBar(title: const Text('Synced folders')),
          body: ListView(
            padding: const EdgeInsets.only(bottom: 28),
            children: [
              SettingsSection(
                title: 'On this phone',
                footer: 'A synced folder stays the same on every device it is shared '
                    'with: a change on any of them reaches the others. Only devices '
                    'you gave special rules take part, as you choose per folder.',
                children: [
                  if (folders.isEmpty)
                    SettingsTile(
                      icon: Icons.folder_off_outlined,
                      iconColor: UcColors.textDisabled,
                      title: 'No synced folders yet',
                    ),
                  for (final c in folders)
                    SettingsTile(
                      icon: Icons.folder_copy_outlined,
                      iconColor: UcColors.warning,
                      title: c.label.isEmpty ? 'Synced folder' : c.label,
                      subtitle: _stateLine(state.sync.folderStatus(c.id), c),
                      onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                          builder: (_) => SyncFolderPage(state: state, id: c.id))),
                    ),
                ],
              ),
              SettingsSection(children: [
                SettingsTile(
                  icon: Icons.create_new_folder_outlined,
                  iconColor: UcColors.accent,
                  title: 'New synced folder',
                  subtitle: 'Share a folder on this phone with your devices.',
                  onTap: () => _create(context),
                ),
              ]),
              if (offers.isNotEmpty)
                SettingsSection(
                  title: 'Offered to you',
                  children: [
                    for (final (key, id, label) in offers)
                      SettingsTile(
                        icon: Icons.download_for_offline_outlined,
                        title: label.isEmpty ? 'Synced folder' : label,
                        subtitle: 'from ${state.deviceNameForKey(key)}',
                        trailing: FilledButton(
                          onPressed: () => _join(context, key, id, label),
                          child: const Text('Join'),
                        ),
                      ),
                  ],
                ),
            ],
          ),
        );
      },
    );
  }
}

class SyncFolderPage extends StatelessWidget {
  const SyncFolderPage({required this.state, required this.id, super.key});
  final AppState state;
  final String id;

  // Devices that can be members: those with special rules (only they sync),
  // and anyone already a member, so they can be removed.
  List<String> _candidates(FolderConfig c) {
    final keys = <String>{
      ...state.store.special.keys,
      ...c.peers.keys,
    }..remove('');
    return keys.toList()
      ..sort((a, b) => state.deviceNameForKey(a).compareTo(state.deviceNameForKey(b)));
  }

  bool _online(String key) => state.session.peers.values
      .any((p) => p.identityKey == key && p.stateCode == 3);

  String _eventText(String kind) {
    if (kind.startsWith('following:')) {
      return 'conflict: followed ${state.deviceNameForKey(kind.substring(10))}';
    }
    if (kind.startsWith('blocked:')) return 'not changed here (${kind.substring(8).replaceAll('_', ' ')})';
    if (kind.startsWith('held:')) return 'not synced here';
    return switch (kind) {
      'conflict' => 'conflict: waiting for you',
      'kept' => 'conflict: kept this phone\'s version',
      'waiting' => 'conflict: waiting for its devices to connect',
      _ => kind,
    };
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final c = state.syncFolder(id);
        if (c == null) {
          return Scaffold(
              appBar: AppBar(title: const Text('Synced folder')),
              body: const Center(child: Text('This folder is no longer synced.')));
        }
        final st = state.sync.folderStatus(id);
        final conflicts = (st['conflicts'] as List?)?.cast<Map>() ?? const <Map>[];
        final held = (st['held'] as List?)?.cast<Map>() ?? const <Map>[];
        final blocked = (st['blocked'] as Map?) ?? const {};
        final events = state.syncEvents.where((e) => e.folderId == id).take(30).toList();
        return Scaffold(
          backgroundColor: UcColors.canvas,
          appBar: AppBar(title: Text(c.label.isEmpty ? 'Synced folder' : c.label)),
          body: ListView(
            padding: const EdgeInsets.only(bottom: 28),
            children: [
              SettingsSection(title: 'Folder', children: [
                SettingsTile(
                  icon: Icons.folder_outlined,
                  iconColor: UcColors.warning,
                  title: _stateLine(st, c),
                  subtitle: c.path,
                ),
                SettingsSwitchTile(
                  icon: Icons.pause_circle_outline,
                  title: 'Paused',
                  subtitle: 'Stops scanning and applying changes here.',
                  value: c.paused,
                  onChanged: (on) => state.setSyncPaused(id, on),
                ),
                SettingsTile(
                  icon: Icons.refresh,
                  title: 'Rescan now',
                  enabled: !c.paused,
                  onTap: () => state.sync.rescan(id),
                ),
              ]),
              SettingsSection(
                title: 'Devices',
                footer: 'Send: the device gets this folder and your changes. '
                    'Accept: you take its changes. A device that is only sent the '
                    'folder keeps a copy without changing yours.',
                children: [
                  for (final key in _candidates(c))
                    _MemberRow(
                      name: state.deviceNameForKey(key),
                      special: state.store.special.containsKey(key),
                      fingerprint: fingerprintOfHex(key),
                      online: _online(key),
                      grant: c.grantOf(key),
                      onChanged: (g) => state.setSyncMember(id, key,
                          receive: g.receive, contribute: g.contribute),
                    ),
                  if (_candidates(c).isEmpty)
                    SettingsTile(
                      icon: Icons.devices_other,
                      iconColor: UcColors.textDisabled,
                      title: 'No devices yet',
                      subtitle: 'Folders sync only with devices you gave special '
                          'rules: add them from its device page.',
                    ),
                ],
              ),
              if (conflicts.isNotEmpty)
                SettingsSection(title: 'Conflicts', children: [
                  for (final cf in conflicts)
                    _ConflictRow(state: state, id: id, conflict: cf),
                ]),
              if (held.isNotEmpty || blocked.isNotEmpty)
                SettingsSection(title: 'Not synced here', children: [
                  for (final h in held)
                    SettingsTile(
                      icon: Icons.block,
                      iconColor: UcColors.warning,
                      title: '${h['path']}',
                      subtitle: '${h['reason']}'.startsWith('clash:')
                          ? 'Only differs in letter case from ${'${h['reason']}'.substring(6)}'
                          : 'Its name does not work on every device (${'${h['reason']}'.replaceFirst('name:', '')})',
                    ),
                  for (final e in blocked.entries)
                    SettingsTile(
                      icon: Icons.error_outline,
                      iconColor: UcColors.error,
                      title: '${e.key}',
                      subtitle: 'Not changed here: ${'${e.value}'.replaceAll('_', ' ')}',
                    ),
                ]),
              if (events.isNotEmpty)
                SettingsSection(title: 'Recent', children: [
                  for (final e in events)
                    SettingsTile(title: e.path, subtitle: _eventText(e.kind)),
                ]),
              SettingsSection(children: [
                SettingsTile(
                  icon: Icons.logout,
                  iconColor: UcColors.error,
                  title: 'Stop syncing this folder',
                  subtitle: 'Its files stay on this phone.',
                  onTap: () async {
                    final ok = await showDialog<bool>(
                      context: context,
                      builder: (context) => AlertDialog(
                        title: const Text('Stop syncing?'),
                        content: const Text(
                            'This phone leaves the folder. Its files stay where they are.'),
                        actions: [
                          TextButton(
                              onPressed: () => Navigator.pop(context, false),
                              child: const Text('Cancel')),
                          FilledButton(
                              onPressed: () => Navigator.pop(context, true),
                              child: const Text('Stop syncing')),
                        ],
                      ),
                    );
                    if (ok == true) {
                      await state.leaveSyncFolder(id);
                      if (context.mounted) Navigator.of(context).pop();
                    }
                  },
                ),
              ]),
            ],
          ),
        );
      },
    );
  }
}

class _MemberRow extends StatelessWidget {
  const _MemberRow({
    required this.name,
    required this.fingerprint,
    required this.online,
    required this.special,
    required this.grant,
    required this.onChanged,
  });

  final String name;
  final String fingerprint;
  final bool online;
  final bool special;
  final Grant grant;
  final ValueChanged<Grant> onChanged;

  @override
  Widget build(BuildContext context) {
    Widget toggle(String label, bool value, ValueChanged<bool> set) => Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Switch(value: value, onChanged: set),
            Text(label, style: TextStyle(fontSize: 11, color: UcColors.textSecondary)),
          ],
        );
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
      child: Row(
        children: [
          Container(
            width: 9,
            height: 9,
            decoration: BoxDecoration(
              color: online ? UcColors.success : UcColors.textDisabled,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name,
                    style: TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w500, color: UcColors.text)),
                Text(fingerprint,
                    style: TextStyle(
                        fontSize: 11, fontFamily: 'monospace', color: UcColors.textSecondary)),
                if (!special)
                  Text('Not syncing: no special rules',
                      style: TextStyle(fontSize: 11, color: UcColors.warning)),
              ],
            ),
          ),
          toggle('Send', grant.receive,
              (on) => onChanged(Grant(receive: on, contribute: grant.contribute))),
          toggle('Accept', grant.contribute,
              (on) => onChanged(Grant(receive: grant.receive, contribute: on))),
        ],
      ),
    );
  }
}

class _ConflictRow extends StatelessWidget {
  const _ConflictRow({required this.state, required this.id, required this.conflict});
  final AppState state;
  final String id;
  final Map conflict;

  @override
  Widget build(BuildContext context) {
    final path = '${conflict['path']}';
    final candidates = (conflict['candidates'] as List?)?.cast<Map>() ?? const <Map>[];
    final waiting = conflict['waiting'] == true;
    final following = '${conflict['following'] ?? ''}';
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(path,
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500, color: UcColors.text)),
          const SizedBox(height: 2),
          Text(
            following.isNotEmpty
                ? 'Different on several devices; following ${state.deviceNameForKey(following)}.'
                : waiting
                    ? 'Different on several devices; waiting for them to connect.'
                    : 'Changed differently on several devices. Which one should stay?',
            style: TextStyle(fontSize: 12.5, color: UcColors.textSecondary),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              OutlinedButton(
                onPressed: () => state.sync.resolveConflict(id, path, 'mine', ''),
                child: const Text('Keep mine'),
              ),
              for (final cand in candidates)
                if (cand['mine'] != true)
                  OutlinedButton(
                    onPressed: () =>
                        state.sync.resolveConflict(id, path, 'theirs', '${cand['key']}'),
                    child: Text('Take ${state.deviceNameForKey('${cand['key']}')}\'s'),
                  ),
              TextButton(
                onPressed: () => state.sync.resolveConflict(id, path, 'skip', ''),
                child: const Text('Stop syncing this file'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
