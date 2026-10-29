import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:giwifi_ua_switcher/services/auth_service.dart';
import 'package:giwifi_ua_switcher/services/secret_store.dart';
import 'package:giwifi_ua_switcher/services/settings_service.dart';

class _MemorySecrets implements SecretStore {
  final values = <String, String>{};
  bool failWrite = false;
  bool ignoreWrites = false;

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    if (failWrite)
      throw const FileSystemException('secure storage unavailable');
    if (ignoreWrites) return;
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async => values.remove(key);
}

void main() {
  late Directory dir;
  late _MemorySecrets secrets;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('giwifi-secrets');
    secrets = _MemorySecrets();
    SettingsService.configDirOverride = dir.path;
    SettingsService.secretStoreOverride = secrets;
  });

  tearDown(() async {
    SettingsService.configDirOverride = null;
    SettingsService.secretStoreOverride = null;
    await dir.delete(recursive: true);
  });

  test(
      'remembered password survives restart without appearing in settings.json',
      () async {
    await SettingsService.saveLoginInfo(
      username: 'student',
      password: 'private-pass',
      serverUrl: 'http://100.100.9.2',
      profileId: 'android_phone',
      customUa: '',
      remember: true,
    );
    final file = File('${dir.path}${Platform.pathSeparator}settings.json');
    expect(await file.readAsString(), isNot(contains('private-pass')));
    expect((await SettingsService.loadLoginInfo())[SettingsService.kPassword],
        'private-pass');
  });

  test('legacy password is removed only after secure write succeeds', () async {
    final file = File('${dir.path}${Platform.pathSeparator}settings.json');
    await file.writeAsString(jsonEncode({
      'username': 'student',
      'password': 'old-pass',
      'remember': true,
    }));
    secrets.failWrite = true;
    await expectLater(
        SettingsService.loadLoginInfo(), throwsA(isA<FileSystemException>()));
    expect(await file.readAsString(), contains('old-pass'));
    secrets.failWrite = false;
    expect((await SettingsService.loadLoginInfo())[SettingsService.kPassword],
        'old-pass');
    expect(await file.readAsString(), isNot(contains('old-pass')));
  });

  test('a silently failed secure write never removes the legacy password',
      () async {
    final file = File('${dir.path}${Platform.pathSeparator}settings.json');
    await file.writeAsString(
        '{"username":"student","password":"keep-me","remember":true}');
    secrets.ignoreWrites = true;
    await expectLater(SettingsService.loadLoginInfo(), throwsStateError);
    expect(await file.readAsString(), contains('keep-me'));
  });

  test('turning off remember removes the saved password', () async {
    await SettingsService.saveLoginInfo(
      username: 'student',
      password: 'private-pass',
      serverUrl: 'http://100.100.9.2',
      profileId: 'pc',
      customUa: '',
      remember: true,
    );
    await SettingsService.saveLoginInfo(
      username: 'student',
      password: 'private-pass',
      serverUrl: 'http://100.100.9.2',
      profileId: 'pc',
      customUa: '',
      remember: false,
    );
    expect(
        (await SettingsService.loadLoginInfo())[SettingsService.kPassword], '');
    expect(secrets.values, isEmpty);
  });

  test('a different account in shared settings never receives the old password',
      () async {
    await SettingsService.saveLoginInfo(
      username: 'student',
      password: 'private-pass',
      serverUrl: 'http://100.100.9.2',
      profileId: 'pc',
      customUa: '',
      remember: true,
    );
    final file = File('${dir.path}${Platform.pathSeparator}settings.json');
    final settings =
        jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    settings['username'] = 'another-student';
    await file.writeAsString(jsonEncode(settings));
    expect(
        (await SettingsService.loadLoginInfo())[SettingsService.kPassword], '');
  });

  test('redirect response cookies are captured and restored after restart',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    var issued = false;
    server.listen((request) async {
      if (!issued) {
        issued = true;
        request.response.statusCode = HttpStatus.found;
        request.response.headers.set(HttpHeaders.locationHeader, '/final');
        request.response.cookies
            .add(Cookie('redirect_session', 'secret')..path = '/');
      } else {
        final hasCookie =
            request.cookies.any((c) => c.name == 'redirect_session');
        request.response.write(hasCookie
            ? '<input name="si" value="ok">'
            : '<input type="password">');
      }
      await request.response.close();
    });
    final base = 'http://127.0.0.1:${server.port}';
    final first = AuthService(baseUrl: base, secretStore: secrets);
    addTearDown(first.dispose);
    expect(await first.checkOnline('phone'), OnlineStatus.online);
    final second = AuthService(baseUrl: base, secretStore: secrets);
    addTearDown(second.dispose);
    expect(await second.checkOnline('phone'), OnlineStatus.online);
  });

  test('portal cookie survives service restart and stays scoped to UA',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      final hasCookie = request.cookies.any(
          (cookie) => cookie.name == 'portal' && cookie.value == 'session');
      if (hasCookie) {
        request.response.write('<input type="hidden" name="si" value="ok">');
      } else {
        request.response.cookies.add(Cookie('portal', 'session')..path = '/');
        request.response.write('<input type="password" name="password">');
      }
      await request.response.close();
    });
    final baseUrl = 'http://127.0.0.1:${server.port}';
    final first = AuthService(baseUrl: baseUrl, secretStore: secrets);
    expect(await first.checkOnline('mobile-ua'), OnlineStatus.offline);
    first.dispose();
    final second = AuthService(baseUrl: baseUrl, secretStore: secrets);
    expect(await second.checkOnline('mobile-ua'), OnlineStatus.online);
    second.dispose();
    final otherUa = AuthService(baseUrl: baseUrl, secretStore: secrets);
    expect(await otherUa.checkOnline('desktop-ua'), OnlineStatus.offline);
    otherUa.dispose();
  });

  test('successful logout clears persisted cookies before the next check',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    var loggedOut = false;
    server.listen((request) async {
      if (request.method == 'POST') {
        loggedOut = true;
        await request.drain<void>();
        request.response.write('{"status":1}');
      } else if (!loggedOut) {
        request.response.cookies
            .add(Cookie('portal', 'logout-session')..path = '/');
        request.response.write('<input type="hidden" name="si" value="ok">');
      } else {
        request.response.write(request.cookies.isEmpty
            ? '<input type="password">'
            : '<input name="si" value="stale">');
      }
      await request.response.close();
    });
    final auth = AuthService(
      baseUrl: 'http://127.0.0.1:${server.port}',
      secretStore: secrets,
    );
    addTearDown(auth.dispose);
    expect(await auth.logout('phone'), isTrue);
    expect(secrets.values, isEmpty);
    expect(await auth.checkOnline('phone'), OnlineStatus.offline);
  });
}
