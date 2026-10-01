import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'bond_controller.dart';
import 'network_adapter_service.dart';

enum BondPlatform { windows, macos, linux, unsupported }

/// Shell values are always single-quoted data, never executable fragments.
String shellQuote(String value) => "'${value.replaceAll("'", "'\"'\"'")}'";
String powershellQuote(String value) => "'${value.replaceAll("'", "''")}'";

class NativeMember {
  const NativeMember(
      {required this.adapter,
      required this.prefix,
      required this.gateway,
      required this.restoreId,
      this.reason});
  final NetworkAdapter adapter;
  final int prefix;
  final String gateway;
  final String restoreId;
  final String? reason;
  Map<String, dynamic> toJson() => {
        'name': adapter.name,
        'address': adapter.address,
        'prefix': prefix,
        'gateway': gateway,
        'restoreId': restoreId
      };
}

/// Probe arguments and mutation scripts are independently injectable in tests.
class NativeBondBackend implements BondBackend {
  NativeBondBackend(
      {BondPlatform? platform,
      Future<ProcessResult> Function(String, List<String>)? run,
      this.listMembers})
      : platform = platform ??
            (Platform.isWindows
                ? BondPlatform.windows
                : Platform.isMacOS
                    ? BondPlatform.macos
                    : Platform.isLinux
                        ? BondPlatform.linux
                        : BondPlatform.unsupported),
        run = run ?? _run;

  final BondPlatform platform;
  final Future<ProcessResult> Function(String, List<String>) run;
  final Future<List<NativeMember>> Function()? listMembers;
  String? _unsupported;

  static Future<ProcessResult> _run(
      String executable, List<String> args) async {
    // On Windows explicitly hide helper windows; no networking commands run
    // until the user starts or stops the bond through the confirmation dialog.
    final process = await Process.start(executable, args,
        mode: ProcessStartMode.normal,
        runInShell: false,
        environment: {'LC_ALL': 'C', 'LANG': 'C'});
    final stdout = process.stdout.transform(utf8.decoder).join();
    final stderr = process.stderr.transform(utf8.decoder).join();
    // Do not kill an elevated mutation on a timeout. Each network operation
    // in the script has an OS timeout. Killing its launcher could race cleanup.
    final code = await process.exitCode;
    return ProcessResult(process.pid, code, await stdout, await stderr);
  }

  Future<String> _read(String executable, List<String> args) async {
    final result =
        await run(executable, args).timeout(const Duration(seconds: 15));
    if (result.exitCode != 0 || result.stdout.toString().contains('** Error:'))
      throw BondException(
          '${executable.split(Platform.pathSeparator).last}：${result.stderr.toString().trim()}');
    return result.stdout.toString().trim();
  }

  Future<String> _ps(String script) => _read('powershell.exe', [
        '-NoProfile',
        '-NonInteractive',
        '-WindowStyle',
        'Hidden',
        '-EncodedCommand',
        _encodePowerShell(script)
      ]);

  static String _encodePowerShell(String script) => base64Encode([
        for (final unit in script.codeUnits) ...[unit & 255, unit >> 8]
      ]);

  Future<List<NativeMember>> _members() async {
    _unsupported = null;
    if (listMembers != null) return listMembers!();
    switch (platform) {
      case BondPlatform.windows:
        return _windowsMembers();
      case BondPlatform.macos:
        return _macMembers();
      case BondPlatform.linux:
        return _linuxMembers();
      case BondPlatform.unsupported:
        _unsupported = '此平台不支持桌面原生网卡绑定';
        return [];
    }
  }

