// Settings > Network rules: this topic's ordered list of IP-pattern rules
// (protocol section 4.2), an editor for one rule, and copying another
// device's rules for the topic (rules.get).

import 'dart:async';

import 'package:flutter/material.dart';

import '../app/app_state.dart';
import '../core/network_rules.dart';
import '../core/permissions.dart';
import '../core/session.dart';
import 'settings_widgets.dart';
import 'adaptive.dart';
import 'theme.dart';

class NetworkRulesPage extends StatefulWidget {
  const NetworkRulesPage({required this.state, super.key});
  final AppState state;

  @override
  State<NetworkRulesPage> createState() => _NetworkRulesPageState();
}

class _NetworkRulesPageState extends State<NetworkRulesPage> {
  AppState get state => widget.state;
  StreamSubscription<NetworkRulesOffer>? _offers;
  String _copyStatus = '';

  @override
  void initState() {
    super.initState();
    _offers = state.networkRulesOffers.listen(_onOffer);
  }

  @override
  void dispose() {
    _offers?.cancel();
    super.dispose();
  }

  String _nameOf(String dev) => state.session.peers[dev]?.displayName ?? shortId(dev);

  // Names can be copied: a device is told apart by its fingerprint, whose
  // start is shown next to its name ("not proven" until it proved it).
  String _fingerprintOf(PeerRecord? p) =>
      p != null && p.identityState == 'verified' ? p.fingerprint : '';
  String _shortFingerprint(PeerRecord? p) {
    final f = _fingerprintOf(p);
    return f.isEmpty ? 'not proven' : f.substring(0, 9);
  }

