import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:giwifi_ua_switcher/pages/home_page.dart';
import 'package:giwifi_ua_switcher/services/network_adapter_service.dart';
import 'package:giwifi_ua_switcher/services/settings_service.dart';

Future<void> removeTestDirectory(Directory dir) async {
  // Windows may still be closing the last asynchronous file handle.
  for (var attempt = 0;; attempt++) {
    try {
      await dir.delete(recursive: true);
      return;
    } on FileSystemException {
      if (attempt == 20) rethrow;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }
}

void main() {
  testWidgets('桌面端恢复失效网卡、阻止检测期间切换并允许恢复系统默认', (tester) async {
    tester.view.physicalSize = const Size(1000, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final dir = Directory.systemTemp.createTempSync('giwifi-adapter-ui');
    SettingsService.configDirOverride = dir.path;
    addTearDown(() async {
      SettingsService.configDirOverride = null;
      await removeTestDirectory(dir);
    });
    const saved = NetworkAdapter(name: '校园 Wi-Fi', address: '192.0.2.1');
    await tester.runAsync(() => SettingsService.saveNetworkAdapter(saved));
    final loaded = Completer<void>();
    final checking = Completer<List<NetworkAdapter>>();
    var calls = 0;
    final service = NetworkAdapterService(listAdapters: () {
      if (calls++ == 0) {
        loaded.complete();
        return Future.value([]);
      }
      return checking.future;
    });
    await tester
        .pumpWidget(MaterialApp(home: HomePage(networkAdapters: service)));
    for (var i = 0; i < 100 && !loaded.isCompleted; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
    expect(loaded.isCompleted, isTrue);
    await tester.pumpAndSettle();
    expect(find.text('校园 Wi-Fi · 192.0.2.1（不可用）'), findsOneWidget);
    final selector = find.byKey(const ValueKey('network-adapter-selector'));
    await tester.tap(find.text('检查状态'));
    await tester.pump();
    expect(tester.widget<DropdownButton<NetworkAdapter>>(selector).onChanged,
        isNull);
    expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '一键认证'))
            .onPressed,
        isNull);
    checking.complete([]);
    await tester.pumpAndSettle();
    expect(find.textContaining('不会自动改用其他网卡'), findsOneWidget);
    expect(tester.widget<DropdownButton<NetworkAdapter>>(selector).onChanged,
        isNotNull);
    await tester.tap(selector);
    await tester.pumpAndSettle();
    await tester.tap(find.text('系统默认').last);
    await tester.pumpAndSettle();
    NetworkAdapter? persisted = saved;
    for (var i = 0; i < 100 && persisted != null; i++) {
      persisted = await tester.runAsync(SettingsService.loadNetworkAdapter);
      await tester.pump();
    }
    expect(persisted, isNull, reason: '切换到系统默认后未保存');
    for (var i = 0;
        i < 100 &&
            tester.widget<DropdownButton<NetworkAdapter>>(selector).onChanged ==
                null;
        i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
    expect(tester.widget<DropdownButton<NetworkAdapter>>(selector).onChanged,
        isNotNull);
    await tester.pumpAndSettle();
    expect(
        tester.widget<DropdownButton<NetworkAdapter>>(selector).value, isNull);
    expect(find.textContaining('不会自动改用其他网卡'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('手机端不显示桌面网卡选择', (tester) async {
    final dir = Directory.systemTemp.createTempSync('giwifi-adapter-mobile');
    SettingsService.configDirOverride = dir.path;
    addTearDown(() async {
      SettingsService.configDirOverride = null;
      await removeTestDirectory(dir);
    });
    await tester.pumpWidget(MaterialApp(
        home: HomePage(
      networkAdapters: NetworkAdapterService(
          listAdapters: () async => throw StateError('手机端不应枚举网卡')),
    )));
    await tester.pumpAndSettle();
    expect(
        find.byKey(const ValueKey('network-adapter-selector')), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));
}
