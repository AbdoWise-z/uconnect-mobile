import 'package:flutter_test/flutter_test.dart';
import 'package:uconnect_mobile/app/container_paths.dart';
import 'package:uconnect_mobile/app/folder_access.dart';

void main() {
  const ours = '/var/mobile/Containers/Data/Application/'
      'AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE';
  const oursBefore = '/var/mobile/Containers/Data/Application/'
      '11111111-2222-3333-4444-555555555555';
  const anotherApps = '/private/var/mobile/Containers/Data/Application/'
      '99999999-8888-7777-6666-555555555555/Documents/Notes';
  const cloud = '/private/var/mobile/Library/Mobile Documents/'
      'com~apple~CloudDocs/Photos';

  String rebase(String p) => rebaseIosContainerPath(p, ours);

  test('a path of our own still moves to the current container', () {
    final map = savedPathMapper(const {}, rebase);
    expect(map('$oursBefore/Documents/Sync/Photos'), '$ours/Documents/Sync/Photos');
    expect(map('$ours/Documents/Shared'), '$ours/Documents/Shared');
  });

  test('a picked folder is left where it is', () {
    final map = savedPathMapper(const {cloud: cloud, anotherApps: anotherApps}, rebase);
    expect(map(cloud), cloud);
    // Inside an app container, but not one of ours: without the bookmark
    // list it would be mistaken for our own folder under an earlier install.
    expect(map(anotherApps), anotherApps);
    expect(rebase(anotherApps), isNot(anotherApps));
  });

  test('a picked folder that moved is followed', () {
    const moved = '/private/var/mobile/Library/Mobile Documents/'
        'com~apple~CloudDocs/Pictures';
    final map = savedPathMapper(const {cloud: moved}, rebase);
    expect(map(cloud), moved);
  });

  test('a picked folder that cannot be reached keeps its path', () {
    final map = savedPathMapper(const {anotherApps: ''}, rebase);
    expect(map(anotherApps), anotherApps);
  });
}
