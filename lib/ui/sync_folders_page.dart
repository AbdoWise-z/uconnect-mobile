// Settings > Synced folders: the folders this phone syncs (protocol section
// 6), the ones other devices offer it, creating or joining one, and when
// sync may run; and a page per folder for its state, what is in it, its
// rules, its members and how far each is, conflicts and kept files -- the
// mobile SyncWindow.

import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../app/app_state.dart';
import '../app/storage_access.dart';
import '../core/identity.dart';
import '../core/permissions.dart';
import '../core/sync/sync_folder.dart';
import 'adaptive.dart';
import 'format.dart';
import 'prompt_dialog.dart';
import 'settings_widgets.dart';
import 'sync_files_page.dart';
import 'sync_kept_page.dart';
import 'sync_rules_page.dart';
import 'sync_transfers_page.dart';
import 'theme.dart';

String _stateLine(Map<String, Object?> st, FolderConfig c) {
  final state = (st['state'] as String?) ?? (c.paused ? 'paused' : 'scanning');
  final files = (st['files'] as num?)?.toInt() ?? 0;
  final bytes = (st['bytes'] as num?) ?? 0;
  final needFiles = (st['needFiles'] as num?)?.toInt() ?? 0;
  final needBytes = (st['needBytes'] as num?) ?? 0;
  final conflicts = (st['conflicts'] as List?)?.length ?? 0;
  final deletes = (st['pendingDeleteCount'] as num?)?.toInt() ?? 0;
  final label = switch (state) {
    'paused' => 'Paused',
    'waiting' => st['reason'] == 'charging' ? 'Waiting for the charger' : 'Waiting for Wi-Fi',
    'missing' => 'Folder missing',
    'syncing' => 'Syncing ${plural(needFiles, 'file')} (${formatBytes(needBytes)})',
    'scanning' => 'Scanning…',
    _ => 'Up to date',
  };
  final extra = [
    if (conflicts > 0) plural(conflicts, 'conflict'),
    if (deletes > 0) '$deletes deletes waiting',
  ].join(', ');
  return '$label${extra.isEmpty ? '' : ' · $extra'} · ${plural(files, 'file')}, ${formatBytes(bytes)}';
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
        final active = state.sync.transfers().where((t) => t['active'] == true).length;
        final rate = state.sync.receiveRate();
        return Scaffold(
          backgroundColor: UcColors.canvas,
          appBar: AppBar(title: const Text('Synced folders')),
          body: ContentWidth(
              child: ListView(
            padding: const EdgeInsets.only(bottom: 28),
            children: [
              SettingsSection(
                title: 'On this phone',
                footer: 'A synced folder stays the same on every device it is shared '
                    'with: a change on any of them reaches the others. A device takes '
                    'part once you grant it Offer sync or Receive sync (its permissions), '
                    'then you choose per folder.',
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
                  if (folders.isNotEmpty)
                    SettingsTile(
                      icon: Icons.swap_vert,
                      iconColor: UcColors.accent,
                      title: 'Transfers',
                      subtitle: active == 0
                          ? 'Nothing being fetched'
                          : '${plural(active, 'file')} being fetched · ${formatRate(rate)}',
                      onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                          builder: (_) => SyncTransfersPage(state: state))),
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
              SettingsSection(
                title: 'When to sync',
                footer: state.sync.suspended.isEmpty
                    ? 'Sync pauses on every folder while a condition does not hold, and '
                        'goes on by itself when it does again.'
                    : state.sync.suspended == 'wifi'
                        ? 'Waiting for Wi-Fi: the phone is on a metered network.'
                        : 'Waiting for the charger.',
                children: [
                  SettingsSwitchTile(
                    icon: Icons.wifi,
                    title: 'Sync only on Wi-Fi',
                    subtitle: 'Not on mobile data or another metered network',
                    value: state.store.syncWifiOnly,
                    onChanged: (v) => state.saveSettings(syncWifiOnly: v),
                  ),
                  SettingsSwitchTile(
                    icon: Icons.battery_charging_full,
                    title: 'Sync only while charging',
                    value: state.store.syncChargingOnly,
                    onChanged: (v) => state.saveSettings(syncChargingOnly: v),
                  ),
                  SettingsSwitchTile(
                    icon: Icons.notifications_outlined,
                    title: 'Notify about sync problems',
                    subtitle: 'Conflicts, names that cannot sync, deletes waiting for you, '
                        'a device that stays behind',
                    value: state.store.syncNotify,
                    onChanged: (v) => state.saveSettings(syncNotify: v),
                  ),
                ],
              ),
            ],
          )),
        );
      },
    );
  }
}

