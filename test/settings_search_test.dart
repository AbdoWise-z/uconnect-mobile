// Settings search reads pages as built: section titles and rows (plain and
// switch), matched by title or status line, case-insensitively.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uconnect_mobile/ui/settings_widgets.dart';

void main() {
  final page = <Widget>[
    const SettingsSection(title: 'Viewing quality', footer: 'what to ask for', children: [
      SettingsTile(title: 'Full', subtitle: '1920 px wide · 60 fps'),
      SettingsTile(title: 'Low', subtitle: '960 px wide · 30 fps'),
    ]),
    SettingsSection(children: [
      SettingsSwitchTile(title: 'Offer camera', value: true, onChanged: (_) {}),
    ]),
    const Padding(padding: EdgeInsets.zero),  // not a setting
  ];

  test('finds sections and rows, with their section', () {
    final entries = settingsIn(page);
    expect(entries.map((e) => e.text), ['Viewing quality', 'Full', 'Low', 'Offer camera']);
    expect(entries[1].section, 'Viewing quality');
    expect(entries[3].section, isNull);
  });

  test('matches titles and status lines, ignoring case', () {
    final entries = settingsIn(page);
    List<String> find(String q) =>
        [for (final e in entries) if (e.matches(q)) e.text];
    expect(find('camera'), ['Offer camera']);
    expect(find('fps'), ['Full', 'Low']);
    expect(find('60 fps'), ['Full']);
    expect(find('ask for'), ['Viewing quality']);  // a section's footer
    expect(find(''), isEmpty);
  });
}
