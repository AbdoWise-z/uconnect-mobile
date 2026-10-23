// Network rules: per-topic permission sets chosen by where a device's direct
// connection comes from (protocol section 4.2), the same as uconnect-desktop's
// NetworkRules.cpp.
//
// A rule's pattern has four dot-separated parts, one per IPv4 byte:
//   x  any value            m  the same as this device's own address
//   0-255  exactly that value
// so "m.m.m.x" is "my /24", "100.x.x.x" anything starting 100, and "x.x.x.x"
// any address. The first rule a proven device matches decides what it may do
// here, unless it has special rules of its own (see Session.permissionsFor).

import 'dart:io';

import 'permissions.dart';

class NetworkRule {
  const NetworkRule(this.pattern, {this.label = '', this.permissions = const {}});

  final String pattern;
  final String label;
  final Set<String> permissions;

  String get displayName => label.isEmpty ? pattern : label;

  NetworkRule copyWith({String? pattern, String? label, Set<String>? permissions}) =>
      NetworkRule(pattern ?? this.pattern,
          label: label ?? this.label, permissions: permissions ?? this.permissions);

  Map<String, Object?> toJson() => {
        'pattern': pattern,
        'label': label,
        'perms': (permissions.toList()..sort()),
      };

  @override
  bool operator ==(Object other) =>
      other is NetworkRule &&
      other.pattern == pattern &&
      other.label == label &&
      other.permissions.length == permissions.length &&
      other.permissions.containsAll(permissions);

  @override
  int get hashCode => Object.hash(pattern, label, Object.hashAllUnordered(permissions));
}

const maxNetworkRules = 64;

// The pattern's parts: -1 for x, -2 for m, else the byte value.
List<int>? _parse(String pattern) {
  final parts = pattern.trim().toLowerCase().split('.');
  if (parts.length != 4) return null;
  final out = <int>[];
  for (final p in parts) {
    if (p == 'x' || p == '*') {
      out.add(-1);
    } else if (p == 'm') {
      out.add(-2);
    } else {
      if (p.isEmpty || p.length > 3 || !RegExp(r'^[0-9]+$').hasMatch(p)) return null;
      final v = int.parse(p);
      if (v > 255) return null;
      out.add(v);
    }
  }
  return out;
}

/// Why [pattern] is not a valid rule pattern, or null if it is.
String? networkPatternProblem(String pattern) {
  final p = pattern.trim();
  if (p.isEmpty) return 'Enter a pattern such as m.m.m.x';
  if ('.'.allMatches(p).length != 3) return 'Use four parts separated by dots, like m.m.m.x';
  if (_parse(p) == null) return 'Each part must be x, m or a number from 0 to 255';
  return null;
}

// The four IPv4 bytes of [a] (also unwrapping ::ffff:a.b.c.d), or null.
List<int>? _ipv4(InternetAddress a) {
  final raw = a.rawAddress;
  if (raw.length == 4) return raw;
  if (raw.length == 16) {
    for (var i = 0; i < 10; i++) {
      if (raw[i] != 0) return null;
    }
    if (raw[10] == 0xff && raw[11] == 0xff) return raw.sublist(12);
  }
  return null;
}

/// Whether [peer] matches [pattern], comparing "m" parts with each of [mine]
/// (this device's IPv4 addresses) in turn. "x.x.x.x" matches any address,
/// IPv6 included; other patterns only match IPv4 (or IPv4-mapped) addresses.
bool networkPatternMatches(String pattern, InternetAddress? peer, List<InternetAddress> mine) {
  final parts = _parse(pattern);
  if (parts == null || peer == null) return false;
  if (parts.every((p) => p == -1)) return true;
  final p = _ipv4(peer);
  if (p == null) return false;
  var usesMine = false;
  for (var i = 0; i < 4; i++) {
    if (parts[i] == -2) {
      usesMine = true;
    } else if (parts[i] >= 0 && p[i] != parts[i]) {
      return false;
    }
  }
  if (!usesMine) return true;
  for (final a in mine) {
    final m = _ipv4(a);
    if (m == null) continue;
    var all = true;
    for (var i = 0; i < 4 && all; i++) {
      if (parts[i] == -2 && p[i] != m[i]) all = false;
    }
    if (all) return true;
  }
  return false;
}

/// The index of the first rule [peer] matches, or -1.
int firstMatchingRule(List<NetworkRule> rules, InternetAddress? peer, List<InternetAddress> mine) {
  for (var i = 0; i < rules.length; i++) {
    if (networkPatternMatches(rules[i].pattern, peer, mine)) return i;
  }
  return -1;
}

/// Rules from their wire / stored form, dropping invalid ones and unknown
/// permissions and keeping at most [maxNetworkRules].
List<NetworkRule> networkRulesFromJson(Object? json) {
  final out = <NetworkRule>[];
  if (json is! List) return out;
  for (final v in json) {
    if (out.length >= maxNetworkRules) break;
    if (v is! Map) continue;
    final pattern = v['pattern'] is String ? (v['pattern'] as String).trim().toLowerCase() : '';
    if (networkPatternProblem(pattern) != null) continue;
    final label = v['label'] is String ? v['label'] as String : '';
    final perms = <String>{
      if (v['perms'] is List)
        for (final p in v['perms'] as List)
          if (p is String && isKnownPermission(p)) p
    };
    out.add(NetworkRule(pattern,
        label: label.length > 64 ? label.substring(0, 64) : label, permissions: perms));
  }
  return out;
}

List<Map<String, Object?>> networkRulesToJson(List<NetworkRule> rules) =>
    [for (final r in rules) r.toJson()];

/// This device's IPv4 addresses (not loopback), for the rules' "m" parts.
Future<List<InternetAddress>> localIpv4Addresses() async {
  try {
    final interfaces = await NetworkInterface.list(
        includeLoopback: false, type: InternetAddressType.IPv4);
    return [
      for (final i in interfaces)
        for (final a in i.addresses)
          if (!a.isLoopback) a
    ];
  } on Object {
    return const [];
  }
}