class SyncFolderPage extends StatelessWidget {
  const SyncFolderPage({required this.state, required this.id, super.key});
  final AppState state;
  final String id;

  // Devices that can be members: those granted a sync permission here, and
  // anyone already a member, so they can be removed.
  List<String> _candidates(FolderConfig c) => state.syncCandidates(c);

  bool _online(String key) => state.session.peers.values
      .any((p) => p.identityKey == key && p.stateCode == 3);

  void _push(BuildContext context, Widget page) =>
      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));

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
        final members = {
          for (final m in (st['members'] as List?)?.cast<Map>() ?? const <Map>[])
            '${m['key']}': m.cast<String, Object?>()
        };
        final pending = (st['pendingDeletes'] as List?)?.cast<String>() ?? const <String>[];
        final pendingCount = (st['pendingDeleteCount'] as num?)?.toInt() ?? 0;
        final events = state.syncEvents.where((e) => e.folderId == id).take(30).toList();
        final files = (st['files'] as num?)?.toInt() ?? 0;
        final dirs = (st['dirs'] as num?)?.toInt() ?? 0;
        final bytes = (st['bytes'] as num?) ?? 0;
        final free = (st['free'] as num?)?.toInt() ?? -1;
        final transfers = (st['transfers'] as List?)?.length ?? 0;
        return Scaffold(
          backgroundColor: UcColors.canvas,
          appBar: AppBar(title: Text(c.label.isEmpty ? 'Synced folder' : c.label)),
          body: ContentWidth(
              child: ListView(
            padding: const EdgeInsets.only(bottom: 28),
            children: [
              SettingsSection(title: 'Folder', children: [
                SettingsTile(
                  icon: Icons.folder_outlined,
                  iconColor: UcColors.warning,
                  title: _stateLine(st, c),
                  subtitle: c.path,
                ),
                SettingsTile(
                  icon: Icons.pie_chart_outline,
                  title: '${plural(files, 'file')} in ${plural(dirs, 'folder')}, ${formatBytes(bytes)}',
                  subtitle: free < 0
                      ? 'Free space on this disk unknown'
                      : '${formatBytes(free)} free on this disk',
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
              SettingsSection(children: [
                SettingsTile(
                  icon: Icons.account_tree_outlined,
                  iconColor: UcColors.accent,
                  title: 'Files',
                  subtitle: 'What is in the folder, and the state of each file',
                  onTap: () => _push(context, SyncFilesPage(state: state, id: id)),
                ),
                SettingsTile(
                  icon: Icons.rule,
                  iconColor: UcColors.accent,
                  title: 'Rules',
                  subtitle: 'Edit .syncignore (every device) and .syncskip (this phone)',
                  onTap: () => _push(context, SyncRulesPage(state: state, id: id)),
                ),
                _KeptTile(state: state, id: id),
                SettingsTile(
                  icon: Icons.swap_vert,
                  iconColor: UcColors.accent,
                  title: 'Transfers',
                  subtitle: transfers == 0
                      ? 'Nothing being fetched'
                      : '${plural(transfers, 'file')} being fetched · ${formatRate(state.sync.receiveRate())}',
                  onTap: () => _push(context, SyncTransfersPage(state: state)),
                ),
              ]),
              if (pendingCount > 0)
                SettingsSection(
                  title: 'Deletes waiting for you',
                  footer: 'Another device removed many files at once. They stay here until '
                      'you decide. Keeping them makes them this phone\'s changes, so the '
                      'other devices get them back.',
                  children: [
                    SettingsTile(
                      icon: Icons.delete_sweep_outlined,
                      iconColor: UcColors.warning,
                      title: '${plural(pendingCount, 'file')} would be deleted here',
                      subtitle: [
                        ...pending.take(5),
                        if (pendingCount > 5) '…and ${pendingCount - 5} more',
                      ].join('\n'),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                      child: Row(children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            icon: const Icon(Icons.delete_outline, size: 18),
                            label: const Text('Delete them'),
                            onPressed: () => state.sync.confirmDeletes(id, true),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: FilledButton.icon(
                            icon: const Icon(Icons.restore, size: 18),
                            label: const Text('Keep them'),
                            onPressed: () => state.sync.confirmDeletes(id, false),
                          ),
                        ),
                      ]),
                    ),
                  ],
                ),
              SettingsSection(
                title: 'Devices',
                footer: 'Send: the device gets this folder and your changes. '
                    'Accept: you take its changes. A device that is only sent the '
                    'folder keeps a copy without changing yours. Pause keeps both '
                    'settings but grants nothing until you resume.',
                children: [
                  for (final key in _candidates(c))
                    _MemberRow(
                      state: state,
                      name: state.deviceNameForKey(key),
                      syncs: syncsWith(state.permissionsOfKey(key)),
                      fingerprint: fingerprintOfHex(key),
                      online: _online(key),
                      grant: c.grantOf(key),
                      status: members[key],
                      onChanged: (g) => state.setSyncMember(id, key,
                          receive: g.receive, contribute: g.contribute),
                      onPaused: c.peers.containsKey(key)
                          ? (p) => state.setSyncMemberPaused(id, key, p)
                          : null,
                    ),
                  if (_candidates(c).isEmpty)
                    SettingsTile(
                      icon: Icons.devices_other,
                      iconColor: UcColors.textDisabled,
                      title: 'No devices yet',
                      subtitle: 'Folders sync with devices granted Offer sync or Receive '
                          'sync here: grant one from its device page, or in the defaults.',
                    ),
                ],
              ),
              if (conflicts.isNotEmpty)
                SettingsSection(
                  title: 'Conflicts',
                  footer: 'Devices changed these files without seeing each other\'s change. '
                      'Whatever you choose reaches every device; a version you give up is '
                      'kept in .synctrash.',
                  children: [
                    for (final cf in conflicts)
                      _ConflictRow(state: state, id: id, conflict: cf),
                  ],
                ),
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
                      onTap: () => showSyncFileHistory(context, state, id, '${h['path']}'),
                    ),
                  for (final e in blocked.entries)
                    SettingsTile(
                      icon: Icons.error_outline,
                      iconColor: UcColors.error,
                      title: '${e.key}',
                      subtitle: 'Not changed here: ${'${e.value}'.replaceAll('_', ' ')}',
                      onTap: () => showSyncFileHistory(context, state, id, '${e.key}'),
                    ),
                ]),
              if (events.isNotEmpty)
                SettingsSection(title: 'Recent', children: [
                  for (final e in events)
                    SettingsTile(
                      title: e.path.isEmpty ? (c.label.isEmpty ? 'This folder' : c.label) : e.path,
                      subtitle: '${formatTime(e.time)}  ${syncEventText(state, e.kind)}',
                      onTap: e.path.isEmpty
                          ? null
                          : () => showSyncFileHistory(context, state, id, e.path),
                    ),
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
          )),
        );
      },
    );
  }
}

