import 'package:flutter/material.dart';

import 'pages/home_page.dart';
import 'theme.dart';

void main() {
  runApp(const GiWiFiApp());
}

class GiWiFiApp extends StatelessWidget {
  const GiWiFiApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'GiWiFi 一键认证',
      debugShowCheckedModeBanner: false,
      theme: buildGiWiFiTheme(),
      darkTheme: buildGiWiFiTheme(Brightness.dark),
      themeMode: ThemeMode.system,
      home: const HomePage(),
    );
  }
}
