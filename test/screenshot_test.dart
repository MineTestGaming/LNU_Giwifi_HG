import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:giwifi_ua_switcher/pages/home_page.dart';
import 'package:giwifi_ua_switcher/services/settings_service.dart';
import 'package:giwifi_ua_switcher/theme.dart';

/// 使用应用真实字体与完整图标字体，避免新增字符和图标在截图中缺失。
Future<void> _loadUiFonts() async {
  final uiLoader = FontLoader('MiSans')
    ..addFont(rootBundle.load('assets/fonts/mi_sans_regular.ttf'))
    ..addFont(rootBundle.load('assets/fonts/mi_sans_medium.ttf'))
    ..addFont(rootBundle.load('assets/fonts/mi_sans_bold.ttf'));
  await uiLoader.load();
  final iconLoader = FontLoader('MaterialIcons')
    ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
  await iconLoader.load();
}

Future<void> _pumpApp(WidgetTester tester, Size size,
    {Brightness brightness = Brightness.light}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildGiWiFiTheme(brightness),
      home: const HomePage(),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await _loadUiFonts();
  });

  setUp(() {
    final tmp = Directory.systemTemp.createTempSync('giwifi_golden');
    SettingsService.configDirOverride = tmp.path;
    addTearDown(() {
      SettingsService.configDirOverride = null;
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
    });
  });

  testWidgets('桌面窗口截图（含在线检测提示）', (WidgetTester tester) async {
    await _pumpApp(tester, const Size(1100, 1040));
    await tester.tap(find.text('检查状态'));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(HomePage),
      matchesGoldenFile('goldens/home_desktop.png'),
    );
  });

  testWidgets('手机窗口截图（自定义 UA 面板展开）', (WidgetTester tester) async {
    await _pumpApp(tester, const Size(420, 920));
    await tester.tap(find.text('自定义'));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(HomePage),
      matchesGoldenFile('goldens/home_mobile.png'),
    );
  });

  testWidgets('深色手机窗口截图', (WidgetTester tester) async {
    await _pumpApp(tester, const Size(420, 920), brightness: Brightness.dark);
    await expectLater(
      find.byType(HomePage),
      matchesGoldenFile('goldens/home_mobile_dark.png'),
    );
  });
}
