import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:giwifi_ua_switcher/services/bond_controller.dart';
import 'package:giwifi_ua_switcher/services/native_bond_backend.dart';
import 'package:giwifi_ua_switcher/services/network_adapter_service.dart';

const _a = NetworkAdapter(name: 'Ethernet', address: '192.0.2.1');
const _b = NetworkAdapter(name: 'Ethernet 2', address: '192.0.2.2');

String _encode(String script) => base64Encode([
      for (final unit in script.codeUnits) ...[unit & 255, unit >> 8]
    ]);

String _decode(String encoded) {
  final bytes = base64Decode(encoded);
  return String.fromCharCodes([
    for (var i = 0; i < bytes.length; i += 2) bytes[i] | (bytes[i + 1] << 8)
  ]);
}

// Every network command is replaced inside a child PowerShell process. This
// exercises the generated scripts without reading or changing real adapters.
String _fakeWindows({
  int productType = 3,
  bool moduleAvailable = true,
  String? missingCommand,
  bool queryFails = false,
  bool existingTeam = false,
  bool membershipMismatch = false,
}) =>
    '''
\$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
\$script:trace = [System.Collections.Generic.List[string]]::new()
function Get-CimInstance { param(\$ClassName) [pscustomobject]@{ ProductType = $productType } }
function Import-Module {
  param(\$Name, \$ErrorAction)
  if (${moduleAvailable ? '\$false' : '\$true'}) { throw 'NetLbfo unavailable' }
  \$script:trace.Add('Import-Module')
}
function Get-Command {
  param(\$Name, \$Module, [System.Management.Automation.CommandTypes]\$CommandType, \$ErrorAction)
  if (\$Name -ne ${powershellQuote(missingCommand ?? '')} -and
      (-not \$CommandType -or (\$CommandType -band [System.Management.Automation.CommandTypes]::Function))) {
    [pscustomobject]@{ Name = \$Name; CommandType = 'Function'; ModuleName = 'NetLbfo' }
  }
}
function Get-NetLbfoTeam {
  [CmdletBinding()]
  param(\$Name)
  if (${queryFails ? '\$true' : '\$false'}) { Write-Error 'LBFO provider unavailable'; return }
  if (${existingTeam ? '\$true' : '\$false'}) { [pscustomobject]@{ Name = 'gw12345678' } }
}
function Get-NetLbfoTeamMember {
  param(\$Team, \$ErrorAction)
  if (${queryFails ? '\$true' : '\$false'}) { throw 'LBFO provider unavailable' }
  if (\$Team) {
    [pscustomobject]@{ Name = 'Ethernet' }
    [pscustomobject]@{ Name = ${powershellQuote(membershipMismatch ? 'Other NIC' : 'Ethernet 2')} }
  }
}
function Get-NetAdapter {
  param(\$Name, [switch]\$Physical)
  foreach (\$i in 1..2) {
    \$alias = @('Ethernet', 'Ethernet 2')[\$i - 1]
    if (-not \$Name -or \$Name -eq \$alias) {
      [pscustomobject]@{ Name = \$alias; ifIndex = \$i; HardwareInterface = \$true; Status = 'Up'; MediaType = '802.3' }
    }
  }
}
function Get-NetIPInterface { param(\$InterfaceIndex, \$AddressFamily) [pscustomobject]@{ Dhcp = 'Enabled' } }
function Get-NetIPConfiguration {
  param(\$InterfaceIndex)
  [pscustomobject]@{ IPv4DefaultGateway = [pscustomobject]@{ NextHop = '192.0.2.254' } }
}
function Get-NetIPAddress {
  param(\$InterfaceIndex, \$AddressFamily)
  [pscustomobject]@{ IPAddress = "192.0.2.\$InterfaceIndex"; PrefixLength = 24 }
}
function New-NetLbfoTeam {
  param(\$Name, \$TeamMembers, \$TeamingMode, \$LoadBalancingAlgorithm, \$Confirm)
  \$script:trace.Add("create:\$Name|\$(\$TeamMembers -join ',')|\$TeamingMode|\$LoadBalancingAlgorithm")
}
function Remove-NetLbfoTeam { param(\$Name, \$Confirm) \$script:trace.Add("remove:\$Name") }
function Set-NetIPInterface { param(\$InterfaceAlias, \$AddressFamily, \$Dhcp) \$script:trace.Add("dhcp:\$InterfaceAlias") }
function Disable-NetAdapterBinding { param(\$Name, \$ComponentID) \$script:trace.Add("binding:\$Name") }
''';

Future<ProcessResult> _powershell(String script) => Process.run(
    'powershell.exe',
    ['-NoProfile', '-NonInteractive', '-EncodedCommand', _encode(script)],
    stdoutEncoding: utf8,
    stderrEncoding: utf8);

NativeBondBackend _backend(String environment) => NativeBondBackend(
    platform: BondPlatform.windows,
    run: (executable, args) {
      expect(executable, 'powershell.exe');
      return _powershell('$environment\n${_decode(args.last)}');
    });

BondSession _session() => const BondSession(
      id: 'gw12345678',
      members: [_a, _b],
      data: {
        'platform': 'windows',
        'authExpiresAt': 9999999999,
        'members': [
          {
            'name': 'Ethernet',
            'address': '192.0.2.1',
            'prefix': 24,
            'gateway': '192.0.2.254',
            'restoreId': 'Ethernet',
          },
          {
            'name': 'Ethernet 2',
            'address': '192.0.2.2',
            'prefix': 24,
            'gateway': '192.0.2.254',
            'restoreId': 'Ethernet 2',
          },
        ],
      },
    );

