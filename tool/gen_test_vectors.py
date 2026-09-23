# -*- coding: utf-8 -*-
"""生成 AES-CBC-ZeroPadding 测试向量（与 pycryptodome / CryptoJS 对拍）"""
import base64
import json
import urllib.parse

from Crypto.Cipher import AES

KEY = "1234567887654321"
IV = "ffac952f576cf411"  # 来自门户页隐藏字段 iv


def aes_cbc_zeropad(plaintext, key, iv):
    key_b = key.encode("utf-8")
    iv_b = iv.encode("utf-8")
    data = plaintext.encode("utf-8")
    pad = (16 - len(data) % 16) % 16
    if pad:
        data += b"\x00" * pad
    return base64.b64encode(AES.new(key_b, AES.MODE_CBC, iv_b).encrypt(data)).decode("ascii")


FIELDS = {
    "sign": "i9VxNtOviZf0rFWc8jOjFKzszNLfF1YOgj5oVwt0i0faXMJpFTFIPtWuZKjEfHFYZLKhCwp7T5yMph6z60uVKFml//rAnpFWywtNnJGF8IoKPhwLXDoJkpv4i4RY19pNsHDtEgzkfuZ0mN8GWUcS1wwiiyO9IcoDHP7D+Rsl/8jwWA0QXd7rjt69HVVs9EpwJ1qUpJfyWKESkKscfA7+taw4ya3JKaB46nEov/keVV0zglqOLfL0WzX8KMc/TUl4wGzJtvlIG/CDUYs85SnWnQ==",
    "sta_vlan": "",
    "sta_port": "",
    "sta_ip": "10.12.224.224",
    "nas_ip": "",
    "nas_name": "GiWiFi_lnsf",
    "last_url": "",
    "request_ip": "10.11.119.129",
    "device_mode": "Windows NT 10.0",
    "device_type": "1",
    "device_os_type": "3",
    "is_mobile": "0",
    "iv": IV,
    "login_type": "1",
    "account_type": "2",
    "user_account": "test2024",
    "user_password": "TestPass123@",
}

ORDER = [
    "sign", "sta_vlan", "sta_port", "sta_ip", "nas_ip", "nas_name", "last_url",
    "request_ip", "device_mode", "device_type", "device_os_type", "is_mobile",
    "iv", "login_type", "account_type", "user_account", "user_password",
]

form_str = "&".join(
    urllib.parse.quote(k, safe="") + "=" + urllib.parse.quote(FIELDS[k], safe="")
    for k in ORDER
)

plain_vectors = [
    "a",
    "ABCDEFGHIJKLMNOP",
    "ABCDEFGHIJKLMNOPQ",
    "用户密码abc123",
    form_str,
]

out = {"form_string": form_str}
for p in plain_vectors:
    out[repr(p)] = aes_cbc_zeropad(p, KEY, IV)

print(json.dumps(out, ensure_ascii=False, indent=2))