// 独立自检脚本：不依赖任何第三方包，可用 SDK 自带的 dart 直接运行。
// 用法: dart run tool/selfcheck.dart
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../lib/services/settings_service.dart';
import '../lib/utils/aes_crypto.dart';
import '../lib/utils/form_builder.dart';
import '../lib/utils/html_parser.dart';

int _failures = 0;

void _check(bool ok, String name) {
  if (ok) {
    stdout.writeln('[PASS] $name');
  } else {
    _failures++;
    stdout.writeln('[FAIL] $name');
  }
}

void _eq(Object? actual, Object? expected, String name) {
  final ok = actual == expected;
  if (!ok) {
    stdout.writeln('  实际: $actual');
    stdout.writeln('  期望: $expected');
  }
  _check(ok, name);
}

Uint8List _fromHex(String hex) {
  final bytes = <int>[];
  for (var i = 0; i < hex.length; i += 2) {
    bytes.add(int.parse(hex.substring(i, i + 2), radix: 16));
  }
  return Uint8List.fromList(bytes);
}

Future<void> _testStorage() async {
  final tmp = Directory.systemTemp.createTempSync('giwifi_selfcheck');
  SettingsService.configDirOverride = tmp.path;
  try {
    await SettingsService.saveLoginInfo(
      username: 'u1',
      password: 'p1',
      serverUrl: 'http://x',
      profileId: 'ipad',
      customUa: 'ua1',
      remember: true,
    );
    final s = await SettingsService.loadLoginInfo();
    _eq(s[SettingsService.kUsername], 'u1', '存储: 保存/读取用户名');
    _eq(s[SettingsService.kProfileId], 'ipad', '存储: 保存/读取设备类型');

    await SettingsService.appendLog(
      LogEntry(
        time: DateTime(2026, 8, 13, 12),
        device: '电脑',
        success: true,
        message: 'ok',
      ),
    );
    final log = await SettingsService.loadLog();
    _eq(log.length, 1, '存储: 日志追加');
    _eq(log.first.message, 'ok', '存储: 日志内容');

    await SettingsService.clearLog();
    _eq((await SettingsService.loadLog()).length, 0, '存储: 日志清除');

    await SettingsService.saveLoginInfo(
      username: 'u2',
      password: 'p2',
      serverUrl: 'http://y',
      profileId: 'pc',
      customUa: '',
      remember: false,
    );
    final s2 = await SettingsService.loadLoginInfo();
    _eq(s2[SettingsService.kUsername], '', '存储: 取消记住后清除账号');
  } finally {
    final old = Platform.environment['APPDATA'] ?? '';
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  }
}

