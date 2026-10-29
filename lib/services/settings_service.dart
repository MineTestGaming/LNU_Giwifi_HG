import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'network_adapter_service.dart';
import 'bond_controller.dart';
import 'secret_store.dart';

/// 一次认证操作的日志条目
class LogEntry {
  const LogEntry({
    required this.time,
    required this.device,
    required this.success,
    required this.message,
  });

  final DateTime time;
  final String device;
  final bool success;
  final String message;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'time': time.millisecondsSinceEpoch,
        'device': device,
        'success': success,
        'message': message,
      };

  factory LogEntry.fromJson(Map<String, dynamic> json) => LogEntry(
        time: DateTime.fromMillisecondsSinceEpoch(json['time'] as int? ?? 0),
        device: json['device'] as String? ?? '',
        success: json['success'] as bool? ?? false,
        message: json['message'] as String? ?? '',
      );
}

/// 本地设置与操作日志（JSON 文件持久化）。
///
/// 存储位置：Windows 优先沿用 %APPDATA%，其他平台使用 Flutter
/// 官方提供的应用支持目录，确保 Android 写入应用自己的持久化沙盒。
///
/// 密码保存在系统安全存储中；旧版 JSON 密码会在首次读取时迁移并删除。
class SettingsService {
  static SecretStore? get secretStoreOverride => SecretStores.override;
  static set secretStoreOverride(SecretStore? store) =>
      SecretStores.override = store;
  static SecretStore get _secrets => SecretStores.current;
  static const String _passwordSecretKey = 'giwifi_password_v1';

  static Future<void> _storePassword(String username, String password) async {
    final payload = jsonEncode({'username': username, 'password': password});
    await _secrets.write(_passwordSecretKey, payload);
    if (await _secrets.read(_passwordSecretKey) != payload) {
      throw StateError('安全存储校验失败，旧密码未删除');
    }
  }

  static const String kUsername = 'username';
  static const String kPassword = 'password';
  static const String kServerUrl = 'server_url';
  static const String kWlanAcName = 'wlan_ac_name';
  static const String kProfileId = 'profile_id';
  static const String kCustomUa = 'custom_ua';
  static const String kRemember = 'remember';
  static const String kLog = 'log';
  static const int kMaxLog = 50;

  // Separate from the native Windows adapter ID, which Dart does not expose.
  static const String kNetworkAdapter = 'flutter_network_adapter';

  static Future<NetworkAdapter?> loadNetworkAdapter() async {
    final saved = (await _readAll())[kNetworkAdapter];
    if (saved is! Map ||
        saved['name'] is! String ||
        saved['address'] is! String) return null;
    return NetworkAdapter(
        name: saved['name'] as String, address: saved['address'] as String);
  }

  static Future<void> saveNetworkAdapter(NetworkAdapter? adapter) async {
    final data = await _readAll();
    if (adapter == null) {
      data.remove(kNetworkAdapter);
    } else {
      data[kNetworkAdapter] = {
        'name': adapter.name,
        'address': adapter.address
      };
    }
    await _writeAll(data);
  }

  // Separate journal: normal settings writes cannot overwrite recovery data.
  static Future<File> _bondFile() async {
    final dir = Directory(await _configDir());
    await dir.create(recursive: true);
    return File(
        '${dir.path}${Platform.pathSeparator}flutter_bond_recovery.json');
  }

  static Future<BondSession?> loadBondSession() async {
    final file = await _bondFile();
    if (!await file.exists()) return null;
    return BondSession.fromJson(
        jsonDecode(await file.readAsString()) as Map<String, dynamic>);
  }

  static Future<void> saveBondSession(BondSession? session) async {
    final file = await _bondFile();
    if (session == null) {
      if (await file.exists()) await file.delete();
    } else {
      if (await file.exists()) throw const BondException('发现已有恢复记录，请先恢复上次聚合');
      await file.writeAsString(session.encode(), flush: true);
    }
  }

  /// 测试专用：覆盖配置目录（正常使用请保持为 null）。
  static String? configDirOverride;