  Future<List<NativeMember>> _windowsMembers() async {
    final raw = await _ps(r'''
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
$server = (Get-CimInstance Win32_OperatingSystem).ProductType -ne 1
$supported = $server -and [bool](Get-Command New-NetLbfoTeam -ErrorAction SilentlyContinue)
$members = @()
if ($supported) {
  $teams = @(Get-NetLbfoTeamMember -ErrorAction Stop)
  foreach ($a in Get-NetAdapter -Physical) {
    $reason = $null
    if ($a.Status -ne 'Up' -or $a.MediaType -ne '802.3') { $reason = 'Only connected Ethernet is supported' }
    if ($teams | Where-Object Name -eq $a.Name) { $reason = 'Already belongs to another team' }
    $ipif = Get-NetIPInterface -InterfaceIndex $a.ifIndex -AddressFamily IPv4
    if ($ipif.Dhcp -ne 'Enabled') { $reason = 'Only DHCP is supported' }
    $gateway = (Get-NetIPConfiguration -InterfaceIndex $a.ifIndex).IPv4DefaultGateway.NextHop
    foreach ($ip in Get-NetIPAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4) {
      $members += @{name=$a.Name; address=$ip.IPAddress; prefix=$ip.PrefixLength;
        gateway=[string]$gateway; restoreId=$a.Name; reason=$reason}
    }
  }
}
@{supported=$supported; members=$members} | ConvertTo-Json -Depth 5 -Compress
''');
    final json = jsonDecode(raw) as Map;
    if (json['supported'] != true) {
      _unsupported =
          '当前 Windows 不支持原生 Team：需 Windows Server 和 NetLbfo；Windows 10/11 客户端不支持。';
      return [];
    }
    return [for (final row in json['members'] as List) _fromRow(row as Map)];
  }

  NativeMember _fromRow(Map row) => NativeMember(
      adapter: NetworkAdapter(
          name: row['name'] as String, address: row['address'] as String),
      prefix: (row['prefix'] as num).toInt(),
      gateway: row['gateway'] as String,
      restoreId: row['restoreId'] as String,
      reason: row['reason'] as String?);

  Future<List<NativeMember>> _linuxMembers() async {
    if (!await File('/usr/bin/pkexec').exists()) {
      _unsupported = 'Linux 原生绑定需要 pkexec 和桌面授权代理，请先安装 polkit。';
      return [];
    }
    await _read('/usr/bin/nmcli', ['-t', '-f', 'RUNNING', 'general']);
    final names =
        await _read('/usr/bin/nmcli', ['-g', 'DEVICE', 'device', 'status']);
    final result = <NativeMember>[];
    for (final name in names.split('\n').where((s) => s.isNotEmpty)) {
      // Kernel physical Ethernet devices have a device symlink and no wireless
      // directory. Reject bridges, VLANs, veth, tun, and Wi-Fi, even when nmcli
      // labels a virtual device as Ethernet.
      final type = await _read(
          '/usr/bin/nmcli', ['-g', 'GENERAL.TYPE', 'device', 'show', name]);
      if (type != 'ethernet' ||
          !await Directory('/sys/class/net/$name/device').exists() ||
          await Directory('/sys/class/net/$name/wireless').exists()) continue;
      final uuid = await _read(
          '/usr/bin/nmcli', ['-g', 'GENERAL.CON-UUID', 'device', 'show', name]);
      if (!RegExp(r'^[a-fA-F0-9-]{36}$').hasMatch(uuid)) continue;
      final method = await _read('/usr/bin/nmcli',
          ['-g', 'ipv4.method', 'connection', 'show', 'uuid', uuid]);
      final master = await _read('/usr/bin/nmcli',
          ['-g', 'connection.master', 'connection', 'show', 'uuid', uuid]);
      final ips = await _read(
          '/usr/bin/nmcli', ['-g', 'IP4.ADDRESS', 'device', 'show', name]);
      final gateway = await _read(
          '/usr/bin/nmcli', ['-g', 'IP4.GATEWAY', 'device', 'show', name]);
      for (final ip in ips.split('\n')) {
        final parts = ip.split('/');
        if (parts.length != 2) continue;
        result.add(NativeMember(
            adapter: NetworkAdapter(name: name, address: parts[0]),
            prefix: int.parse(parts[1]),
            gateway: gateway,
            restoreId: uuid,
            reason: method != 'auto'
                ? '仅支持 DHCP，静态地址不加入聚合'
                : master.isNotEmpty && master != '--'
                    ? '已属于其他绑定或桥接'
                    : null));
      }
    }
    return result;
  }

