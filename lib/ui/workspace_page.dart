// The main screen once a topic is joined: status bar, the devices in the
// topic, transfers, and settings -- the mobile layout of the desktop's
// WorkspacePage + DevicesPanel + StatusBar.
//
// On a phone the three tabs sit in a bottom bar and a device opens as its
// own page. From 600 dp the tabs move to a rail on the left; from 840 dp
// the devices tab shows the list beside the chosen device's page, and
// settings show the overview beside the page a row opens.

import 'package:flutter/material.dart';

import '../app/app_state.dart';
import '../core/session.dart';
import 'adaptive.dart';
import 'device_view.dart';
import 'prompt_dialog.dart';
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
  String? _device; // chosen in the list pane, when there is one

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final breadth = breadthOf(context);
    final twoPane = breadth == Breadth.expanded;
    final tabs = <Widget>[
      _devicesTab(state, twoPane),
      ContentWidth(child: TransfersView(state: state)),
      SettingsPage(state: state, twoPane: twoPane),
    ];
    final body = Column(
      children: [
        if (state.screenHost.sharing) _SharingBar(state: state),
        // All three stay built, so a tab keeps its place (a search typed, a
        // page chosen) while another is shown.
        Expanded(child: IndexedStack(index: _tab, children: tabs)),
      ],
    );
    const destinations = [
      (Icons.devices_outlined, 'Devices'),
      (Icons.swap_vert, 'Transfers'),
      (Icons.settings_outlined, 'Settings'),
    ];
    return Scaffold(
      appBar: AppBar(
        title: Text(destinations[_tab].$2),
        actions: [
          if (_tab == 0)
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: 'Refresh now',
              onPressed: () => state.session.refreshNow(),
            ),
          if (_tab == 0)
            IconButton(
              icon: const Icon(Icons.logout),
              tooltip: 'Leave topic',
              onPressed: () async {
                if (await confirmLeaveTopic(context)) await state.leaveTopic();
              },
            ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(28),
          child: _StatusBar(state: state),
        ),
      ),
      body: breadth == Breadth.compact
          ? body
          : Row(children: [
              NavigationRail(
                selectedIndex: _tab,
                onDestinationSelected: (i) => setState(() => _tab = i),
                labelType: NavigationRailLabelType.all,
                groupAlignment: -0.9,
                destinations: [
                  for (final (icon, label) in destinations)
                    NavigationRailDestination(icon: Icon(icon), label: Text(label)),
                ],
              ),
              VerticalDivider(width: 1, thickness: 1, color: UcColors.divider),
              Expanded(child: body),
            ]),
      bottomNavigationBar: breadth == Breadth.compact
          ? NavigationBar(
              selectedIndex: _tab,
              onDestinationSelected: (i) => setState(() => _tab = i),
              destinations: [
                for (final (icon, label) in destinations)
                  NavigationDestination(icon: Icon(icon), label: label),
              ],
            )
          : null,
    );
  }

  Widget _devicesTab(AppState state, bool twoPane) {
    if (!twoPane) {
      return _DevicesTab(
        state: state,
        onSelect: (devId) => Navigator.of(context).push(MaterialPageRoute<void>(
          builder: (_) => DeviceView(state: state, devId: devId),
        )),
      );
    }
    final chosen = _device;
    return Row(children: [
      SizedBox(
        width: kListPaneWidth,
        child: _DevicesTab(
          state: state,
          selected: chosen,
          onSelect: (devId) => setState(() => _device = devId),
        ),
      ),
      VerticalDivider(width: 1, thickness: 1, color: UcColors.divider),
      Expanded(
        child: chosen == null
            ? const PanePlaceholder(
                icon: Icons.devices_other_outlined,
                text: 'Choose a device to see what it offers\nand what it may do here.')
            : DeviceView(state: state, devId: chosen, embedded: true),
      ),
    ]);
  }
}

class _SharingBar extends StatelessWidget {
  const _SharingBar({required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final name = state.screenHost.viewerName ?? 'a device';
    final controlling = state.screenHost.controlling;
    return Material(
      color: controlling ? UcColors.error : UcColors.accent,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        child: Row(
          children: [
            Icon(controlling ? Icons.touch_app : Icons.screen_share,
                size: 18, color: Colors.white),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                  controlling
                      ? '$name is controlling this device'
                      : 'Sharing your screen to $name',
                  style: const TextStyle(color: Colors.white, fontSize: 13)),
            ),
            TextButton(
              onPressed: () => state.screenHost.stop(),
              style: TextButton.styleFrom(foregroundColor: Colors.white),
              child: const Text('Stop'),
            ),
          ],
        ),
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
      decoration: BoxDecoration(
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
                  TextStyle(fontSize: 12, color: UcColors.textSecondary),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (s.selfId != null)
            Text(
              'this device: ${shortId(s.selfId!)}',
              style:
                  TextStyle(fontSize: 12, color: UcColors.textDisabled),
            ),
        ],
      ),
    );
  }
}

class _DevicesTab extends StatelessWidget {
  const _DevicesTab({required this.state, required this.onSelect, this.selected});
  final AppState state;
  final void Function(String devId) onSelect;
  final String? selected; // highlighted in the list pane

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
              style: TextStyle(color: UcColors.textSecondary),
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
      return Center(
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
    return ContentWidth(
      child: ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: peers.length,
        itemBuilder: (context, i) {
          final p = peers[i];
          final chosen = p.devId == selected;
          return Card(
            color: chosen ? UcColors.selection : null,
            child: ListTile(
              selected: chosen,
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
                        style: TextStyle(
                            fontWeight: FontWeight.w500, color: UcColors.text)),
                  ),
                  if (p.special) ...[
                    const SizedBox(width: 6),
                    Icon(Icons.verified_user,
                        size: 14, color: UcColors.success),
                  ],
                ],
              ),
              subtitle: Text(
                _subtitle(p),
                style: TextStyle(
                    fontSize: 12, color: UcColors.textSecondary),
              ),
              trailing: Icon(Icons.chevron_right, size: 20, color: UcColors.textSecondary),
              onTap: () => onSelect(p.devId),
            ),
          );
        },
      ),
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
