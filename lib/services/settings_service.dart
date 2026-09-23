import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

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
/// 注意：密码以明文保存在本机配置文件中，请仅在个人设备上使用。
class SettingsService {
  static const String kUsername = 'username';
  static const String kPassword = 'password';
  static const String kServerUrl = 'server_url';
  static const String kProfileId = 'profile_id';
  static const String kCustomUa = 'custom_ua';
  static const String kRemember = 'remember';
  static const String kLog = 'log';
  static const int kMaxLog = 50;

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
    await file.writeAsString(jsonEncode(data), flush: true);
  }

  static Future<void> saveLoginInfo({
    required String username,
    required String password,
    required String serverUrl,
    required String profileId,
    required String customUa,
    required bool remember,
  }) async {
    final data = await _readAll();
    if (remember) {
      data[kUsername] = username;
      data[kPassword] = password;
    } else {
      data.remove(kUsername);
      data.remove(kPassword);
    }
    data[kServerUrl] = serverUrl;
    data[kProfileId] = profileId;
    data[kCustomUa] = customUa;
    data[kRemember] = remember;
    await _writeAll(data);
  }

  static Future<Map<String, Object>> loadLoginInfo() async {
    final data = await _readAll();
    return <String, Object>{
      kUsername: data[kUsername] as String? ?? '',
      kPassword: data[kPassword] as String? ?? '',
      kServerUrl: data[kServerUrl] as String? ?? 'http://100.100.9.2',
      kProfileId: data[kProfileId] as String? ?? 'pc',
      kCustomUa: data[kCustomUa] as String? ?? '',
      kRemember: data[kRemember] as bool? ?? true,
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
