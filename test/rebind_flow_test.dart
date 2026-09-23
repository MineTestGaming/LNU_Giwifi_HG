import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:giwifi_ua_switcher/services/auth_service.dart';

/// 本地模拟 GiWiFi 门户，验证“换绑确认 -> 冷却 -> 二次认证”完整链路：
/// 第一次 loginAction 返回 resultCode=124，确认换绑并 POST resultData 后，
/// 等待冷却再次认证返回 status=1。
void main() {
  test('换绑流程：124 确认 -> 提交换绑 -> 冷却 -> 二次认证成功', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final base = 'http://127.0.0.1:${server.port}';
    var loginAttempts = 0;
    var rebindPosts = 0;
    var online = false;

    server.listen((req) async {
      final path = req.uri.path;
      try {
        if (path == '/gportal/web/login') {
          req.response.headers.contentType = ContentType.html;
          req.response.write('''
<html><body>
<form id="loginForm">
<input type="hidden" name="sign" value="sig123">
<input type="hidden" name="sta_vlan" value="">
<input type="hidden" name="sta_ip" value="10.0.0.1">
<input type="hidden" name="iv" value="0123456789abcdef">
<input type="hidden" name="login_type" value="1">
<input type="password" name="user_password">
</form>
</body></html>
''');
        } else if (path == '/gportal/Web/loginAction') {
          loginAttempts++;
          if (loginAttempts == 1) {
            req.response.write(jsonEncode(<String, dynamic>{
              'status': 0,
              'info': '系统检测到您当前可更换上网设备次数仅剩19次,是否重新绑定至当前设备？请慎重点击确认！',
              'data': <String, dynamic>{
                'resultCode': '124',
                'resultData': '/gportal/Web/rebindAction',
              },
            }));
          } else {
            online = true;
            req.response.write(jsonEncode(<String, dynamic>{
              'status': 1,
              'info': '认证成功',
              'data': <String, dynamic>{},
            }));
          }
        } else if (path == '/gportal/Web/rebindAction') {
          rebindPosts++;
          req.response.write('ok');
        } else if (path == '/gportal/web/logout') {
          final start = DateTime.now().millisecondsSinceEpoch ~/ 1000;
          if (online) {
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

    final auth = AuthService(
      baseUrl: base,
      rebindCooldown: const Duration(milliseconds: 300),
    );
    String? confirmInfo;
    final result = await auth.login(
      username: 'test2024',
      password: 'TestPass123@',
      userAgent: 'TestUA',
      onRebindConfirm: (info) async {
        confirmInfo = info;
        return true;
      },
    );
    await server.close(force: true);

    expect(result.success, isTrue);
    expect(result.message, contains('认证成功'));
    expect(loginAttempts, 2);
    expect(rebindPosts, 1);
    expect(confirmInfo, contains('更换上网设备'));
  });

  test('换绑流程：用户取消确认时不提交换绑', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final base = 'http://127.0.0.1:${server.port}';
    var rebindPosts = 0;

    server.listen((req) async {
      final path = req.uri.path;
      try {
        if (path == '/gportal/web/login') {
          req.response.headers.contentType = ContentType.html;
          req.response.write('''
<html><body>
<form id="loginForm">
<input type="hidden" name="sign" value="sig123">
<input type="hidden" name="iv" value="0123456789abcdef">
<input type="hidden" name="login_type" value="1">
<input type="password" name="user_password">
</form>
</body></html>
''');
        } else if (path == '/gportal/Web/loginAction') {
          req.response.write(jsonEncode(<String, dynamic>{
            'status': 0,
            'info': '系统检测到您当前可更换上网设备次数仅剩19次,是否重新绑定至当前设备？',
            'data': <String, dynamic>{
              'resultCode': '124',
              'resultData': '/gportal/Web/rebindAction',
            },
          }));
        } else if (path == '/gportal/Web/rebindAction') {
          rebindPosts++;
          req.response.write('ok');
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
      onRebindConfirm: (info) async => false,
    );
    await server.close(force: true);

    expect(result.success, isFalse);
    expect(result.message, '已取消换绑，认证未完成');
    expect(rebindPosts, 0);
  });
}
