// One device: its connection, identity and fingerprint, what it may do here
// (the permission editor), and what it offers us -- the mobile DeviceView,
// TrustDialog and PermissionEditor in one place.

import 'package:flutter/material.dart';

import '../app/app_state.dart';
import '../core/permissions.dart';
import '../core/session.dart';
import '../core/wire.dart';
import 'screen_view.dart';
import 'storage_view.dart';
import 'theme.dart';

class DeviceView extends StatelessWidget {
  const DeviceView({required this.state, required this.devId, super.key});

  final AppState state;
  final String devId;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final p = state.session.peers[devId];
        if (p == null) {
          return Scaffold(
            appBar: AppBar(title: const Text('Device')),
            body: Center(
              child: Text('This device is no longer in the topic.',
                  style: TextStyle(color: UcColors.textSecondary)),
            ),
          );
        }
        return Scaffold(
          appBar: AppBar(title: Text(p.displayName)),
          backgroundColor: UcColors.canvas,
          body: ListView(
            padding: const EdgeInsets.only(bottom: 28),
            children: [
              _header(p),
              _servicesCard(context, p),
              _connectionCard(context, p),
              _identityCard(context, p),
              if (p.identityState == 'verified') _permissionsCard(context, p),
            ],
          ),
        );
      },
    );
  }

  Widget _row(String label, String value, {Color? color}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 110,
              child: Text(label,
                  style: TextStyle(
                      color: UcColors.textSecondary, fontSize: 13)),
            ),
            Expanded(
              child: Text(value,
                  style: TextStyle(
                      color: color ?? UcColors.text, fontSize: 13)),
            ),
          ],
        ),
      );

  // The device's icon, name and connection state at the top of the page.
  Widget _header(PeerRecord p) {
    final os = p.os.toLowerCase();
    final phone = os.contains('android') ||
        os.contains('ios') ||
        os.contains('iphone') ||
        os.contains('ipad');
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
      child: Row(
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: UcColors.accent,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Icon(phone ? Icons.smartphone : Icons.computer,
                color: Colors.white, size: 30),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(p.displayName,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w600,
                        color: UcColors.text)),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                          color: stateColor(p.stateCode),
                          shape: BoxShape.circle),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      [
                        stateName(p.stateCode),
                        if (p.hasHello && p.os.isNotEmpty) p.os,
                        if (p.trusted) 'trusted',
                      ].join(' · '),
                      style: TextStyle(
                          fontSize: 13, color: UcColors.textSecondary),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // A titled panel, matching the settings sections.
  Widget _card(String title, List<Widget> children, {Widget? trailing}) =>
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 6),
              child: Row(
                children: [
                  Expanded(
                    child: Text(title.toUpperCase(),
                        style: TextStyle(
                            fontSize: 11.5,
                            letterSpacing: 0.8,
                            fontWeight: FontWeight.w600,
                            color: UcColors.textSecondary)),
                  ),
                  if (trailing != null) trailing,
                ],
              ),
            ),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: UcColors.panel,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: UcColors.border),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: children,
              ),
            ),
          ],
        ),
      );

  Widget _connectionCard(BuildContext context, PeerRecord p) {
    return _card('Connection', [
      _row('State', stateName(p.stateCode), color: stateColor(p.stateCode)),
      if (p.closeReason.isNotEmpty) _row('Reason', p.closeReason),
      _row('Route', p.relayed ? 'through the server\'s relay' : 'direct'),
      _row('Device id', shortId(p.devId)),
      if (p.hasHello) _row('System', p.os),
      _row('Traffic',
          '${_bytes(p.bytesSent)} sent · ${_bytes(p.bytesReceived)} received'),
    ],
        trailing: p.stateCode == 3
            ? TextButton(
                onPressed: () => state.session.disconnectPeer(p.devId),
                child: const Text('Disconnect'),
              )
            : TextButton(
                onPressed: () => state.session.connectPeer(p.devId),
                child: const Text('Connect'),
              ));
  }

  Widget _identityCard(BuildContext context, PeerRecord p) {
    final (stateText, stateColor_) = switch (p.identityState) {
      'verified' => ('proven in this session', UcColors.success),
      'invalid' => ('PROOF FAILED — do not trust', UcColors.error),
      _ => ('not proven yet', UcColors.textSecondary),
    };
    return _card('Identity', [
      _row('Status', stateText, color: stateColor_),
      if (p.fingerprint.isNotEmpty) _row('Fingerprint', p.fingerprint),
      if (p.trusted)
        _row('Trust', 'trusted', color: UcColors.success)
      else if (p.identityState == 'verified')
        _row('Trust', 'not trusted yet'),
      const SizedBox(height: 8),
      if (p.identityState == 'verified' && !p.trusted)
        FilledButton(
          onPressed: () => _showTrustDialog(context, p),
          child: const Text('Trust this device...'),
        ),
      if (p.trusted)
        OutlinedButton(
          onPressed: () async {
            await state.untrustDevice(p.identityKey);
          },
          child: const Text('Withdraw trust'),
        ),
    ]);
  }

  Future<void> _showTrustDialog(BuildContext context, PeerRecord p) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Trust this device?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Check that "${p.displayName}" shows exactly this fingerprint '
              'under its own identity before trusting it:',
              style: TextStyle(color: UcColors.textSecondary),
            ),
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: UcColors.canvas,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: UcColors.border),
              ),
              child: Text(
                p.fingerprint,
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 15,
                    color: UcColors.text),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'A trusted device can be granted more: screen viewing, remote '
              'control, writing to your files.',
              style: TextStyle(color: UcColors.textSecondary, fontSize: 12),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('The fingerprints match — trust'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await state.trustDevice(p.identityKey, p.displayName);
    }
  }

  Widget _permissionsCard(BuildContext context, PeerRecord p) {
    final trustedEntry = state.store.trusted[p.identityKey];
    final editable = trustedEntry != null;
    final current = editable
        ? trustedEntry.permissions
        : state.session.permissionsFor(p.devId);
    final rows = <Widget>[];
    String? service;
    for (final info in permissionTable) {
      if (!info.available) continue;
      if (info.trustedOnly && !editable) continue;
      if (info.service != service) {
        service = info.service;
        rows.add(Padding(
          padding: const EdgeInsets.only(top: 8, bottom: 2),
          child: Text(service.toUpperCase(),
              style: TextStyle(
                  fontSize: 11,
                  letterSpacing: 1,
                  color: UcColors.textDisabled)),
        ));
      }
      rows.add(SwitchListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        title: Text(info.label,
            style: TextStyle(fontSize: 13, color: UcColors.text)),
        subtitle: Text(info.description,
            style: TextStyle(
                fontSize: 11, color: UcColors.textSecondary)),
        value: current.contains(info.id),
        onChanged: !editable
            ? null
            : (on) async {
                final next = {...trustedEntry.permissions};
                if (on) {
                  next.add(info.id);
                } else {
                  next.remove(info.id);
                }
                await state.setTrustedPermissions(p.identityKey, next);
              },
      ));
    }
    return _card(
      editable ? 'What it may do here' : 'What it may do here (defaults)',
      [
        if (!editable)
          Padding(
            padding: EdgeInsets.only(bottom: 6),
            child: Text(
              'Trust the device to give it permissions of its own.',
              style: TextStyle(fontSize: 12, color: UcColors.textSecondary),
            ),
          ),
        ...rows,
      ],
    );
  }

  Widget _servicesCard(BuildContext context, PeerRecord p) {
    final connected = p.stateCode == 3;
    final offersStorage = p.services.contains(Services.storage);
    final mayBrowse = p.grantedToMe.contains(Perm.storageObserve);
    final offersScreen = p.services.contains(Services.screen);
    final mayWatch = p.grantedToMe.contains(Perm.screenView);
    final offersControl = p.services.contains(Services.control);
    final mayControl = p.grantedToMe.contains(Perm.controlInput);
    final offersCamera = p.services.contains(Services.camera);
    final mayViewCamera = p.grantedToMe.contains(Perm.cameraView);

    void open(Widget page) => Navigator.of(context)
        .push(MaterialPageRoute<void>(builder: (_) => page));

    final tiles = <Widget>[
      if (offersStorage)
        _actionTile(
          icon: Icons.folder_outlined,
          title: 'Browse files',
          enabled: connected && mayBrowse,
          subtitle: !connected
              ? 'Device is offline'
              : mayBrowse
                  ? 'Open, download and upload shared folders'
                  : 'Not granted to this device yet',
          onTap: () => open(StorageView(
              state: state, devId: p.devId, devName: p.displayName)),
        ),
      if (offersScreen)
        _actionTile(
          icon: Icons.screen_share_outlined,
          title: 'Watch screen',
          enabled: connected && mayWatch,
          subtitle: !connected
              ? 'Device is offline'
              : mayWatch
                  ? 'See a live view of its screen'
                  : 'Not granted to this device yet',
          onTap: () => open(ScreenView(
              state: state, devId: p.devId, devName: p.displayName)),
        ),
      if (offersCamera)
        _actionTile(
          icon: Icons.videocam_outlined,
          title: 'Watch camera',
          enabled: connected && mayViewCamera,
          subtitle: !connected
              ? 'Device is offline'
              : mayViewCamera
                  ? 'See a live feed from its camera'
                  : 'Not granted to this device yet',
          onTap: () => open(ScreenView(
              state: state,
              devId: p.devId,
              devName: p.displayName,
              camera: true)),
        ),
      if (offersControl && mayControl)
        _actionTile(
          icon: Icons.touch_app_outlined,
          title: 'Take control',
          enabled: connected && mayWatch,
          subtitle: !connected
              ? 'Device is offline'
              : mayWatch
                  ? 'Watch and drive its mouse and keyboard'
                  : 'Also needs screen viewing to control',
          onTap: () => open(ScreenView(
              state: state,
              devId: p.devId,
              devName: p.displayName,
              startControl: true)),
        ),
    ];

    return _card('Use this device', [
      if (tiles.isEmpty)
        Padding(
          padding: const EdgeInsets.fromLTRB(2, 0, 2, 6),
          child: Text(
            "This device isn't offering anything to you yet.",
            style: TextStyle(fontSize: 13, color: UcColors.textSecondary),
          ),
        )
      else
        ...tiles,
    ]);
  }

  // One tappable action row: an icon chip, a title and a status line, with a
  // chevron when it can be opened. Dimmed with an inline reason when it can't.
  Widget _actionTile({
    required IconData icon,
    required String title,
    required String subtitle,
    required bool enabled,
    required VoidCallback onTap,
  }) {
    final tint = enabled ? UcColors.accent : UcColors.textDisabled;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: enabled ? onTap : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 10),
          child: Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: tint.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Icon(icon, size: 20, color: tint),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                            color:
                                enabled ? UcColors.text : UcColors.textDisabled)),
                    const SizedBox(height: 2),
                    Text(subtitle,
                        style: TextStyle(
                            fontSize: 12, color: UcColors.textSecondary)),
                  ],
                ),
              ),
              if (enabled)
                Icon(Icons.chevron_right,
                    size: 22, color: UcColors.textSecondary),
            ],
          ),
        ),
      ),
    );
  }

  String _bytes(int n) {
    if (n < 1024) return '$n B';
    if (n < 1024 * 1024) return '${(n / 1024).toStringAsFixed(1)} KB';
    if (n < 1024 * 1024 * 1024) {
      return '${(n / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    return '${(n / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }
}
