// A synced folder's files as sync sees them: a tree with each path's state
// (synced, waiting to send or receive, transferring with progress, in
// conflict, ignored, skipped, not syncable), a search and a filter, and per
// path: ignore everywhere, skip on this phone, share, history.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../app/app_state.dart';
import '../core/sync/sync_model.dart';
import '../core/sync/sync_scanner.dart';
import 'format.dart';
import 'theme.dart';

enum _Filter { all, pending, problems, left }

/// Icon and colour for a file state (shared with the folder page).
(IconData, Color) syncStateIcon(String state) => switch (state) {
      'synced' => (Icons.check_circle_outline, UcColors.success),
      'send' => (Icons.upload_outlined, UcColors.accent),
      'receive' => (Icons.download_outlined, UcColors.accent),
      'transferring' => (Icons.sync, UcColors.accent),
      'conflict' => (Icons.warning_amber_outlined, UcColors.warning),
      'ignored' => (Icons.visibility_off_outlined, UcColors.textDisabled),
      'skipped' => (Icons.remove_circle_outline, UcColors.textDisabled),
      'held' => (Icons.block, UcColors.warning),
      'blocked' => (Icons.error_outline, UcColors.error),
      _ => (Icons.help_outline, UcColors.textSecondary),
    };

/// A line saying what a file state means, with its detail.
String syncStateText(Map<String, Object?> row) {
  final detail = '${row['detail'] ?? ''}';
  switch ('${row['state']}') {
    case 'synced':
      return 'Synced';
    case 'send':
      return detail.isEmpty
          ? 'Waiting to send'
          : 'Waiting to send to ${plural(int.tryParse(detail) ?? 1, 'device')}';
    case 'receive':
      return detail == 'waiting'
          ? 'Waiting to receive: no device online has it'
          : detail == 'delete'
              ? 'To be deleted here'
              : 'Waiting to receive';
    case 'transferring':
      final p = (row['progress'] as num?)?.toDouble() ?? 0;
      return 'Receiving · ${(p * 100).round()}%';
    case 'conflict':
      return 'Conflict: changed on several devices';
    case 'ignored':
      return detail.isEmpty ? 'Ignored (.syncignore)' : 'Ignored by rule "$detail"';
    case 'skipped':
      return detail.isEmpty
          ? 'Skipped on this phone (.syncskip)'
          : 'Skipped on this phone by rule "$detail"';
    case 'held':
      return detail.startsWith('clash:')
          ? 'Not synced: only differs in letter case from ${detail.substring(6)}'
          : 'Not synced: its name does not work on every device (${detail.replaceFirst('name:', '')})';
    case 'blocked':
      return 'Not changed here: ${detail.replaceAll('_', ' ')}';
  }
  return '${row['state']}';
}

class SyncFilesPage extends StatefulWidget {
  const SyncFilesPage({required this.state, required this.id, super.key});
  final AppState state;
  final String id;

  @override
  State<SyncFilesPage> createState() => _SyncFilesPageState();
}

class _SyncFilesPageState extends State<SyncFilesPage> {
  final _expanded = <String>{};
  final _search = TextEditingController();
  _Filter _filter = _Filter.all;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  bool _passes(Map<String, Object?> row) {
    final state = '${row['state']}';
    switch (_filter) {
      case _Filter.all:
        return true;
      case _Filter.pending:
        return state == 'send' || state == 'receive' || state == 'transferring';
      case _Filter.problems:
        return state == 'conflict' || state == 'held' || state == 'blocked';
      case _Filter.left:
        return state == 'ignored' || state == 'skipped';
    }
  }

  // The rows to show: the tree, or a flat list when searching or filtering.
  List<(Map<String, Object?>, int)> _visible(List<Map<String, Object?>> all) {
    final query = _search.text.trim().toLowerCase();
    final flat = query.isNotEmpty || _filter != _Filter.all;
    final out = <(Map<String, Object?>, int)>[];
    for (final row in all) {
      final path = '${row['path']}';
      if (flat) {
        if (!_passes(row)) continue;
        if (query.isNotEmpty && !path.toLowerCase().contains(query)) continue;
        out.add((row, 0));
        continue;
      }
      final parts = path.split('/');
      var shown = true;
      for (var i = 1; i < parts.length && shown; i++) {
        shown = _expanded.contains(parts.sublist(0, i).join('/'));
      }
      if (shown) out.add((row, parts.length - 1));
    }
    return out;
  }

