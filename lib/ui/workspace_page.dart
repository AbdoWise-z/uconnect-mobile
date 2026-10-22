// The main screen once a topic is joined: status bar, the devices in the
// topic, transfers, and settings -- the mobile layout of the desktop's
// WorkspacePage + DevicesPanel + StatusBar.

import 'package:flutter/material.dart';

import '../app/app_state.dart';
import '../core/session.dart';
import 'device_view.dart';
import 'settings_page.dart';
import 'theme.dart';
import 'transfers_view.dart';

class WorkspacePage extends StatefulWidget {
  const WorkspacePage({required this.state, super.key});
  final AppState state;

  @override
  State<WorkspacePage> createState() => _WorkspacePageState();
}

class _WorkspacePageState extends State<WorkspacePage> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final body = switch (_tab) {
      1 => TransfersView(state: state),
      2 => SettingsPage(state: state),
      _ => _DevicesTab(state: state),
    };
    return Scaffold(
      appBar: AppBar(
        title: Text(switch (_tab) {
          1 => 'Transfers',
          2 => 'Settings',
          _ => 'Devices',
        }),
        actions: [
          if (_tab == 0)
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: 'Refresh now',
              onPressed: () => state.session.refreshNow(),
            ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(28),
          child: _StatusBar(state: state),
        ),
      ),
      body: body,
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(
              icon: Icon(Icons.devices_outlined), label: 'Devices'),
          NavigationDestination(
              icon: Icon(Icons.swap_vert), label: 'Transfers'),
          NavigationDestination(
              icon: Icon(Icons.settings_outlined), label: 'Settings'),
        ],
      ),
    );
  }
}

class _StatusBar extends StatelessWidget {
  const _StatusBar({required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final s = state.session;
    final (color, text) = switch (s.status) {
      SessionStatus.online => (UcColors.success, s.statusDetail),
      SessionStatus.connecting => (UcColors.warning, s.statusDetail),
      SessionStatus.reconnecting => (UcColors.warning, s.statusDetail),
      SessionStatus.error => (UcColors.error, s.statusDetail),
      SessionStatus.offline => (UcColors.textDisabled, 'Offline'),
    };
    return Container(
      height: 28,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      alignment: Alignment.centerLeft,
      decoration: const BoxDecoration(
        color: UcColors.panel,
        border: Border(top: BorderSide(color: UcColors.divider)),
      ),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text.isEmpty ? 'Not connected' : text,
              style:
                  const TextStyle(fontSize: 12, color: UcColors.textSecondary),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (s.selfId != null)
            Text(
              'this device: ${shortId(s.selfId!)}',
              style:
                  const TextStyle(fontSize: 12, color: UcColors.textDisabled),
            ),
        ],
      ),
    );
  }
}

class _DevicesTab extends StatelessWidget {
  const _DevicesTab({required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final session = state.session;
    final peers = session.peers.values.toList()
      ..sort((a, b) {
        final byState = b.stateCode.compareTo(a.stateCode);
        return byState != 0 ? byState : a.displayName.compareTo(b.displayName);
      });
    if (session.status == SessionStatus.offline ||
        session.status == SessionStatus.error) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              session.status == SessionStatus.error
                  ? session.statusDetail
                  : 'Not connected.',
              style: const TextStyle(color: UcColors.textSecondary),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: state.connect,
              child: const Text('Connect'),
            ),
          ],
        ),
      );
    }
    if (peers.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'No other devices in this topic yet.\n\nOpen uConnect on another '
            'device, give it the same server and invite link, and it will '
            'appear here.',
            textAlign: TextAlign.center,
            style: TextStyle(color: UcColors.textSecondary),
          ),
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: peers.length,
      itemBuilder: (context, i) {
        final p = peers[i];
        return Card(
          child: ListTile(
            leading: Stack(
              alignment: Alignment.bottomRight,
              children: [
                CircleAvatar(
                  backgroundColor: UcColors.selectionInactive,
                  child: Icon(
                    _osIcon(p.os),
                    size: 20,
                    color: UcColors.text,
                  ),
                ),
                Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    color: stateColor(p.stateCode),
                    shape: BoxShape.circle,
                    border: Border.all(color: UcColors.panel, width: 1.5),
                  ),
                ),
              ],
            ),
            title: Row(
              children: [
                Flexible(
                  child: Text(p.displayName,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w500)),
                ),
                if (p.trusted) ...[
                  const SizedBox(width: 6),
                  const Icon(Icons.verified_user,
                      size: 14, color: UcColors.success),
                ],
              ],
            ),
            subtitle: Text(
              _subtitle(p),
              style: const TextStyle(
                  fontSize: 12, color: UcColors.textSecondary),
            ),
            trailing: const Icon(Icons.chevron_right, size: 20),
            onTap: () {
              Navigator.of(context).push(MaterialPageRoute<void>(
                builder: (_) => DeviceView(state: state, devId: p.devId),
              ));
            },
          ),
        );
      },
    );
  }

  String _subtitle(PeerRecord p) {
    final bits = <String>[stateName(p.stateCode)];
    if (p.stateCode == 5 && p.closeReason.isNotEmpty) {
      bits.add(p.closeReason);
    }
    if (p.relayed) bits.add('relayed');
    if (p.hasHello && p.services.isNotEmpty) bits.add(p.services.join(', '));
    return bits.join(' · ');
  }

  IconData _osIcon(String os) => switch (os) {
        'windows' => Icons.desktop_windows_outlined,
        'macos' => Icons.laptop_mac_outlined,
        'linux' => Icons.computer_outlined,
        'android' => Icons.smartphone_outlined,
        'ios' => Icons.phone_iphone_outlined,
        _ => Icons.device_unknown_outlined,
      };
}