  Future<List<NativeMember>> _macMembers() async {
    final interfaces = await const NetworkAdapterService().listAvailable();
    final result = <NativeMember>[];
    final ports =
        await _read('/usr/sbin/networksetup', ['-listallhardwareports']);
    for (final a in interfaces) {
      final block = ports
          .split(RegExp(r'\n\s*\n'))
          .where((s) =>
              s.split('\n').any((line) => line.trim() == 'Device: ${a.name}'))
          .toList();
      if (block.isEmpty ||
          RegExp(r'Wi-Fi|AirPort|Bluetooth', caseSensitive: false)
              .hasMatch(block.first)) continue;
      final supported =
          await _read('/usr/sbin/networksetup', ['-isBondSupported', a.name]);
      if (!RegExp(r'\bYes\b', caseSensitive: false).hasMatch(supported))
        continue;
      String packet;
      try {
        packet = await _read('/usr/sbin/ipconfig', ['getpacket', a.name]);
      } catch (_) {
        continue;
      } // No DHCP lease: do not mutate static interfaces.
      final mask = RegExp(r'subnet_mask[^\n]*?:\s*(\d+\.\d+\.\d+\.\d+)')
          .firstMatch(packet)
          ?.group(1);
      final router = RegExp(r'router[^\n]*?:\s*\{?\s*(\d+\.\d+\.\d+\.\d+)')
          .firstMatch(packet)
          ?.group(1);
      if (mask == null || router == null) continue;
      final prefix = InternetAddress(mask).rawAddress.fold<int>(
          0,
          (count, byte) =>
              count +
              byte.toRadixString(2).split('').where((s) => s == '1').length);
      result.add(NativeMember(
          adapter: a, prefix: prefix, gateway: router, restoreId: a.name));
    }
    return result;
  }

  String get description => switch (platform) {
        BondPlatform.windows =>
          'Windows Server：原生 Team / SwitchIndependent / Dynamic',
        BondPlatform.macos => 'macOS：原生 LACP；交换机端口须已配置 LACP',
        BondPlatform.linux => 'Linux：NetworkManager bond / balance-tlb（同一二层网络）',
        _ => '此平台不支持原生绑定',
      };

  @override
  Future<BondCapability> inspect(List<NetworkAdapter> adapters) async {
    final members = await _members();
    return BondCapability(_unsupported ?? description, {
      for (final a in adapters)
        a.name: _unsupported ??
            members
                .where((m) => m.adapter == a)
                .map((m) => m.reason)
                .firstOrNull ??
            (members.any((m) => m.adapter == a)
                ? null
                : '仅支持已连接、使用 DHCP 的物理以太网；Wi-Fi/VPN 不支持原生绑定'),
    });
  }

  @override
  Future<BondSession> prepare(List<NetworkAdapter> members) async {
    final current = await _members();
    final resolved = <NativeMember>[];
    for (final a in members) {
      final match = current.where((m) => m.adapter == a).firstOrNull;
      if (match == null || match.reason != null)
        throw BondException(
            '${a.name}：${match?.reason ?? _unsupported ?? '网卡地址或系统配置已变化'}');
      resolved.add(match);
    }
    validateTopology(resolved);
    final random = Random.secure();
    final suffix =
        List.generate(8, (_) => random.nextInt(16).toRadixString(16)).join();
    final id = 'gw$suffix'; // <= 15 bytes for Linux kernel interface names.
    return BondSession(id: id, members: members, data: {
      'platform': platform.name,
      'members': [for (final m in resolved) m.toJson()],
    });
  }

  static void validateTopology(List<NativeMember> members) {
    if (members.length < 2 ||
        members.map((m) => m.adapter.name).toSet().length != members.length) {
      throw const BondException('至少需要两张不同物理网卡');
    }
    String subnet(NativeMember m) {
      if (m.prefix < 1 || m.prefix > 30)
        throw const BondException('无有效 IPv4 子网');
      final bytes = InternetAddress(m.adapter.address).rawAddress;
      if (bytes.length != 4) throw const BondException('仅支持 IPv4 聚合');
      final ip = bytes.fold<int>(0, (v, b) => (v << 8) | b);
      return '${ip >> (32 - m.prefix)}/${m.prefix}';
    }

    final first = members.first;
    if (first.gateway.isEmpty ||
        members.any((m) =>
            m.reason != null ||
            m.gateway != first.gateway ||
            subnet(m) != subnet(first)) ||
        members.map((m) => m.adapter.address).toSet().length !=
            members.length) {
      throw const BondException('原生绑定要求成员使用不同 IPv4、相同子网与网关；不能合并独立网络');
    }
  }

