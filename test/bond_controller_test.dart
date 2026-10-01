import 'package:flutter_test/flutter_test.dart';
import 'package:giwifi_ua_switcher/services/auth_service.dart';
import 'package:giwifi_ua_switcher/services/bond_controller.dart';
import 'package:giwifi_ua_switcher/services/network_adapter_service.dart';

class FakeBackend implements BondBackend {
  int creates = 0;
  int removes = 0;
  bool failRemove = false;
  Future<void> Function()? beforeCreate;
  @override
  Future<BondCapability> inspect(List<NetworkAdapter> adapters) async =>
      BondCapability('test', {for (final a in adapters) a.name: null});
  @override
  Future<BondSession> prepare(List<NetworkAdapter> members) async =>
      BondSession(id: 'test-bond', members: members, data: const {});
  @override
  Future<void> create(BondSession session) async {
    creates++;
    await beforeCreate?.call();
  }

  @override
  Future<void> remove(BondSession session) async {
    removes++;
    if (failRemove) throw StateError('restore failed');
  }

  @override
  Future<NetworkAdapter> resolve(BondSession session) async =>
      const NetworkAdapter(name: 'test-bond', address: '192.0.2.10');
}

void main() {
  const a = NetworkAdapter(name: 'eth0', address: '192.0.2.1');
  const b = NetworkAdapter(name: 'eth1', address: '192.0.2.2');
  late FakeBackend backend;
  late BondController controller;
  var statuses = <String, OnlineStatus>{};
  BondSession? saved;
  setUp(() async {
    backend = FakeBackend();
    saved = null;
    statuses = {
      a.name: OnlineStatus.online,
      b.name: OnlineStatus.online,
      'test-bond': OnlineStatus.online
    };
    controller = BondController(
      backend: backend,
      adapters: NetworkAdapterService(listAdapters: () async => [a, b]),
      checkOnline: (adapter) async =>
          statuses[adapter.name] ?? OnlineStatus.unknown,
      saveSession: (session) async {
        saved = session;
      },
    );
    await controller.refresh([a, b]);
  });
  tearDown(() => controller.dispose());

  test('只有刚验证在线的网卡能通过 Checkbox 选择', () async {
    controller.select(a, true);
    expect(controller.selected, isEmpty);
    await controller.check(a);
    controller.select(a, true);
    expect(controller.selected, [a]);
    statuses[a.name] = OnlineStatus.offline;
    await controller.check(a);
    expect(controller.selected, isEmpty);
  });

  test('开始前重新检测，离线或未知成员都不创建原生聚合', () async {
    for (final status in [OnlineStatus.offline, OnlineStatus.unknown]) {
      await controller.check(a);
      await controller.check(b);
      controller.select(a, true);
      controller.select(b, true);
      statuses[b.name] = status;
      await expectLater(controller.start(), throwsA(isA<BondException>()));
      expect(backend.creates, 0);
      expect(saved, isNull);
      statuses[b.name] = OnlineStatus.online;
    }
  });

  test('创建前保存恢复记录，聚合接口未认证则自动撤销', () async {
    await controller.check(a);
    await controller.check(b);
    controller.select(a, true);
    controller.select(b, true);
    statuses['test-bond'] = OnlineStatus.offline;
    backend.beforeCreate = () async {
      expect(saved, isNotNull);
    };
    await expectLater(controller.start(), throwsA(isA<BondException>()));
    expect(backend.creates, 1);
    expect(backend.removes, 1);
    expect(saved, isNull);
    expect(controller.session, isNull);
  });

  test('恢复记录保存失败不会修改系统网络', () async {
    final c = BondController(
        backend: backend,
        adapters: controller.adapters,
        checkOnline: controller.checkOnline,
        saveSession: (_) async => throw StateError('disk full'));
    addTearDown(c.dispose);
    await c.refresh([a, b]);
    await c.checkAll();
    c.select(a, true);
    c.select(b, true);
    await expectLater(c.start(), throwsA(isA<BondException>()));
    expect(backend.creates, 0);
    expect(backend.removes, 0);
  });

  test('在线证据过期或认证配置变化后，Checkbox 失效', () async {
    var now = DateTime(2026);
    final c = BondController(
        backend: backend,
        adapters: controller.adapters,
        checkOnline: controller.checkOnline,
        saveSession: (_) async {},
        now: () => now);
    addTearDown(c.dispose);
    await c.refresh([a, b]);
    await c.checkAll();
    expect(c.canSelect(a), isTrue);
    now = now.add(const Duration(seconds: 60));
    expect(c.canSelect(a), isFalse);
    c.select(a, true);
    expect(c.selected, isEmpty);
    await c.checkAll();
    c.select(a, true);
    c.invalidateChecks();
    expect(c.canSelect(a), isFalse);
    expect(c.selected, isEmpty);
  });

  test('重启恢复模式不会沿用旧在线状态，恢复完成后重新验证', () async {
    controller
        .recover(const BondSession(id: 'test-bond', members: [a, b], data: {}));
    expect(controller.session, isNotNull);
    expect(controller.active, isFalse);
    expect(controller.canSelect(a), isFalse);
    expect(controller.available, [a, b]);
    await controller.stop();
    expect(controller.session, isNull);
    expect(controller.checks, isEmpty);
  });

  test('回滚失败保留恢复记录并允许重试停止', () async {
    await controller.check(a);
    await controller.check(b);
    controller.select(a, true);
    controller.select(b, true);
    statuses['test-bond'] = OnlineStatus.unknown;
    backend.failRemove = true;
    await expectLater(controller.start(), throwsA(isA<BondException>()));
    expect(saved, isNotNull);
    expect(controller.session, isNotNull);
    expect(controller.active, isFalse);
    backend.failRemove = false;
    await controller.stop();
    expect(saved, isNull);
    expect(controller.session, isNull);
  });

  test('运行后掉线撤销，地址变化使原有认证证据失效', () async {
    await controller.check(a);
    await controller.check(b);
    controller.select(a, true);
    controller.select(b, true);
    await controller.start();
    expect(controller.active, isTrue);
    statuses['test-bond'] = OnlineStatus.offline;
    await expectLater(controller.verify(), throwsA(isA<BondException>()));
    expect(backend.removes, 1);
    expect(controller.active, isFalse);
    await controller
        .refresh([const NetworkAdapter(name: 'eth0', address: '192.0.2.3'), b]);
    expect(controller.canSelect(a), isFalse);
  });
}