Future<void> main() async {
  stdout.writeln('=== GiWiFi 自检 ===');

  // 1. NIST SP 800-38A F.1.1 AES-128 官方向量（单个加密块）
  final aes = Aes128(
    _fromHex('2b7e151628aed2a6abf7158809cf4f3c'),
  );
  final nistBlock = _fromHex('6bc1bee22e409f96e93d7e117393172a');
  final nistIv = _fromHex('000102030405060708090a0b0c0d0e0f');
  for (var i = 0; i < 16; i++) {
    nistBlock[i] ^= nistIv[i];
  }
  final nistOut = base64Encode(aes.encryptBlock(nistBlock));
  _eq(
    nistOut,
    'dkmrrIEZskbO6Y6bEukZfQ==',
    'NIST SP 800-38A AES-128 加密块',
  );

  // 2. GiWiFi 密钥 + 真实 IV 的短向量（与 pycryptodome/.NET 对拍）
  const key = '1234567887654321';
  const iv = 'ffac952f576cf411';
  _eq(aesCbcZeroPadEncrypt('a', key, iv), 'baVPS61O2qhpcK0WQswfFQ==',
      '向量: "a"');
  _eq(
    aesCbcZeroPadEncrypt('ABCDEFGHIJKLMNOP', key, iv),
    'rZjqxSGRE+p9byDJRYZVCA==',
    '向量: 16 字节对齐不追加填充块',
  );
  _eq(
    aesCbcZeroPadEncrypt('ABCDEFGHIJKLMNOPQ', key, iv),
    'rZjqxSGRE+p9byDJRYZVCESUy56AKo89Ivir+2j2b7o=',
    '向量: 17 字节',
  );
  _eq(
    aesCbcZeroPadEncrypt('用户密码abc123', key, iv),
    '/KTcXIPmlWE18c8XQ2Tsp5mKixjnSh21tZ3wD73YXmo=',
    '向量: UTF-8 中文',
  );

  // 3. 完整链路：真实 sign 字段 + 表单构建 + 加密
  const sign =
      'i9VxNtOviZf0rFWc8jOjFKzszNLfF1YOgj5oVwt0i0faXMJpFTFIPtWuZKjEfHFYZLKhCwp7T5yMph6z60uVKFml//rAnpFWywtNnJGF8IoKPhwLXDoJkpv4i4RY19pNsHDtEgzkfuZ0mN8GWUcS1wwiiyO9IcoDHP7D+Rsl/8jwWA0QXd7rjt69HVVs9EpwJ1qUpJfyWKESkKscfA7+taw4ya3JKaB46nEov/keVV0zglqOLfL0WzX8KMc/TUl4wGzJtvlIG/CDUYs85SnWnQ==';
  const expectedEnc =
      'lYenTmf4ZS/lZdM04CvDfvmSSf+tIJ4AZ97AoUtb/Eve7tCVW+qP5k7eiqtWyzOOPzZduXuTby5AkPLBnZ71XiGIQJsN4hVulAU3vbv/10QfSDkxgWgrgkRks6ZelZBDPSqhtUMkBYp4Jo2Yl+nqhN0dv+puHZRMD9aOmzuS2dVvN0coUF7F2C39xYGSc8VoLXK1f8mfDL7OpdtIW110miVRKW8zIzNqv0OVFRtn2rltMHf59tnFkh18A/GfD8UeZGjUVSPkyFvwrV5lNoxn58iXeCZWxD8Pkl2dMMgvFbTwhzqJw9lU2H7baahzxSTEj3Siw4r3M/7pdfrzyfpqVX3dSulW9NLQWfTjua/zwBSdWUAaEjQg7iwJxbsweIn3KUoWKiqEecDuOsNhgFHXO2Dpu2B4vp+UgJFUl1sM+Q3/547AmAcxExiGw+WOJ5zxEXSj7NuzUTpdJekQAwSusc2eAab83mwLPzUbbVRWgYUl3qNd3XgGcWb/Fr8myiTbKtHYXdELaAP2tCnuLOWPfib40EpMjbLEbAp8VPxW8V8qUmBCLa3mlAfYIT6YeRPKtmF0cr3QkLkw6Suc85oOkVRtuXcUxCvC7NXB1r2DI6g2+TAJPqL4R4+JKdz96E1NFUNveF4Fa2AYI+wIk39ccqYEAtBVaBBDtYpc0vIO5uko9AlKyiSA2BVH3F1XM9Wasb898b5gd0aOc6qb+Jt5pGPQbr5A3oAVRrX99db5ItnUG9nnbUCQDiZV962dXcafW/OBuVPjjjn4Q9YeOV5EYA==';
  final fields = <String, String>{
    'sign': sign,
    'sta_vlan': '',
    'sta_port': '',
    'sta_ip': '10.12.224.224',
    'nas_ip': '',
    'nas_name': 'GiWiFi_lnsf',
    'last_url': '',
    'request_ip': '10.11.119.129',
    'device_mode': 'Windows NT 10.0',
    'device_type': '1',
    'device_os_type': '3',
    'is_mobile': '0',
    'iv': iv,
    'login_type': '1',
    'account_type': '2',
    'user_account': 'test2024',
    'user_password': 'TestPass123@',
  };
  final formStr = buildFormString(fields);
  _eq(formStr.length, 584, '完整链路: 表单长度');
  _check(
    formStr.contains('user_password=TestPass123%40'),
    '完整链路: 表单编码',
  );
  _eq(
    aesCbcZeroPadEncrypt(formStr, kGiWifiAesKey, iv),
    expectedEnc,
    '完整链路: 表单加密与参考实现对拍',
  );

  // 4. HTML hidden input 解析
  const html = '<input type="hidden" name="sign" value="a/b+c=d">'
      '<input type="hidden" name="sta_ip" value="10.12.224.224">'
      '<input type="text" name="user_account" value="ignored">'
      '<input type="hidden" name="iv" value="ffac952f576cf411">';
  final hidden = parseHiddenInputs(html);
  _eq(hidden['sign'], 'a/b+c=d', 'HTML: 提取 sign');
  _eq(hidden['sta_ip'], '10.12.224.224', 'HTML: 提取 sta_ip');
  _eq(hidden.containsKey('user_account'), false, 'HTML: 忽略非 hidden');
  _eq(hidden['iv'], 'ffac952f576cf411', 'HTML: 提取 iv');

  // 5. 本地存储读写
  await _testStorage();

  stdout.writeln('');
  if (_failures == 0) {
    stdout.writeln('ALL SELF-CHECKS PASSED');
    exit(0);
  } else {
    stdout.writeln('$_failures 项失败');
    exit(1);
  }
}