  void _validateSession(BondSession session) {
    if (!RegExp(r'^gw[0-9a-f]{8}$').hasMatch(session.id) ||
        session.data['platform'] != platform.name ||
        session.members.length < 2) {
      throw const BondException('恢复记录不属于此平台或名称无效，已拒绝系统操作');
    }
    final rows = session.data['members'];
    if (rows is! List ||
        rows.length != session.members.length ||
        session.members.map((a) => a.name).toSet().length !=
            session.members.length) {
      throw const BondException('恢复记录成员无效');
    }
    for (var i = 0; i < rows.length; i++) {
      final row = rows[i];
      final a = session.members[i];
      if (row is! Map ||
          row['name'] != a.name ||
          row['address'] != a.address ||
          row['restoreId'] is! String ||
          row['prefix'] is! int ||
          (row['prefix'] as int) < 1 ||
          (row['prefix'] as int) > 30 ||
          row['gateway'] is! String ||
          a.name.isEmpty ||
          a.name.startsWith('-') ||
          a.name.contains('\n') ||
          a.name.contains('\u0000') ||
          (platform == BondPlatform.linux &&
              !RegExp(r'^[a-fA-F0-9-]{36}$')
                  .hasMatch(row['restoreId'] as String)) ||
          (platform != BondPlatform.linux && row['restoreId'] != a.name)) {
        throw const BondException('恢复记录成员与原始网卡不匹配，已拒绝系统操作');
      }
      if (InternetAddress.tryParse(a.address)?.type !=
              InternetAddressType.IPv4 ||
          InternetAddress.tryParse(row['gateway'] as String)?.type !=
              InternetAddressType.IPv4) {
        throw const BondException('恢复记录中的 IPv4 无效');
      }
    }
  }

  @override
  Future<void> create(BondSession session) async {
    _validateSession(session);
    final expiry = session.data['authExpiresAt'];
    if (expiry is! int ||
        expiry <= DateTime.now().millisecondsSinceEpoch ~/ 1000) {
      throw const BondException('认证证据已过期，已取消系统绑定');
    }
    await _elevate(buildCreateScript(session));
  }

  @override
  Future<void> remove(BondSession session) async {
    _validateSession(session);
    await _elevate(buildRemoveScript(session));
  }

  @override
  Future<NetworkAdapter> resolve(BondSession session) async {
    _validateSession(session);
    String name = session.id;
    if (platform == BondPlatform.macos) {
      final info = await _read('/usr/bin/plutil', [
        '-convert',
        'json',
        '-o',
        '-',
        '/Library/Preferences/SystemConfiguration/preferences.plist'
      ]);
      name =
          macBondDeviceFromPreferences(jsonDecode(info) as Map, session.id) ??
              '';
      if (name.isEmpty) throw const BondException('未找到原生聚合接口');
    }
    for (var i = 0; i < 15; i++) {
      final matches = (await const NetworkAdapterService().listAvailable())
          .where((a) => a.name == name);
      if (matches.isNotEmpty) return matches.first;
      await Future<void>.delayed(const Duration(seconds: 2));
    }
    throw const BondException('聚合接口未获得 IPv4，可能是 DHCP 或 LACP 未就绪');
  }