Future<Map<String, dynamic>> _mutation(
    String environment, String script) async {
  final result = await _powershell('''
$environment
\$ok = \$true
\$failure = \$null
try {
$script
} catch { \$ok = \$false; \$failure = \$_.Exception.Message }
@{ok = \$ok; error = \$failure; trace = @(\$script:trace)} | ConvertTo-Json -Compress
''');
  expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
  return jsonDecode(result.stdout.toString().trim()) as Map<String, dynamic>;
}

void main() {
  test('Windows Server 与域控制器可检测 LBFO 并准备两张 DHCP 网卡', () async {
    for (final type in [2, 3]) {
      final backend = _backend(_fakeWindows(productType: type));
      final capability = await backend.inspect([_a, _b]);
      expect(capability.description, contains('LBFO'));
      expect(capability.reason(_a), isNull);
      expect(capability.reason(_b), isNull);
      final plan = await backend.prepare([_a, _b]);
      expect(plan.members, [_a, _b]);
      expect(plan.data['platform'], 'windows');
    }
  }, skip: !Platform.isWindows);

  test('Windows 客户端不查询 LBFO，即使命令可用', () async {
    final backend = _backend(_fakeWindows(productType: 1, queryFails: true));
    final capability = await backend.inspect([_a, _b]);
    expect(capability.description, contains('Windows 10/11'));
    expect(capability.reason(_a), isNotNull);
  }, skip: !Platform.isWindows);

  test('NetLbfo 模块缺失时显示明确原因并禁止准备', () async {
    final backend = _backend(_fakeWindows(moduleAvailable: false));
    final capability = await backend.inspect([_a, _b]);
    expect(capability.description, contains('NetLbfo'));
    expect(capability.description, contains('模块'));
    expect(capability.reason(_a), isNotNull);
    await expectLater(backend.prepare([_a, _b]), throwsA(isA<BondException>()));
  }, skip: !Platform.isWindows);

  test('LBFO 缺少恢复命令时禁止创建', () async {
    final backend =
        _backend(_fakeWindows(missingCommand: 'Remove-NetLbfoTeam'));
    final capability = await backend.inspect([_a, _b]);
    expect(capability.description, contains('Remove-NetLbfoTeam'));
    expect(capability.reason(_a), isNotNull);
  }, skip: !Platform.isWindows);

  test('LBFO 查询失败返回能力原因而非丢失具体错误', () async {
    final backend = _backend(_fakeWindows(queryFails: true));
    final capability = await backend.inspect([_a, _b]);
    expect(capability.description, contains('LBFO provider unavailable'));
    expect(capability.reason(_a), isNotNull);
  }, skip: !Platform.isWindows);

  test('LBFO 创建按选择成员使用 SwitchIndependent 和 Dynamic', () async {
    final backend = NativeBondBackend(platform: BondPlatform.windows);
    final result =
        await _mutation(_fakeWindows(), backend.buildCreateScript(_session()));
    expect(result['ok'], isTrue, reason: result['error'] as String?);
    expect(result['trace'], contains('Import-Module'));
    expect(
        result['trace'],
        contains(
            'create:gw12345678|Ethernet,Ethernet 2|SwitchIndependent|Dynamic'));
  }, skip: !Platform.isWindows);

  test('管理员授权后 LBFO 模块不可用时创建和恢复均不修改网卡', () async {
    final backend = NativeBondBackend(platform: BondPlatform.windows);
    for (final script in [
      backend.buildCreateScript(_session()),
      backend.buildRemoveScript(_session()),
    ]) {
      final result =
          await _mutation(_fakeWindows(moduleAvailable: false), script);
      expect(result['ok'], isFalse);
      expect(result['trace'], isEmpty);
    }
  }, skip: !Platform.isWindows);

  test('LBFO 只删除成员匹配的自身 Team 并恢复成员 DHCP', () async {
    final backend = NativeBondBackend(platform: BondPlatform.windows);
    final result = await _mutation(_fakeWindows(existingTeam: true),
        backend.buildRemoveScript(_session()));
    expect(result['ok'], isTrue, reason: result['error'] as String?);
    expect(result['trace'], [
      'Import-Module',
      'remove:gw12345678',
      'dhcp:Ethernet',
      'dhcp:Ethernet 2',
    ]);
    final mismatch = await _mutation(
        _fakeWindows(existingTeam: true, membershipMismatch: true),
        backend.buildRemoveScript(_session()));
    expect(mismatch['ok'], isFalse);
    expect(mismatch['trace'], ['Import-Module']);
  }, skip: !Platform.isWindows);

  test('恢复时 LBFO 查询失败不会被当作 Team 已不存在', () async {
    final backend = NativeBondBackend(platform: BondPlatform.windows);
    final result = await _mutation(
        _fakeWindows(queryFails: true), backend.buildRemoveScript(_session()));
    expect(result['ok'], isFalse);
    expect(result['error'], contains('LBFO provider unavailable'));
    expect(result['trace'], ['Import-Module']);
  }, skip: !Platform.isWindows);

  test('LBFO 恢复不依赖创建命令', () async {
    final backend = NativeBondBackend(platform: BondPlatform.windows);
    final result = await _mutation(
        _fakeWindows(existingTeam: true, missingCommand: 'New-NetLbfoTeam'),
        backend.buildRemoveScript(_session()));
    expect(result['ok'], isTrue, reason: result['error'] as String?);
    expect(result['trace'], contains('remove:gw12345678'));
  }, skip: !Platform.isWindows);
}
