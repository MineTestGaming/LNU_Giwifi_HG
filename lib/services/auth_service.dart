import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../utils/aes_crypto.dart';
import '../utils/form_builder.dart';
import '../utils/html_parser.dart';

/// 认证结果
class LoginResult {
  const LoginResult({
    required this.success,
    required this.message,
    this.raw,
    this.needsRebind = false,
    this.rebindInfo,
    this.rebindUrl,
    this.redirectUrl,
    this.onlineDuration,
    this.alreadyOnline = false,
  });

  final bool success;
  final String message;
  final Map<String, dynamic>? raw;

  /// 服务器要求确认“更换绑定设备”（resultCode=124）。
  final bool needsRebind;

  /// 换绑确认弹窗的提示文案（服务器返回）。
  final String? rebindInfo;

  /// 确认换绑时要 POST 的地址（服务器返回）。
  final String? rebindUrl;

  /// 服务器要求跳转的地址（resultCode=40）。
  final String? redirectUrl;

  /// 认证成功后的在线时长（HH:MM:SS），解析失败为 null。
  final String? onlineDuration;

  /// 请求登录页时当前设备已在线（门户直接返回在线页面而非登录表单）。
  final bool alreadyOnline;
}

/// 用户主动停止了正在进行的认证请求。
class AuthCancelledException implements Exception {
  const AuthCancelledException();

  @override
  String toString() => '认证已停止';
}

/// 在线状态
enum OnlineStatus { online, offline, unknown }

/// GiWiFi gportal 认证客户端（零第三方依赖，dart:io HttpClient）。
///
/// 完整流程（与门户页 JS 一致）：
/// 1. 以指定 UA 请求登录页，服务器据此渲染 device_type 等隐藏字段
/// 2. 组装表单 -> AES-128-CBC + ZeroPadding 加密
/// 3. POST /gportal/Web/loginAction
///    - status=1：认证成功，进一步查询在线时长
///    - resultCode=124：服务器要求确认“更换绑定设备”，
///      POST resultData 提交换绑 -> 等待 6 秒冷却 -> 自动再次认证
///    - resultCode=40：跟随服务器要求跳转后重试
///    - 其余错误码直接返回服务器提示
///
/// 整个流程复用同一个 HttpClient（自动携带 Cookie 会话），
/// 与浏览器行为保持一致。
class AuthService {
  AuthService({
    this.baseUrl = 'http://100.100.9.2',
    this.timeout = const Duration(seconds: 10),
    this.rebindCooldown = const Duration(seconds: 6),
    this.portalCooldown = const Duration(seconds: 6),
    this.verifyInterval = const Duration(seconds: 2),
  });

  final String baseUrl;
  final Duration timeout;

  /// 提交换绑后、再次认证前的冷却时间（门户页大约 6 秒后允许再次点击）。
  final Duration rebindCooldown;

  /// 门户登录接口自身的频率限制冷却（提示“请5秒后再试”，含注销后立即登录）。
  final Duration portalCooldown;

  /// status=1 后轮询 logout 页确认上线的时间间隔。
  final Duration verifyInterval;

  HttpClient? _session;
  HttpClient? _activeClient;
  bool _cancelled = false;

  bool get isCancelled => _cancelled;

  static const String kLoginPath = '/gportal/web/login';
  static const String kLogoutPath = '/gportal/web/logout';
  static const String kLoginActionPath = '/gportal/Web/loginAction';
  static const String kLogoutActionPath = '/gportal/Web/logoutAction';

  /// 中断当前认证流程。关闭 socket 后 Android 上也能立即返回。
  void cancel() {
    _cancelled = true;
    _activeClient?.close(force: true);
    _activeClient = null;
    _session?.close(force: true);
    _session = null;
  }

  void _checkCancelled() {
    if (_cancelled) throw const AuthCancelledException();
  }

  /// 整个认证流程期间复用的会话客户端（自动携带 Cookie）。
  HttpClient get _client => _session ??= HttpClient();

  /// 相对路径/绝对 URL 统一解析。
  String _abs(String pathOrUrl) =>
      Uri.parse(baseUrl).resolve(pathOrUrl).toString();

  // ================= 一键认证（含换绑 + 冷却 + 二次认证） =================

