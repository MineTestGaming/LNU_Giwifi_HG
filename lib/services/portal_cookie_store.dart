import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'secret_store.dart';

/// Persists only cookies issued by the configured portal origin. Values are
/// kept in the platform's encrypted secret storage, never in settings.json.
class PortalCookieStore {
  PortalCookieStore({
    required this.baseUrl,
    required this.userAgent,
    required this.adapterIdentity,
    required this.secrets,
  });

  final String baseUrl;
  final String userAgent;
  final String adapterIdentity;
  final SecretStore secrets;

  final Map<String, _SavedCookie> _cookies = {};
  bool _loaded = false;

  Uri get _portal => Uri.parse(baseUrl);
  String get _key => 'giwifi_portal_cookies_v1_${sha256.convert(utf8.encode(
        '${_portal.origin}\n$userAgent\n$adapterIdentity',
      ))}';

  bool _sameOrigin(Uri uri) => uri.origin == _portal.origin;

  Future<void> load() async {
    if (_loaded) return;
    final raw = await secrets.read(_key);
    if (raw != null) {
      try {
        final values = jsonDecode(raw) as List<dynamic>;
        for (final value in values) {
          final cookie = _SavedCookie.fromJson(value as Map<String, dynamic>);
          if (cookie.expiresAt.isAfter(DateTime.now().toUtc())) {
            _cookies[cookie.identity] = cookie;
          }
        }
      } on FormatException {
        _cookies.clear();
        await secrets.delete(_key);
      } on TypeError {
        _cookies.clear();
        await secrets.delete(_key);
      }
    }
    _loaded = true;
  }

  void apply(HttpClientRequest request, Uri uri) {
    if (!_sameOrigin(uri)) return;
    final now = DateTime.now().toUtc();
    final ordered = _cookies.values.toList()
      ..sort((a, b) => b.path.length.compareTo(a.path.length));
    for (final saved in ordered) {
      if (saved.expiresAt.isAfter(now) &&
          (!saved.secure || uri.scheme == 'https') &&
          (uri.path == saved.path ||
              uri.path.startsWith(
                  saved.path.endsWith('/') ? saved.path : '${saved.path}/'))) {
        request.cookies.add(Cookie(saved.name, saved.value));
      }
    }
  }

  Future<void> capture(HttpClientResponse response, Uri uri) async {
    if (!_sameOrigin(uri) || response.cookies.isEmpty) return;
    final now = DateTime.now().toUtc();
    for (final cookie in response.cookies) {
      final domain = cookie.domain?.replaceFirst(RegExp(r'^\.'), '');
      if (domain != null && domain.toLowerCase() != uri.host.toLowerCase()) {
        continue;
      }
      final expires = cookie.maxAge != null
          ? now.add(Duration(seconds: cookie.maxAge!))
          : cookie.expires?.toUtc() ?? now.add(const Duration(hours: 24));
      final path = cookie.path?.startsWith('/') == true
          ? cookie.path!
          : _defaultPath(uri);
      final identity = '${cookie.name}\n$path';
      if (!expires.isAfter(now)) {
        _cookies.remove(identity);
      } else {
        _cookies[identity] = _SavedCookie(
          name: cookie.name,
          value: cookie.value,
          path: path,
          secure: cookie.secure,
          expiresAt: expires,
        );
      }
    }
    await _save();
  }

  String _defaultPath(Uri uri) {
    final lastSlash = uri.path.lastIndexOf('/');
    return lastSlash <= 0 ? '/' : uri.path.substring(0, lastSlash);
  }

  Future<void> clear() async {
    _cookies.clear();
    await secrets.delete(_key);
  }

  Future<void> _save() async {
    final now = DateTime.now().toUtc();
    _cookies.removeWhere((_, cookie) => !cookie.expiresAt.isAfter(now));
    if (_cookies.isEmpty) {
      await secrets.delete(_key);
    } else {
      await secrets.write(
        _key,
        jsonEncode(_cookies.values.map((cookie) => cookie.toJson()).toList()),
      );
    }
  }
}

class _SavedCookie {
  const _SavedCookie({
    required this.name,
    required this.value,
    required this.path,
    required this.secure,
    required this.expiresAt,
  });

  final String name;
  final String value;
  final String path;
  final bool secure;
  final DateTime expiresAt;
  String get identity => '$name\n$path';

  Map<String, Object> toJson() => {
        'name': name,
        'value': value,
        'path': path,
        'secure': secure,
        'expiresAt': expiresAt.millisecondsSinceEpoch,
      };

  factory _SavedCookie.fromJson(Map<String, dynamic> json) => _SavedCookie(
        name: json['name'] as String,
        value: json['value'] as String,
        path: json['path'] as String,
        secure: json['secure'] as bool,
        expiresAt: DateTime.fromMillisecondsSinceEpoch(
          json['expiresAt'] as int,
          isUtc: true,
        ),
      );
}