  Future<void> _menu(BuildContext context, Map<String, Object?> row) async {
    final path = '${row['path']}';
    final dir = row['dir'] == true;
    final state = '${row['state']}';
    final c = widget.state.syncFolder(widget.id);
    final abs = c == null ? '' : joinPath(c.path, path);
    final onDisk = abs.isNotEmpty &&
        FileSystemEntity.typeSync(abs, followLinks: false) != FileSystemEntityType.notFound;
    final choice = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: UcColors.panel,
      builder: (context) => SafeArea(
        child: ListView(shrinkWrap: true, children: [
          ListTile(
            leading: Icon(syncStateIcon(state).$1, color: syncStateIcon(state).$2),
            title: Text(path, style: TextStyle(color: UcColors.text)),
            subtitle: Text(syncStateText(row), style: TextStyle(color: UcColors.textSecondary)),
          ),
          Divider(height: 1, color: UcColors.border),
          ListTile(
            leading: const Icon(Icons.history),
            title: const Text('History'),
            onTap: () => Navigator.pop(context, 'history'),
          ),
          if (state != 'ignored')
            ListTile(
              leading: const Icon(Icons.visibility_off_outlined),
              title: const Text('Ignore everywhere'),
              subtitle: const Text('Adds it to .syncignore, which every device gets'),
              onTap: () => Navigator.pop(context, 'ignore'),
            ),
          if (state != 'skipped' && state != 'ignored')
            ListTile(
              leading: const Icon(Icons.remove_circle_outline),
              title: const Text('Skip on this phone'),
              subtitle: const Text('Adds it to .syncskip; this phone keeps its own copy'),
              onTap: () => Navigator.pop(context, 'skip'),
            ),
          if (!dir && onDisk)
            ListTile(
              leading: const Icon(Icons.ios_share),
              title: const Text('Share / open'),
              onTap: () => Navigator.pop(context, 'share'),
            ),
        ]),
      ),
    );
    if (choice == null || !context.mounted) return;
    switch (choice) {
      case 'history':
        await showSyncFileHistory(context, widget.state, widget.id, path);
      case 'ignore':
        final ok = await _confirmRule(context, path, false);
        if (ok) widget.state.sync.addRule(widget.id, false, path);
      case 'skip':
        if (await _confirmRule(context, path, true)) {
          widget.state.sync.addRule(widget.id, true, path);
        }
      case 'share':
        await SharePlus.instance.share(ShareParams(files: [XFile(abs)]));
    }
    if (mounted) setState(() {});
  }

  Future<bool> _confirmRule(BuildContext context, String path, bool skip) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(skip ? 'Skip on this phone?' : 'Ignore everywhere?'),
          content: Text(skip
              ? '$path stays as it is on this phone: changes to it are neither sent nor taken. '
                  'Other devices keep syncing it among themselves.'
              : '$path stops syncing on every device. It counts as deleted for sync, but every '
                  'device keeps its copy on disk. .syncignore is sent to every member.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text(skip ? 'Skip' : 'Ignore')),
          ],
        ),
      ) ==
      true;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.state,
      builder: (context, _) {
        final c = widget.state.syncFolder(widget.id);
        final all = widget.state.sync.files(widget.id);
        final rows = _visible(all);
        var pending = 0, problems = 0, left = 0;
        for (final r in all) {
          final s = '${r['state']}';
          if (s == 'send' || s == 'receive' || s == 'transferring') pending++;
          if (s == 'conflict' || s == 'held' || s == 'blocked') problems++;
          if (s == 'ignored' || s == 'skipped') left++;
        }
        return Scaffold(
          backgroundColor: UcColors.canvas,
          appBar: AppBar(
            title: Text(c == null || c.label.isEmpty ? 'Files' : c.label),
            actions: [
              PopupMenuButton<_Filter>(
                icon: Icon(_filter == _Filter.all ? Icons.filter_list : Icons.filter_list_alt,
                    color: _filter == _Filter.all ? null : UcColors.accent),
                tooltip: 'Filter',
                initialValue: _filter,
                onSelected: (f) => setState(() => _filter = f),
                itemBuilder: (context) => [
                  CheckedPopupMenuItem(
                      value: _Filter.all, checked: _filter == _Filter.all, child: const Text('All')),
                  CheckedPopupMenuItem(
                      value: _Filter.pending,
                      checked: _filter == _Filter.pending,
                      child: Text('Only pending ($pending)')),
                  CheckedPopupMenuItem(
                      value: _Filter.problems,
                      checked: _filter == _Filter.problems,
                      child: Text('Only problems ($problems)')),
                  CheckedPopupMenuItem(
                      value: _Filter.left,
                      checked: _filter == _Filter.left,
                      child: Text('Ignored or skipped ($left)')),
                ],
              ),
            ],
          ),
          body: Column(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: TextField(
                controller: _search,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  prefixIcon: const Icon(Icons.search),
                  hintText: 'Search files',
                  isDense: true,
                  suffixIcon: _search.text.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.clear),
                          tooltip: 'Clear',
                          onPressed: () => setState(_search.clear),
                        ),
                ),
              ),
            ),
            Expanded(
              child: rows.isEmpty
                  ? Center(
                      child: Text(
                          all.isEmpty ? 'Nothing in this folder yet.' : 'Nothing matches.',
                          style: TextStyle(color: UcColors.textSecondary)))
                  : ListView.builder(
                      itemCount: rows.length,
                      itemBuilder: (context, i) {
                        final (row, depth) = rows[i];
                        final path = '${row['path']}';
                        final dir = row['dir'] == true;
                        final flat = depth == 0 && (_search.text.isNotEmpty || _filter != _Filter.all);
                        final state = '${row['state']}';
                        final (icon, color) = syncStateIcon(state);
                        final progress = (row['progress'] as num?)?.toDouble() ?? -1;
                        return InkWell(
                          onTap: dir && !flat
                              ? () => setState(() {
                                    if (!_expanded.remove(path)) _expanded.add(path);
                                  })
                              : () => _menu(context, row),
                          onLongPress: () => _menu(context, row),
                          child: Padding(
                            padding: EdgeInsets.fromLTRB(16.0 + depth * 18, 8, 12, 8),
                            child: Row(children: [
                              if (dir && !flat)
                                Icon(
                                    _expanded.contains(path)
                                        ? Icons.expand_more
                                        : Icons.chevron_right,
                                    size: 20,
                                    color: UcColors.textSecondary)
                              else
                                const SizedBox(width: 20),
                              const SizedBox(width: 4),
                              Icon(dir ? Icons.folder_outlined : Icons.insert_drive_file_outlined,
                                  size: 22, color: dir ? UcColors.warning : UcColors.textSecondary),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(flat ? path : '${row['name']}',
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(fontSize: 14.5, color: UcColors.text)),
                                    Row(children: [
                                      Icon(icon, size: 14, color: color),
                                      const SizedBox(width: 4),
                                      Expanded(
                                        child: Text(syncStateText(row),
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(fontSize: 12, color: color)),
                                      ),
                                    ]),
                                    if (state == 'transferring' && progress >= 0)
                                      Padding(
                                        padding: const EdgeInsets.only(top: 4),
                                        child: LinearProgressIndicator(
                                            value: progress, backgroundColor: UcColors.border),
                                      ),
                                  ],
                                ),
                              ),
                              if (!dir) ...[
                                const SizedBox(width: 8),
                                Text(formatBytes((row['size'] as num?) ?? 0),
                                    style: TextStyle(fontSize: 12, color: UcColors.textSecondary)),
                              ],
                            ]),
                          ),
                        );
                      },
                    ),
            ),
          ]),
        );
      },
    );
  }
}

