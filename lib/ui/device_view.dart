// One device: its connection, identity and fingerprint, what it may do here
// (the permission editor), and what it offers us -- the mobile DeviceView,
// special-rules dialog and permission editor in one place.

import 'package:flutter/material.dart';

import '../app/app_state.dart';
import '../core/permissions.dart';
import '../core/session.dart';
import '../core/wire.dart';
import 'adaptive.dart';
import 'screen_view.dart';
import 'storage_view.dart';
import 'theme.dart';

class DeviceView extends StatelessWidget {
  const DeviceView(
      {required this.state, required this.devId, this.embedded = false, super.key});

  final AppState state;
  final String devId;
  /// Shown beside the device list on a wide screen: no app bar of its own.
  final bool embedded;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final p = state.session.peers[devId];
        if (p == null) {
          final gone = Center(
            child: Text('This device is no longer in the topic.',
                style: TextStyle(color: UcColors.textSecondary)),
          );
          if (embedded) return Material(color: UcColors.canvas, child: gone);
          return Scaffold(appBar: AppBar(title: const Text('Device')), body: gone);
        }
        final body = ContentWidth(
          child: ListView(
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
        if (embedded) return Material(color: UcColors.canvas, child: body);
        return Scaffold(
          appBar: AppBar(title: Text(p.displayName)),
          backgroundColor: UcColors.canvas,
          body: body,
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
                Row(children: [
                  Flexible(
                    child: Text(p.displayName,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w600,
                            color: UcColors.text)),
                  ),
                  if (p.special) ...[
                    const SizedBox(width: 6),
                    Tooltip(
                      message: 'Special rules',
                      child: Icon(Icons.verified_user,
                          size: 20, color: UcColors.success),
                    ),
                  ],
                ]),
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
      'invalid' => ('PROOF FAILED — give it nothing', UcColors.error),
      _ => ('not proven yet', UcColors.textSecondary),
    };
    final rule = p.networkRule >= 0 && p.networkRule < state.networkRules.length
        ? state.networkRules[p.networkRule]
        : null;
    final (rulesText, rulesColor) = switch (p.permissionSource) {
      'device' when p.exception => ('special rules (exception)', UcColors.success),
      'device' => (
          rule != null
              ? 'special rules + network rule ${rule.displayName} + defaults'
              : 'special rules + defaults',
          UcColors.success
        ),
      'rule' => ('network rule ${rule?.displayName ?? ''} + defaults', UcColors.accent),
      _ => ('defaults', UcColors.textSecondary),
    };
    return _card('Identity & rules', [
      _row('Status', stateText, color: stateColor_),
      if (p.fingerprint.isNotEmpty) _row('Fingerprint', p.fingerprint),
      _row('Connected from',
          p.address.isNotEmpty ? p.address : 'relayed through the server'),
      _row('Rules', rulesText, color: rulesColor),
      const SizedBox(height: 8),
      if (p.identityState == 'verified' && !p.special)
        FilledButton(
          onPressed: () => _showSpecialRulesDialog(context, p),
          child: const Text('Add special rules...'),
        ),
      if (p.special)
        OutlinedButton(
          onPressed: () async {
            await state.removeSpecialRules(p.identityKey);
          },
          child: const Text('Remove special rules'),
        ),
    ]);
  }

