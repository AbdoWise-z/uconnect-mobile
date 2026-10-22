// Settings: this device's name, the topic invite link (with a QR code other
// devices can read), what is offered and to whom by default, the trusted
// devices, and the shared folder -- the mobile SettingsWindow.

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../app/app_state.dart';
import '../core/identity.dart';
import '../core/session.dart';
import '../core/permissions.dart';
import 'theme.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({required this.state, super.key});
  final AppState state;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  AppState get state => widget.state;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        _deviceCard(context),
        _topicCard(context),
        _storageCard(context),
        _defaultsCard(context),
        _trustedCard(context),
        _aboutCard(context),
      ],
    );
  }

  Widget _card(String title, List<Widget> children) => Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title,
                  style: const TextStyle(
                      fontWeight: FontWeight.w600, color: UcColors.text)),
              const SizedBox(height: 10),
              ...children,
            ],
          ),
        ),
      );

  Widget _deviceCard(BuildContext context) {
    return _card('This device', [
      ListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Name', style: TextStyle(fontSize: 13)),
        subtitle: Text(state.store.deviceName,
            style: const TextStyle(color: UcColors.textSecondary)),
        trailing: const Icon(Icons.edit_outlined, size: 18),
        onTap: () async {
          final name = await _ask(context, 'Device name',
              initial: state.store.deviceName);
          if (name != null && name.isNotEmpty) {
            await state.saveSettings(deviceName: name);
          }
        },
      ),
      const SizedBox(height: 4),
      const Text('Fingerprint — other devices check this before trusting:',
          style: TextStyle(fontSize: 12, color: UcColors.textSecondary)),
      const SizedBox(height: 6),
      Container(
        width: double.infinity,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: UcColors.canvas,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: UcColors.border),
        ),
        child: Text(
          state.identity?.fingerprint ?? '',
          textAlign: TextAlign.center,
          style: const TextStyle(
              fontFamily: 'monospace', fontSize: 14, color: UcColors.text),
        ),
      ),
    ]);
  }

  Widget _topicCard(BuildContext context) {
    final uri = state.store.topicUri;
    return _card('Topic', [
      Row(
        children: [
          Expanded(
            child: Text(
              state.store.server.isEmpty
                  ? 'No server set'
                  : 'Server: ${state.store.server}',
              style: const TextStyle(
                  fontSize: 13, color: UcColors.textSecondary),
            ),
          ),
          TextButton(
            onPressed: () async {
              final server = await _ask(context, 'Rendezvous server (host:port)',
                  initial: state.store.server);
              if (server != null && server.contains(':')) {
                await state.saveSettings(server: server);
                await state.connect();
              }
            },
            child: const Text('Change'),
          ),
        ],
      ),
      if (uri.isNotEmpty) ...[
        const SizedBox(height: 6),
        Center(
          child: Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(8),
            ),
            child: QrImageView(
              data: uri,
              size: 180,
              backgroundColor: Colors.white,
            ),
          ),
        ),
        const SizedBox(height: 8),
        const Center(
          child: Text(
            'Send the invite link privately to your other devices.',
            style: TextStyle(fontSize: 12, color: UcColors.textSecondary),
          ),
        ),
        const SizedBox(height: 6),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            OutlinedButton.icon(
              icon: const Icon(Icons.copy, size: 16),
              label: const Text('Copy link'),
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: uri));
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                      content: Text('Invite link copied'),
                      duration: Duration(seconds: 2)));
                }
              },
            ),
            const SizedBox(width: 8),
            TextButton(
              onPressed: () => _changeTopic(context),
              child: const Text('Change topic...'),
            ),
          ],
        ),
      ],
      SwitchListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        title: const Text('Force the relay', style: TextStyle(fontSize: 13)),
        subtitle: const Text(
            'Skip NAT punching; for networks where it is known to fail.',
            style: TextStyle(fontSize: 11, color: UcColors.textSecondary)),
        value: state.store.forceRelay,
        onChanged: (on) async {
          await state.saveSettings(forceRelay: on);
          if (state.session.status != SessionStatus.offline) {
            await state.connect();
          }
        },
      ),
    ]);
  }

  Future<void> _changeTopic(BuildContext context) async {
    final link = await _ask(context, 'Invite link (uconn://...)',
        initial: state.store.topicUri);
    if (link == null || !link.startsWith('uconn://')) return;
    await state.saveSettings(topicUri: link);
    await state.connect();
  }

  Widget _storageCard(BuildContext context) {
    return _card('Storage', [
      SwitchListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        title: const Text('Offer storage', style: TextStyle(fontSize: 13)),
        subtitle: const Text(
            'Let devices you allow browse this device\'s shared folder.',
            style: TextStyle(fontSize: 11, color: UcColors.textSecondary)),
        value: state.store.offerStorage,
        onChanged: (on) => state.saveSettings(offerStorage: on),
      ),
      SwitchListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        title: const Text('Offer screen sharing', style: TextStyle(fontSize: 13)),
        subtitle: const Text(
            'Let a trusted device you grant it watch this screen. Android asks '
            'to confirm screen capture each time.',
            style: TextStyle(fontSize: 11, color: UcColors.textSecondary)),
        value: state.store.offerScreen,
        onChanged: (on) => state.saveSettings(offerScreen: on),
      ),
      SwitchListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        title: const Text('Offer remote control', style: TextStyle(fontSize: 13)),
        subtitle: const Text(
            'Let a trusted device you grant it control this device while it '
            'watches your screen. Needs the uConnect accessibility service on.',
            style: TextStyle(fontSize: 11, color: UcColors.textSecondary)),
        value: state.store.offerControl,
        onChanged: (on) => state.saveSettings(offerControl: on),
      ),
      if (state.store.offerControl && !state.controlAvailable)
        Padding(
          padding: const EdgeInsets.only(top: 4, bottom: 4),
          child: Row(
            children: [
              const Expanded(
                child: Text(
                  'The remote-control service is off. Turn on "uConnect remote '
                  'control" under Accessibility to allow control.',
                  style: TextStyle(fontSize: 11, color: UcColors.warning),
                ),
              ),
              TextButton(
                onPressed: () async {
                  await state.input.openSettings();
                },
                child: const Text('Enable'),
              ),
            ],
          ),
        ),
      ListTile(
        contentPadding: EdgeInsets.zero,
        leading: const Icon(Icons.folder_outlined, color: UcColors.warning),
        title: const Text('Shared', style: TextStyle(fontSize: 13)),
        subtitle: Text(
          'Files you add here are what other devices see.',
          style: const TextStyle(fontSize: 11, color: UcColors.textSecondary),
        ),
        trailing: TextButton(
          onPressed: () => _addToShared(context),
          child: const Text('Add files...'),
        ),
      ),
    ]);
  }

  Future<void> _addToShared(BuildContext context) async {
    final result = await FilePicker.platform.pickFiles(allowMultiple: true);
    if (result == null) return;
    var added = 0;
    for (final f in result.files) {
      final src = f.path;
      if (src == null) continue;
      try {
        await File(src).copy(
            '${state.sharedDir}${Platform.pathSeparator}${f.name}');
        added++;
      } on FileSystemException {
        // skip what cannot be read
      }
    }
    if (context.mounted && added > 0) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('$added file(s) added to Shared'),
          duration: const Duration(seconds: 2)));
    }
  }

  Widget _defaultsCard(BuildContext context) {
    final defaults = state.store.defaultPermissions;
    return _card('Devices that are not trusted may', [
      const Text(
        'Applies to every device in the topic until you trust it. '
        'Trusted-only grants are never available here.',
        style: TextStyle(fontSize: 12, color: UcColors.textSecondary),
      ),
      const SizedBox(height: 4),
      for (final info in permissionTable)
        if (info.available && !info.trustedOnly)
          SwitchListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text('${_serviceLabel(info.service)}: ${info.label}',
                style: const TextStyle(fontSize: 13)),
            subtitle: Text(info.description,
                style: const TextStyle(
                    fontSize: 11, color: UcColors.textSecondary)),
            value: defaults.contains(info.id),
            onChanged: (on) async {
              final next = {...defaults};
              if (on) {
                next.add(info.id);
              } else {
                next.remove(info.id);
              }
              await state.setDefaultPermissions(next);
              setState(() {});
            },
          ),
    ]);
  }

  Widget _trustedCard(BuildContext context) {
    final trusted = state.store.trusted.values.toList();
    return _card('Trusted devices', [
      if (trusted.isEmpty)
        const Text('None yet. Trust a device from its page under Devices.',
            style: TextStyle(fontSize: 12, color: UcColors.textSecondary)),
      for (final t in trusted)
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading:
              const Icon(Icons.verified_user, color: UcColors.success, size: 20),
          title: Text(t.name.isEmpty ? 'Unnamed device' : t.name,
              style: const TextStyle(fontSize: 13)),
          subtitle: Text(fingerprintOfHex(t.keyHex),
              style: const TextStyle(
                  fontSize: 11,
                  fontFamily: 'monospace',
                  color: UcColors.textSecondary)),
          trailing: TextButton(
            onPressed: () async {
              await state.untrustDevice(t.keyHex);
              setState(() {});
            },
            child: const Text('Remove'),
          ),
        ),
    ]);
  }

  Widget _aboutCard(BuildContext context) {
    return _card('About', [
      const Text(
        'uConnect Mobile 0.1.0 — talks the uConnect app protocol '
        '(storage 1.3) with uConnect Desktop over the uconnect library\'s '
        'end-to-end encrypted sessions.',
        style: TextStyle(fontSize: 12, color: UcColors.textSecondary),
      ),
      const SizedBox(height: 8),
      Row(
        children: [
          OutlinedButton(
            onPressed: () => state.connect(),
            child: const Text('Reconnect'),
          ),
          const SizedBox(width: 8),
          TextButton(
            onPressed: () => _showLog(context),
            child: const Text('Session log'),
          ),
        ],
      ),
    ]);
  }

  void _showLog(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: UcColors.panel,
      builder: (context) => SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(12),
          children: [
            for (final line in state.session.logHistory.reversed)
              Text(line,
                  style: const TextStyle(
                      fontSize: 11,
                      fontFamily: 'monospace',
                      color: UcColors.textSecondary)),
          ],
        ),
      ),
    );
  }

  String _serviceLabel(String service) => switch (service) {
        'storage' => 'Storage',
        'camera' => 'Camera',
        'screen' => 'Screen Sharing',
        'control' => 'Remote Control',
        'display' => 'Extended Display',
        _ => service,
      };

  Future<String?> _ask(BuildContext context, String title,
      {String initial = ''}) async {
    final controller = TextEditingController(text: initial);
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title, style: const TextStyle(fontSize: 15)),
        content: TextField(controller: controller, autofocus: true),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, controller.text.trim()),
              child: const Text('OK')),
        ],
      ),
    );
    controller.dispose();
    return value;
  }
}
