// Settings: an overview of grouped rows (this device, appearance, topic,
// what is shared, permissions, about), each opening a focused page
// -- the mobile SettingsWindow.

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';

import '../app/app_state.dart';
import '../app/store.dart';
import '../core/identity.dart';
import '../core/permissions.dart';
import '../core/session.dart';
import 'prompt_dialog.dart';
import 'network_rules_page.dart';
import 'scheme_picker.dart';
import 'settings_widgets.dart';
import 'sync_folders_page.dart';
import 'theme.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({required this.state, super.key});
  final AppState state;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  AppState get state => widget.state;

  String get _schemeLabel => ucSchemes
      .firstWhere((s) => s.id == state.store.colorScheme,
          orElse: () => ucSchemes[1])
      .label;

  String _onOff(bool on) => on ? 'On' : 'Off';

  void _open(String title, List<Widget> Function(BuildContext) builder) =>
      openSettingsPage(context, state, title, builder);

  @override
  Widget build(BuildContext context) {
    final store = state.store;
    final specialCount = store.special.length;
    final ruleCount = state.networkRules.length;
    final defaultsCount = store.defaultPermissions.length;
    return ListView(
      padding: const EdgeInsets.only(bottom: 28),
      children: [
        _profileHeader(context),
        SettingsSection(title: 'General', children: [
          SettingsTile(
            icon: Icons.palette_outlined,
            iconColor: const Color(0xFF9C6ADE),
            title: 'Appearance',
            subtitle: _schemeLabel,
            onTap: () => _open('Appearance', _appearancePage),
          ),
          SettingsTile(
            icon: Icons.hub_outlined,
            title: 'Topic & connection',
            subtitle: store.server.isEmpty ? 'No server set' : store.server,
            onTap: () => _open('Topic & connection', _topicPage),
          ),
        ]),
        SettingsSection(title: 'Share from this phone', children: [
          SettingsTile(
            icon: Icons.folder_outlined,
            iconColor: UcColors.warning,
            title: 'Storage',
            subtitle: _onOff(store.offerStorage),
            onTap: () => _open('Storage', _storagePage),
          ),
          SettingsTile(
            icon: Icons.folder_copy_outlined,
            iconColor: UcColors.warning,
            title: 'Synced folders',
            subtitle: store.syncFolders.isEmpty
                ? (state.syncOffers.isEmpty ? 'None' : 'Offered to you')
                : '${store.syncFolders.length} folder${store.syncFolders.length == 1 ? '' : 's'}',
            onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                builder: (_) => SyncFoldersPage(state: state))),
          ),
          SettingsTile(
            icon: Icons.videocam_outlined,
            iconColor: const Color(0xFF3FA3A3),
            title: 'Camera',
            subtitle: _onOff(store.offerCamera),
            onTap: () => _open('Camera', _cameraPage),
          ),
          SettingsTile(
            icon: Icons.screen_share_outlined,
            iconColor: const Color(0xFF5C9A5C),
            title: 'Screen sharing',
            subtitle: _onOff(store.offerScreen),
            onTap: () => _open('Screen sharing', _screenPage),
          ),
          SettingsTile(
            icon: Icons.touch_app_outlined,
            iconColor: const Color(0xFFE07B53),
            title: 'Remote control',
            subtitle: store.offerControl && !state.controlAvailable
                ? 'On · accessibility service is off'
                : _onOff(store.offerControl),
            onTap: () => _open('Remote control', _controlPage),
          ),
        ]),
        SettingsSection(
          title: 'Permissions',
          footer: 'For each device the first of these applies: its special '
              'rules, then this topic\'s network rules, then the defaults.',
          children: [
            SettingsTile(
              icon: Icons.verified_user_outlined,
              iconColor: UcColors.success,
              title: 'Devices with special rules',
              subtitle: specialCount == 0
                  ? 'None yet'
                  : '$specialCount device${specialCount == 1 ? '' : 's'}',
              onTap: () => _open('Special rules', _specialPage),
            ),
            SettingsTile(
              icon: Icons.lan_outlined,
              title: 'Network rules',
              subtitle: ruleCount == 0
                  ? 'None for this topic'
                  : '$ruleCount rule${ruleCount == 1 ? '' : 's'} for this topic',
              onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                  builder: (_) => NetworkRulesPage(state: state))),
            ),
            SettingsTile(
              icon: Icons.shield_outlined,
              iconColor: UcColors.textSecondary,
              title: 'Default permissions',
              subtitle: defaultsCount == 0
                  ? 'Nothing'
                  : '$defaultsCount permission${defaultsCount == 1 ? '' : 's'}',
              onTap: () => _open('Default permissions', _defaultsPage),
            ),
          ],
        ),
        SettingsSection(title: 'About', children: [
          SettingsTile(
            icon: Icons.info_outline,
            iconColor: UcColors.textSecondary,
            title: 'uConnect Mobile',
            subtitle: 'Version 0.1.0',
            onTap: () => _open('About', _aboutPage),
          ),
        ]),
      ],
    );
  }

  // --- overview header -----------------------------------------------------

  Widget _profileHeader(BuildContext context) {
    final fp = state.identity?.fingerprint ?? '';
    final shortFp = fp.split(' ').take(4).join(' ');
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: Material(
        color: UcColors.panel,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: UcColors.border),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => _open('This device', _devicePage),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Container(
                  width: 52,
                  height: 52,
                  decoration: BoxDecoration(
                    color: UcColors.accent,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: const Icon(Icons.smartphone,
                      color: Colors.white, size: 28),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(state.store.deviceName,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w600,
                              color: UcColors.text)),
                      const SizedBox(height: 3),
                      Text('Fingerprint $shortFp …',
                          style: TextStyle(
                              fontSize: 12.5,
                              fontFamily: 'monospace',
                              color: UcColors.textSecondary)),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right, color: UcColors.textDisabled),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // --- pages ----------------------------------------------------------------

  List<Widget> _devicePage(BuildContext context) {
    final fp = state.identity?.fingerprint ?? '';
    return [
      SettingsSection(
          title: 'Identity',
          footer: 'How this phone appears to your other devices.',
          children: [
            SettingsTile(
              icon: Icons.badge_outlined,
              title: 'Name',
              subtitle: state.store.deviceName,
              trailing: Icon(Icons.edit_outlined,
                  size: 18, color: UcColors.textSecondary),
              onTap: () async {
                final name = await askText(context, 'Device name',
                    initial: state.store.deviceName);
                if (name != null && name.trim().isNotEmpty) {
                  await state.saveSettings(deviceName: name);
                }
              },
            ),
          ]),
      SettingsSection(
        title: 'Fingerprint',
        footer: 'Before another device gives this phone special rules, check that it '
            'shows exactly this fingerprint.',
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 8, 16),
            child: Row(
              children: [
                Expanded(
                  child: Text(fp,
                      style: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 15,
                          height: 1.4,
                          color: UcColors.text)),
                ),
                IconButton(
                  tooltip: 'Copy',
                  icon:
                      Icon(Icons.copy, size: 18, color: UcColors.textSecondary),
                  onPressed: () => _copy(context, fp, 'Fingerprint copied'),
                ),
              ],
            ),
          ),
        ],
      ),
    ];
  }

  List<Widget> _appearancePage(BuildContext context) => [
        SettingsSection(
          title: 'Color scheme',
          footer: '“Follow system” switches between Dark and Light with your '
              'phone\'s setting.',
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: SchemePicker(
                selected: state.store.colorScheme,
                onSelected: (id) => state.saveSettings(colorScheme: id),
              ),
            ),
          ],
        ),
      ];

  List<Widget> _topicPage(BuildContext context) {
    final uri = state.store.topicUri;
    return [
      if (uri.isNotEmpty)
        SettingsSection(
          title: 'Invite',
          footer: 'Scan this with another device\'s camera, or send the link '
              'privately. It contains the topic key — share it only with your '
              'own devices.',
          children: [
            Column(children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 20, 16, 12),
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: QrImageView(
                        data: uri, size: 200, backgroundColor: Colors.white),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        icon: const Icon(Icons.copy, size: 18),
                        label: const Text('Copy link'),
                        onPressed: () =>
                            _copy(context, uri, 'Invite link copied'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: FilledButton.icon(
                        icon: const Icon(Icons.ios_share, size: 18),
                        label: const Text('Share'),
                        onPressed: () =>
                            SharePlus.instance.share(ShareParams(text: uri)),
                      ),
                    ),
                  ],
                ),
              ),
            ]),
          ],
        ),
      SettingsSection(title: 'Topic', children: [
        SettingsTile(
          icon: Icons.swap_horiz,
          title: 'Join another topic',
          subtitle: 'Paste an invite link',
          onTap: () => _changeTopic(context),
        ),
        SettingsTile(
          icon: Icons.logout,
          iconColor: UcColors.error,
          title: 'Leave this topic',
          subtitle: 'Go offline until you join one again',
          onTap: () async {
            if (!await confirmLeaveTopic(context) || !context.mounted) return;
            Navigator.of(context).popUntil((r) => r.isFirst);
            await state.leaveTopic();
          },
        ),
        SettingsTile(
          icon: Icons.dns_outlined,
          title: 'Rendezvous server',
          subtitle: state.store.server.isEmpty ? 'Not set' : state.store.server,
          trailing: Icon(Icons.edit_outlined,
              size: 18, color: UcColors.textSecondary),
          onTap: () async {
            final server = await askText(
                context, 'Rendezvous server (host:port)',
                initial: state.store.server);
            if (server != null && server.contains(':')) {
              await state.saveSettings(server: server);
              await state.connect();
            }
          },
        ),
      ]),
      SettingsSection(
        title: 'Relay',
        footer: RelayMode.blurbs[state.store.relayMode],
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: SizedBox(
              width: double.infinity,
              child: SegmentedButton<int>(
                showSelectedIcon: false,
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
          ),
        ],
      ),
    ];
  }

  List<Widget> _storagePage(BuildContext context) => [
        SettingsSection(
          footer: 'Devices you allow can browse this phone\'s shared folder.',
          children: [
            SettingsSwitchTile(
              icon: Icons.folder_outlined,
              iconColor: UcColors.warning,
              title: 'Offer storage',
              value: state.store.offerStorage,
              onChanged: (on) => state.saveSettings(offerStorage: on),
            ),
          ],
        ),
        SettingsSection(
          title: 'Shared folder',
          footer: 'Files you add here are what other devices see.',
          children: [
            SettingsTile(
              icon: Icons.note_add_outlined,
              title: 'Add files',
              subtitle: 'Copy files into the shared folder',
              enabled: state.store.offerStorage,
              onTap: () => _addToShared(context),
            ),
          ],
        ),
      ];

  List<Widget> _cameraPage(BuildContext context) => [
        SettingsSection(
          footer: 'A device your special or network rules allow can watch this phone\'s '
              'camera. Asks for the camera permission, and to confirm each '
              'viewer unless you allow that device to watch without asking.',
          children: [
            SettingsSwitchTile(
              icon: Icons.videocam_outlined,
              iconColor: const Color(0xFF3FA3A3),
              title: 'Offer camera',
              value: state.store.offerCamera,
              onChanged: (on) => state.saveSettings(offerCamera: on),
            ),
          ],
        ),
        if (state.store.offerCamera) ..._cameraSourceSections(),
      ];

  List<Widget> _screenPage(BuildContext context) => [
        SettingsSection(
          footer: 'A device your special or network rules allow can watch this screen. '
              'Android asks to confirm screen capture each time.',
          children: [
            SettingsSwitchTile(
              icon: Icons.screen_share_outlined,
              iconColor: const Color(0xFF5C9A5C),
              title: 'Offer screen sharing',
              value: state.store.offerScreen,
              onChanged: (on) => state.saveSettings(offerScreen: on),
            ),
          ],
        ),
      ];

  List<Widget> _controlPage(BuildContext context) => [
        SettingsSection(
          footer: 'A device your special or network rules allow can control this phone while '
              'it watches your screen. Needs the uConnect accessibility '
              'service on.',
          children: [
            SettingsSwitchTile(
              icon: Icons.touch_app_outlined,
              iconColor: const Color(0xFFE07B53),
              title: 'Offer remote control',
              value: state.store.offerControl,
              onChanged: (on) => state.saveSettings(offerControl: on),
            ),
          ],
        ),
        if (state.store.offerControl)
          SettingsSection(title: 'Accessibility service', children: [
            SettingsTile(
              icon: state.controlAvailable
                  ? Icons.check_circle_outline
                  : Icons.warning_amber_outlined,
              iconColor:
                  state.controlAvailable ? UcColors.success : UcColors.warning,
              title: state.controlAvailable ? 'Enabled' : 'Turned off',
              subtitle: state.controlAvailable
                  ? 'uConnect can apply taps and keys.'
                  : 'Turn on “uConnect remote control” under Accessibility.',
              onTap: () => state.input.openSettings(),
            ),
          ]),
      ];

  List<Widget> _defaultsPage(BuildContext context) {
    final defaults = state.store.defaultPermissions;
    final byService = <String, List<PermissionInfo>>{};
    for (final info in permissionTable) {
      if (info.available) {
        byService.putIfAbsent(info.service, () => []).add(info);
      }
    }
    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
        child: Text(
          'What a device may do here when no special or network rule covers '
          'it, including devices whose identity is unknown.',
          style: TextStyle(fontSize: 13, color: UcColors.textSecondary),
        ),
      ),
      if (defaults.any(isSensitivePermission))
        SettingsSection(children: [
          SettingsTile(
            icon: Icons.warning_amber_outlined,
            iconColor: UcColors.warning,
            title: 'Every device in the topic gets these',
            subtitle: 'Camera, screen or control is on for any device, known '
                'or not. Special or network rules are usually the better place.',
          ),
        ]),
      for (final entry in byService.entries)
        SettingsSection(title: _serviceLabel(entry.key), children: [
          for (final info in entry.value)
            SettingsSwitchTile(
              title: info.label,
              subtitle: info.description,
              value: defaults.contains(info.id),
              onChanged: (on) async {
                final next = {...defaults};
                on ? next.add(info.id) : next.remove(info.id);
                await state.setDefaultPermissions(next);
                if (mounted) setState(() {});
              },
            ),
        ]),
    ];
  }

  List<Widget> _specialPage(BuildContext context) {
    final special = state.store.special.values.toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return [
      SettingsSection(
        footer: 'Give a device special rules from its page under Devices, '
            'after checking its fingerprint; change them there too. Removing '
            'them leaves it to the network rules and defaults.',
        children: [
          if (special.isEmpty)
            SettingsTile(
              icon: Icons.verified_user_outlined,
              iconColor: UcColors.textDisabled,
              title: 'No devices with special rules yet',
            ),
          for (final t in special)
            SettingsTile(
              icon: Icons.verified_user,
              iconColor: UcColors.success,
              title: t.name.isEmpty ? 'Unnamed device' : t.name,
              subtitle: '${fingerprintOfHex(t.keyHex)}\n'
                  '${t.permissions.length} permission${t.permissions.length == 1 ? '' : 's'}',
              trailing: TextButton(
                onPressed: () async {
                  final ok = await _confirm(
                      context,
                      'Remove the special rules of ${t.name.isEmpty ? 'this device' : t.name}?',
                      'Network rules and defaults apply to it again.');
                  if (ok) {
                    await state.removeSpecialRules(t.keyHex);
                    if (mounted) setState(() {});
                  }
                },
                child: Text('Remove', style: TextStyle(color: UcColors.error)),
              ),
            ),
        ],
      ),
    ];
  }

  List<Widget> _aboutPage(BuildContext context) => [
        SettingsSection(
          footer: 'Talks the uConnect app protocol with uConnect Desktop over '
              'the uconnect library\'s end-to-end encrypted sessions.',
          children: [
            SettingsTile(
              icon: Icons.info_outline,
              iconColor: UcColors.textSecondary,
              title: 'uConnect Mobile',
              subtitle: 'Version 0.1.0',
            ),
          ],
        ),
        SettingsSection(title: 'Troubleshooting', children: [
          SettingsTile(
            icon: Icons.refresh,
            title: 'Reconnect',
            subtitle: 'Rejoin the topic',
            onTap: () => state.connect(),
          ),
          SettingsTile(
            icon: Icons.receipt_long_outlined,
            title: 'Session log',
            onTap: () => _showLog(context),
          ),
        ]),
      ];

  // --- camera sources ------------------------------------------------------

  List<Widget> _cameraSourceSections() {
    final cams = state.cameras;
    String label(String f) => switch (f) {
          'front' => 'Front camera',
          'back' => 'Back camera',
          _ => 'External camera',
        };
    IconData icon(String f) => switch (f) {
          'front' => Icons.camera_front_outlined,
          'back' => Icons.camera_rear_outlined,
          _ => Icons.videocam_outlined,
        };
    bool isOffered(String id) =>
        state.store.cameraOffered.isEmpty ||
        state.store.cameraOffered.contains(id);
    void toggle(String id, bool on) {
      final all = {for (final c in cams) c.id};
      final set = state.store.cameraOffered.isEmpty
          ? {...all}
          : {...state.store.cameraOffered};
      on ? set.add(id) : set.remove(id);
      if (set.isEmpty) return; // always offer at least one
      state.saveSettings(cameraOffered: set);
    }

    Widget drop(int value, List<int> options, String suffix,
            void Function(int) set) =>
        DropdownButton<int>(
          value: options.contains(value) ? value : options[1],
          isDense: true,
          style: TextStyle(fontSize: 14, color: UcColors.text),
          dropdownColor: UcColors.popup,
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
      SettingsSection(
        title: 'Cameras to offer',
        footer: cams.length > 1 ? 'At least one camera stays offered.' : null,
        children: [
          if (cams.isEmpty)
            SettingsTile(
              icon: Icons.no_photography_outlined,
              iconColor: UcColors.textDisabled,
              title: 'No cameras found',
            ),
          for (final c in cams)
            SettingsSwitchTile(
              icon: icon(c.facing),
              title: label(c.facing),
              value: isOffered(c.id),
              onChanged: (on) => toggle(c.id, on),
            ),
        ],
      ),
      SettingsSection(
        title: 'Quality',
        footer:
            'The most a viewer can ask for; the camera\'s own limits apply.',
        children: [
          SettingsTile(
            icon: Icons.aspect_ratio,
            title: 'Resolution',
            subtitle: 'Up to this width',
            trailing: drop(
                state.store.cameraMaxWidth,
                const [1920, 1280, 960, 640],
                ' px',
                (v) => state.saveSettings(cameraMaxWidth: v)),
          ),
          SettingsTile(
            icon: Icons.speed,
            title: 'Frame rate',
            trailing: drop(state.store.cameraMaxFps, const [60, 30, 24, 15],
                ' fps', (v) => state.saveSettings(cameraMaxFps: v)),
          ),
        ],
      ),
    ];
  }

  // --- actions ----------------------------------------------------------------

  Future<void> _changeTopic(BuildContext context) async {
    final link = await askText(context, 'Invite link (uconn://...)',
        initial: state.store.topicUri);
    if (link == null || !link.startsWith('uconn://')) return;
    await state.saveSettings(topicUri: link);
    await state.connect();
  }

  Future<void> _addToShared(BuildContext context) async {
    final result = await FilePicker.platform.pickFiles(allowMultiple: true);
    if (result == null) return;
    var added = 0;
    for (final f in result.files) {
      final src = f.path;
      if (src == null) continue;
      try {
        await File(src)
            .copy('${state.sharedDir}${Platform.pathSeparator}${f.name}');
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

  Future<void> _copy(BuildContext context, String text, String done) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(done), duration: const Duration(seconds: 2)));
    }
  }

  Future<bool> _confirm(BuildContext context, String title, String body) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text('Remove', style: TextStyle(color: UcColors.error))),
        ],
      ),
    );
    return ok == true;
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
        'screen' => 'Screen sharing',
        'control' => 'Remote control',
        'display' => 'Extended display',
        _ => service,
      };
}
