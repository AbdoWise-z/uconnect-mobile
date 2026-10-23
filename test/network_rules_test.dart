// Network rules: the x / m / number pattern language, first-match order and
// the JSON form exchanged with other devices -- the same cases as
// uconnect-desktop's NetworkRulesTest.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:uconnect_mobile/core/network_rules.dart';

InternetAddress ip(String s) => InternetAddress(s);

void main() {
  final mine = [ip('192.168.1.20'), ip('10.0.5.7')];

  test('validates patterns', () {
    expect(networkPatternProblem('m.m.m.x'), isNull);
    expect(networkPatternProblem('x.x.x.x'), isNull);
    expect(networkPatternProblem('100.x.x.x'), isNull);
    expect(networkPatternProblem(' M.M.0.* '), isNull);
    for (final bad in ['', 'm.m.m', 'm.m.m.x.x', '256.x.x.x', '1a.x.x.x', '-1.x.x.x', 'm..m.x']) {
      expect(networkPatternProblem(bad), isNotNull, reason: bad);
    }
  });

  test('matches mine byte for byte', () {
    expect(networkPatternMatches('m.m.m.x', ip('192.168.1.99'), mine), isTrue);
    expect(networkPatternMatches('m.m.m.x', ip('10.0.5.200'), mine), isTrue);
    expect(networkPatternMatches('m.m.m.x', ip('192.168.2.99'), mine), isFalse);
    expect(networkPatternMatches('m.m.x.x', ip('192.168.2.99'), mine), isTrue);
    expect(networkPatternMatches('m.m.m.x', ip('192.0.5.1'), mine), isFalse);
    expect(networkPatternMatches('m.x.x.x', ip('172.16.0.1'), []), isFalse);
  });

  test('matches literals and anything', () {
    expect(networkPatternMatches('100.x.x.x', ip('100.64.3.2'), mine), isTrue);
    expect(networkPatternMatches('100.x.x.x', ip('10.64.3.2'), mine), isFalse);
    expect(networkPatternMatches('x.x.x.x', ip('8.8.8.8'), mine), isTrue);
    expect(networkPatternMatches('x.x.x.x', ip('2001:db8::1'), mine), isTrue);
    expect(networkPatternMatches('m.m.m.x', ip('2001:db8::1'), mine), isFalse);
    expect(networkPatternMatches('m.m.m.x', ip('::ffff:192.168.1.50'), mine), isTrue);
    expect(networkPatternMatches('x.x.x.x', null, mine), isFalse);
  });

  test('first match wins', () {
    const rules = [
      NetworkRule('m.m.m.x', label: 'Home', permissions: {'storage.observe'}),
      NetworkRule('x.x.x.x', label: 'Anywhere'),
    ];
    expect(firstMatchingRule(rules, ip('192.168.1.4'), mine), 0);
    expect(firstMatchingRule(rules, ip('8.8.8.8'), mine), 1);
    expect(firstMatchingRule(const [], ip('8.8.8.8'), mine), -1);
  });

  test('json round trips and drops the invalid', () {
    const rules = [NetworkRule('m.m.m.x', label: 'Home', permissions: {'camera.view', 'storage.observe'})];
    expect(networkRulesFromJson(networkRulesToJson(rules)), rules);

    final got = networkRulesFromJson([
      {'pattern': 'bogus', 'perms': ['storage.read']},
      {'pattern': 'X.X.X.X', 'perms': ['no.such', 'storage.read', 'storage.read']},
    ]);
    expect(got.length, 1);
    expect(got.first.pattern, 'x.x.x.x');
    expect(got.first.permissions, {'storage.read'});

    final many = [for (var i = 0; i < maxNetworkRules + 10; i++) {'pattern': 'x.x.x.x'}];
    expect(networkRulesFromJson(many).length, maxNetworkRules);
  });
}
