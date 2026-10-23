// Settings: this device's name, the topic invite link (with a QR code other
// devices can read), what is offered and to whom by default, the trusted
// devices, and the shared folder -- the mobile SettingsWindow.

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../app/app_state.dart';
import '../app/store.dart';
import '../core/identity.dart';
import '../core/session.dart';
import '../core/permissions.dart';
import 'prompt_dialog.dart';
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
        _appearanceCard(context),
        _storageCard(context),
        _cameraCard(context),
        _screenCard(context),
        _controlCard(context),
        _defaultsCard(context),
        _trustedCard(context),
        _aboutCard(context),
      ],
    );
  }

  Widget _card(String title, List<Widget> children,
          {bool initiallyExpanded = true}) =>
      _CollapsibleCard(
          title: title,
          initiallyExpanded: initiallyExpanded,
          children: children);

  // Colour-scheme picker. Switching restyles the whole app live (main.dart
  // rebuilds the theme from the stored scheme).
  Widget _appearanceCard(BuildContext context) {
    return _card('Appearance', [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Color scheme',
                style: TextStyle(fontSize: 11, color: UcColors.textSecondary)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final s in ucSchemes)
                  ChoiceChip(
                    label: Text(s.label),
                    selected: state.store.colorScheme == s.id,
                    onSelected: (_) =>
                        state.saveSettings(colorScheme: s.id),
                  ),
              ],
            ),
          ],
        ),
      ),
    ]);
  }

  Widget _deviceCard(BuildContext context) {
    return _card('This device', [
      ListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Name', style: TextStyle(fontSize: 13)),
        subtitle: Text(state.store.deviceName,
            style: TextStyle(color: UcColors.textSecondary)),
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
      Text('Fingerprint — other devices check this before trusting:',
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
          style: TextStyle(
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
              style: TextStyle(
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
        Center(
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
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Relay', style: TextStyle(fontSize: 13)),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: SegmentedButton<int>(
                showSelectedIcon: false,
                style: ButtonStyle(
                  visualDensity: VisualDensity.compact,
                  textStyle: WidgetStateProperty.all(
                      const TextStyle(fontSize: 12)),
                ),
                segments: [
                  for (var i = 0; i < RelayMode.labels.length; i++)
                    ButtonSegment<int>(
                        value: i, label: Text(RelayMode.labels[i])),
                ],
                selected: {state.store.relayMode},
                onSelectionChanged: (s) async {
                  await state.saveSettings(relayMode: s.first);
                  if (state.session.status != SessionStatus.offline) {
                    await state.connect();
                  }
                },
              ),
            ),
            const SizedBox(height: 6),
            Text(RelayMode.blurbs[state.store.relayMode],
                style: TextStyle(
                    fontSize: 11, color: UcColors.textSecondary)),
          ],
        ),
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

  // The camera-source controls shown under "Offer camera": which of this
  // device's cameras to offer, and the top resolution/frame rate to encode at.
  List<Widget> _cameraSourceSettings() {
    final cams = state.cameras;
    String label(String f) => switch (f) {
          'front' => 'Front camera',
          'back' => 'Back camera',
          _ => 'External camera',
        };
    bool isOffered(String id) =>
        state.store.cameraOffered.isEmpty ||
        state.store.cameraOffered.contains(id);
    void toggle(String id, bool on) {
      final all = {for (final c in cams) c.id};
      final set = state.store.cameraOffered.isEmpty
          ? {...all}
          : {...state.store.cameraOffered};
      if (on) {
        set.add(id);
      } else {
        set.remove(id);
      }
      if (set.isEmpty) return; // always offer at least one
      state.saveSettings(cameraOffered: set);
    }

    const widths = [1920, 1280, 960, 640];
    const rates = [60, 30, 24, 15];
    Widget drop(int value, List<int> options, String suffix, void Function(int) set) =>
        DropdownButton<int>(
          value: options.contains(value) ? value : options[1],
          isDense: true,
          style: TextStyle(fontSize: 12, color: UcColors.text),
          dropdownColor: UcColors.panel,
          underline: const SizedBox.shrink(),
          items: [
            for (final o in options)
              DropdownMenuItem(value: o, child: Text('$o$suffix'))
          ],
          onChanged: (v) {
            if (v != null) set(v);
          },
        );

    return [
      Padding(
        padding: EdgeInsets.only(left: 16, top: 2),
        child: Text('Cameras to offer',
            style: TextStyle(fontSize: 11, color: UcColors.textSecondary)),
      ),
      if (cams.isEmpty)
        Padding(
          padding: EdgeInsets.only(left: 16, top: 4, bottom: 4),
          child: Text('No cameras found on this device.',
              style: TextStyle(fontSize: 11, color: UcColors.textSecondary)),
        ),
      for (final c in cams)
        Padding(
          padding: const EdgeInsets.only(left: 8),
          child: SwitchListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text(label(c.facing), style: const TextStyle(fontSize: 12)),
            value: isOffered(c.id),
            onChanged: (on) => toggle(c.id, on),
          ),
        ),
      Padding(
        padding: const EdgeInsets.only(left: 16, top: 4, bottom: 6),
        child: Row(
          children: [
            const Text('Up to', style: TextStyle(fontSize: 12)),
            const SizedBox(width: 10),
            drop(state.store.cameraMaxWidth, widths, 'px',
                (v) => state.saveSettings(cameraMaxWidth: v)),
            const SizedBox(width: 14),
            drop(state.store.cameraMaxFps, rates, ' fps',
                (v) => state.saveSettings(cameraMaxFps: v)),
          ],
        ),
      ),
    ];
  }

  // One switch + its description, used for each "offer <service>" toggle.
  Widget _offerSwitch(String title, String subtitle, bool value,
          ValueChanged<bool> onChanged) =>
      SwitchListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        title: Text(title, style: const TextStyle(fontSize: 13)),
        subtitle: Text(subtitle,
            style: TextStyle(fontSize: 11, color: UcColors.textSecondary)),
        value: value,
        onChanged: onChanged,
      );

  Widget _storageCard(BuildContext context) {
    return _card('Storage', [
      _offerSwitch(
          'Offer storage',
          'Let devices you allow browse this device\'s shared folder.',
          state.store.offerStorage,
          (on) => state.saveSettings(offerStorage: on)),
      ListTile(
        contentPadding: EdgeInsets.zero,
        leading: Icon(Icons.folder_outlined, color: UcColors.warning),
        title: const Text('Shared folder', style: TextStyle(fontSize: 13)),
        subtitle: Text(
          'Files you add here are what other devices see.',
          style: TextStyle(fontSize: 11, color: UcColors.textSecondary),
        ),
        trailing: TextButton(
          onPressed: () => _addToShared(context),
          child: const Text('Add files...'),
        ),
      ),
    ]);
  }

  Widget _cameraCard(BuildContext context) {
    return _card('Camera', [
      _offerSwitch(
          'Offer camera',
          'Let a trusted device you grant it watch this device\'s camera. '
              'Asks for the camera permission, and to confirm each viewer.',
          state.store.offerCamera,
          (on) => state.saveSettings(offerCamera: on)),
      if (state.store.offerCamera) ..._cameraSourceSettings(),
    ]);
  }

  Widget _screenCard(BuildContext context) {
    return _card('Screen sharing', [
      _offerSwitch(
          'Offer screen sharing',
          'Let a trusted device you grant it watch this screen. Android asks '
              'to confirm screen capture each time.',
          state.store.offerScreen,
          (on) => state.saveSettings(offerScreen: on)),
    ]);
  }

  Widget _controlCard(BuildContext context) {
    return _card('Remote control', [
      _offerSwitch(
          'Offer remote control',
          'Let a trusted device you grant it control this device while it '
              'watches your screen. Needs the uConnect accessibility service on.',
          state.store.offerControl,
          (on) => state.saveSettings(offerControl: on)),
      if (state.store.offerControl && !state.controlAvailable)
        Padding(
          padding: const EdgeInsets.only(top: 4, bottom: 4),
          child: Row(
            children: [
              Expanded(
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
      Text(
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
                style: TextStyle(
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
        Text('None yet. Trust a device from its page under Devices.',
            style: TextStyle(fontSize: 12, color: UcColors.textSecondary)),
      for (final t in trusted)
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading:
              Icon(Icons.verified_user, color: UcColors.success, size: 20),
          title: Text(t.name.isEmpty ? 'Unnamed device' : t.name,
              style: const TextStyle(fontSize: 13)),
          subtitle: Text(fingerprintOfHex(t.keyHex),
              style: TextStyle(
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
      Text(
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
                  style: TextStyle(
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
          {String initial = ''}) =>
      askText(context, title, initial: initial);
}

/// A settings card whose body can be collapsed by tapping its header, so the
/// long settings list stays scannable.
class _CollapsibleCard extends StatefulWidget {
  const _CollapsibleCard({
    required this.title,
    required this.children,
    this.initiallyExpanded = true,
  });

  final String title;
  final List<Widget> children;
  final bool initiallyExpanded;

  @override
  State<_CollapsibleCard> createState() => _CollapsibleCardState();
}

class _CollapsibleCardState extends State<_CollapsibleCard> {
  late bool _expanded = widget.initiallyExpanded;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            InkWell(
              onTap: () => setState(() => _expanded = !_expanded),
              borderRadius: BorderRadius.circular(6),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(widget.title,
                          style: TextStyle(
                              fontWeight: FontWeight.w600, color: UcColors.text)),
                    ),
                    AnimatedRotation(
                      turns: _expanded ? 0 : -0.25,
                      duration: const Duration(milliseconds: 150),
                      child: Icon(Icons.expand_more,
                          color: UcColors.textSecondary, size: 20),
                    ),
                  ],
                ),
              ),
            ),
            AnimatedCrossFade(
              firstChild: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [const SizedBox(height: 10), ...widget.children],
              ),
              secondChild: const SizedBox(width: double.infinity),
              crossFadeState: _expanded
                  ? CrossFadeState.showFirst
                  : CrossFadeState.showSecond,
              duration: const Duration(milliseconds: 150),
            ),
          ],
        ),
      ),
    );
  }
}
