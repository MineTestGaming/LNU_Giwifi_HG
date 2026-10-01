import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:giwifi_ua_switcher/services/bond_controller.dart';
import 'package:giwifi_ua_switcher/services/native_bond_backend.dart';
import 'package:giwifi_ua_switcher/services/network_adapter_service.dart';

void main() {
  const a = NetworkAdapter(name: 'eth0', address: '192.0.2.1');
  const b = NetworkAdapter(name: 'eth1', address: '192.0.2.2');
  NativeMember member(NetworkAdapter adapter,
          {String gateway = '192.0.2.254', int prefix = 24, String? reason}) =>
      NativeMember(
          adapter: adapter,
          prefix: prefix,
          gateway: gateway,
          restoreId: '00000000-0000-0000-0000-000000000001',
          reason: reason);

  test('原生绑定拒绝不同子网、不同网关、重复地址和不支持的设备', () {
    NativeBondBackend.validateTopology([member(a), member(b)]);
    for (final second in [
      member(b, gateway: '192.0.2.253'),
      member(const NetworkAdapter(name: 'eth1', address: '198.51.100.1')),
      member(const NetworkAdapter(name: 'eth1', address: '192.0.2.1')),
      member(b, reason: 'Wi-Fi 不支持'),
      member(b, prefix: 32)
    ]) {
      expect(() => NativeBondBackend.validateTopology([member(a), second]),
          throwsA(isA<BondException>()));
    }
  });

  test('网卡的 IPv4 不在系统清单时拒绝准备，平台能力注明原因', () async {
    final backend = NativeBondBackend(
        platform: BondPlatform.linux,
        listMembers: () async => [member(a), member(b)]);
    const missing = NetworkAdapter(name: 'eth0', address: '192.0.2.3');
    expect((await backend.inspect([missing, b])).reason(missing), isNotNull);
    await expectLater(
        backend.prepare([missing, b]), throwsA(isA<BondException>()));
  });

  test('Windows 客户端即使装有 NetLbfo 命令也显示不支持', () async {
    final backend = NativeBondBackend(
        platform: BondPlatform.windows,
        run: (_, __) async =>
            ProcessResult(0, 0, '{"supported":false,"members":[]}', ''));
    final capability = await backend.inspect([a, b]);
    expect(capability.description, contains('Windows 10/11'));
    expect(capability.reason(a), isNotNull);
  });

  test('恢复记录不匹配时绝不调用系统命令', () async {
    var calls = 0;
    final backend = NativeBondBackend(
        platform: BondPlatform.linux,
        run: (_, __) async {
          calls++;
          return ProcessResult(0, 0, '', '');
        });
    await expectLater(
        backend.remove(const BondSession(
            id: 'arbitrary', members: [a, b], data: {'platform': 'linux'})),
        throwsA(isA<BondException>()));
    expect(calls, 0);
  });

  test('macOS 从原生配置按精确名称识别逻辑接口', () {
    final preferences = {
      'VirtualNetworkInterfaces': {
        'Bond': {
          'bond0': {'UserDefinedName': 'other'},
          'bond1': {'UserDefinedName': 'gw12345678'},
        }
      }
    };
    expect(
        NativeBondBackend.macBondDeviceFromPreferences(
            preferences, 'gw12345678'),
        'bond1');
    expect(
        NativeBondBackend.macBondDeviceFromPreferences(
            preferences, 'gw1234567'),
        isNull);
    expect(NativeBondBackend.macBondDeviceFromPreferences({}, 'gw12345678'),
        isNull);
  });

  test('系统参数作为数据转义，不解析单引号或命令替换', () {
    expect(shellQuote("eth'\$(touch x)"), "'eth'\"'\"'\$(touch x)'");
    expect(powershellQuote("Ethernet'; Write-Output x; '"),
        "'Ethernet''; Write-Output x; '''");
  });

  test('生成的平台脚本含认证期限，Linux 原配置只停用和恢复', () async {
    final backend = NativeBondBackend(
        platform: BondPlatform.linux,
        listMembers: () async => [member(a), member(b)]);
    final plan = await backend.prepare([a, b]);
    final session = BondSession(
        id: plan.id,
        members: plan.members,
        data: {...plan.data, 'authExpiresAt': 9999999999});
    final create = backend.buildCreateScript(session);
    final remove = backend.buildRemoveScript(session);
    expect(create, contains('balance-tlb'));
    expect(create, contains('9999999999'));
    expect(create, contains('Member IPv4 changed'));
    expect(remove, contains('connection up uuid'));
    expect(remove, isNot(contains('connection delete uuid')));
  });

  test('平台脚本仅做语法校验，不运行网卡操作', () async {
    final dir = await Directory.systemTemp.createTemp('giwifi-bond-syntax-');
    addTearDown(() => dir.delete(recursive: true));
    for (final platform in [
      BondPlatform.windows,
      BondPlatform.macos,
      BondPlatform.linux
    ]) {
      final backend = NativeBondBackend(platform: platform);
      final session = BondSession(id: 'gw12345678', members: const [
        a,
        b
      ], data: {
        'platform': platform.name,
        'authExpiresAt': 9999999999,
        'members': [
          for (final m in [member(a), member(b)]) m.toJson()
        ],
      });
      for (final script in [
        backend.buildCreateScript(session),
        backend.buildRemoveScript(session)
      ]) {
        final file = File('${dir.path}/${platform.name}.txt');
        await file.writeAsString(script);
        if (platform == BondPlatform.windows && Platform.isWindows) {
          final parsed = await Process.run('powershell.exe', [
            '-NoProfile',
            '-NonInteractive',
            '-Command',
            '\$tokens=\$null; \$errors=\$null; [void][System.Management.Automation.Language.Parser]::ParseFile(${powershellQuote(file.path)}, [ref]\$tokens, [ref]\$errors); if (\$errors.Count) { \$errors | ForEach-Object Message; exit 1 }'
          ]);
          expect(parsed.exitCode, 0,
              reason: '${parsed.stdout}\n${parsed.stderr}');
        } else if (platform != BondPlatform.windows) {
          final shell = Platform.isWindows
              ? 'C:/Program Files/Git/bin/bash.exe'
              : '/bin/sh';
          if (!await File(shell).exists()) continue;
          final parsed = await Process.run(shell, ['-n', file.path]);
          expect(parsed.exitCode, 0,
              reason: '${parsed.stdout}\n${parsed.stderr}');
        }
      }
    }
  });
}