  /// [onRebindConfirm]：需要换绑时回调，返回 true 表示用户确认；
  /// [onStatus]：流程进度回调（用于界面实时显示当前阶段）。
  Future<LoginResult> login({
    required String username,
    required String password,
    required String userAgent,
    String accountType = '2',
    Future<bool> Function(String rebindInfo)? onRebindConfirm,
    Future<bool> Function()? onSwitchConfirm,
    void Function(String status)? onStatus,
  }) async {
    _cancelled = false;
    _session?.close(force: true);
    _session = HttpClient();

    void report(String status) {
      try {
        onStatus?.call(status);
      } catch (_) {
        // 界面回调异常不影响认证主流程
      }
    }

    var rebindDone = false;
    for (var round = 1; round <= 6; round++) {
      _checkCancelled();
      report(round == 1 ? '正在提交认证…' : '正在重新提交认证（第 $round 次）…');

      final result = await _submitLogin(
        username: username,
        password: password,
        userAgent: userAgent,
        accountType: accountType,
      );

      if (result.alreadyOnline) {
        // 已在线并不能证明账号密码正确。询问用户是否下线切换；
        // 取消或注销失败时都按“未完成认证”返回，绝不显示认证成功。
        final confirmed =
            await (onSwitchConfirm?.call() ?? Future<bool>.value(false));
        if (!confirmed) {
          return const LoginResult(
            success: false,
            message: '当前设备已在线，已取消切换（未验证账号密码）',
          );
        }
        report('正在注销当前在线设备…');
        if (!await logout(userAgent)) {
          return const LoginResult(
            success: false,
            message: '注销失败，无法切换设备；请先在网页端手动下线后重试',
          );
        }
        report('已下线，等待 ${portalCooldown.inSeconds} 秒后重新认证…');
        await _sleep(portalCooldown);
        continue;
      }

      if (result.success) {
        // 只有 loginAction 返回 status=1 才算成功，且成功后还要复核
        // 设备是否真实上线，避免“密码错误也显示成功”的假成功。
        // 门户在 status=1 后是异步放行，需轮询 logout 页直到 si 出现。
        report('服务器返回成功，正在等待设备上线…');
        if (await _verifyOnline(userAgent) != _OnlineVerify.online) {
          return LoginResult(
            success: false,
            message: '服务器提示成功，但设备未检测到在线，请核对账号密码后重试',
            raw: result.raw,
          );
        }
        final duration = await _fetchOnlineDuration(userAgent);
        final message = duration != null
            ? '认证成功，当前在线时长 $duration'
            : '认证成功';
        return LoginResult(
          success: true,
          message: message,
          raw: result.raw,
          onlineDuration: duration,
        );
      }

      if (result.needsRebind) {
        if (rebindDone) {
          // 已换绑一次但服务器仍要求确认，可能是绑定尚未生效，
          // 不再重复消耗“更换设备次数”，等待后直接重试登录。
          report('换绑后仍需确认，等待 8 秒后自动重试…');
          await _sleep(const Duration(seconds: 8));
          continue;
        }
        final info = result.rebindInfo ?? '是否将上网设备重新绑定至当前设备？';
        report('服务器要求确认更换绑定设备');
        final confirmed =
            await (onRebindConfirm?.call(info) ?? Future<bool>.value(false));
        if (!confirmed) {
          return const LoginResult(success: false, message: '已取消换绑，认证未完成');
        }
        report('正在提交换绑确认…');
        await _confirmRebind(result.rebindUrl ?? '', userAgent);
        rebindDone = true;
        report(
          '换绑已提交，等待 ${rebindCooldown.inSeconds} 秒冷却后自动再次认证…',
        );
        await _sleep(rebindCooldown);
        continue;
      }

      if (result.redirectUrl != null && result.redirectUrl!.isNotEmpty) {
        report('服务器要求跳转页面，正在处理…');
        try {
          await _getText(_abs(result.redirectUrl!), userAgent);
        } catch (_) {
          // 跳转失败不影响重试
        }
        continue;
      }

      if (result.message.contains('频繁') || result.message.contains('稍后')) {
        report('门户提示操作过于频繁，等待 ${portalCooldown.inSeconds} 秒后自动重试…');
        await _sleep(portalCooldown);
        continue;
      }

      return result;
    }

    return const LoginResult(success: false, message: '多次尝试仍未成功，请稍后重试');
  }

