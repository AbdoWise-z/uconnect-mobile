// Browsing another device's shared folders: list with paging, download to
// this device, upload from it, new folder / rename / delete / move-copy --
// the mobile StorageView. A live fs.watch refreshes the open folder.

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../app/app_state.dart';
import '../core/storage/storage_client.dart';
import 'prompt_dialog.dart';
import 'adaptive.dart';
import 'theme.dart';

class StorageView extends StatefulWidget {
  const StorageView(
      {required this.state, required this.devId, required this.devName, super.key});

  final AppState state;
  final String devId;
  final String devName;

  @override
  State<StorageView> createState() => _StorageViewState();
}

class _StorageViewState extends State<StorageView> {
  String _path = '/';
  FsListing? _listing;
  String _error = '';
  bool _loading = false;
  int? _watchId;

  StorageClient get client => widget.state.storageClient;

  @override
  void initState() {
    super.initState();
    _open('/');
  }

  @override
  void dispose() {
    if (_watchId != null) client.unwatch(_watchId!);
    super.dispose();
  }

  Future<void> _open(String path) async {
    setState(() {
      _loading = true;
      _error = '';
    });
    try {
      final listing = await client.list(widget.devId, path);
      if (!mounted) return;
      if (_watchId != null) client.unwatch(_watchId!);
      _watchId = client.watch(widget.devId, path, (_) => _reload());
      setState(() {
        _path = path;
        _listing = listing;
        _loading = false;
      });
    } on FsException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = _describe(e);
        _loading = false;
      });
    }
  }

  Future<void> _reload() async {
    try {
      final listing = await client.list(widget.devId, _path);
      if (mounted) setState(() => _listing = listing);
    } on FsException {
      // The folder may be mid-change; the next fs.changed tries again.
    }
  }

  String _describe(FsException e) => switch (e.code) {
        'not_offered' => 'The device does not offer storage.',
        'forbidden' => 'The device has not granted this.',
        'not_found' => 'No such folder.',
        'busy' => 'The device is busy; try again shortly.',
        'timeout' => 'No answer from the device.',
        'read_only' => 'The share is read-only.',
        _ => e.toString(),
      };

  void _up() {
    if (_path == '/') return;
    final cut = _path.lastIndexOf('/');
    _open(cut <= 0 ? '/' : _path.substring(0, cut));
  }

  bool get _mayUpload {
    final p = widget.state.session.peers[widget.devId];
    return p != null &&
        p.grantedToMe.contains('storage.upload') &&
        _path != '/' &&
        (_listing?.readOnly != true);
  }

  bool get _mayWrite {
    final p = widget.state.session.peers[widget.devId];
    return p != null &&
        p.grantedToMe.contains('storage.write') &&
        (_listing?.readOnly != true);
  }

  bool get _mayRead {
    final p = widget.state.session.peers[widget.devId];
    return p != null && p.grantedToMe.contains('storage.read');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.devName, style: const TextStyle(fontSize: 15)),
            Text(_path,
                style: TextStyle(
                    fontSize: 12, color: UcColors.textSecondary)),
          ],
        ),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () {
            if (_path == '/') {
              Navigator.of(context).pop();
            } else {
              _up();
            }
          },
        ),
        actions: [
          if (_mayUpload)
            IconButton(
              icon: const Icon(Icons.upload_file_outlined),
              tooltip: 'Upload a file here',
              onPressed: _pickAndUpload,
            ),
          if (_mayUpload)
            IconButton(
              icon: const Icon(Icons.create_new_folder_outlined),
              tooltip: 'New folder',
              onPressed: _newFolder,
            ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _reload,
          ),
        ],
      ),
      body: ContentWidth(maxWidth: 900, child: _body()),
    );
  }

  Widget _body() {
    if (_loading && _listing == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error.isNotEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_error,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: UcColors.error)),
              const SizedBox(height: 12),
              OutlinedButton(
                  onPressed: () => _open(_path), child: const Text('Retry')),
            ],
          ),
        ),
      );
    }
    final listing = _listing;
    if (listing == null) return const SizedBox.shrink();
    if (listing.entries.isEmpty) {
      return Center(
        child: Text('Empty folder',
            style: TextStyle(color: UcColors.textSecondary)),
      );
    }
    final entries = [...listing.entries]..sort((a, b) {
        if (a.dir != b.dir) return a.dir ? -1 : 1;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
    return RefreshIndicator(
      onRefresh: _reload,
      child: ListView.builder(
        physics: const AlwaysScrollableScrollPhysics(),
        itemCount: entries.length,
        itemBuilder: (context, i) {
          final e = entries[i];
          final childPath = _path == '/' ? '/${e.name}' : '$_path/${e.name}';
          return ListTile(
            leading: Icon(
              e.dir
                  ? (e.readOnly == true
                      ? Icons.folder_special_outlined
                      : Icons.folder_outlined)
                  : Icons.insert_drive_file_outlined,
              color: e.dir ? UcColors.warning : UcColors.textSecondary,
            ),
            title: Text(e.name, overflow: TextOverflow.ellipsis),
            subtitle: e.dir
                ? (e.readOnly == true
                    ? Text('read-only',
                        style: TextStyle(
                            fontSize: 11, color: UcColors.textSecondary))
                    : null)
                : Text(
                    '${_bytes(e.size)}${e.mtime > 0 ? ' · ${_date(e.mtime)}' : ''}',
                    style: TextStyle(
                        fontSize: 11, color: UcColors.textSecondary)),
            onTap: e.dir ? () => _open(childPath) : null,
            trailing: PopupMenuButton<String>(
              color: UcColors.popup,
              itemBuilder: (context) => [
                if (!e.dir && _mayRead)
                  const PopupMenuItem(
                      value: 'download', child: Text('Download')),
                if (_mayWrite)
                  const PopupMenuItem(value: 'rename', child: Text('Rename')),
                if (_mayWrite)
                  const PopupMenuItem(value: 'delete', child: Text('Delete')),
              ],
              onSelected: (action) => _onAction(action, e, childPath),
            ),
          );
        },
      ),
    );
  }

  Future<void> _onAction(String action, FsEntry e, String childPath) async {
    switch (action) {
      case 'download':
        final local =
            '${widget.state.downloadsDir}${Platform.pathSeparator}${safeLocalName(e.name)}';
        client.download(widget.devId, childPath, local);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Downloading ${e.name} — see Transfers'),
            duration: const Duration(seconds: 2),
          ));
        }
      case 'rename':
        final name = await _askName('Rename', initial: e.name);
        if (name == null || name.isEmpty || name == e.name) return;
        await _tryOp(() => client.rename(widget.devId, childPath, name));
      case 'delete':
        final sure = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text('Delete ${e.name}?'),
            content: Text(e.dir
                ? 'The folder and everything in it will be deleted on the other device.'
                : 'The file will be deleted on the other device.'),
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
        if (sure == true) {
          await _tryOp(() => client.delete(widget.devId, childPath));
        }
    }
  }

  Future<void> _tryOp(
      Future<Map<String, Object?>> Function() op) async {
    try {
      await op();
      await _reload();
    } on FsException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(_describe(e))));
      }
    }
  }

  Future<String?> _askName(String title, {String initial = ''}) =>
      askText(context, title, initial: initial);

  Future<void> _newFolder() async {
    final name = await _askName('New folder');
    if (name == null || name.isEmpty) return;
    await _tryOp(() => client.mkdir(widget.devId, _path, name));
  }

  Future<void> _pickAndUpload() async {
    final result = await FilePicker.platform.pickFiles(allowMultiple: true);
    if (result == null) return;
    for (final f in result.files) {
      final path = f.path;
      if (path == null) continue;
      client.upload(widget.devId, path, _path);
    }
    if (mounted && result.files.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Uploading — see Transfers'),
        duration: Duration(seconds: 2),
      ));
    }
  }

  String _bytes(int n) {
    if (n < 1024) return '$n B';
    if (n < 1024 * 1024) return '${(n / 1024).toStringAsFixed(1)} KB';
    if (n < 1024 * 1024 * 1024) {
      return '${(n / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    return '${(n / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }

  String _date(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int v) => v < 10 ? '0$v' : '$v';
    return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
  }
}