  /// Kept public for syntax validation without executing system mutations.
  String buildCreateScript(BondSession session) {
    final id = session.id;
    final names = session.members.map((a) => a.name).toList();
    final rows = session.data['members'] as List;
    final expiry = session.data['authExpiresAt'] as int;
    switch (platform) {
      case BondPlatform.windows:
        final members = names.map(powershellQuote).join(',');
        return '''
\$ErrorActionPreference = 'Stop'
if ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() -ge $expiry) { throw 'Authentication evidence expired during administrator authorization' }
if ((Get-CimInstance Win32_OperatingSystem).ProductType -eq 1) { throw 'Windows client does not support native teaming' }
if (Get-NetLbfoTeam -Name ${powershellQuote(id)} -ErrorAction SilentlyContinue) { throw 'Team name already exists' }
${[
          for (final row in rows)
            '''\$a = Get-NetAdapter -Name ${powershellQuote(row['name'] as String)}
if (-not \$a.HardwareInterface -or \$a.Status -ne 'Up' -or \$a.MediaType -ne '802.3') { throw 'Member is not connected physical Ethernet' }
if ((Get-NetIPInterface -InterfaceIndex \$a.ifIndex -AddressFamily IPv4).Dhcp -ne 'Enabled') { throw 'Member no longer uses DHCP' }
if (-not (Get-NetIPAddress -InterfaceIndex \$a.ifIndex -AddressFamily IPv4 | Where-Object { \$_.IPAddress -eq ${powershellQuote(row['address'] as String)} -and \$_.PrefixLength -eq ${row['prefix']} })) { throw 'Member IPv4 changed' }
if ((Get-NetIPConfiguration -InterfaceIndex \$a.ifIndex).IPv4DefaultGateway.NextHop -ne ${powershellQuote(row['gateway'] as String)}) { throw 'Member gateway changed' }
if (Get-NetLbfoTeamMember | Where-Object Name -eq \$a.Name) { throw 'Member already teamed' }'''
        ].join('\n')}
New-NetLbfoTeam -Name ${powershellQuote(id)} -TeamMembers @($members) -TeamingMode SwitchIndependent -LoadBalancingAlgorithm Dynamic -Confirm:\$false | Out-Null
Set-NetIPInterface -InterfaceAlias ${powershellQuote(id)} -AddressFamily IPv4 -Dhcp Enabled
Disable-NetAdapterBinding -Name ${powershellQuote(id)} -ComponentID ms_tcpip6 | Out-Null
''';
      case BondPlatform.macos:
        return '''
set -eu
export LC_ALL=C
[ "\$(/bin/date +%s)" -lt $expiry ] || { echo 'Authentication evidence expired' >&2; exit 1; }
${rows.map((r) => '[ "\$(/usr/sbin/ipconfig getifaddr ${shellQuote(r['name'] as String)})" = ${shellQuote(r['address'] as String)} ] || { echo \'Member IPv4 changed\' >&2; exit 1; }').join('\n')}
${_macNetworksetupFunction()}
ns -createBond ${shellQuote(id)} ${names.map(shellQuote).join(' ')}
${_macFindDeviceFunction()}
device=\$(find_device ${shellQuote(id)})
[ -n "\$device" ] || { echo 'Cannot resolve created bond device' >&2; exit 1; }
if ! /usr/sbin/networksetup -listallnetworkservices | /usr/bin/grep -Fx ${shellQuote(id)} >/dev/null; then
  ns -createnetworkservice ${shellQuote(id)} "\$device"
fi
ns -setdhcp ${shellQuote(id)}
ns -setv6off ${shellQuote(id)}
''';
      case BondPlatform.linux:
        return '''
set -eu
export LC_ALL=C
[ "\$(/bin/date +%s)" -lt $expiry ] || { echo 'Authentication evidence expired' >&2; exit 1; }
${[
          for (final r in rows)
            '''[ "\$(/usr/bin/nmcli -g GENERAL.CON-UUID device show ${shellQuote(r['name'] as String)})" = ${shellQuote(r['restoreId'] as String)} ] || { echo 'Member connection changed' >&2; exit 1; }
/usr/bin/nmcli -g IP4.ADDRESS device show ${shellQuote(r['name'] as String)} | /usr/bin/grep -Fx ${shellQuote('${r['address']}/${r['prefix']}')} >/dev/null || { echo 'Member IPv4 changed' >&2; exit 1; }
[ "\$(/usr/bin/nmcli -g IP4.GATEWAY device show ${shellQuote(r['name'] as String)})" = ${shellQuote(r['gateway'] as String)} ] || { echo 'Member gateway changed' >&2; exit 1; }'''
        ].join('\n')}
if /usr/bin/nmcli -g connection.id connection show ${shellQuote(id)} >/dev/null 2>&1; then echo 'Bond name already exists' >&2; exit 1; fi
/usr/bin/nmcli connection add type bond con-name ${shellQuote(id)} ifname ${shellQuote(id)} bond.options 'mode=balance-tlb,miimon=100' ipv4.method auto ipv6.method disabled connection.autoconnect no
${[
          for (var i = 0; i < names.length; i++)
            '''/usr/bin/nmcli connection add type ethernet con-name ${shellQuote('$id-p$i')} ifname ${shellQuote(names[i])} master ${shellQuote(id)} slave-type bond connection.autoconnect no
/usr/bin/nmcli --wait 15 connection down uuid ${shellQuote(rows[i]['restoreId'] as String)}
/usr/bin/nmcli --wait 30 connection up ${shellQuote('$id-p$i')}'''
        ].join('\n')}
/usr/bin/nmcli --wait 30 connection up ${shellQuote(id)}
''';
      case BondPlatform.unsupported:
        throw const BondException('平台不支持');
    }
  }