  /// 单次“拉登录页 -> 加密 -> 提交”并解析服务器返回。
  Future<LoginResult> _submitLogin({
    required String username,
    required String password,
    required String userAgent,
    required String accountType,
  }) async {
    final html = await fetchLoginPage(userAgent);

    if (!_hasPasswordInput(html)) {
      // 移动端在线首页无表单，且页面 JS 模板里带“logout/online_duration”
      // 等字样，不能用文本提示判断在线，只能以 logout 页的 si 为准。
      if (await _hasActiveSession(userAgent)) {
        // 已在线不代表账号密码验证通过：绝不能当作“认证成功”返回，
        // 是否切换设备由上层决定。
        return const LoginResult(
          success: false,
          message: '当前设备已在线',
          alreadyOnline: true,
        );
      }
      return const LoginResult(
        success: false,
        message: '响应不是登录页（可能已在线，或未连接校园网）',
      );
    }

    // PC 端设备已在线时，登录页仍渲染表单，不能仅凭表单判断状态；
    // 实测在线时门户对任意密码都直接返回 status=1（旧会话），
    // 只有 logout 页是否下发 si 才是可靠的在线信号。
    if (await _hasActiveSession(userAgent)) {
      return const LoginResult(
        success: false,
        message: '当前设备已在线',
        alreadyOnline: true,
      );
    }

    final hidden = parseHiddenInputs(html);
    final iv = hidden['iv'] ?? '';
    final sign = hidden['sign'] ?? '';
    if (iv.isEmpty) {
      return const LoginResult(
        success: false,
        message: '登录页缺少 iv 参数，门户页面结构可能已变化',
      );
    }
    if (sign.isEmpty) {
      return const LoginResult(
        success: false,
        message: '登录页缺少 sign 参数，门户页面结构可能已变化',
      );
    }

    final fields = <String, String>{
      'sign': sign,
      'sta_vlan': hidden['sta_vlan'] ?? '',
      'sta_port': hidden['sta_port'] ?? '',
      'sta_ip': hidden['sta_ip'] ?? '',
      'nas_ip': hidden['nas_ip'] ?? '',
      'nas_name': hidden['nas_name'] ?? '',
      'last_url': hidden['last_url'] ?? '',
      'request_ip': hidden['request_ip'] ?? '',
      'device_mode': hidden['device_mode'] ?? '',
      'device_type': hidden['device_type'] ?? '1',
      'device_os_type': hidden['device_os_type'] ?? '3',
      'is_mobile': hidden['is_mobile'] ?? '0',
      'iv': iv,
      'login_type': hidden['login_type'] ?? '1',
      'account_type': accountType,
      'user_account': username,
      'user_password': password,
    };

    final formStr = buildFormString(fields);
    final data = aesCbcZeroPadEncrypt(formStr, kGiWifiAesKey, iv);

    final body = await _postText(
      '$baseUrl$kLoginActionPath',
      userAgent,
      body: 'data=${Uri.encodeComponent(data)}'
          '&iv=${Uri.encodeComponent(iv)}',
    );

    return _parseLoginResponse(body);
  }

  LoginResult _parseLoginResponse(String body) {
    Map<String, dynamic> json;
    try {
      json = jsonDecode(body) as Map<String, dynamic>;
    } catch (_) {
      final preview = body.length > 120 ? body.substring(0, 120) : body;
      return LoginResult(success: false, message: '服务器响应解析失败：$preview');
    }

    final status = json['status'];
    final info = json['info']?.toString() ?? '未知响应';
    if (status == 1) {
      return LoginResult(success: true, message: info, raw: json);
    }
    if (status == 0) {
      final data = json['data'];
      if (data is Map) {
        final code = data['resultCode']?.toString();
        final resultData = data['resultData']?.toString();
        switch (code) {
          case '124':
            return LoginResult(
              success: false,
              message: info,
              raw: json,
              needsRebind: true,
              rebindInfo: info,
              rebindUrl: resultData,
            );
          case '40':
            return LoginResult(
              success: false,
              message: info,
              raw: json,
              redirectUrl: resultData,
            );
          case '114':
            return LoginResult(
              success: false,
              message: '账号需要先设置密码，请到网页端操作：$info',
              raw: json,
            );
          case '152':
            return LoginResult(
              success: false,
              message: '账号需要修改密码，请到网页端操作：$info',
              raw: json,
            );
          default:
            return LoginResult(success: false, message: info, raw: json);
        }
      }
      return LoginResult(success: false, message: info, raw: json);
    }
    return LoginResult(
      success: false,
      message: '未知响应：${json.toString()}',
      raw: json,
    );
  }