  Future<void> _onOffer(NetworkRulesOffer offer) async {
    if (!mounted) return;
    final name = _nameOf(offer.dev);
    if (offer.error.isNotEmpty) {
      setState(() => _copyStatus = offer.error == 'forbidden'
          ? '$name would not share its rules: it has no special or network rules for this phone.'
          : '$name could not share its rules (${offer.error}).');
      return;
    }
    setState(() => _copyStatus = '');
    final choice = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Rules from $name'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Builder(builder: (context) {
                final fp = _fingerprintOf(state.session.peers[offer.dev]);
                return Row(children: [
                  Icon(fp.isEmpty ? Icons.warning_amber : Icons.fingerprint,
                      size: 18,
                      color: fp.isEmpty ? UcColors.error : UcColors.textSecondary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                        fp.isEmpty ? 'This device has not proved its identity.' : fp,
                        style: TextStyle(
                            color: fp.isEmpty ? UcColors.error : UcColors.text,
                            fontFamily: fp.isEmpty ? null : 'monospace',
                            fontSize: 13)),
                  ),
                ]);
              }),
              const SizedBox(height: 10),
              Text(
                offer.rules.isEmpty
                    ? 'It has no network rules on this topic.'
                    : 'Its network rules on this topic, first match first:',
                style: TextStyle(color: UcColors.textSecondary),
              ),
              const SizedBox(height: 10),
              for (var i = 0; i < offer.rules.length; i++)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    '${i + 1}.  ${offer.rules[i].pattern}'
                    '${offer.rules[i].label.isEmpty ? '' : '  —  ${offer.rules[i].label}'}\n'
                    '${_permissionsSummary(offer.rules[i].permissions)}',
                    style: TextStyle(color: UcColors.text, fontSize: 13),
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          if (offer.rules.isNotEmpty)
            TextButton(
                onPressed: () => Navigator.pop(context, 'add'),
                child: const Text('Add to mine')),
          FilledButton(
              onPressed: () => Navigator.pop(context, 'replace'),
              child: const Text('Replace mine')),
        ],
      ),
    );
    if (choice == null) return;
    final next = choice == 'replace'
        ? offer.rules
        : [...state.networkRules, ...offer.rules.where((r) => !state.networkRules.contains(r))];
    await state.setNetworkRules(next);
    if (mounted) {
      setState(() => _copyStatus = choice == 'replace'
          ? 'Replaced with ${offer.rules.length} rule(s) from $name.'
          : 'Added ${offer.rules.length} rule(s) from $name.');
    }
  }

  String _permissionsSummary(Set<String> perms) {
    if (perms.isEmpty) return 'no permissions';
    return [
      for (final info in permissionTable)
        if (perms.contains(info.id)) '${_serviceLabel(info.service)}: ${info.label}'
    ].join(', ');
  }

  Future<void> _edit(int index) => Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => NetworkRuleEditorPage(state: state, index: index)));

  Future<void> _add() async {
    final rules = [...state.networkRules, const NetworkRule('m.m.m.x')];
    await state.setNetworkRules(rules);
    if (mounted) await _edit(rules.length - 1);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final rules = state.networkRules;
        final topicJoined = state.topicKey.isNotEmpty;
        final connected = state.session.peers.values
            .where((p) => p.stateCode == 3)
            .toList();
        return Scaffold(
          backgroundColor: UcColors.canvas,
          appBar: AppBar(title: const Text('Network rules')),
          body: ContentWidth(
              child: ListView(
            padding: const EdgeInsets.only(bottom: 28),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
                child: Text(
                  'Choose what devices may do here by where they connect from. '
                  'The first rule a device matches applies, adding to the '
                  'defaults and to its special rules (unless those are an '
                  'exception). A device matches once it has proved its '
                  'identity over a direct connection; through the relay its '
                  'address is unknown.',
                  style: TextStyle(fontSize: 13, color: UcColors.textSecondary),
                ),
              ),
              SettingsSection(
                title: 'This topic',
                footer: 'Patterns have four parts: x for any value, m for the '
                    'same as this phone\'s address, or a number. m.m.m.x is '
                    'this phone\'s /24 network, 100.x.x.x anything starting '
                    'with 100, x.x.x.x any address.',
                children: [
                  if (!topicJoined)
                    SettingsTile(
                      icon: Icons.info_outline,
                      iconColor: UcColors.warning,
                      title: 'Join a topic first',
                      subtitle: 'Rules are kept per topic.',
                    ),
                  for (var i = 0; i < rules.length; i++)
                    SettingsTile(
                      icon: Icons.lan_outlined,
                      title: '${i + 1}.  ${rules[i].displayName}',
                      subtitle: '${rules[i].label.isEmpty ? '' : '${rules[i].pattern} · '}'
                          '${rules[i].permissions.length} permission'
                          '${rules[i].permissions.length == 1 ? '' : 's'}',
                      onTap: () => _edit(i),
                    ),
                  if (topicJoined)
                    SettingsTile(
                      icon: Icons.add,
                      title: 'Add rule',
                      enabled: rules.length < maxNetworkRules,
                      onTap: _add,
                    ),
                ],
              ),
              SettingsSection(
                title: 'This phone',
                children: [
                  SettingsTile(
                    icon: Icons.wifi,
                    iconColor: UcColors.textSecondary,
                    title: state.localAddresses.isEmpty
                        ? 'No IPv4 address right now'
                        : state.localAddresses.map((a) => a.address).join(',  '),
                    subtitle: 'What "m" compares with',
                  ),
                ],
              ),
              SettingsSection(
                title: 'Copy from another device',
                footer: 'Take the rules another of your devices uses on this '
                    'topic, to set up quickly on a network you already use. It '
                    'shares them only if it has special or network rules for '
                    'this phone, and you review them first.',
                children: [
                  if (connected.isEmpty)
                    SettingsTile(
                      icon: Icons.devices_other,
                      iconColor: UcColors.textDisabled,
                      title: 'No device is connected',
                    ),
                  for (final p in connected)
                    SettingsTile(
                      icon: Icons.download_outlined,
                      title: 'Request rules from ${p.displayName}',
                      subtitle: _shortFingerprint(p),
                      onTap: () {
                        setState(() => _copyStatus =
                            'Asking ${p.displayName} (${_shortFingerprint(p)})…');
                        state.requestNetworkRules(p.devId);
                      },
                    ),
                ],
              ),
              if (_copyStatus.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                  child: Text(_copyStatus,
                      style: TextStyle(fontSize: 13, color: UcColors.text)),
                ),
            ],
          )),
        );
      },
    );
  }
}

/// Edits one network rule (by index); changes are saved as they are made.
class NetworkRuleEditorPage extends StatefulWidget {
  const NetworkRuleEditorPage({required this.state, required this.index, super.key});
  final AppState state;
  final int index;

  @override
  State<NetworkRuleEditorPage> createState() => _NetworkRuleEditorPageState();
}

