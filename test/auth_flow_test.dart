import 'package:flutter_test/flutter_test.dart';

import 'package:giwifi_ua_switcher/utils/aes_crypto.dart';
import 'package:giwifi_ua_switcher/utils/form_builder.dart';

void main() {
  // sign 值来自真实门户页捕获（giwifi_page.html），
  // 期望密文由 tool/gen_test_vectors.py 用 pycryptodome 生成。
  const sign =
      'i9VxNtOviZf0rFWc8jOjFKzszNLfF1YOgj5oVwt0i0faXMJpFTFIPtWuZKjEfHFYZLKhCwp7T5yMph6z60uVKFml//rAnpFWywtNnJGF8IoKPhwLXDoJkpv4i4RY19pNsHDtEgzkfuZ0mN8GWUcS1wwiiyO9IcoDHP7D+Rsl/8jwWA0QXd7rjt69HVVs9EpwJ1qUpJfyWKESkKscfA7+taw4ya3JKaB46nEov/keVV0zglqOLfL0WzX8KMc/TUl4wGzJtvlIG/CDUYs85SnWnQ==';
  const iv = 'ffac952f576cf411';
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

  test('完整链路：表单构建 + 加密与参考实现对拍一致', () {
    final formStr = buildFormString(fields);
    expect(formStr.length, 584);
    expect(
      formStr,
      contains(
        'sign=i9VxNtOviZf0rFWc8jOjFKzszNLfF1YOgj5oVwt0i0faXMJpFTFIPtWuZKjEfHFYZLKhCwp7T5yMph6z60uVKFml%2F%2FrAnpFWywtNnJGF8IoKPhwLXDoJkpv4i4RY19pNsHDtEgzkfuZ0mN8GWUcS1wwiiyO9IcoDHP7D%2BRsl%2F8jwWA0QXd7rjt69HVVs9EpwJ1qUpJfyWKESkKscfA7%2Btaw4ya3JKaB46nEov%2FkeVV0zglqOLfL0WzX8KMc%2FTUl4wGzJtvlIG%2FCDUYs85SnWnQ%3D%3D&',
      ),
    );
    expect(aesCbcZeroPadEncrypt(formStr, kGiWifiAesKey, iv), expectedEnc);
  });
}
