import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'pages/home_page.dart';
import 'services/device_store.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ZCodeRemoteApp());
}

class ZCodeRemoteApp extends StatelessWidget {
  const ZCodeRemoteApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => DeviceStore()..load(),
      child: MaterialApp(
        title: 'ZCode Remote',
        debugShowCheckedModeBanner: false,
        themeMode: ThemeMode.system,
        theme: ThemeData(
          useMaterial3: true,
          brightness: Brightness.light,
          colorScheme:
              ColorScheme.fromSeed(seedColor: const Color(0xFF5B5CE2)),
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
