import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:uconnect_mobile/app/app_state.dart';
import 'package:uconnect_mobile/main.dart';

void main() {
  testWidgets('first run shows the connect page', (tester) async {
    final dir = await Directory.systemTemp.createTemp('ucapp');
    final state = AppState(dir.path);
    await tester.pumpWidget(UConnectApp(state));
    await state.init();
    await tester.pump();
    expect(find.text('uConnect'), findsOneWidget);
    expect(find.text('Connect'), findsOneWidget);
    expect(find.text('Rendezvous server'), findsOneWidget);
    expect(find.text('Invite link'), findsOneWidget);
    state.dispose();
    await tester.pump();
    await dir.delete(recursive: true);
  });
}