  String buildRemoveScript(BondSession session) {
    final id = session.id;
    switch (platform) {
      case BondPlatform.windows:
        return '''
\$ErrorActionPreference = 'Stop'
if (Get-NetLbfoTeam -Name ${powershellQuote(id)} -ErrorAction SilentlyContinue) {
  \$expected = @(${session.members.map((a) => powershellQuote(a.name)).join(',')})
  \$actual = @(Get-NetLbfoTeamMember -Team ${powershellQuote(id)} | Select-Object -ExpandProperty Name)
  if (@(Compare-Object \$expected \$actual).Count -ne 0) { throw 'Team ownership mismatch; manual recovery required' }
  Remove-NetLbfoTeam -Name ${powershellQuote(id)} -Confirm:\$false
}
${session.members.map((a) => 'Set-NetIPInterface -InterfaceAlias ${powershellQuote(a.name)} -AddressFamily IPv4 -Dhcp Enabled').join('\n')}
''';
      case BondPlatform.macos:
        // -deleteBond takes a device, not the aggregate's service name.
        return '''
set -eu
export LC_ALL=C
${_macNetworksetupFunction()}
${_macFindDeviceFunction()}
device=\$(find_device ${shellQuote(id)})
if [ -n "\$device" ]; then
  ${[
          for (var i = 0; i < session.members.length; i++)
            '[ "\$(/usr/libexec/PlistBuddy -c "Print :VirtualNetworkInterfaces:Bond:\$device:Interfaces:$i" /Library/Preferences/SystemConfiguration/preferences.plist)" = ${shellQuote(session.members[i].name)} ] || { echo \'Bond membership changed; manual recovery required\' >&2; exit 1; }'
        ].join('\n  ')}
  if /usr/libexec/PlistBuddy -c "Print :VirtualNetworkInterfaces:Bond:\$device:Interfaces:${session.members.length}" /Library/Preferences/SystemConfiguration/preferences.plist >/dev/null 2>&1; then echo 'Bond has unexpected members' >&2; exit 1; fi
  if /usr/sbin/networksetup -listallnetworkservices | /usr/bin/grep -Fx ${shellQuote(id)} >/dev/null; then ns -removenetworkservice ${shellQuote(id)}; fi
  ns -deleteBond "\$device"
fi
''';
      case BondPlatform.linux:
        final rows = session.data['members'] as List;
        return '''
set -u
export LC_ALL=C
failed=0
${[
          for (var i = 0; i < session.members.length; i++)
            '''if /usr/bin/nmcli -g connection.id connection show ${shellQuote('$id-p$i')} >/dev/null 2>&1; then
  /usr/bin/nmcli --wait 15 connection delete ${shellQuote('$id-p$i')} || failed=1
fi'''
        ].join('\n')}
if /usr/bin/nmcli -g connection.id connection show ${shellQuote(id)} >/dev/null 2>&1; then
  /usr/bin/nmcli --wait 15 connection delete ${shellQuote(id)} || failed=1
fi
${rows.map((r) => '/usr/bin/nmcli --wait 30 connection up uuid ${shellQuote(r['restoreId'] as String)} || failed=1').join('\n')}
exit "\$failed"
''';
      case BondPlatform.unsupported:
        throw const BondException('平台不支持');
    }
  }