  // Special rules pin the device's key, so this is where a person compares
  // fingerprints before giving it permissions of its own.
  Future<void> _showSpecialRulesDialog(BuildContext context, PeerRecord p) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add special rules?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Check that "${p.displayName}" shows exactly this fingerprint '
              'under its own identity first:',
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
              'Its special rules add to what network rules and defaults '
              'grant it, so nothing changes until you edit them. Make them '
              'an exception to apply only those. Folders sync only with '
              'devices that have special rules.',
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
            child: const Text('Fingerprints match — add'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await state.addSpecialRules(p.identityKey, p.displayName);
    }
  }

  Widget _permissionsCard(BuildContext context, PeerRecord p) {
    final entry = state.store.special[p.identityKey];
    final editable = entry != null;
    final current = p.permissions.toSet();
    final rule = p.networkRule >= 0 && p.networkRule < state.networkRules.length
        ? state.networkRules[p.networkRule]
        : null;
    final rows = <Widget>[];
    String? service;
    for (final info in permissionTable) {
      if (!info.available) continue;
      if (info.service != service) {
        service = info.service;
        rows.add(Padding(
          padding: const EdgeInsets.only(top: 8, bottom: 2),
          child: Text(serviceLabel(service).toUpperCase(),
              style: TextStyle(
                  fontSize: 11,
                  letterSpacing: 1,
                  color: UcColors.textDisabled)),
        ));
      }
      // Which layer grants it; one carried over from a network rule or the
      // defaults is not for the special rules to take away.
      final from = p.permissionFrom[info.id];
      final carried = from == 'rule' || from == 'default';
      final (fromIcon, fromColor, fromText) = switch (from) {
        'device' => (Icons.verified_user, UcColors.success, 'From its special rules'),
        'rule' => (
            Icons.lan_outlined,
            UcColors.accent,
            'Carried over from the network rule ${rule?.displayName ?? ''}'
          ),
        'default' => (
            Icons.shield_outlined,
            UcColors.textSecondary,
            'Carried over from your defaults'
          ),
        _ => (null, UcColors.textSecondary, ''),
      };
      rows.add(SwitchListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        secondary: SizedBox(
          width: 22,
          child: fromIcon == null
              ? null
              : Tooltip(
                  message: fromText,
                  child: Icon(fromIcon, size: 18, color: fromColor)),
        ),
        title: Text(info.label,
            style: TextStyle(fontSize: 13, color: UcColors.text)),
        subtitle: Text.rich(TextSpan(children: [
          TextSpan(text: info.description),
          if (carried)
            TextSpan(
                text: '\n$fromText',
                style: TextStyle(color: fromColor)),
        ]),
            style: TextStyle(
                fontSize: 11, color: UcColors.textSecondary)),
        value: current.contains(info.id),
        onChanged: !editable
            ? null
            : carried
                // Granted below the special rules: say how to take it away.
                ? (_) => ScaffoldMessenger.of(context)
                  ..hideCurrentSnackBar()
                  ..showSnackBar(SnackBar(
                      content: Text('$fromText. Turn on Exception to take it '
                          'away from this device.')))
                : (on) async {
                final next = <String>{...entry.permissions};
                if (on) {
                  next.add(info.id);
                } else {
                  next.remove(info.id);
                }
                await state.setSpecialPermissions(p.identityKey, entry.name, next);
              },
      ));
    }
    final note = switch (p.permissionSource) {
      'device' when p.exception => 'Only its special rules apply: it is an '
          'exception to the network rules and defaults. Changes apply right '
          'away.',
      'device' => 'Its special rules, plus what '
          '${rule != null ? 'the network rule ${rule.displayName} and your defaults' : 'your defaults'} '
          'grant it. Changes apply right away.',
      'rule' => 'From the network rule ${rule?.displayName ?? ''}, because it '
          'connects from ${p.address}, plus your defaults.',
      _ => 'Your default permissions, which any device with the invite link '
          'gets.',
    };
    return _card('What it may do here', [
      Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(note,
            style: TextStyle(fontSize: 12, color: UcColors.textSecondary)),
      ),
      if (!editable)
        Container(
          margin: const EdgeInsets.only(top: 4, bottom: 6),
          padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
          decoration: BoxDecoration(
            color: UcColors.canvas,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: UcColors.border),
          ),
          child: Row(children: [
            Icon(Icons.lock_outline, size: 18, color: UcColors.textSecondary),
            const SizedBox(width: 10),
            Expanded(
              child: Text('Add special rules to change these for this device.',
                  style: TextStyle(fontSize: 12, color: UcColors.textSecondary)),
            ),
            TextButton(
              onPressed: () => _showSpecialRulesDialog(context, p),
              child: const Text('Add'),
            ),
          ]),
        ),
      if (editable)
        SwitchListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          secondary: Icon(Icons.rule, size: 20, color: UcColors.textSecondary),
          title: Text('Exception',
              style: TextStyle(fontSize: 13, color: UcColors.text)),
          subtitle: Text(
              'Only its special rules apply, so it can be given less than '
              'network rules or defaults grant. Turning this on keeps what it '
              'has now.',
              style: TextStyle(fontSize: 11, color: UcColors.textSecondary)),
          value: entry.exception,
          onChanged: (on) => state.setSpecialException(p.identityKey, on),
        ),
      // Read-only until it has special rules: dimmed so it reads as such.
      Opacity(
        opacity: editable ? 1 : 0.45,
        child: IgnorePointer(
          ignoring: !editable,
          child: Column(
              crossAxisAlignment: CrossAxisAlignment.start, children: rows),
        ),
      ),
    ]);
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
