import 'dart:convert';
import 'dart:typed_data';

/// GiWiFi 门户 aes.js 中硬编码的密钥。
const String kGiWifiAesKey = '1234567887654321';

/// 与前端 CryptoJS.AES.encrypt(data, key, {mode: CBC, padding: ZeroPadding})
/// 等价的加密，返回 Base64 密文。
///
/// 纯 Dart 实现（FIPS-197 AES-128 + CBC），不依赖任何第三方包，
/// 正确性由 NIST SP 800-38A 官方向量 + 门户真实会话对拍测试保证。
///
/// 注意：CryptoJS 的 ZeroPadding 在明文长度已是 16 字节整数倍时
/// 不追加填充块（区别于 PKCS#7）。
String aesCbcZeroPadEncrypt(String plaintext, String keyStr, String ivStr) {
  final key = utf8.encode(keyStr);
  final iv = utf8.encode(ivStr);
  var data = utf8.encode(plaintext);

  final padLen = (16 - data.length % 16) % 16;
  if (padLen > 0) {
    data = Uint8List.fromList([...data, ...List<int>.filled(padLen, 0)]);
  }

  final aes = Aes128(key);
  final out = Uint8List(data.length);
  var prev = Uint8List.fromList(iv);

  for (var off = 0; off < data.length; off += 16) {
    final block = Uint8List.fromList(data.sublist(off, off + 16));
    for (var i = 0; i < 16; i++) {
      block[i] ^= prev[i];
    }
    final encrypted = aes.encryptBlock(block);
    out.setRange(off, off + 16, encrypted);
    prev = encrypted;
  }

  return base64Encode(out);
}

/// 最小 AES-128 加密块实现（FIPS-197）。
///
/// 状态布局按 FIPS 约定：s[r][c] = input[r + 4c]，
/// 即字节按自然顺序存放，每 4 字节为一列。
class Aes128 {
  Aes128(List<int> key) {
    if (key.length != 16) {
      throw ArgumentError('AES-128 需要 16 字节密钥，实际 ${key.length}');
    }
    _roundKeys = _expandKey(key);
  }

  late final List<Uint8List> _roundKeys; // 11 轮密钥，每轮 16 字节

  Uint8List encryptBlock(Uint8List input) {
    if (input.length != 16) {
      throw ArgumentError('块长度必须为 16 字节');
    }
    var state = Uint8List.fromList(input);

    _addRoundKey(state, _roundKeys[0]);
    for (var round = 1; round <= 9; round++) {
      _subBytes(state);
      _shiftRows(state);
      _mixColumns(state);
      _addRoundKey(state, _roundKeys[round]);
    }
    _subBytes(state);
    _shiftRows(state);
    _addRoundKey(state, _roundKeys[10]);

    return state;
  }

  static List<Uint8List> _expandKey(List<int> key) {
    final w = List<Uint8List>.generate(44, (_) => Uint8List(4));
    for (var i = 0; i < 4; i++) {
      w[i][0] = key[4 * i];
      w[i][1] = key[4 * i + 1];
      w[i][2] = key[4 * i + 2];
      w[i][3] = key[4 * i + 3];
    }
    for (var i = 4; i < 44; i++) {
      final temp = Uint8List.fromList(w[i - 1]);
      if (i % 4 == 0) {
        // RotWord
        final t0 = temp[0];
        temp[0] = temp[1];
        temp[1] = temp[2];
        temp[2] = temp[3];
        temp[3] = t0;
        // SubWord
        for (var j = 0; j < 4; j++) {
          temp[j] = _sbox[temp[j]];
        }
        // Rcon[i/4 - 1]
        temp[0] ^= _rcon[i ~/ 4 - 1];
      }
      for (var j = 0; j < 4; j++) {
        w[i][j] = w[i - 4][j] ^ temp[j];
      }
    }
    final roundKeys = List<Uint8List>.generate(11, (_) => Uint8List(16));
    for (var r = 0; r < 11; r++) {
      for (var j = 0; j < 4; j++) {
        roundKeys[r].setRange(j * 4, j * 4 + 4, w[r * 4 + j]);
      }
    }
    return roundKeys;
  }

  static void _addRoundKey(Uint8List state, Uint8List roundKey) {
    for (var i = 0; i < 16; i++) {
      state[i] ^= roundKey[i];
    }
  }

  static void _subBytes(Uint8List state) {
    for (var i = 0; i < 16; i++) {
      state[i] = _sbox[state[i]];
    }
  }

  static void _shiftRows(Uint8List state) {
    // 第 1 行（下标 1,5,9,13）左移 1
    final s1 = state[1];
    state[1] = state[5];
    state[5] = state[9];
    state[9] = state[13];
    state[13] = s1;
    // 第 2 行（下标 2,6,10,14）左移 2
    final s2a = state[2];
    final s2b = state[6];
    state[2] = state[10];
    state[6] = state[14];
    state[10] = s2a;
    state[14] = s2b;
    // 第 3 行（下标 3,7,11,15）左移 3
    final s3a = state[3];
    final s3b = state[7];
    final s3c = state[11];
    state[3] = state[15];
    state[7] = s3a;
    state[11] = s3b;
    state[15] = s3c;
  }

