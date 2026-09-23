/// 与门户页登录表单一致的字段顺序。
const List<String> kFormFieldOrder = <String>[
  'sign',
  'sta_vlan',
  'sta_port',
  'sta_ip',
  'nas_ip',
  'nas_name',
  'last_url',
  'request_ip',
  'device_mode',
  'device_type',
  'device_os_type',
  'is_mobile',
  'iv',
  'login_type',
  'account_type',
  'user_account',
  'user_password',
];

/// 序列化为 key1=val1&key2=val2&...。
///
/// 编码规则与 Python `requests.utils.quote(s, safe='')` 一致：
/// 保留 A-Za-z0-9-._~，其余字符百分号编码。
String buildFormString(Map<String, String> fields) {
  return kFormFieldOrder
      .map(
        (k) =>
            '${Uri.encodeComponent(k)}=${Uri.encodeComponent(fields[k] ?? '')}',
      )
      .join('&');
}
