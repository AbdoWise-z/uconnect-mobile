// Shown while not in a topic (first run, or after leaving one): the rendezvous
// server and the topic's invite link, the two things a device needs before it
// can meet the others; the mobile analogue of the desktop's FirstRunPage.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/app_state.dart';
import 'logo.dart';
import 'scan_page.dart';
import 'theme.dart';

class ConnectPage extends StatefulWidget {
  const ConnectPage({required this.state, super.key});
  final AppState state;

  @override
  State<ConnectPage> createState() => _ConnectPageState();
}

class _ConnectPageState extends State<ConnectPage> {
  late final _server = TextEditingController(text: widget.state.store.server);
  late final _link = TextEditingController(
      text: widget.state.store.topicUri.isNotEmpty
          ? widget.state.store.topicUri
          : widget.state.store.lastTopicUri);
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
      setState(() => _error =
          'Scan a QR code, paste a uconn:// invite link, or create a new topic.');
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

  // The QR code another device shows for its topic: scan it, and join right
  // away when the server is already known; otherwise the link waits in its
  // field while the server is asked for.
  Future<void> _scan() async {
    final link = await scanInviteLink(context);
    if (link == null || !mounted) return;
    _link.text = link;
    setState(() => _error = '');
    if (_server.text.trim().contains(':')) {
      await _connect();
    } else {
      setState(() => _error = 'Give the rendezvous server as host:port.');
    }
  }

  Future<void> _rejoin() async {
    _link.text = widget.state.store.lastTopicUri;
    await _connect();
  }

  @override
  Widget build(BuildContext context) {
    final left = widget.state.store.lastTopicUri;
    final leftId = left.length > 16 ? left.substring(8, 16) : '';
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
                  const Center(child: UcLogo(size: 72)),
                  const SizedBox(height: 12),
                  Text('uConnect',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.w600,
                          color: UcColors.text)),
                  const SizedBox(height: 4),
                  Text(
                    left.isEmpty
                        ? 'Your devices, connected: browse and share files with '
                            'your computers, end-to-end encrypted.'
                        : 'Not connected. Join a topic to see your devices.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: UcColors.textSecondary),
                  ),
                  const SizedBox(height: 28),
                  if (left.isNotEmpty && widget.state.store.server.isNotEmpty) ...[
                    Container(
                      padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
                      decoration: BoxDecoration(
                        color: UcColors.panel,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: UcColors.border),
                      ),
                      child: Row(children: [
                        Icon(Icons.history, color: UcColors.accent),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('Last topic',
                                  style: TextStyle(
                                      fontWeight: FontWeight.w600,
                                      color: UcColors.text)),
                              Text('$leftId… on ${widget.state.store.server}',
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                      fontSize: 12,
                                      fontFamily: 'monospace',
                                      color: UcColors.textSecondary)),
                            ],
                          ),
                        ),
                        FilledButton.tonal(
                          onPressed: _busy ? null : _rejoin,
                          child: const Text('Rejoin'),
                        ),
                      ]),
                    ),
                    const SizedBox(height: 24),
                  ],
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
                  const SizedBox(height: 12),
                  FilledButton.tonalIcon(
                    onPressed: _busy ? null : _scan,
                    icon: const Icon(Icons.qr_code_scanner, size: 20),
                    label: const Padding(
                      padding: EdgeInsets.symmetric(vertical: 8),
                      child: Text('Scan QR code'),
                    ),
                  ),
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
