import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:giwifi_ua_switcher/pages/home_page.dart';
import 'package:giwifi_ua_switcher/services/settings_service.dart';
import 'package:giwifi_ua_switcher/theme.dart';

/// 加载子集化的真实字体（Noto Sans SC + MaterialIcons），
/// 保证金色截图里中文与图标按真实样式渲染。
Future<void> _loadUiFonts() async {
  final uiBytes = File('test/fonts/ui_font.ttf').readAsBytesSync();
  final uiLoader = FontLoader('UiTestFont')
    ..addFont(Future<ByteData>.value(uiBytes.buffer.asByteData()));
  await uiLoader.load();
  final iconBytes = File('test/fonts/icons.otf').readAsBytesSync();
  final iconLoader = FontLoader('MaterialIcons')
    ..addFont(Future<ByteData>.value(iconBytes.buffer.asByteData()));
  await iconLoader.load();
}

ThemeData _withUiFont(ThemeData base) {
  return base.copyWith(
    textTheme: base.textTheme.apply(fontFamily: 'UiTestFont'),
    primaryTextTheme: base.primaryTextTheme.apply(fontFamily: 'UiTestFont'),
  );
}

Future<void> _pumpApp(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: _withUiFont(buildGiWiFiTheme()),
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
}
