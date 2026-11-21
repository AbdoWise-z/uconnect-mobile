import 'package:flutter_test/flutter_test.dart';
import 'package:uconnect_mobile/core/permissions.dart';

void main() {
  // The device page, the network rules and the defaults all leave out a
  // permission marked unavailable. That is right for a feature the app does
  // not have, and it once hid the two display permissions after the phone
  // had learned to be an extended display: the switch was there, and no way
  // to let a computer use it.
  test('every permission of a service the app offers can be granted', () {
    const offered = {'storage', 'screen', 'control', 'camera', 'display', 'sync'};
    for (final info in permissionTable) {
      if (offered.contains(info.service)) {
        expect(info.available, isTrue, reason: '${info.id} is hidden');
      }
    }
    final services = {for (final info in permissionTable) info.service};
    expect(services.difference(offered), isEmpty,
        reason: 'a service this test does not know about');
  });

  test('the display permissions are there, and marked sensitive', () {
    for (final id in [Perm.displayShow, Perm.displayDirect]) {
      final info = permissionTable.firstWhere((p) => p.id == id);
      expect(info.service, 'display');
      expect(info.available, isTrue);
      expect(isSensitivePermission(id), isTrue);
    }
  });
}
