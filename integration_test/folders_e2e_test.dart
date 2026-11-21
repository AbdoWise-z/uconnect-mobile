// On-device test of folders outside the app's own (iOS): the bookmarks that
// keep a picked folder reachable across launches (SyncPlatform.swift, through
// lib/app/folder_access.dart), and the way to the system's folder picker from
// Settings > Synced folders. Needs no peer; scripts/e2e-ios.sh runs it with
// the rest.
//
// A test cannot tap inside the picker, which is drawn by another process, so
// the last test ends with it open: that it opens is what is checked.
//
//   E2E_HOLD   seconds to rest with the picker open (for a screenshot)

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uconnect_mobile/app/app_state.dart';
import 'package:uconnect_mobile/app/folder_access.dart';
import 'package:uconnect_mobile/ui/sync_folders_page.dart';

const hold = int.fromEnvironment('E2E_HOLD');

Future<void> pumpUntil(WidgetTester tester, bool Function() condition,
    {Duration timeout = const Duration(seconds: 30), required String reason}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('timed out waiting for: $reason');
    }
    await tester.pump(const Duration(milliseconds: 200));
  }
}

bool shown(Finder finder) => finder.evaluate().isNotEmpty;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  if (!FolderAccess.supported) {
    test('picked folders (skipped: iOS only)', () {},
        skip: 'folders are plain paths on this platform');
    return;
  }

  testWidgets('a folder is kept, reopened at the next launch, and given back',
      (tester) async {
    final documents = await getApplicationDocumentsDirectory();
    final folder = Directory(
        '${documents.path}/picked-${DateTime.now().millisecondsSinceEpoch}');
    await folder.create(recursive: true);
    addTearDown(() async {
      await FolderAccess.release(folder.path);
      if (await folder.exists()) await folder.delete(recursive: true);
    });

    // What the picker does with the folder the user chose.
    final kept = await FolderAccess.adopt(folder.path);
    expect(kept, isNotNull, reason: 'iOS gave a bookmark for the folder');
    // iOS may spell the path its own way (/private/var for /var).
    expect(Directory(kept!).resolveSymbolicLinksSync(),
        folder.resolveSymbolicLinksSync());

    // What the next launch does: every kept folder is found again, here.
    var restored = await FolderAccess.restore();
    expect(restored[kept], kept);
    await File('$kept/written.txt').writeAsString('through the kept folder');
    expect(await File('${folder.path}/written.txt').readAsString(),
        'through the kept folder');
    // ignore: avoid_print
    print('E2E_FOLDERS kept=${restored.length}');

    // A folder that has gone keeps its entry, marked unreachable, so it can
    // come back; one that is given up is forgotten.
    await FolderAccess.release(kept);
    restored = await FolderAccess.restore();
    expect(restored.containsKey(kept), isFalse);
  });

  testWidgets('a new synced folder can go in a folder picked in Files',
      (tester) async {
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final support = await getApplicationSupportDirectory();
    final documents = await getApplicationDocumentsDirectory();
    final data = Directory('${support.path}/folders-e2e-$stamp');
    final files = Directory('${documents.path}/folders-e2e-$stamp');
    await data.create(recursive: true);
    await files.create(recursive: true);
    final state = AppState(data.path, filesDir: files.path);
    addTearDown(() async {
      state.shutdown();
      await data.delete(recursive: true);
      await files.delete(recursive: true);
    });
    await state.init();
    expect(state.initError, isEmpty);
    await tester.pumpWidget(MaterialApp(home: SyncFoldersPage(state: state)));

    await pumpUntil(tester, () => shown(find.text('New synced folder')),
        reason: 'the synced folders page');
    await tester.tap(find.text('New synced folder'));
    await pumpUntil(tester, () => shown(find.text('Name of the synced folder')),
        reason: 'the name prompt');
    await tester.tap(find.widgetWithText(FilledButton, 'OK'));
    await pumpUntil(tester, () => shown(find.text('Where should it be on this phone?')),
        reason: 'the location prompt');
    // Both choices: the app's own folder, shown in Files, and any other.
    expect(find.text('Use uConnect\'s folder'), findsOneWidget);
    final pick = find.widgetWithText(TextButton, 'Pick a folder');
    expect(pick, findsOneWidget);
    await tester.tap(pick);
    await pumpUntil(
        tester, () => !shown(find.text('Where should it be on this phone?')),
        reason: 'the prompt closing');
    // The system's picker is up now; nothing was made yet.
    for (var i = 0; i < (3 + hold) * 5; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    expect(state.store.syncFolders, isEmpty);
    // ignore: avoid_print
    print('E2E_SCREEN folder-picker');
  });
}
