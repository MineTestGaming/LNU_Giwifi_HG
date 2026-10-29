import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:giwifi_ua_switcher/main.dart';
import 'package:giwifi_ua_switcher/pages/home_page.dart';
import 'package:giwifi_ua_switcher/services/settings_service.dart';
import 'package:giwifi_ua_switcher/services/secret_store.dart';
import 'package:giwifi_ua_switcher/theme.dart';
import 'support/memory_secret_store.dart';
import 'support/pump_settings.dart';

void main() {
  setUp(() => SecretStores.override = MemorySecretStore());
  tearDown(() => SecretStores.override = null);
  for (final brightness in Brightness.values) {
    testWidgets('窄屏大字号：设备、表单和高级设置可用（${brightness.name}）',
        (WidgetTester tester) async {
      tester.view.physicalSize = const Size(320, 740);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final tmp = Directory.systemTemp.createTempSync('giwifi_m3_test');
      SettingsService.configDirOverride = tmp.path;
      addTearDown(() {
        SettingsService.configDirOverride = null;
        tmp.deleteSync(recursive: true);
      });
      await tester.pumpWidget(MaterialApp(
        theme: buildGiWiFiTheme(brightness),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: const HomePage(),
      ));
      await waitForSettings(tester);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      final custom = find.widgetWithText(ChoiceChip, '自定义');
      await tester.scrollUntilVisible(custom, 200,
          scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();
      await tester.tap(custom);
      await tester.pumpAndSettle();
      expect(tester.widget<ChoiceChip>(custom).selected, isTrue);

      final ua = find.widgetWithText(TextField, '完整 UA 字符串');
      await tester.scrollUntilVisible(ua, 200,
          scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();
      await tester.enterText(ua, 'Test UA');
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      final advanced = find.text('高级设置');
      await tester.scrollUntilVisible(advanced, 200,
          scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();
      await tester.tap(advanced);
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('断线自动重连'), 200,
          scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      final acName = find.widgetWithText(TextField, '校园 AC 名称（wlanacname）');
      final acMenu = find.byTooltip('选择校园 AC 名称');
      await Scrollable.ensureVisible(tester.element(acName), alignment: 0.5);
      await tester.pumpAndSettle();
      await tester.tap(acMenu);
      await tester.pumpAndSettle();
      expect(find.text('GiWiFi_lnsfHG (湖光)'), findsOneWidget);
      await tester.tap(find.text('GiWiFi_lnsf (寸金)'));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(acName).controller!.text, 'GiWiFi_lnsf');
      await tester.enterText(acName, 'custom_ac');
      expect(tester.widget<TextField>(acName).controller!.text, 'custom_ac');

      final login = find.widgetWithText(FilledButton, '一键认证');
      await tester.scrollUntilVisible(login, 200,
          scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();
      await tester.tap(login);
      await tester.pumpAndSettle();
      expect(find.text('请先填写账号和密码'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

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
    await waitForSettings(tester);
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
    await waitForSettings(tester);
    await tester.pumpAndSettle();

    await tester.tap(find.text('检查状态'));
    await tester.pumpAndSettle();

    expect(find.text('状态未知（可能不在校园网）'), findsOneWidget);
  });

  testWidgets('取消记住立即删除已保存密码，无需再次登录', (tester) async {
    tester.view.physicalSize = const Size(1000, 2200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final tmp = Directory.systemTemp.createTempSync('giwifi_forget_password');
    SettingsService.configDirOverride = tmp.path;
    addTearDown(() async {
      SettingsService.configDirOverride = null;
      for (var attempt = 0;; attempt++) {
        try {
          await tmp.delete(recursive: true);
          break;
        } on FileSystemException {
          if (attempt == 20) rethrow;
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      }
    });
    await tester.runAsync(() => SettingsService.saveLoginInfo(
          username: 'student',
          password: 'private-pass',
          serverUrl: 'http://100.100.9.2',
          profileId: 'pc',
          customUa: '',
          remember: true,
        ));
    await tester.pumpWidget(const GiWiFiApp());
    final switchFinder = find.widgetWithText(SwitchListTile, '记住账号密码');
    for (var i = 0; i < 100; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
      if (tester.widget<SwitchListTile>(switchFinder).onChanged != null) break;
    }
    await tester.tap(switchFinder);
    await tester.pump();
    for (var i = 0; i < 100; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
      if (tester.widget<SwitchListTile>(switchFinder).onChanged != null) break;
    }
    expect(tester.widget<SwitchListTile>(switchFinder).value, isFalse);
    expect((SecretStores.override as MemorySecretStore).values, isEmpty);
    final saved = await tester.runAsync(SettingsService.loadLoginInfo);
    expect(saved![SettingsService.kRemember], isFalse);
    expect(saved[SettingsService.kPassword], '');
    await tester.pumpWidget(const SizedBox());
  });
}
