// Editing a synced folder's rules in the app: .syncignore (sent to every
// member) and .syncskip (this phone only), with a live preview of what each
// line decides, the lines that are no use, which rule decides a path typed
// in, and what saving would change.

import 'dart:async';

import 'package:flutter/material.dart';

import '../app/app_state.dart';
import 'format.dart';
import 'theme.dart';

class SyncRulesPage extends StatefulWidget {
  const SyncRulesPage({required this.state, required this.id, this.skipFirst = false, super.key});
  final AppState state;
  final String id;
  final bool skipFirst; // open on the .syncskip tab

  @override
  State<SyncRulesPage> createState() => _SyncRulesPageState();
}

class _SyncRulesPageState extends State<SyncRulesPage> with SingleTickerProviderStateMixin {
  late final TabController _tabs =
      TabController(length: 2, vsync: this, initialIndex: widget.skipFirst ? 1 : 0);
  late final _editors = [
    _RulesEditor(this, false),
    _RulesEditor(this, true),
  ];

  @override
  void initState() {
    super.initState();
    _tabs.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _tabs.dispose();
    for (final e in _editors) {
      e.dispose();
    }
    super.dispose();
  }

  _RulesEditor get _current => _editors[_tabs.index];

  void refresh() => setState(() {});

  Future<void> _save() async {
    final e = _current;
    final preview = e.preview;
    final stop = (preview['stop'] as num?)?.toInt() ?? 0;
    if (stop > 0) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Save these rules?'),
          content: Text(e.skip
              ? '${plural(stop, 'synced file')} will stop syncing on this phone and keep '
                  'their local contents. Other devices keep syncing them.'
              : '${plural(stop, 'synced file')} will stop syncing and count as deleted on the '
                  'other devices (their copies stay on disk). .syncignore syncs to every '
                  'member, so this reaches all of them.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Save')),
          ],
        ),
      );
      if (ok != true || !mounted) return;
    }
    final saved = widget.state.sync.saveRules(widget.id, e.skip, e.controller.text);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(saved ? 'Saved. The folder is being scanned again.' : 'Could not save.')));
    if (saved) setState(() => e.saved = e.controller.text);
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.state.syncFolder(widget.id);
    final dirty = _current.controller.text != _current.saved;
    return Scaffold(
      backgroundColor: UcColors.canvas,
      appBar: AppBar(
        title: Text(c == null || c.label.isEmpty ? 'Rules' : '${c.label}: rules'),
        actions: [
          IconButton(
            icon: const Icon(Icons.undo),
            tooltip: 'Revert to the saved file',
            onPressed: dirty ? () => setState(() => _current.revert()) : null,
          ),
          IconButton(
            icon: const Icon(Icons.save_outlined),
            tooltip: 'Save',
            onPressed: dirty ? _save : null,
          ),
        ],
        bottom: TabBar(
          controller: _tabs,
          tabs: const [
            Tab(text: '.syncignore · every device'),
            Tab(text: '.syncskip · this phone only'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: [for (final e in _editors) e.build(context)],
      ),
    );
  }
}

/// One rules file being edited, with its debounced preview.
class _RulesEditor {
  _RulesEditor(this.page, this.skip) {
    saved = page.widget.state.sync.rulesText(page.widget.id, skip);
    controller = TextEditingController(text: saved);
    controller.addListener(_changed);
    probe.addListener(_changed);
    _refresh();
  }

  final _SyncRulesPageState page;
  final bool skip;
  late String saved;
  late final TextEditingController controller;
  final probe = TextEditingController();
  Map<String, Object?> preview = const {};
  Timer? _debounce;

  void dispose() {
    _debounce?.cancel();
    controller.dispose();
    probe.dispose();
  }

  void revert() {
    controller.text = saved;
  }

  void _changed() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), _refresh);
  }

  void _refresh() {
    preview = page.widget.state.sync
        .previewRules(page.widget.id, skip, controller.text, probe: probe.text.trim());
    if (page.mounted) page.refresh();
  }

  Widget build(BuildContext context) {
    final problems = (preview['problems'] as List?)?.cast<Map>() ?? const [];
    final matches = (preview['matches'] as List?)?.cast<Map>() ?? const [];
    final stop = (preview['stop'] as num?)?.toInt() ?? 0;
    final resume = (preview['resume'] as num?)?.toInt() ?? 0;
    final probed = (preview['probe'] as Map?)?.cast<String, Object?>();
    TextStyle sub([Color? color]) =>
        TextStyle(fontSize: 12.5, color: color ?? UcColors.textSecondary);
    Widget heading(String t) => Padding(
          padding: const EdgeInsets.fromLTRB(16, 18, 16, 6),
          child: Text(t.toUpperCase(),
              style: TextStyle(
                  fontSize: 11.5,
                  letterSpacing: 0.8,
                  fontWeight: FontWeight.w600,
                  color: UcColors.textSecondary)),
        );
    String decided(Map m) {
      final line = (m['line'] as num?)?.toInt() ?? 0;
      if (line == 0) return 'no rule: syncs';
      final via = '${m['via'] ?? ''}';
      final by = 'line $line "${m['pattern']}"';
      if (m['negate'] == true) return 'brought back by $by';
      return via.isEmpty ? 'excluded by $by' : 'excluded with the folder $via, by $by';
    }

    return ListView(padding: const EdgeInsets.only(bottom: 28), children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
        child: Text(
          skip
              ? 'Paths matching these patterns keep their contents on this phone: changes to '
                  'them are neither sent nor taken. The file never syncs.'
              : 'Paths matching these patterns are not synced. A synced file that becomes '
                  'ignored counts as deleted on the other devices; copies stay on disk. The '
                  'file itself syncs to every member.',
          style: sub(),
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
        child: TextField(
          controller: controller,
          maxLines: null,
          minLines: 6,
          keyboardType: TextInputType.multiline,
          autocorrect: false,
          enableSuggestions: false,
          style: TextStyle(fontFamily: 'monospace', fontSize: 13.5, color: UcColors.text),
          decoration: const InputDecoration(
            hintText: '# one pattern per line\n*.tmp\nbuild/\n!keep.tmp',
            alignLabelWithHint: true,
          ),
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
        child: Text(
          '* and ? stay within one name, ** spans folders, a / anchors at the top, a '
          'trailing / matches folders only, ! brings a match back.',
          style: sub(),
        ),
      ),
      if (problems.isNotEmpty) ...[
        heading('Lines that are no use'),
        for (final p in problems)
          ListTile(
            dense: true,
            leading: Icon(Icons.error_outline, color: UcColors.error, size: 20),
            title: Text('line ${p['line']}: "${p['pattern']}"',
                style: TextStyle(fontFamily: 'monospace', color: UcColors.text)),
            subtitle: Text('Skipped: not a usable pattern.', style: sub()),
          ),
      ],
      heading('If saved'),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Text(
          [
            if (stop > 0)
              skip
                  ? '${plural(stop, 'synced file')} will stop syncing on this phone.'
                  : '${plural(stop, 'synced file')} will stop syncing and count as deleted '
                      'on the other devices (their copies stay on disk).',
            if (resume > 0) '${plural(resume, 'file')} left out now would sync again.',
            if (stop == 0 && resume == 0) 'No synced file changes state.',
          ].join(' '),
          style: sub(stop > 0 ? UcColors.warning : null),
        ),
      ),
      heading('Which rule decides a path?'),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: TextField(
          controller: probe,
          autocorrect: false,
          style: TextStyle(fontFamily: 'monospace', fontSize: 13.5, color: UcColors.text),
          decoration: InputDecoration(
            hintText: 'docs/notes.txt (end with / for a folder)',
            isDense: true,
            helperText: probed == null ? null : decided(probed),
            helperMaxLines: 3,
            helperStyle: sub(probed != null && probed['excluded'] == true
                ? UcColors.warning
                : UcColors.success),
          ),
        ),
      ),
      heading('What the rules decide (${matches.length})'),
      if (matches.isEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text('No known path matches a rule.', style: sub()),
        ),
      for (final m in matches.take(300))
        ListTile(
          dense: true,
          leading: Icon(
            m['negate'] == true ? Icons.check_circle_outline : Icons.visibility_off_outlined,
            size: 20,
            color: m['negate'] == true ? UcColors.success : UcColors.textDisabled,
          ),
          title: Text('${m['path']}${m['dir'] == true ? '/' : ''}',
              overflow: TextOverflow.ellipsis, style: TextStyle(color: UcColors.text)),
          subtitle: Text(decided(m), style: sub()),
        ),
      if (matches.length > 300)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text('…and ${matches.length - 300} more.', style: sub()),
        ),
    ]);
  }
}
