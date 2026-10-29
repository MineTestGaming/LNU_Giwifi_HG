import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:giwifi_ua_switcher/services/auth_service.dart';
import 'package:giwifi_ua_switcher/services/secret_store.dart';
import 'package:giwifi_ua_switcher/services/settings_service.dart';

// Native Linux plugin probe. Build this as a Flutter desktop entry point and
// run write/read in separate processes. The backend remains the real system
// keyring; namespaced keys and a dedicated config directory isolate test data.
const _username = 'wsl-probe-student';
const _password = 'WSL-NATIVE-PASSWORD-PROBE-6c419d';
const _cookie = 'WSL-NATIVE-COOKIE-PROBE-b93e27';
const _ua = 'giwifi-wsl-storage-probe';

class _ProbeSecrets implements SecretStore {
  _ProbeSecrets(this.namespace);
  final String namespace;
  final SecretStore backend = const PlatformSecretStore();

  String scoped(String key) => 'giwifi_probe_${namespace}_$key';

  @override
  Future<String?> read(String key) => backend.read(scoped(key));

  @override
  Future<void> write(String key, String value) =>
      backend.write(scoped(key), value);

  @override
  Future<void> delete(String key) => backend.delete(scoped(key));
}

void _require(bool condition, String message) {
  if (!condition) throw StateError(message);
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const SizedBox.shrink());
  try {
    _require(Platform.isLinux, 'This probe requires Linux');
    final path = Platform.environment['GIWIFI_STORAGE_PROBE_ROOT'];
    final phase = Platform.environment['GIWIFI_STORAGE_PROBE_PHASE'];
    _require(path != null && path.startsWith('/'),
        'An absolute probe root is required');
    final root = Directory(path!);
    _require(await File('${root.path}/.giwifi-storage-probe').exists(),
        'Probe marker missing; refusing to use an arbitrary configuration');
    _require(
        phase == 'write' || phase == 'read', 'Phase must be write or read');
    final secrets =
        _ProbeSecrets(root.uri.pathSegments.where((s) => s.isNotEmpty).last);
    SecretStores.override = secrets;
    SettingsService.configDirOverride = '${root.path}/config';
    await Directory(SettingsService.configDirOverride!).create(recursive: true);
    final config = File('${SettingsService.configDirOverride}/settings.json');
    final state = File('${root.path}/http-port');
    if (phase == 'write') {
      await config.writeAsString(jsonEncode({
        'username': _username,
        'password': _password,
        'remember': true,
      }));
    }
    final loaded = await SettingsService.loadLoginInfo();
    _require(loaded[SettingsService.kPassword] == _password,
        'Native password migration or restoration failed');
    final configText = await config.readAsString();
    _require(
        !configText.contains(_password) &&
            !(jsonDecode(configText) as Map).containsKey('password'),
        'Plaintext password remains in settings.json');
    stdout.writeln(
        'PASS: native password ${phase == 'write' ? 'migration' : 'restoration'}');

    final port = phase == 'write' ? 0 : int.parse(await state.readAsString());
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    var loggedOut = false;
    server.listen((request) async {
      if (request.method == 'POST') {
        await request.drain<void>();
        loggedOut = true;
        request.response.write('{"status":1}');
      } else if (phase == 'write') {
        request.response.cookies
            .add(Cookie('portal_probe', _cookie)..path = '/');
        request.response.write('<input type="hidden" name="si" value="probe">');
      } else {
        final hasCookie = request.cookies
            .any((c) => c.name == 'portal_probe' && c.value == _cookie);
        request.response.write(!loggedOut && hasCookie
            ? '<input type="hidden" name="si" value="probe">'
            : '<input type="password">');
      }
      await request.response.close();
    });
    final auth = AuthService(baseUrl: 'http://127.0.0.1:${server.port}');
    try {
      _require(await auth.checkOnline(_ua) == OnlineStatus.online,
          'Native Cookie persistence or restoration failed');
      if (phase == 'write') {
        await state.writeAsString('${server.port}');
        stdout.writeln('PASS: native Cookie persistence');
      } else {
        stdout.writeln('PASS: native Cookie restoration across processes');
        _require(await auth.logout(_ua), 'Logout failed');
        _require(await auth.checkOnline(_ua) == OnlineStatus.offline,
            'Logout did not clear the persisted Cookie');
        await SettingsService.saveLoginInfo(
          username: _username,
          password: _password,
          serverUrl: 'http://127.0.0.1:${server.port}',
          profileId: 'pc',
          customUa: '',
          remember: false,
        );
        _require(await secrets.read('giwifi_password_v1') == null,
            'Disabling remember did not delete the native saved password');
        stdout.writeln('PASS: native password and Cookie deletion');
      }
    } finally {
      auth.dispose();
      await server.close(force: true);
    }
    stdout.writeln('PROBE_${phase!.toUpperCase()}_PASS');
    exit(0);
  } catch (error, stack) {
    stderr.writeln('NATIVE_STORAGE_PROBE_FAILED: $error\n$stack');
    exit(1);
  }
}
