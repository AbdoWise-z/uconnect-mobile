// First-run page: the rendezvous server and the topic's invite link, the two
// things a device needs before it can meet the others; the mobile analogue of
// the desktop's FirstRunPage/ConnectPage.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/app_state.dart';
import 'theme.dart';

class ConnectPage extends StatefulWidget {
  const ConnectPage({required this.state, super.key});
  final AppState state;

  @override
  State<ConnectPage> createState() => _ConnectPageState();
}

class _ConnectPageState extends State<ConnectPage> {
  late final _server = TextEditingController(text: widget.state.store.server);
  late final _link = TextEditingController(text: widget.state.store.topicUri);
  String _error = '';
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _takeInvite();
  }

  @override
  void didUpdateWidget(ConnectPage old) {
    super.didUpdateWidget(old);
    _takeInvite();
  }

  // A scanned invite that opened the app before a server was set: fill it in.
  void _takeInvite() {
    final link = widget.state.takePendingInvite();
    if (link != null) {
      _link.text = link;
      _error = '';
    }
  }

  @override
  void dispose() {
    _server.dispose();
    _link.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    final server = _server.text.trim();
    final link = _link.text.trim();
    setState(() => _error = '');
    if (server.isEmpty || !server.contains(':')) {
      setState(() => _error = 'Give the rendezvous server as host:port.');
      return;
    }
    if (!link.startsWith('uconn://')) {
      setState(() => _error = 'Paste a uconn:// invite link, or create a new topic.');
      return;
    }
    setState(() => _busy = true);
    await widget.state.saveSettings(server: server, topicUri: link);
    await widget.state.connect();
    if (!mounted) return;
    setState(() => _busy = false);
    if (widget.state.startError.isNotEmpty) {
      setState(() => _error = widget.state.startError);
    }
  }

  Future<void> _newTopic() async {
    final uri = await widget.state.createTopic();
    if (uri != null) _link.text = uri;
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim() ?? '';
    if (text.isNotEmpty) _link.text = text;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Icon(Icons.hub_outlined, size: 56, color: UcColors.accent),
                  const SizedBox(height: 12),
                  Text('uConnect',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.w600,
                          color: UcColors.text)),
                  const SizedBox(height: 4),
                  Text(
                    'Your devices, connected: browse and share files with your '
                    'computers, end-to-end encrypted.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: UcColors.textSecondary),
                  ),
                  const SizedBox(height: 32),
                  TextField(
                    controller: _server,
                    decoration: const InputDecoration(
                      labelText: 'Rendezvous server',
                      hintText: 'host:port',
                    ),
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _link,
                    decoration: InputDecoration(
                      labelText: 'Invite link',
                      hintText: 'uconn://...',
                      suffixIcon: IconButton(
                        icon: const Icon(Icons.paste, size: 18),
                        onPressed: _paste,
                        tooltip: 'Paste',
                      ),
                    ),
                    autocorrect: false,
                  ),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      onPressed: _newTopic,
                      child: const Text('Create a new topic instead'),
                    ),
                  ),
                  if (_error.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: UcColors.errorBackground,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(_error,
                          style: TextStyle(color: UcColors.error)),
                    ),
                  ],
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: _busy ? null : _connect,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      child: _busy
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2))
                          : const Text('Connect'),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Devices meet in a topic, shared by its invite link. Send '
                    'the link privately to your own devices only: anyone who '
                    'has it can join.',
                    textAlign: TextAlign.center,
                    style:
                        TextStyle(color: UcColors.textSecondary, fontSize: 12),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
