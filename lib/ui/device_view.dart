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
            body: const Center(
              child: Text('This device is no longer in the topic.',
                  style: TextStyle(color: UcColors.textSecondary)),
            ),
          );
        }
        return Scaffold(
          appBar: AppBar(title: Text(p.displayName)),
          body: ListView(
            padding: const EdgeInsets.symmetric(vertical: 8),
            children: [
              _connectionCard(context, p),
              _identityCard(context, p),
              if (p.identityState == 'verified') _permissionsCard(context, p),
              _servicesCard(context, p),
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
                  style: const TextStyle(
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

  Widget _card(String title, List<Widget> children, {Widget? trailing}) =>
      Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(title,
                        style: const TextStyle(
                            fontWeight: FontWeight.w600,
                            color: UcColors.text)),
                  ),
                  if (trailing != null) trailing,
                ],
              ),
              const SizedBox(height: 8),
              ...children,
            ],
          ),
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
              style: const TextStyle(color: UcColors.textSecondary),
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
                style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 15,
                    color: UcColors.text),
              ),
            ),
            const SizedBox(height: 12),
            const Text(
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
              style: const TextStyle(
                  fontSize: 11,
                  letterSpacing: 1,
                  color: UcColors.textDisabled)),
        ));
      }
      rows.add(SwitchListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        title: Text(info.label,
            style: const TextStyle(fontSize: 13, color: UcColors.text)),
        subtitle: Text(info.description,
            style: const TextStyle(
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
          const Padding(
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
    final offersStorage = p.services.contains(Services.storage);
    final mayBrowse = p.grantedToMe.contains(Perm.storageObserve);
    final offersScreen = p.services.contains(Services.screen);
    final mayWatch = p.grantedToMe.contains(Perm.screenView);
    return _card('On that device', [
      if (p.grantedToMe.isNotEmpty)
        _row('Granted to us', p.grantedToMe.join(', '))
      else
        _row('Granted to us', 'nothing yet'),
      const SizedBox(height: 8),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          FilledButton.icon(
            onPressed: p.stateCode == 3 && offersStorage && mayBrowse
                ? () {
                    Navigator.of(context).push(MaterialPageRoute<void>(
                      builder: (_) => StorageView(
                          state: state, devId: p.devId, devName: p.displayName),
                    ));
                  }
                : null,
            icon: const Icon(Icons.folder_outlined, size: 18),
            label: const Text('Browse files'),
          ),
          FilledButton.icon(
            onPressed: p.stateCode == 3 && offersScreen && mayWatch
                ? () {
                    Navigator.of(context).push(MaterialPageRoute<void>(
                      builder: (_) => ScreenView(
                          state: state, devId: p.devId, devName: p.displayName),
                    ));
                  }
                : null,
            icon: const Icon(Icons.screen_share_outlined, size: 18),
            label: const Text('Watch screen'),
          ),
        ],
      ),
      if (offersStorage && !mayBrowse)
        const Padding(
          padding: EdgeInsets.only(top: 6),
          child: Text(
            'It offers storage but has not granted browsing to this device.',
            style: TextStyle(fontSize: 12, color: UcColors.textSecondary),
          ),
        ),
      if (offersScreen && !mayWatch)
        const Padding(
          padding: EdgeInsets.only(top: 6),
          child: Text(
            'It offers screen sharing but has not granted watching to this device.',
            style: TextStyle(fontSize: 12, color: UcColors.textSecondary),
          ),
        ),
    ]);
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