  static String? macBondDeviceFromPreferences(Map preferences, String id) {
    final virtual = preferences['VirtualNetworkInterfaces'];
    final bonds = virtual is Map ? virtual['Bond'] : null;
    if (bonds is! Map) return null;
    for (final entry in bonds.entries) {
      if (entry.value is Map &&
          entry.value['UserDefinedName'] == id &&
          entry.key is String &&
          RegExp(r'^bond\d+$').hasMatch(entry.key as String)) {
        return entry.key as String;
      }
    }
    return null;
  }

  // SCBondInterface stores its name here; avoid localized command output.
  String _macFindDeviceFunction() => r'''
find_device() {
  /usr/bin/plutil -lint /Library/Preferences/SystemConfiguration/preferences.plist >/dev/null || return $?
  configured=$(/usr/libexec/PlistBuddy -c 'Print :VirtualNetworkInterfaces:Bond' /Library/Preferences/SystemConfiguration/preferences.plist 2>/dev/null | /usr/bin/sed -n 's/^[[:space:]]*\(bond[0-9][0-9]*\) = Dict.*$/\1/p')
  for candidate in $(/sbin/ifconfig -l) $configured; do
    case "$candidate" in bond[0-9]*)
      name=$(/usr/libexec/PlistBuddy -c "Print :VirtualNetworkInterfaces:Bond:$candidate:UserDefinedName" /Library/Preferences/SystemConfiguration/preferences.plist 2>/dev/null) || continue
      if [ "$name" = "$1" ]; then printf '%s\n' "$candidate"; return; fi
      ;; esac
  done
}
''';

  String _macNetworksetupFunction() => r'''
ns() {
  output=$(/usr/sbin/networksetup "$@") || return $?
  case "$output" in *'** Error:'*) printf '%s\n' "$output" >&2; return 1;; esac
}
''';

  Future<void> _elevate(String script) async {
    ProcessResult result;
    if (platform == BondPlatform.windows) {
      final dir = await Directory.systemTemp.createTemp('giwifi-bond-');
      try {
        final output = File('${dir.path}${Platform.pathSeparator}result.json');
        final body = '''
try {
$script
  @{ok=\$true} | ConvertTo-Json | Set-Content -Encoding UTF8 -LiteralPath ${powershellQuote(output.path)}
} catch {
  @{ok=\$false; error=\$_.Exception.Message} | ConvertTo-Json | Set-Content -Encoding UTF8 -LiteralPath ${powershellQuote(output.path)}
  exit 1
}
''';
        final helper = File('${dir.path}${Platform.pathSeparator}helper.ps1');
        await helper.writeAsString('\uFEFF$body', flush: true);
        final arguments = powershellQuote(
            '-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "${helper.path}"');
        result = await run('powershell.exe', [
          '-NoProfile',
          '-NonInteractive',
          '-WindowStyle',
          'Hidden',
          '-EncodedCommand',
          _encodePowerShell('''
\$ErrorActionPreference = 'Stop'
\$p = Start-Process powershell.exe -Verb RunAs -WindowStyle Hidden -PassThru -Wait -ArgumentList $arguments
exit \$p.ExitCode
''')
        ]);
        if (!await output.exists())
          throw const BondException('管理员授权已取消或系统命令未完成');
        final value =
            jsonDecode((await output.readAsString()).replaceFirst('\uFEFF', ''))
                as Map;
        if (value['ok'] != true)
          throw BondException('原生 Team 操作失败：${value['error']}');
      } finally {
        await dir.delete(recursive: true);
      }
    } else if (platform == BondPlatform.macos) {
      final command = '/bin/sh -c ${shellQuote(script)}';
      final literal = command
          .replaceAll('\\', '\\\\')
          .replaceAll('"', '\\"')
          .replaceAll('\n', '\\n')
          .replaceAll('\r', '\\r');
      result = await run('/usr/bin/osascript',
          ['-e', 'do shell script "$literal" with administrator privileges']);
    } else if (platform == BondPlatform.linux) {
      result = await run('/usr/bin/pkexec', ['/bin/sh', '-c', script]);
    } else {
      throw const BondException('此平台不支持原生绑定');
    }
    if (result.exitCode != 0)
      throw BondException(
          '系统绑定操作失败或管理员授权被取消：${result.stderr.toString().trim()}');
  }
}
