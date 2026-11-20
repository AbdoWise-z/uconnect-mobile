import 'package:flutter_test/flutter_test.dart';
import 'package:uconnect_mobile/app/container_paths.dart';

void main() {
  const old = '/var/mobile/Containers/Data/Application/'
      '11111111-2222-3333-4444-555555555555';
  const now = '/var/mobile/Containers/Data/Application/'
      'AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE';

  test('a path saved under an old container moves to the current one', () {
    expect(rebaseIosContainerPath('$old/Documents/Sync/Photos', now),
        '$now/Documents/Sync/Photos');
    expect(rebaseIosContainerPath('$old/Library/Application Support/shared', now),
        '$now/Library/Application Support/shared');
    expect(rebaseIosContainerPath(old, now), now);
  });

  test('a path in the current container is left alone', () {
    expect(rebaseIosContainerPath('$now/Documents/Shared', now),
        '$now/Documents/Shared');
  });

  test('the simulator container layout is recognised', () {
    const sim = '/Users/me/Library/Developer/CoreSimulator/Devices/'
        'F853DDA4-D78B-4431-B491-62080FE8BFC3/data/Containers/Data/Application/'
        '0A1B2C3D-0000-1111-2222-333344445555';
    expect(iosContainerOf('$sim/Documents/Downloads/a.txt'), sim);
    expect(rebaseIosContainerPath('$sim/Documents/Downloads/a.txt', now),
        '$now/Documents/Downloads/a.txt');
  });

  test('paths outside an app container are left alone', () {
    for (final p in [
      '/storage/emulated/0/Android/data/dev.uconnect.mobile/files/Sync/A',
      r'C:\Users\me\Documents\Sync',
      '/private/var/mobile/Library/Mobile Documents/com~apple~CloudDocs/A',
      '',
    ]) {
      expect(rebaseIosContainerPath(p, now), p);
      expect(iosContainerOf(p), isNull);
    }
  });
}
