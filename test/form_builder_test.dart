import 'package:flutter_test/flutter_test.dart';

import 'package:giwifi_ua_switcher/utils/form_builder.dart';
import 'package:giwifi_ua_switcher/utils/html_parser.dart';

void main() {
  const html = '''
<html><body>
<input type="hidden" name="sign" value="a/b+c=d">
<input type="hidden" name="sta_ip" value="10.12.224.224">
<input type="text" name="user_account" value="ignored">
<input type="hidden" name="iv" value="ffac952f576cf411">
<input type="hidden" name="single" value='sq'>
</body></html>
''';

  test('parseHiddenInputs 提取 hidden input 并忽略其他 input', () {
    final m = parseHiddenInputs(html);
    expect(m['sign'], 'a/b+c=d');
    expect(m['sta_ip'], '10.12.224.224');
    expect(m['iv'], 'ffac952f576cf411');
    expect(m['single'], 'sq');
    expect(m.containsKey('user_account'), isFalse);
    expect(m.containsKey('noval'), isFalse);
  });

  test('buildFormString 按全部字段固定顺序百分号编码', () {
    final s = buildFormString(<String, String>{
      'sign': 'a/b+c=d',
      'sta_ip': '10.12.224.224',
      'iv': 'ffac952f576cf411',
    });
    expect(
      s,
      'sign=a%2Fb%2Bc%3Dd&sta_vlan=&sta_port=&sta_ip=10.12.224.224'
      '&nas_ip=&nas_name=&last_url=&request_ip=&device_mode='
      '&device_type=&device_os_type=&is_mobile='
      '&iv=ffac952f576cf411&login_type=&account_type='
      '&user_account=&user_password=',
    );
  });

  test('空值字段保留 key= 形式', () {
    final s = buildFormString(<String, String>{
      'sign': 's',
      'sta_vlan': '',
      'sta_ip': '1',
    });
    expect(
      s,
      'sign=s&sta_vlan=&sta_port=&sta_ip=1&nas_ip=&nas_name=&last_url='
      '&request_ip=&device_mode=&device_type=&device_os_type=&is_mobile='
      '&iv=&login_type=&account_type=&user_account=&user_password=',
    );
  });

  test('字段顺序与门户页一致', () {
    expect(kFormFieldOrder, const <String>[
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
    ]);
  });
}
