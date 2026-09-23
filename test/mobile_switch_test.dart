import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:giwifi_ua_switcher/services/auth_service.dart';

String _formPage() => '''
<html><body>
<form id="loginForm">
<input type="hidden" name="sign" value="sig123">
<input type="hidden" name="sta_ip" value="10.0.0.1">
<input type="hidden" name="iv" value="0123456789abcdef">
<input type="hidden" name="login_type" value="1">
<input type="password" name="user_password">
</form>
</body></html>
''';

void main() {
  test('移动端 UA：首页无表单时自动降级到 pagetype=login 再认证', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final base = 'http://127.0.0.1:${server.port}';
    var sawMobileForm = false;
    var loginPosts = 0;
    var authenticated = false;

    server.listen((req) async {
      final path = req.uri.path;
      final query = req.uri.query;
      try {
        if (path == '/gportal/web/login') {
          if (query.contains('pagetype=login')) {
            sawMobileForm = true;
            req.response.headers.contentType = ContentType.html;
            req.response.write(_formPage());
          } else {
            req.response.headers.contentType = ContentType.html;
            req.response.write(
              '<html><head><title>欢迎使用GiWiFi</title></head>'
              '<body><script>function reloadMobile(){}</script>'
              '<a href="/gportal/web/logout">logout</a>'
              '<div id="online_duration">online_duration</div>'
              '<div class="web-login">网页登录</div></body></html>',
            );
          }
        } else if (path == '/gportal/Web/loginAction') {
          loginPosts++;
          authenticated = true;
          req.response.write(jsonEncode(<String, dynamic>{
            'status': 1,
            'info': '认证成功',
            'data': <String, dynamic>{},
          }));
        } else if (path == '/gportal/web/logout') {
          final start = DateTime.now().millisecondsSinceEpoch ~/ 1000;
          if (authenticated) {
            req.response.write(
              '<html><input type="hidden" name="si" value="sess1">'
              'var start = "$start"; online_duration</html>',
            );
          } else {
            req.response.write(
              '<html>var start = "$start"; online_duration</html>',
            );
          }
        } else {
          req.response.statusCode = 404;
        }
        await req.response.close();
      } catch (_) {
        await req.response.close();
      }
    });

    final auth = AuthService(baseUrl: base);
    final result = await auth.login(
      username: 'test2024',
      password: 'TestPass123@',
      userAgent:
          'Mozilla/5.0 (Linux; Android 14; 24031PN0DC) AppleWebKit/537.36 '
          '(KHTML, like Gecko) Chrome/126.0.0.0 Mobile Safari/537.36',
    );
    await server.close(force: true);

    expect(result.success, isTrue);
    expect(result.message, contains('认证成功'));
    expect(sawMobileForm, isTrue);
    expect(loginPosts, 1);
  });

  test('已在线时自动注销再切换设备认证', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final base = 'http://127.0.0.1:${server.port}';
    var logoutPosts = 0;
    var loginPosts = 0;
    var online = true;

    server.listen((req) async {
      final path = req.uri.path;
      final query = req.uri.query;
      try {
        if (path == '/gportal/web/login' && query.isEmpty) {
          req.response.headers.contentType = ContentType.html;
          if (online) {
            // 在线：登录页无表单，含“注销”链接
            req.response.write(
              '<html><body><a href="/gportal/web/logout">注销</a></body></html>',
            );
          } else {
            req.response.write(_formPage());
          }
        } else if (path == '/gportal/web/login') {
          req.response.headers.contentType = ContentType.html;
          req.response.write(_formPage());
        } else if (path == '/gportal/web/logout') {
          final start = DateTime.now().millisecondsSinceEpoch ~/ 1000;
          if (online) {
            req.response.write(
              '<html><input type="hidden" name="si" value="abc123">'
              '<div id="online_duration" data-timestamp="$start">'
              'online_duration</div></html>',
            );
          } else {
            req.response.write(_formPage());
          }
        } else if (path == '/gportal/Web/logoutAction') {
          logoutPosts++;
          online = false;
          req.response.write(jsonEncode(<String, dynamic>{'status': 1}));
        } else if (path == '/gportal/Web/loginAction') {
          loginPosts++;
          online = true;
          req.response.write(jsonEncode(<String, dynamic>{
            'status': 1,
            'info': '认证成功',
            'data': <String, dynamic>{},
          }));
        } else {
          req.response.statusCode = 404;
        }
        await req.response.close();
      } catch (_) {
        await req.response.close();
      }
    });

    final auth = AuthService(
      baseUrl: base,
      portalCooldown: const Duration(milliseconds: 300),
    );
    final result = await auth.login(
      username: 'test2024',
      password: 'TestPass123@',
      userAgent: 'TestUA',
      onSwitchConfirm: () async => true,
    );
    await server.close(force: true);

    expect(result.success, isTrue);
    expect(logoutPosts, 1);
    expect(loginPosts, 1);
  });

  test('已在线但用户取消切换：不注销且不算认证成功', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final base = 'http://127.0.0.1:${server.port}';
    var logoutPosts = 0;

    server.listen((req) async {
      final path = req.uri.path;
      try {
        if (path == '/gportal/web/login') {
          req.response.headers.contentType = ContentType.html;
          req.response.write(
            '<html><body><a href="/gportal/web/logout">注销</a></body></html>',
          );
        } else if (path == '/gportal/Web/logoutAction') {
          logoutPosts++;
          req.response.write(jsonEncode(<String, dynamic>{'status': 1}));
        } else if (path == '/gportal/web/logout') {
          // 已在线：logout 页带 si（真实门户的可靠在线信号）
          req.response.headers.contentType = ContentType.html;
          req.response.write(
            '<html><input type="hidden" name="si" value="abc123"></html>',
          );
        } else {
          req.response.statusCode = 404;
        }
        await req.response.close();
      } catch (_) {
        await req.response.close();
      }
    });

    final auth = AuthService(baseUrl: base);
    final result = await auth.login(
      username: 'test2024',
      password: 'TestPass123@',
      userAgent: 'TestUA',
      onSwitchConfirm: () async => false,
    );
    await server.close(force: true);

    expect(result.success, isFalse);
    expect(result.message, contains('已取消切换'));
    expect(logoutPosts, 0);
  });

  test('服务器返回 status=1 但设备未上线：不算认证成功', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final base = 'http://127.0.0.1:${server.port}';

    server.listen((req) async {
      final path = req.uri.path;
      try {
        if (path == '/gportal/web/login') {
          req.response.headers.contentType = ContentType.html;
          req.response.write(_formPage());
        } else if (path == '/gportal/Web/loginAction') {
          // 模拟异常：status=1 但实际未放行
          req.response.write(jsonEncode(<String, dynamic>{
            'status': 1,
            'info': '认证成功',
            'data': <String, dynamic>{},
          }));
        } else if (path == '/gportal/web/logout') {
          // 复核时仍是登录表单 → 判定未上线
          req.response.headers.contentType = ContentType.html;
          req.response.write(_formPage());
        } else {
          req.response.statusCode = 404;
        }
        await req.response.close();
      } catch (_) {
        await req.response.close();
      }
    });

    final auth = AuthService(baseUrl: base);
    final result = await auth.login(
      username: 'test2024',
      password: 'WrongPass123',
      userAgent: 'TestUA',
    );
    await server.close(force: true);

    expect(result.success, isFalse);
    expect(result.message, contains('未检测到在线'));
  });

  test('PC 端已在线但登录页仍带表单：错误密码不能认证成功', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final base = 'http://127.0.0.1:${server.port}';
    var loginPosts = 0;

    server.listen((req) async {
      final path = req.uri.path;
      try {
        if (path == '/gportal/web/login') {
          // 真实门户：PC 端在线时登录页依然渲染表单
          req.response.headers.contentType = ContentType.html;
          req.response.write(_formPage());
        } else if (path == '/gportal/web/logout') {
          req.response.headers.contentType = ContentType.html;
          req.response.write(
            '<html><input type="hidden" name="si" value="abc123">'
            '<div id="online_duration"></div></html>',
          );
        } else if (path == '/gportal/Web/loginAction') {
          loginPosts++;
          req.response.write(jsonEncode(<String, dynamic>{
            'status': 1,
            'info': '认证中',
            'data': <String, dynamic>{},
          }));
        } else {
          req.response.statusCode = 404;
        }
        await req.response.close();
      } catch (_) {
        await req.response.close();
      }
    });

    final auth = AuthService(baseUrl: base);
    final result = await auth.login(
      username: 'test2024',
      password: 'WrongPass123',
      userAgent: 'TestUA',
      onSwitchConfirm: () async => false,
    );
    await server.close(force: true);

    expect(result.success, isFalse);
    expect(result.message, contains('已在线'));
    expect(loginPosts, 0);
  });

  test('status=1 后设备延迟上线：轮询到 si 才算认证成功', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final base = 'http://127.0.0.1:${server.port}';
    var loginPosts = 0;
    var logoutGets = 0;

    server.listen((req) async {
      final path = req.uri.path;
      try {
        if (path == '/gportal/web/login') {
          req.response.headers.contentType = ContentType.html;
          req.response.write(_formPage());
        } else if (path == '/gportal/Web/loginAction') {
          loginPosts++;
          req.response.write(jsonEncode(<String, dynamic>{
            'status': 1,
            'info': '认证中，请勿关闭当前页面！',
            'data': <String, dynamic>{},
          }));
        } else if (path == '/gportal/web/logout') {
          logoutGets++;
          final start = DateTime.now().millisecondsSinceEpoch ~/ 1000;
          if (logoutGets >= 3) {
            // 门户异步放行：前两次还没有 si，第三次才上线
            req.response.write(
              '<html><input type="hidden" name="si" value="sess1">'
              'var start = "$start"; online_duration</html>',
            );
          } else {
            req.response.write(
              '<html>认证中，请勿关闭当前页面！</html>',
            );
          }
        } else {
          req.response.statusCode = 404;
        }
        await req.response.close();
      } catch (_) {
        await req.response.close();
      }
    });

    final auth = AuthService(
      baseUrl: base,
      verifyInterval: const Duration(milliseconds: 50),
    );
    final result = await auth.login(
      username: 'test2024',
      password: 'TestPass123@',
      userAgent: 'TestUA',
    );
    await server.close(force: true);

    expect(result.success, isTrue);
    expect(result.message, contains('认证成功'));
    expect(result.onlineDuration, isNotNull);
    expect(loginPosts, 1);
    expect(logoutGets, greaterThanOrEqualTo(3));
  });
}