/// The "Kept files" entry: how many wait in .synctrash, asked of the sync
/// worker when the page opens and after the kept-files page closes, not on
/// every status tick.
class _KeptTile extends StatefulWidget {
  const _KeptTile({required this.state, required this.id});
  final AppState state;
  final String id;

  @override
  State<_KeptTile> createState() => _KeptTileState();
}

class _KeptTileState extends State<_KeptTile> {
  int? _count;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final list = await widget.state.sync.keptFiles(widget.id);
      if (mounted) setState(() => _count = list.length);
    } on Object {
      // sync stopped
    }
  }

  @override
  Widget build(BuildContext context) {
    final kept = _count;
    return SettingsTile(
      icon: Icons.history,
      iconColor: UcColors.accent,
      title: 'Kept files',
      subtitle: kept == null
          ? 'Files removed by syncing, restorable'
          : kept == 0
              ? 'Nothing removed by syncing yet'
              : '${plural(kept, 'file')} in .synctrash, restorable',
      onTap: () async {
        await Navigator.of(context).push(MaterialPageRoute<void>(
            builder: (_) => SyncKeptPage(state: widget.state, id: widget.id)));
        unawaited(_load());
      },
    );
  }
}

class _MemberRow extends StatelessWidget {
  const _MemberRow({
    required this.state,
    required this.name,
    required this.fingerprint,
    required this.online,
    required this.syncs,
    required this.grant,
    required this.status,
    required this.onChanged,
    required this.onPaused,
  });

