import 'package:flutter/material.dart';

/// 用品牌黄色生成完整的 Material 3 明暗色彩角色。
const Color kBrandPrimary = Color(0xFFF3D223);

ThemeData buildGiWiFiTheme([Brightness brightness = Brightness.light]) {
  return ThemeData(
    useMaterial3: true,
    fontFamily: 'MiSans',
    colorScheme: ColorScheme.fromSeed(
      seedColor: kBrandPrimary,
      brightness: brightness,
    ),
    // 保留组件默认的 M3 形状、状态层、字体和触控目标。
    inputDecorationTheme: const InputDecorationTheme(
      border: OutlineInputBorder(),
    ),
    snackBarTheme: const SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
    ),
  );
}