  /// 提交换绑确认（与门户页一致的：POST 到 resultData，body 为空）。
  Future<void> _confirmRebind(String url, String userAgent) async {
    if (url.isEmpty) {
      throw const FormatException('换绑地址为空');
    }
    await _postText(
      _abs(url),
      userAgent,
      body: '',
      contentType: 'application/x-www-form-urlencoded; charset=UTF-8',
    );
  }

  /// 复核设备是否真实上线：请求 logout 页。
  /// 实测：logout 页带 si 隐藏域即在线；带密码框即离线。
  Future<_OnlineVerify> _verifyOnline(String userAgent) async {
    // 换绑/正常认证后门户异步放行（约 2~5 秒），轮询等待上线。
    for (var i = 0; i < 6; i++) {
      try {
        final html = await _getText('$baseUrl$kLogoutPath', userAgent);
        if (_hasPasswordInput(html)) return _OnlineVerify.offline;
        if (_hasSiInput(html)) return _OnlineVerify.online;
      } catch (_) {
        // 单次失败继续轮询
      }
      if (i < 5) await _sleep(verifyInterval);
    }
    return _OnlineVerify.unknown;
  }

  /// 当前设备是否已有在线会话（门户只在下发 si 时表示在线）。
  Future<bool> _hasActiveSession(String userAgent) async {
    try {
      final html = await _getText('$baseUrl$kLogoutPath', userAgent);
      return _hasSiInput(html);
    } catch (_) {
      return false;
    }
  }

  bool _hasSiInput(String html) => RegExp(
        r'name\s*=\s*["\x27]?si\s*["\x27>\s]',
        caseSensitive: false,
      ).hasMatch(html);

  /// 认证成功后查询在线时长（HH:MM:SS）；离线或解析失败返回 null。
  Future<String?> _fetchOnlineDuration(String userAgent) async {
    try {
      final html = await _getText('$baseUrl$kLogoutPath', userAgent);
      if (_hasPasswordInput(html)) return null;
      final match =
          RegExp(r'data-timestamp=["\x27]?(\d{10})').firstMatch(html) ??
              RegExp(
                r'start\s*=\s*["\x27]?(\d{10})["\x27]?',
              ).firstMatch(html);
      if (match == null) return null;
      final start = int.tryParse(match.group(1)!);
      if (start == null) return null;
      final elapsed = DateTime.now().difference(
        DateTime.fromMillisecondsSinceEpoch(start * 1000),
      );
      if (elapsed.isNegative) return null;
      final h = elapsed.inHours.toString().padLeft(2, '0');
      final m = (elapsed.inMinutes % 60).toString().padLeft(2, '0');
      final s = (elapsed.inSeconds % 60).toString().padLeft(2, '0');
      return '$h:$m:$s';
    } catch (_) {
      return null;
    }
  }

  /// 拉取登录页 HTML。
  ///
  /// 门户对移动端 UA 返回的首页不含登录表单（页面 JS 会跳转到
  /// `?is_mobile=1&pagetype=login&logintype=1` 才渲染表单），
  /// 这里按浏览器最终行为依次尝试，只认带密码框的登录表单页；
  /// 连接失败时再带通用 wlan 参数重试一次。
  Future<String> fetchLoginPage(String userAgent) async {
    final urls = <String>[
      '$baseUrl$kLoginPath',
      '$baseUrl$kLoginPath?is_mobile=1&pagetype=login&logintype=1',
      '$baseUrl$kLoginPath?wlanuserip=10.0.0.1&wlanacname=GiWiFi',
    ];
    Object? lastError;
    String? firstPage;
    for (final url in urls) {
      try {
        final html = await _getText(url, userAgent);
        firstPage ??= html;
        if (_hasPasswordInput(html)) return html;
      } on AuthCancelledException {
        rethrow;
      } catch (e) {
        lastError = e;
      }
    }
    if (firstPage != null) return firstPage;
    if (lastError != null) throw lastError;
    throw const SocketException('无法连接认证服务器');
  }

