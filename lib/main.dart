
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

class UConnectApp extends StatefulWidget {
  const UConnectApp(this.state, {super.key});

  final AppState state;

  @override
  State<UConnectApp> createState() => _UConnectAppState();
}

class _UConnectAppState extends State<UConnectApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangePlatformBrightness() {
    // Re-render when the OS switches light/dark, so a "Follow system" scheme
    // tracks it.
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState lifecycle) {
    // When the app is really being torn down (not just backgrounded, which the
    // foreground service keeps alive on purpose), shut the node down so its
    // native loop thread does not outlive this engine and reconnect as a
    // second device.
    if (lifecycle == AppLifecycleState.detached) {
      widget.state.shutdown();
    } else if (lifecycle == AppLifecycleState.resumed) {
      // The user may have just turned the accessibility service on in Settings.
      widget.state.refreshControlAvailability();
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final platformBrightness = MediaQuery.platformBrightnessOf(context);
    // Rebuild the whole app (theme included) when settings change, so picking a
    // colour scheme restyles everything live. ucTheme() is read from the active
    // palette, which we switch to here first.
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        UcColors.applyScheme(state.store.colorScheme, platformBrightness);
        return MaterialApp(
          title: 'uConnect',
          theme: ucTheme(),
          navigatorKey: state.navigatorKey,
          debugShowCheckedModeBanner: false,
          home: Builder(
            builder: (context) {
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
      },
    );
  }
}
