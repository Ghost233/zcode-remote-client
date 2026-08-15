import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'pages/home_page.dart';
import 'services/device_store.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Android edge-to-edge：内容延伸到状态栏/手势条下方，配合 HomePage
  // 里网页层不做 SafeArea 避让，全屏下不再有顶部留白。
  if (Platform.isAndroid) {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  }
  runApp(const ZCodeRemoteApp());
}

class ZCodeRemoteApp extends StatelessWidget {
  const ZCodeRemoteApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => DeviceStore()..load(),
      child: MaterialApp(
        title: 'ZCode远程客户端',
        debugShowCheckedModeBanner: false,
        themeMode: ThemeMode.system,
        theme: ThemeData(
          useMaterial3: true,
          brightness: Brightness.light,
          colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF5B5CE2)),
        ),
        darkTheme: ThemeData(
          useMaterial3: true,
          brightness: Brightness.dark,
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF5B5CE2),
            brightness: Brightness.dark,
          ),
        ),
        home: const HomePage(),
      ),
    );
  }
}
