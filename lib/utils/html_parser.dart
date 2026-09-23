/// 极简 HTML 解析：提取 <input type="hidden"> 的 name/value。
/// 登录页只有这一种需要解析的字段，避免引入完整 HTML 解析库。
Map<String, String> parseHiddenInputs(String html) {
  final result = <String, String>{};
  final tagRe = RegExp(r'<input\b[^>]*>', caseSensitive: false);
  for (final m in tagRe.allMatches(html)) {
    final tag = m.group(0)!;
    final type = _readAttr(tag, 'type');
    if (type == null || type.toLowerCase() != 'hidden') continue;
    final name = _readAttr(tag, 'name');
    if (name == null || name.isEmpty) continue;
    result[name] = _readAttr(tag, 'value') ?? '';
  }
  return result;
}

String? _readAttr(String tag, String name) {
  final re = RegExp(
    '$name\\s*=\\s*(?:"([^"]*)"|\'([^\']*)\'|([^\\s>]+))',
    caseSensitive: false,
  );
  final m = re.firstMatch(tag);
  if (m == null) return null;
  return m.group(1) ?? m.group(2) ?? m.group(3);
}
