import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:giwifi_ua_switcher/main.dart';
import 'package:giwifi_ua_switcher/services/settings_service.dart';

void main() {
  testWidgets('主界面渲染冒烟测试', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1000, 2200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final tmp = Directory.systemTemp.createTempSync('giwifi_widget_test');
    SettingsService.configDirOverride = tmp.path;
    addTearDown(() {
      SettingsService.configDirOverride = null;
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
    });

    await tester.pumpWidget(const GiWiFiApp());
    await tester.pumpAndSettle();

    expect(find.text('GiWiFi 一键认证'), findsOneWidget);
    expect(find.text('一键认证'), findsOneWidget);
    expect(find.text('检查状态'), findsOneWidget);
    expect(find.text('记住账号密码'), findsOneWidget);
    expect(find.text('高级设置'), findsOneWidget);

    // 五种设备预设全部渲染（安卓平板预设已移除）
    for (final label in ['电脑', '安卓手机', 'iPhone', 'iPad', '自定义']) {
      expect(find.text(label), findsOneWidget, reason: '缺少设备选项：$label');
    }
    expect(find.text('安卓平板'), findsNothing);

    // 右上角仓库入口
    expect(find.byTooltip('打开 GitHub 仓库'), findsOneWidget);
  });

  testWidgets('在线检测：无网络时给出友好提示', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1000, 2200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final tmp = Directory.systemTemp.createTempSync('giwifi_widget_test2');
    SettingsService.configDirOverride = tmp.path;
    addTearDown(() {
      SettingsService.configDirOverride = null;
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
    });

    await tester.pumpWidget(const GiWiFiApp());
    await tester.pumpAndSettle();

    await tester.tap(find.text('检查状态'));
    await tester.pumpAndSettle();

    expect(find.text('状态未知（可能不在校园网）'), findsOneWidget);
  });
}