  static Future<String> _configDir() async {
    final override = configDirOverride;
    if (override != null && override.isNotEmpty) return override;
    final appData = Platform.environment['APPDATA'];
    if (Platform.isWindows && appData != null && appData.isNotEmpty) {
      return '$appData${Platform.pathSeparator}giwifi_ua_switcher';
    }
    final supportDir = await getApplicationSupportDirectory();
    return '${supportDir.path}${Platform.pathSeparator}giwifi_ua_switcher';
  }

  static Future<File> _configFile() async {
    final dir = Directory(await _configDir());
    await dir.create(recursive: true);
    return File(
      '${dir.path}${Platform.pathSeparator}settings.json',
    );
  }

  static Future<Map<String, dynamic>> _readAll() async {
    try {
      final file = await _configFile();
      if (!await file.exists()) return <String, dynamic>{};
      final raw = await file.readAsString();
      final data = jsonDecode(raw);
      return data is Map<String, dynamic> ? data : <String, dynamic>{};
    } catch (_) {
      return <String, dynamic>{};
    }
  }

  static Future<void> _writeAll(Map<String, dynamic> data) async {
    final file = await _configFile();
    final temporary =
        File('${file.path}.${DateTime.now().microsecondsSinceEpoch}.tmp');
    try {
      await temporary.writeAsString(jsonEncode(data), flush: true);
      await temporary.rename(file.path);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  static Future<void> saveLoginInfo({
    required String username,
    required String password,
    required String serverUrl,
    String wlanAcName = 'GiWiFi_lnsfHG',
    required String profileId,
    required String customUa,
    required bool remember,
  }) async {
    final data = await _readAll();
    if (remember) {
      data[kUsername] = username;
      await _storePassword(username, password);
      data.remove(kPassword);
    } else {
      data.remove(kUsername);
      data.remove(kPassword);
    }
    data[kServerUrl] = serverUrl;
    data[kWlanAcName] = wlanAcName;
    data[kProfileId] = profileId;
    data[kCustomUa] = customUa;
    data[kRemember] = remember;
    await _writeAll(data);
    if (!remember) await _secrets.delete(_passwordSecretKey);
  }

  static Future<Map<String, Object>> loadLoginInfo() async {
    final data = await _readAll();
    final remember = data[kRemember] as bool? ?? true;
    var password = '';
    if (remember) {
      final legacyPassword = data[kPassword] as String?;
      if (legacyPassword != null) {
        await _storePassword(data[kUsername] as String? ?? '', legacyPassword);
        data.remove(kPassword);
        await _writeAll(data);
        password = legacyPassword;
      } else {
        final secret = await _secrets.read(_passwordSecretKey);
        if (secret != null) {
          final saved = jsonDecode(secret) as Map<String, dynamic>;
          if (saved['username'] == (data[kUsername] as String? ?? '')) {
            password = saved['password'] as String? ?? '';
          }
        }
      }
    } else {
      if (data.containsKey(kPassword)) {
        data.remove(kPassword);
        await _writeAll(data);
      }
      await _secrets.delete(_passwordSecretKey);
    }
    return <String, Object>{
      kUsername: data[kUsername] as String? ?? '',
      kPassword: password,
      kServerUrl: data[kServerUrl] as String? ?? 'http://100.100.9.2',
      kWlanAcName: data[kWlanAcName] as String? ?? 'GiWiFi_lnsfHG',
      kProfileId: data[kProfileId] as String? ?? 'pc',
      kCustomUa: data[kCustomUa] as String? ?? '',
      kRemember: remember,
    };
  }

  static Future<List<LogEntry>> loadLog() async {
    final data = await _readAll();
    final raw = data[kLog];
    if (raw is! List) return <LogEntry>[];
    try {
      return raw
          .map((e) => LogEntry.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return <LogEntry>[];
    }
  }

  static Future<void> appendLog(LogEntry entry) async {
    final data = await _readAll();
    final list = <LogEntry>[entry, ...await loadLog()];
    final kept = list.take(kMaxLog).toList();
    data[kLog] = kept.map((e) => e.toJson()).toList();
    await _writeAll(data);
  }

  static Future<void> clearLog() async {
    final data = await _readAll();
    data.remove(kLog);
    await _writeAll(data);
  }
}
