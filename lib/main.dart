
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'app/app_state.dart';
import 'ui/connect_page.dart';
import 'ui/theme.dart';
import 'ui/workspace_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final dir = await getApplicationSupportDirectory();
  final state = AppState(dir.path);
  runApp(UConnectApp(state));
  await state.init();
}

class UConnectApp extends StatelessWidget {
  const UConnectApp(this.state, {super.key});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'uConnect',
      theme: ucTheme(),
      debugShowCheckedModeBanner: false,
      home: ListenableBuilder(
        listenable: state,
        builder: (context, _) {
          if (!state.loaded) {
            return const Scaffold(
              body: Center(child: CircularProgressIndicator()),
            );
          }
          if (state.store.server.isEmpty || state.store.topicUri.isEmpty) {
            return ConnectPage(state: state);
          }
          return WorkspacePage(state: state);
        },
      ),
    );
  }
}
