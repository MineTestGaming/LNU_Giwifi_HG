import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:giwifi_ua_switcher/services/portal_cookie_store.dart';

import 'support/memory_secret_store.dart';

void main() {
  test('restored cookies obey origin, path, secure flag and targeted deletion',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final otherServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    addTearDown(() => otherServer.close(force: true));
    void serve(HttpRequest request) {
      if (request.uri.path == '/only/issue') {
        request.response.headers.add('set-cookie', 'same=root; Path=/');
        request.response.headers
            .add('set-cookie', 'same=narrow; Path=/gportal');
        request.response.headers
            .add('set-cookie', 'secured=secret; Secure; Path=/');
        request.response.headers
            .add('set-cookie', 'expired=gone; Max-Age=0; Path=/');
        request.response.headers.add('set-cookie', 'default=local');
      } else if (request.uri.path == '/gportal/delete') {
        request.response.headers
            .add('set-cookie', 'same=; Max-Age=0; Path=/gportal');
      }
      request.response.write(jsonEncode([
        for (final cookie in request.cookies) '${cookie.name}=${cookie.value}',
      ]));
      request.response.close();
    }

    server.listen(serve);
    otherServer.listen(serve);
    final secrets = MemorySecretStore();
    final base = 'http://127.0.0.1:${server.port}';
    PortalCookieStore createStore() => PortalCookieStore(
          baseUrl: base,
          userAgent: 'phone',
          adapterIdentity: '',
          secrets: secrets,
        );
    Future<List<dynamic>> get(PortalCookieStore jar, String url) async {
      await jar.load();
      final client = HttpClient();
      try {
        final uri = Uri.parse(url);
        final request = await client.getUrl(uri);
        jar.apply(request, uri);
        final response = await request.close();
        await jar.capture(response, uri);
        return jsonDecode(await utf8.decodeStream(response)) as List<dynamic>;
      } finally {
        client.close(force: true);
      }
    }

    await get(createStore(), '$base/only/issue');
    final restored = createStore();
    expect(await get(restored, '$base/gportal/check'),
        ['same=narrow', 'same=root']);
    expect(await get(restored, '$base/only/check'),
        ['default=local', 'same=root']);
    expect(
        await get(
            restored, 'http://127.0.0.1:${otherServer.port}/gportal/check'),
        isEmpty);
    await get(restored, '$base/gportal/delete');
    expect(await get(createStore(), '$base/gportal/check'), ['same=root']);
  });
}