  final AppState state;
  final String name;
  final String fingerprint;
  final bool online;
  final bool syncs; // granted a sync permission here
  final Grant grant;
  final Map<String, Object?>? status; // from folderStatus().members, once a member
  final ValueChanged<Grant> onChanged;
  final ValueChanged<bool>? onPaused;

  int _n(String key) => (status?[key] as num?)?.toInt() ?? 0;

  // Where the device is at, as short lines.
  List<(IconData, Color, String)> _lines() {
    final st = status;
    if (st == null) return const [];
    final out = <(IconData, Color, String)>[];
    if (grant.paused) {
      out.add((Icons.pause_circle_outline, UcColors.textSecondary, 'Paused: nothing is sent or taken'));
    }
    final sendFiles = _n('toSendFiles'), sendChanges = _n('toSendChanges');
    final recvFiles = _n('toReceiveFiles'), recvChanges = _n('toReceiveChanges');
    final eta = _n('eta');
    if (sendFiles + sendChanges > 0) {
      out.add((
        Icons.upload_outlined,
        UcColors.accent,
        'To send: ${sendFiles > 0 ? '${plural(sendFiles, 'file')} (${formatBytes(_n('toSendBytes'))})' : ''}'
            '${sendFiles > 0 && sendChanges > 0 ? ', ' : ''}'
            '${sendChanges > 0 ? plural(sendChanges, 'other change') : ''}'
      ));
    }
    if (recvFiles + recvChanges > 0) {
      out.add((
        Icons.download_outlined,
        UcColors.accent,
        'To receive: ${recvFiles > 0 ? '${plural(recvFiles, 'file')} (${formatBytes(_n('toReceiveBytes'))})' : ''}'
            '${recvFiles > 0 && recvChanges > 0 ? ', ' : ''}'
            '${recvChanges > 0 ? plural(recvChanges, 'other change') : ''}'
            '${eta > 0 ? ' · about ${formatDuration(eta)} left' : ''}'
      ));
    }
    final current = '${st['current'] ?? ''}';
    if (current.isNotEmpty) {
      final rate = st['sending'] == true ? _n('sendRate') : _n('rate');
      out.add((
        st['sending'] == true ? Icons.north_east : Icons.south_west,
        UcColors.accent,
        '${st['sending'] == true ? 'Sending' : 'Fetching'} $current'
            '${rate > 0 ? ' · ${formatRate(rate)}' : ''}'
      ));
    }
    if (sendFiles + sendChanges + recvFiles + recvChanges == 0 && !grant.paused) {
      final inSync = _n('lastInSync');
      out.add((
        Icons.check_circle_outline,
        UcColors.success,
        online
            ? 'Up to date'
            : inSync > 0
                ? 'Was up to date ${formatAgo(inSync)}'
                : 'Not in sync yet'
      ));
    } else if (_n('lastInSync') > 0) {
      out.add((Icons.history, UcColors.textSecondary, 'Last fully in sync ${formatAgo(_n('lastInSync'))}'));
    }
    final skipped = _n('skipped');
    if (skipped > 0) {
      out.add((Icons.remove_circle_outline, UcColors.textSecondary,
          'Holds back ${plural(skipped, 'path')} (skipped or not syncable there)'));
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    Widget toggle(String label, bool value, ValueChanged<bool> set) => Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Switch(value: value, onChanged: set),
            Text(label, style: TextStyle(fontSize: 11, color: UcColors.textSecondary)),
          ],
        );
    final lastSeen = _n('lastSeen');
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
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
                    Text(
                        '${online ? 'online' : lastSeen > 0 ? 'last seen ${formatAgo(lastSeen)}' : 'offline'}'
                        ' · $fingerprint',
                        style: TextStyle(fontSize: 11, color: UcColors.textSecondary)),
                    if (!syncs)
                      Text('Not syncing: no sync permission here',
                          style: TextStyle(fontSize: 11, color: UcColors.warning)),
                  ],
                ),
              ),
              if (onPaused != null)
                IconButton(
                  icon: Icon(grant.paused ? Icons.play_circle_outline : Icons.pause_circle_outline),
                  tooltip: grant.paused ? 'Resume this device' : 'Pause this device',
                  color: grant.paused ? UcColors.accent : null,
                  onPressed: () => onPaused!(!grant.paused),
                ),
              toggle('Send', grant.receive,
                  (on) => onChanged(Grant(receive: on, contribute: grant.contribute))),
              toggle('Accept', grant.contribute,
                  (on) => onChanged(Grant(receive: grant.receive, contribute: on))),
            ],
          ),
          for (final (icon, color, text) in _lines())
            Padding(
              padding: const EdgeInsets.only(left: 21, top: 3),
              child: Row(children: [
                Icon(icon, size: 14, color: color),
                const SizedBox(width: 6),
                Expanded(
                    child: Text(text,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12, color: color))),
              ]),
            ),
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
    final involved = conflict['involved'] == true;
    final following = '${conflict['following'] ?? ''}';
    String describe(Map cand) {
      if (cand['deleted'] == true) return 'deleted';
      if (cand['dir'] == true) return 'a folder';
      final mtime = (cand['mtime'] as num?)?.toInt() ?? 0;
      return '${formatBytes((cand['size'] as num?) ?? 0)} · '
          '${formatDateTime(DateTime.fromMillisecondsSinceEpoch(mtime))}';
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () => showSyncFileHistory(context, state, id, path),
            child: Row(children: [
              Expanded(
                child: Text(path,
                    style: TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w500, color: UcColors.text)),
              ),
              Icon(Icons.history, size: 18, color: UcColors.textSecondary),
            ]),
          ),
          const SizedBox(height: 2),
          Text(
            involved
                ? 'You changed it here while another device changed it too. Which one should stay?'
                : following.isNotEmpty
                    ? 'Different on several devices; following ${state.deviceNameForKey(following)}, the device connected longest.'
                    : waiting
                        ? 'Different on several devices; waiting for them to connect.'
                        : 'Different on several devices; keeping the version this phone has.',
            style: TextStyle(fontSize: 12.5, color: UcColors.textSecondary),
          ),
          const SizedBox(height: 6),
          // The versions side by side.
          for (final cand in candidates)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Row(children: [
                Icon(
                    cand['mine'] == true ? Icons.phone_android : Icons.devices_other,
                    size: 14,
                    color: cand['mine'] == true ? UcColors.accent : UcColors.textSecondary),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '${cand['mine'] == true ? 'This phone' : state.deviceNameForKey('${cand['key']}')}: ${describe(cand)}',
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 12,
                        color: cand['mine'] == true ? UcColors.text : UcColors.textSecondary),
                  ),
                ),
              ]),
            ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              if (candidates.any((cand) => cand['mine'] == true))
                (involved ? FilledButton.new : OutlinedButton.new)(
                  onPressed: () => state.sync.resolveConflict(id, path, 'mine', ''),
                  child: Text(involved ? 'Keep mine' : 'Keep this version'),
                ),
              for (final cand in candidates)
                if (cand['mine'] != true && '${cand['key']}'.isNotEmpty)
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