  /// 当前设备在线状态。
  /// 登录页在 PC 端无论在线与否都渲染表单，不能作为依据；
  /// 以 logout 页是否下发 si 为准确信号。
  Future<OnlineStatus> checkOnline(String userAgent) async {
    try {
      final html = await _getText('$baseUrl$kLogoutPath', userAgent);
      if (_hasSiInput(html)) return OnlineStatus.online;
      if (_hasPasswordInput(html)) return OnlineStatus.offline;
      return OnlineStatus.unknown;
    } catch (_) {
      return OnlineStatus.unknown;
    }
  }

  /// 注销当前在线设备（取 logout 页的 si 后 POST logoutAction）。
  /// 返回 true 表示门户确认“下线成功”（status=1）。
  Future<bool> logout(String userAgent) async {
    try {
      final html = await _getText('$baseUrl$kLogoutPath', userAgent);
      final hidden = parseHiddenInputs(html);
      final si = hidden['si'] ?? '';
      if (si.isEmpty) return false;
      final body = await _postText(
        '$baseUrl$kLogoutActionPath',
        userAgent,
        body: 'si=${Uri.encodeComponent(si)}',
      );
      final json = jsonDecode(body) as Map<String, dynamic>;
      return json['status'] == 1;
    } catch (_) {
      return false;
    }
  }

  // ================= HTTP 基础（会话复用 + 跟随重定向） =================

  Future<String> _getText(
    String url,
    String userAgent, {
    int maxRedirects = 5,
  }) async {
    var current = url;
    for (var hop = 0; hop <= maxRedirects; hop++) {
      _checkCancelled();
      final client = _client;
      _activeClient = client;
      final req = await client.getUrl(Uri.parse(current)).timeout(timeout);
      req.headers.set(HttpHeaders.userAgentHeader, userAgent);
      req.headers.set(
        HttpHeaders.acceptHeader,
        'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
      );
      final resp = await req.close().timeout(timeout);
      _checkCancelled();
      final location = resp.headers.value(HttpHeaders.locationHeader);
      if (resp.isRedirect && location != null) {
        await resp.drain<void>();
        current = Uri.parse(current).resolve(location).toString();
        continue;
      }
      if (resp.statusCode >= 400) {
        await resp.drain<void>();
        throw HttpException('HTTP ${resp.statusCode}');
      }
      final bytes = await resp
          .fold<List<int>>(<int>[], (all, chunk) => all..addAll(chunk));
      _checkCancelled();
      return utf8.decode(bytes);
    }
    throw const HttpException('重定向次数过多');
  }

  Future<String> _postText(
    String url,
    String userAgent, {
    required String body,
    String contentType = 'application/x-www-form-urlencoded; charset=UTF-8',
    int maxRedirects = 5,
  }) async {
    var current = url;
    var payload = body;
    var useGet = false;
    for (var hop = 0; hop <= maxRedirects; hop++) {
      _checkCancelled();
      final client = _client;
      _activeClient = client;
      final uri = Uri.parse(current);
      final req = await (useGet ? client.getUrl(uri) : client.postUrl(uri))
          .timeout(timeout);
      req.headers.set(HttpHeaders.userAgentHeader, userAgent);
      req.headers.set('X-Requested-With', 'XMLHttpRequest');
      req.headers.set(
        HttpHeaders.acceptHeader,
        'application/json, text/javascript, */*; q=0.01',
      );
      if (!useGet) {
        req.headers.contentType = ContentType.parse(contentType);
        req.write(payload);
      }
      final resp = await req.close().timeout(timeout);
      _checkCancelled();
      final location = resp.headers.value(HttpHeaders.locationHeader);
      if (resp.isRedirect && location != null) {
        await resp.drain<void>();
        current = uri.resolve(location).toString();
        // 浏览器语义：POST 收到 301/302/303 后改为 GET
        if (resp.statusCode == 301 ||
            resp.statusCode == 302 ||
            resp.statusCode == 303) {
          useGet = true;
          payload = '';
        }
        continue;
      }
      final text = await utf8.decodeStream(resp);
      _checkCancelled();
      return text;
    }
    throw const HttpException('重定向次数过多');
  }

  /// 可被 cancel() 打断的等待。
  Future<void> _sleep(Duration duration) async {
    final end = DateTime.now().add(duration);
    while (DateTime.now().isBefore(end)) {
      _checkCancelled();
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
  }

  bool _hasPasswordInput(String html) => RegExp(
        r'type\s*=\s*["\x27]?password',
        caseSensitive: false,
      ).hasMatch(html);

}

/// 在线复核结果（仅本文件内部使用）。
enum _OnlineVerify { online, offline, unknown }