/// A sheet with everything known about one path: its state, size and time,
/// which device changed it how often (the version vector), what each device
/// holds, kept versions (with Restore), and the recent events about it.
Future<void> showSyncFileHistory(
    BuildContext context, AppState state, String id, String path) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: UcColors.panel,
    isScrollControlled: true,
    builder: (context) => StatefulBuilder(builder: (context, setSheet) {
      final info = state.sync.fileInfo(id, path);
      final c = state.syncFolder(id);
      // Member ids (in version vectors) to device names.
      final members = <String, String>{
        if (state.identity != null) memberIdOf(state.identity!.publicKeyHex): 'This phone',
        for (final key in {...state.store.special.keys, ...?c?.peers.keys})
          memberIdOf(key): state.deviceNameForKey(key),
      };
      final version = (info['version'] as Map?)?.cast<String, Object?>() ?? const {};
      final holders = (info['holders'] as List?)?.cast<Map>() ?? const [];
      final kept = (info['kept'] as List?)?.cast<Map>() ?? const [];
      final events = state.syncEvents
          .where((e) => e.folderId == id && e.path == path)
          .take(10)
          .toList();
      final mtime = (info['mtime'] as num?)?.toInt() ?? 0;
      TextStyle sub() => TextStyle(fontSize: 12.5, color: UcColors.textSecondary);
      Widget heading(String t) => Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
            child: Text(t.toUpperCase(),
                style: TextStyle(
                    fontSize: 11.5,
                    letterSpacing: 0.8,
                    fontWeight: FontWeight.w600,
                    color: UcColors.textSecondary)),
          );
      return DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        maxChildSize: 0.95,
        builder: (context, scroll) => ListView(controller: scroll, children: [
          ListTile(
            leading: Icon(syncStateIcon('${info['state']}').$1,
                color: syncStateIcon('${info['state']}').$2),
            title: Text(path, style: TextStyle(color: UcColors.text)),
            subtitle: Text(
                '${syncStateText(info)}'
                '${info['dir'] == true ? '' : ' · ${formatBytes((info['size'] as num?) ?? 0)}'}'
                '${mtime > 0 ? ' · ${formatDateTime(DateTime.fromMillisecondsSinceEpoch(mtime))}' : ''}',
                style: sub()),
          ),
          heading('Changes by device'),
          if (version.isEmpty)
            Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text('Not in the index yet.', style: sub())),
          for (final v in version.entries)
            ListTile(
              dense: true,
              leading: const Icon(Icons.edit_outlined, size: 20),
              title: Text(members[v.key] ?? 'Device ${v.key.substring(0, 8)}…',
                  style: TextStyle(color: UcColors.text)),
              trailing: Text(plural((v.value as num?)?.toInt() ?? 0, 'change'), style: sub()),
            ),
          if (holders.isNotEmpty) heading('What other devices hold'),
          for (final h in holders)
            ListTile(
              dense: true,
              leading: Icon(
                  h['deleted'] == true
                      ? Icons.delete_outline
                      : h['dir'] == true
                          ? Icons.folder_outlined
                          : Icons.insert_drive_file_outlined,
                  size: 20),
              title: Text(state.deviceNameForKey('${h['key']}'),
                  style: TextStyle(color: UcColors.text)),
              subtitle: Text(
                  h['deleted'] == true
                      ? 'deleted'
                      : h['dir'] == true
                          ? 'a folder'
                          : '${formatBytes((h['size'] as num?) ?? 0)} · '
                              '${formatDateTime(DateTime.fromMillisecondsSinceEpoch((h['mtime'] as num?)?.toInt() ?? 0))}'
                              '${h['skipped'] == true ? ' · holds it back' : ''}'
                              '${'${h['hash']}' == '${info['hash']}' ? ' · same content' : ''}',
                  style: sub()),
            ),
          if (kept.isNotEmpty) heading('Kept versions (.synctrash)'),
          for (final k in kept)
            ListTile(
              dense: true,
              leading: const Icon(Icons.history, size: 20),
              title: Text(
                  formatDateTime(DateTime.fromMillisecondsSinceEpoch((k['time'] as num?)?.toInt() ?? 0)),
                  style: TextStyle(color: UcColors.text)),
              subtitle: Text(formatBytes((k['size'] as num?) ?? 0), style: sub()),
              trailing: IconButton(
                icon: const Icon(Icons.restore),
                tooltip: 'Restore this version',
                onPressed: () {
                  final ok = state.sync.restoreKept(id, '${k['kept']}');
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                      content: Text(ok
                          ? 'Restored beside the current file; it syncs as your change.'
                          : 'Could not restore it.')));
                  setSheet(() {});
                },
              ),
            ),
          if (events.isNotEmpty) heading('Recent'),
          for (final e in events)
            ListTile(
              dense: true,
              leading: const Icon(Icons.notes, size: 20),
              title: Text(syncEventText(state, e.kind), style: TextStyle(color: UcColors.text)),
              subtitle: Text(formatAgo(e.time.millisecondsSinceEpoch), style: sub()),
            ),
          const SizedBox(height: 16),
        ]),
      );
    }),
  );
}

/// A short line for an event kind (see SyncEvent).
String syncEventText(AppState state, String kind) {
  if (kind.startsWith('following:')) {
    return 'conflict: followed ${state.deviceNameForKey(kind.substring(10))}';
  }
  if (kind.startsWith('blocked:')) return 'not changed here (${kind.substring(8).replaceAll('_', ' ')})';
  if (kind.startsWith('held:')) return 'not synced here';
  if (kind.startsWith('deletes:')) return '${kind.substring(8)} deletes wait for you';
  return switch (kind) {
    'conflict' => 'conflict: waiting for you',
    'kept' => 'conflict: kept this phone\'s version',
    'waiting' => 'conflict: waiting for its devices to connect',
    _ => kind,
  };
}
