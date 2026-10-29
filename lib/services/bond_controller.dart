import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'auth_service.dart';
import 'network_adapter_service.dart';

class BondException implements Exception {
  const BondException(this.message);
  final String message;
  @override
  String toString() => message;
}

class BondCapability {
  const BondCapability(this.description, this.reasons);
  final String description;

  /// Null means the OS supports this member; absent names are unsupported.
  final Map<String, String?> reasons;
  String? reason(NetworkAdapter adapter) =>
      reasons.containsKey(adapter.name) ? reasons[adapter.name] : '此设备不支持原生绑定';
}

class BondSession {
  const BondSession(
      {required this.id, required this.members, required this.data});
  final String id;
  final List<NetworkAdapter> members;
  final Map<String, dynamic> data;
  Map<String, dynamic> toJson() => {
        'id': id,
        'members': [
          for (final a in members) {'name': a.name, 'address': a.address}
        ],
        'data': data,
      };
  factory BondSession.fromJson(Map<String, dynamic> value) => BondSession(
        id: value['id'] as String,
        members: [
          for (final a in value['members'] as List)
            NetworkAdapter(
                name: a['name'] as String, address: a['address'] as String)
        ],
        data: Map<String, dynamic>.from(value['data'] as Map),
      );
  String encode() => jsonEncode(toJson());
}

abstract interface class BondBackend {
  Future<BondCapability> inspect(List<NetworkAdapter> adapters);
  Future<BondSession> prepare(List<NetworkAdapter> members);
  Future<void> create(BondSession session);
  Future<NetworkAdapter> resolve(BondSession session);
  Future<void> remove(BondSession session);
}

class AdapterCheck {
  const AdapterCheck(this.status, this.time, [this.error]);
  final OnlineStatus status;
  final DateTime time;
  final String? error;
}

/// Authentication evidence never survives an address/configuration change.
/// Native recovery is journaled before creation, including partial failures.
class BondController extends ChangeNotifier {
  BondController(
      {required this.backend,
      required this.adapters,
      required this.checkOnline,
      required this.saveSession,
      DateTime Function()? now})
      : now = now ?? DateTime.now;
  final BondBackend backend;
  final NetworkAdapterService adapters;
  final Future<OnlineStatus> Function(NetworkAdapter) checkOnline;
  final Future<void> Function(BondSession?) saveSession;
  final DateTime Function() now;
  static const evidenceLifetime = Duration(seconds: 60);
  static const startValidationRetries = 3;

  BondCapability capability = const BondCapability('正在检测原生绑定能力…', {});
  final Map<NetworkAdapter, AdapterCheck> checks = {};
  final Set<NetworkAdapter> _selected = {};
  List<NetworkAdapter> available = [];
  List<NetworkAdapter> get selected => List.unmodifiable(_selected);
  BondSession? session;
  NetworkAdapter? bondAdapter;
  bool busy = false;
  bool active = false;
  bool _disposed = false;
  String? message;
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  // 网卡能否使用原生的链路聚合的条件
  //    -不能被占用，可能占用的情况：
  //        - 正在检测
  //        - 正在停止
  //    - 可用
  //        - 不能是回环网卡
  //    - 没有兼容性问题
  //    - 在校园网在线
  bool canSelect(NetworkAdapter adapter) {
    final check = checks[adapter];
    return !busy &&
        session == null &&
        available.contains(adapter) &&
        capability.reason(adapter) == null &&
        check?.status == OnlineStatus.online &&
        now().difference(check!.time) < evidenceLifetime;
  }

  // 刷新网卡
  // 这个是检查网卡是否支持原生绑定的
  // 在手动刷新网卡和加载完成后触发
  // 调用链为 NetworkAdapterService.listAvailable -> BondController.refresh
  // 会筛掉刷新后不存在的网卡以及不兼容的网卡
  Future<void> refresh(List<NetworkAdapter> values) async {
    if (busy || session != null) return;
    busy = true;
    _notify();
    try {
      available = List.unmodifiable(values);
      checks.removeWhere((a, _) => !values.contains(a));
      capability = await backend.inspect(values);
      _selected.removeWhere(
          (a) => !values.contains(a) || capability.reason(a) != null);
      message = null;
    } catch (e) {
      capability = const BondCapability('原生绑定能力检测失败', {});
      _selected.clear();
      message = '$e';
    } finally {
      busy = false;
      _notify();
    }
  }

  // 清除测试结果
  void invalidateChecks() {
    checks.clear();
    _selected.clear();
    _notify();
  }

  void select(NetworkAdapter adapter, bool value) {
    if (busy || session != null) return;
    if (!value) {
      _selected.remove(adapter);
    } else if (canSelect(adapter)) {
      _selected.add(adapter);
    }
    _notify();
  }

  // 检查网卡的内部实现
  Future<OnlineStatus> _check(NetworkAdapter adapter) async {
    try {
      // 网卡必须有效，不能是回环网卡
      await adapters.validate(adapter);
      // 网卡必须在校园网上限
      final status = await checkOnline(adapter);
      checks[adapter] = AdapterCheck(status, now());
      if (status != OnlineStatus.online) _selected.remove(adapter);
      return status;
    } catch (e) {
      checks[adapter] = AdapterCheck(OnlineStatus.unknown, now(), '$e');
      _selected.remove(adapter);
      return OnlineStatus.unknown;
    }
  }