  static void _mixColumns(Uint8List state) {
    for (var c = 0; c < 4; c++) {
      final i0 = 4 * c;
      final a0 = state[i0];
      final a1 = state[i0 + 1];
      final a2 = state[i0 + 2];
      final a3 = state[i0 + 3];
      state[i0] = _gmul(a0, 2) ^ _gmul(a1, 3) ^ a2 ^ a3;
      state[i0 + 1] = a0 ^ _gmul(a1, 2) ^ _gmul(a2, 3) ^ a3;
      state[i0 + 2] = a0 ^ a1 ^ _gmul(a2, 2) ^ _gmul(a3, 3);
      state[i0 + 3] = _gmul(a0, 3) ^ a1 ^ a2 ^ _gmul(a3, 2);
    }
  }

  /// GF(2^8) 乘法（不可约多项式 x^8+x^4+x^3+x+1，即 0x1b）
  static int _gmul(int a, int b) {
    var p = 0;
    for (var i = 0; i < 8; i++) {
      if ((b & 1) != 0) {
        p ^= a;
      }
      final hi = a & 0x80;
      a = (a << 1) & 0xff;
      if (hi != 0) {
        a ^= 0x1b;
      }
      b >>= 1;
    }
    return p & 0xff;
  }

  static const List<int> _rcon = <int>[
    0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x1b, 0x36, //
  ];

  static const List<int> _sbox = <int>[
    0x63, 0x7c, 0x77, 0x7b, 0xf2, 0x6b, 0x6f, 0xc5, 0x30, 0x01, 0x67, 0x2b,
    0xfe, 0xd7, 0xab, 0x76, //
    0xca, 0x82, 0xc9, 0x7d, 0xfa, 0x59, 0x47, 0xf0, 0xad, 0xd4, 0xa2, 0xaf,
    0x9c, 0xa4, 0x72, 0xc0, //
    0xb7, 0xfd, 0x93, 0x26, 0x36, 0x3f, 0xf7, 0xcc, 0x34, 0xa5, 0xe5, 0xf1,
    0x71, 0xd8, 0x31, 0x15, //
    0x04, 0xc7, 0x23, 0xc3, 0x18, 0x96, 0x05, 0x9a, 0x07, 0x12, 0x80, 0xe2,
    0xeb, 0x27, 0xb2, 0x75, //
    0x09, 0x83, 0x2c, 0x1a, 0x1b, 0x6e, 0x5a, 0xa0, 0x52, 0x3b, 0xd6, 0xb3,
    0x29, 0xe3, 0x2f, 0x84, //
    0x53, 0xd1, 0x00, 0xed, 0x20, 0xfc, 0xb1, 0x5b, 0x6a, 0xcb, 0xbe, 0x39,
    0x4a, 0x4c, 0x58, 0xcf, //
    0xd0, 0xef, 0xaa, 0xfb, 0x43, 0x4d, 0x33, 0x85, 0x45, 0xf9, 0x02, 0x7f,
    0x50, 0x3c, 0x9f, 0xa8, //
    0x51, 0xa3, 0x40, 0x8f, 0x92, 0x9d, 0x38, 0xf5, 0xbc, 0xb6, 0xda, 0x21,
    0x10, 0xff, 0xf3, 0xd2, //
    0xcd, 0x0c, 0x13, 0xec, 0x5f, 0x97, 0x44, 0x17, 0xc4, 0xa7, 0x7e, 0x3d,
    0x64, 0x5d, 0x19, 0x73, //
    0x60, 0x81, 0x4f, 0xdc, 0x22, 0x2a, 0x90, 0x88, 0x46, 0xee, 0xb8, 0x14,
    0xde, 0x5e, 0x0b, 0xdb, //
    0xe0, 0x32, 0x3a, 0x0a, 0x49, 0x06, 0x24, 0x5c, 0xc2, 0xd3, 0xac, 0x62,
    0x91, 0x95, 0xe4, 0x79, //
    0xe7, 0xc8, 0x37, 0x6d, 0x8d, 0xd5, 0x4e, 0xa9, 0x6c, 0x56, 0xf4, 0xea,
    0x65, 0x7a, 0xae, 0x08, //
    0xba, 0x78, 0x25, 0x2e, 0x1c, 0xa6, 0xb4, 0xc6, 0xe8, 0xdd, 0x74, 0x1f,
    0x4b, 0xbd, 0x8b, 0x8a, //
    0x70, 0x3e, 0xb5, 0x66, 0x48, 0x03, 0xf6, 0x0e, 0x61, 0x35, 0x57, 0xb9,
    0x86, 0xc1, 0x1d, 0x9e, //
    0xe1, 0xf8, 0x98, 0x11, 0x69, 0xd9, 0x8e, 0x94, 0x9b, 0x1e, 0x87, 0xe9,
    0xce, 0x55, 0x28, 0xdf, //
    0x8c, 0xa1, 0x89, 0x0d, 0xbf, 0xe6, 0x42, 0x68, 0x41, 0x99, 0x2d, 0x0f,
    0xb0, 0x54, 0xbb, 0x16, //
  ];
}
