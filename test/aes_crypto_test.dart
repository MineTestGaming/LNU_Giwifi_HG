import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:giwifi_ua_switcher/utils/aes_crypto.dart';

void main() {
  const key = '1234567887654321';
  const iv = 'ffac952f576cf411';

  // 期望值由 tool/gen_test_vectors.py 生成，
  // 与 pycryptodome（已对拍过真实服务器）及 NIST SP 800-38A 验证一致。
  const vectors = <MapEntry<String, String>>[
    MapEntry('a', 'baVPS61O2qhpcK0WQswfFQ=='),
    MapEntry('ABCDEFGHIJKLMNOP', 'rZjqxSGRE+p9byDJRYZVCA=='),
    MapEntry(
      'ABCDEFGHIJKLMNOPQ',
      'rZjqxSGRE+p9byDJRYZVCESUy56AKo89Ivir+2j2b7o=',
    ),
    MapEntry('用户密码abc123', '/KTcXIPmlWE18c8XQ2Tsp5mKixjnSh21tZ3wD73YXmo='),
  ];

  test('AES-CBC + ZeroPadding 与 CryptoJS 参考实现对拍一致', () {
    for (final v in vectors) {
      expect(
        aesCbcZeroPadEncrypt(v.key, key, iv),
        v.value,
        reason: '明文: ${v.key}',
      );
    }
  });

  test('长度恰为 16 字节整数倍时不追加填充块', () {
    final out = aesCbcZeroPadEncrypt('ABCDEFGHIJKLMNOP', key, iv);
    expect(base64Decode(out).length, 16);
  });

  test('长度不足 16 字节时补零到 16 字节', () {
    final out = aesCbcZeroPadEncrypt('a', key, iv);
    expect(base64Decode(out).length, 16);
  });

  test('中文按 UTF-8 字节加密', () {
    final out = aesCbcZeroPadEncrypt('用户密码abc123', key, iv);
    expect(base64Decode(out).length, 32); // 18 字节 + 14 零填充 = 32
  });
}
