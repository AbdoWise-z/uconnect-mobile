import 'package:flutter_test/flutter_test.dart';
import 'package:uconnect_mobile/app/store.dart';
import 'package:uconnect_mobile/core/permissions.dart';

void main() {
  test('special rules round-trip their exception flag', () {
    final r = SpecialRules('ab', 'Laptop', {Perm.storageRead}, exception: true);
    final back = SpecialRules.fromJson(r.toJson())!;
    expect(back.exception, isTrue);
    expect(back.permissions, {Perm.storageRead});
  });

  // Saved before special rules added up to the defaults: an exception only
  // where that keeps a default away from the device, as it was.
  test('special rules saved before they added up keep their effect', () {
    final defaults = {Perm.storageObserve};
    final narrow = SpecialRules.fromJson(
        {'key': 'aa', 'name': 'Narrow', 'perms': [Perm.storageRead]},
        defaults: defaults)!;
    final wide = SpecialRules.fromJson({
      'key': 'bb',
      'name': 'Wide',
      'perms': [Perm.storageObserve, Perm.storageRead]
    }, defaults: defaults)!;
    expect(narrow.exception, isTrue);
    expect(wide.exception, isFalse);
  });
}
