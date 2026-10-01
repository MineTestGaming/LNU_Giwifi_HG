import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:giwifi_ua_switcher/services/auth_service.dart';
import 'package:giwifi_ua_switcher/services/bond_controller.dart';
import 'package:giwifi_ua_switcher/services/network_adapter_service.dart';
import 'package:giwifi_ua_switcher/widgets/bond_card.dart';
import 'bond_controller_test.dart' show FakeBackend;

void main() {
  testWidgets('Checkbox 仅允许在线成员；检测后可多选，操作期间锁定', (tester) async {
    tester.view.physicalSize = const Size(1000, 1500);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    const a = NetworkAdapter(name: 'eth0', address: '192.0.2.1');
    const b = NetworkAdapter(name: 'eth1', address: '192.0.2.2');
    var bOnline = false;
    final c = BondController(
        backend: FakeBackend(),
        adapters: NetworkAdapterService(listAdapters: () async => [a, b]),
        checkOnline: (adapter) async => adapter == a || bOnline
            ? OnlineStatus.online
            : OnlineStatus.offline,
        saveSession: (_) async {});
    addTearDown(c.dispose);
    await c.refresh([a, b]);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: BondCard(controller: c, locked: false))));
    final checkboxes = find.byType(CheckboxListTile);
    expect(tester.widget<CheckboxListTile>(checkboxes.first).onChanged, isNull);
    await tester.tap(find.text('检测所有网卡'));
    await tester.pumpAndSettle();
    expect(
        tester.widget<CheckboxListTile>(checkboxes.first).onChanged, isNotNull);
    expect(tester.widget<CheckboxListTile>(checkboxes.last).onChanged, isNull);
    await tester.tap(checkboxes.first);
    await tester.pump();
    expect(c.selected, [a]);
    expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '启动原生聚合'))
            .onPressed,
        isNull);
    bOnline = true;
    await c.check(b);
    await tester.pump();
    await tester.tap(checkboxes.last);
    await tester.pump();
    expect(c.selected, [a, b]);
    expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '启动原生聚合'))
            .onPressed,
        isNotNull);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: BondCard(controller: c, locked: true))));
    expect(tester.widget<CheckboxListTile>(checkboxes.first).onChanged, isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