  // 上一个方法对外暴露的接口
  Future<void> check(NetworkAdapter adapter) async {
    if (busy || session != null) return;
    busy = true;
    _notify();
    try {
      await _check(adapter);
    } finally {
      busy = false;
      _notify();
    }
  }

  // 检测所有网卡
  Future<void> checkAll() async {
    if (busy || session != null) return;
    busy = true;
    _notify();
    try {
      for (final a in available) {
        if (_disposed) break;
        message = '正在检测 ${a.label}…';
        _notify();
        await _check(a);
      }
      message = '网卡认证检测完成，请勾选已在线且支持绑定的网卡。';
    } finally {
      busy = false;
      _notify();
    }
  }

  // 开始链路聚合
  Future<void> start() async {
    if (busy || session != null) throw const BondException('已有聚合操作或待恢复记录');
    final members = selected;
    if (members.length < 2 ||
        members.map((a) => a.name).toSet().length != members.length) {
      throw const BondException('请选择至少两张不同的已认证网卡');
    }
    busy = true;
    message = '正在重新验证成员认证状态…';
    _notify();
    try {
      // 在聚合过程重新检查是否支持
      capability = await backend.inspect(members);
      for (final a in members) {
        final reason = capability.reason(a);
        if (reason != null) throw BondException('${a.name}：$reason');
      }

      BondSession? plan;
      var lastFailure = '网卡认证状态已过期';
      for (var attempt = 1; attempt <= startValidationRetries + 1; attempt++) {
        message = '正在重新验证成员认证状态（第 $attempt 轮）…';
        _notify();

        // Check every selected member in every attempt, even after one fails.
        final statuses = <NetworkAdapter, OnlineStatus>{};
        for (final adapter in members) {
          statuses[adapter] = await _check(adapter);
        }
        final failed = members
            .where((adapter) => statuses[adapter] != OnlineStatus.online)
            .toList();
        if (failed.isNotEmpty) {
          lastFailure = '${failed.map((a) => a.name).join('、')} 未确认在线';
          continue;
        }

        // An earlier member's evidence can expire while checking later ones.
        final expiresAt = members
            .map((a) => checks[a]!.time.add(evidenceLifetime))
            .reduce((a, b) => a.isBefore(b) ? a : b);
        if (!now().isBefore(expiresAt)) {
          lastFailure = '网卡认证状态在检测期间过期';
          continue;
        }

        final candidate = await backend.prepare(members);
        if (!now().isBefore(expiresAt)) {
          lastFailure = '系统配置检测期间网卡认证状态过期';
          continue;
        }
        plan = candidate;
        break;
      }

      if (plan == null) {
        throw BondException(
            '初次检测并重试 $startValidationRetries 次后仍未通过，$lastFailure；已取消聚合');
      }
      final expiresAt = members
          .map((a) => checks[a]!.time.add(evidenceLifetime))
          .reduce((a, b) => a.isBefore(b) ? a : b);
      final prepared = BondSession(id: plan.id, members: plan.members, data: {
        ...plan.data,
        'authExpiresAt': expiresAt.millisecondsSinceEpoch ~/ 1000
      });
      if (_disposed) throw const BondException('界面已关闭，已取消创建');
      await saveSession(prepared);
      session = prepared;
      message = '正在创建原生绑定并验证聚合接口…';
      _notify();
      await backend.create(prepared);
      bondAdapter = await backend.resolve(prepared);
      if (_disposed || await checkOnline(bondAdapter!) != OnlineStatus.online) {
        throw const BondException('聚合接口未确认认证在线，原认证可能因 IP/MAC 变化失效');
      }
      active = true;
      message = '原生聚合已启动：${bondAdapter!.label}';
    } catch (e) {
      if (session != null) {
        try {
          await _restore();
        } catch (restoreError) {
          message = '$e；恢复失败：$restoreError。请点击恢复网卡重试。';
          throw BondException(message!);
        }
      }
      message = '$e';
      throw BondException(message!);
    } finally {
      busy = false;
      _notify();
    }
  }

  // 恢复未聚合状态
  Future<void> _restore() async {
    active = false;
    bondAdapter = null;
    await backend.remove(session!);
    await saveSession(null);
    session = null;
    invalidateChecks();
  }

  void recover(BondSession saved) {
    session = saved;
    active = false;
    available = List.unmodifiable(saved.members);
    capability = BondCapability('待恢复的原生聚合：${saved.id}', const {});
    message = '发现上次未结束的原生聚合，请先恢复网卡。';
    _notify();
  }

  Future<void> stop() async {
    if (busy || session == null) return;
    busy = true;
    _notify();
    try {
      await _restore();
      message = '已停止聚合并恢复原网卡连接，请重新检测认证状态。';
    } catch (e) {
      message = '恢复失败：$e。恢复记录已保留，请重试。';
      rethrow;
    } finally {
      busy = false;
      _notify();
    }
  }

  Future<void> verify() async {
    if (busy || !active || session == null) return;
    busy = true;
    _notify();
    try {
      bondAdapter = await backend.resolve(session!);
      if (await checkOnline(bondAdapter!) != OnlineStatus.online) {
        throw const BondException('聚合接口认证已失效');
      }
    } catch (e) {
      try {
        await _restore();
        message = '$e，已停止聚合并恢复网卡。';
      } catch (restoreError) {
        message = '$e；恢复失败：$restoreError，请重试恢复。';
      }
      throw BondException(message!);
    } finally {
      busy = false;
      _notify();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