class _NetworkRuleEditorPageState extends State<NetworkRuleEditorPage> {
  AppState get state => widget.state;
  late int _index = widget.index;
  late final _pattern = TextEditingController(text: _rule?.pattern ?? '');
  late final _label = TextEditingController(text: _rule?.label ?? '');
  String? _problem;

  NetworkRule? get _rule =>
      _index >= 0 && _index < state.networkRules.length ? state.networkRules[_index] : null;

  @override
  void initState() {
    super.initState();
    _problem = networkPatternProblem(_pattern.text);
  }

  @override
  void dispose() {
    _pattern.dispose();
    _label.dispose();
    super.dispose();
  }

  Future<void> _save(NetworkRule Function(NetworkRule r) change) async {
    final rule = _rule;
    if (rule == null) return;
    final rules = [...state.networkRules];
    rules[_index] = change(rule);
    await state.setNetworkRules(rules);
  }

  Future<void> _move(int delta) async {
    final to = _index + delta;
    final rules = [...state.networkRules];
    if (to < 0 || to >= rules.length) return;
    final rule = rules.removeAt(_index);
    rules.insert(to, rule);
    await state.setNetworkRules(rules);
    setState(() => _index = to);
  }

  Future<void> _delete() async {
    final rules = [...state.networkRules]..removeAt(_index);
    await state.setNetworkRules(rules);
    if (mounted) Navigator.of(context).pop();
  }

  InputDecoration _field(String label, {String? hint, String? error}) => InputDecoration(
        labelText: label,
        hintText: hint,
        errorText: error,
      );

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final rule = _rule;
        if (rule == null) {
          return Scaffold(
              appBar: AppBar(title: const Text('Rule')),
              body: const Center(child: Text('This rule no longer exists.')));
        }
        final count = state.networkRules.length;
        final byService = <String, List<PermissionInfo>>{};
        for (final info in permissionTable) {
          if (info.available) byService.putIfAbsent(info.service, () => []).add(info);
        }
        return Scaffold(
          backgroundColor: UcColors.canvas,
          appBar: AppBar(
            title: Text('Rule ${_index + 1}'),
            actions: [
              IconButton(
                tooltip: 'Check earlier',
                icon: const Icon(Icons.arrow_upward),
                onPressed: _index > 0 ? () => _move(-1) : null,
              ),
              IconButton(
                tooltip: 'Check later',
                icon: const Icon(Icons.arrow_downward),
                onPressed: _index < count - 1 ? () => _move(1) : null,
              ),
              IconButton(
                tooltip: 'Delete rule',
                icon: const Icon(Icons.delete_outline),
                onPressed: _delete,
              ),
            ],
          ),
          body: ContentWidth(
              child: ListView(
            padding: const EdgeInsets.only(bottom: 28),
            children: [
              SettingsSection(
                title: 'Match',
                footer: 'x any value · m same as this phone · or a number. '
                    'For example m.m.m.x, 192.168.1.x, 100.x.x.x, x.x.x.x.',
                children: [
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      children: [
                        TextField(
                          controller: _pattern,
                          autocorrect: false,
                          style: const TextStyle(fontFamily: 'monospace'),
                          decoration: _field('Pattern', hint: 'm.m.m.x', error: _problem),
                          onChanged: (v) {
                            setState(() => _problem = networkPatternProblem(v));
                            if (_problem == null) {
                              _save((r) => r.copyWith(pattern: v.trim().toLowerCase()));
                            }
                          },
                        ),
                        const SizedBox(height: 14),
                        TextField(
                          controller: _label,
                          maxLength: 64,
                          decoration: _field('Name (optional)', hint: 'Home'),
                          onChanged: (v) => _save((r) => r.copyWith(label: v)),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              for (final entry in byService.entries)
                SettingsSection(title: _serviceLabel(entry.key), children: [
                  for (final info in entry.value)
                    SettingsSwitchTile(
                      title: info.label,
                      subtitle: info.description,
                      value: rule.permissions.contains(info.id),
                      onChanged: (on) => _save((r) {
                        final next = {...r.permissions};
                        on ? next.add(info.id) : next.remove(info.id);
                        return r.copyWith(permissions: next);
                      }),
                    ),
                ]),
            ],
          )),
        );
      },
    );
  }
}

String _serviceLabel(String service) => serviceLabel(service);
