import 'dart:io';
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:giwifi_ua_switcher/services/auth_service.dart';
import 'package:giwifi_ua_switcher/services/network_adapter_service.dart';
import 'package:giwifi_ua_switcher/services/settings_service.dart';

void main() {
  const wifi = NetworkAdapter(name: 'Wi-Fi', address: '192.0.2.1');

  test('刷新只更新同名网卡，保留已拔除网卡的选择', () {
    const service = NetworkAdapterService();
    const newWifi = NetworkAdapter(name: 'Wi-Fi', address: '192.0.2.2');
    const ethernet = NetworkAdapter(name: 'Ethernet', address: '192.0.2.3');
    expect(service.refreshSelection(wifi, [ethernet]), wifi);
    expect(service.refreshSelection(wifi, [ethernet, newWifi]), newWifi);
    expect(service.refreshSelection(null, [ethernet]), isNull);
  });

  test('同一 IPv4 属于多个网卡时拒绝模糊绑定', () async {
    final service = NetworkAdapterService(
        listAdapters: () async => [
              wifi,
              const NetworkAdapter(name: 'Ethernet', address: '192.0.2.1'),
            ]);
    await expectLater(service.validate(wifi),
        throwsA(isA<NetworkAdapterUnavailableException>()));
  });

  test('登录、注销、检测及跳转使用所选源 IPv4，断卡后不再发请求', () async {
    final available = await const NetworkAdapterService().listAvailable();
    if (available.isEmpty) {
      markTestSkipped('本机没有可用于源地址绑定测试的 IPv4 网卡');
      return;
    }
    final adapter = available.first;
    var connected = true;
    final adapters = NetworkAdapterService(
        listAdapters: () async => connected ? [adapter] : []);
    final server = await HttpServer.bind(adapter.address, 0);
    addTearDown(() => server.close(force: true));
    final sources = <String>[];
    final paths = <String>[];
    var online = false;
    server.listen((request) async {
      sources.add(request.connectionInfo!.remoteAddress.address);
      paths.add('${request.method} ${request.uri.path}');
      if (request.uri.path == '/gportal/web/login') {
        request.response.statusCode = 302;
        request.response.headers.set('location', '/form');
      } else if (request.uri.path == '/form') {
        request.response.write(
            '<input type="hidden" name="sign" value="test"><input type="hidden" name="iv" value="0123456789abcdef"><input type="password">');
      } else if (request.uri.path == '/gportal/Web/loginAction') {
        await request.drain<void>();
        online = true;
        request.response.write('{"status":1,"info":"ok"}');
      } else if (request.uri.path == '/gportal/Web/logoutAction') {
        await request.drain<void>();
        online = false;
        request.response.write('{"status":1}');
      } else {
        request.response.write(online
            ? '<input type="hidden" name="si" value="test-session">'
            : '<input type="password">');
      }
      await request.response.close();
    });
    final auth = AuthService(
      baseUrl: 'http://${adapter.address}:${server.port}',
      networkAdapter: adapter,
      networkAdapters: adapters,
      verifyInterval: Duration.zero,
    );
    addTearDown(auth.dispose);
    final login =
        await auth.login(username: 'test', password: 'test', userAgent: 'test');
    expect(login.success, isTrue, reason: login.message);
    expect(await auth.checkOnline('test'), OnlineStatus.online);
    expect(await auth.logout('test'), isTrue);
    expect(
        paths,
        containsAll([
          'GET /form',
          'POST /gportal/Web/loginAction',
          'POST /gportal/Web/logoutAction'
        ]));
    expect(sources, everyElement(adapter.address));
    final count = paths.length;
    connected = false;
    await expectLater(auth.checkOnline('test'),
        throwsA(isA<NetworkAdapterUnavailableException>()));
    expect(paths.length, count);
  });

  test('停止正在等待门户响应的绑定请求', () async {
    const adapter = NetworkAdapter(name: 'test-loopback', address: '127.0.0.1');
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final received = Completer<void>();
    server.listen((request) {
      if (!received.isCompleted) received.complete();
    });
    final auth = AuthService(
      baseUrl: 'http://127.0.0.1:${server.port}',
      networkAdapter: adapter,
      networkAdapters:
          NetworkAdapterService(listAdapters: () async => [adapter]),
    );
    addTearDown(auth.dispose);
    final checking = auth.checkOnline('test');
    final expectation =
        expectLater(checking, throwsA(isA<AuthCancelledException>()));
    await received.future.timeout(const Duration(seconds: 5));
    auth.cancel();
    await expectation;
  });

  test('指定网卡失效时不回退到另一张网卡', () async {
    final adapters = NetworkAdapterService(listAdapters: () async => []);
    final auth = AuthService(networkAdapter: wifi, networkAdapters: adapters);
    addTearDown(auth.dispose);
    await expectLater(auth.checkOnline('test'),
        throwsA(isA<NetworkAdapterUnavailableException>()));
  });

  test('网卡选择与记住密码独立保存，旧配置默认不选网卡', () async {
    final dir =
        await Directory.systemTemp.createTemp('giwifi-adapter-settings');
    SettingsService.configDirOverride = dir.path;
    addTearDown(() async {
      SettingsService.configDirOverride = null;
      await dir.delete(recursive: true);
    });
    expect(await SettingsService.loadNetworkAdapter(), isNull);
    await SettingsService.saveNetworkAdapter(wifi);
    await SettingsService.saveLoginInfo(
      username: 'test',
      password: 'test',
      serverUrl: 'http://127.0.0.1',
      profileId: 'pc',
      customUa: '',
      remember: false,
    );
    expect(await SettingsService.loadNetworkAdapter(), wifi);
    expect(
        (await SettingsService.loadLoginInfo())[SettingsService.kPassword], '');
    await SettingsService.saveNetworkAdapter(null);
    expect(await SettingsService.loadNetworkAdapter(), isNull);
  });
}
