/// 认证设备类型预设。
///
/// GiWiFi 门户在渲染登录页时会根据请求的 User-Agent 决定
/// device_type / device_os_type / is_mobile 等隐藏字段，
/// 认证成功后服务器把该设备计入对应终端槽位（手机/平板/电脑）。
class DeviceProfile {
  const DeviceProfile({
    required this.id,
    required this.label,
    required this.userAgent,
  });

  final String id;
  final String label;
  final String userAgent;

  static const List<DeviceProfile> presets = <DeviceProfile>[
    DeviceProfile(
      id: 'pc',
      label: '电脑',
      userAgent: 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
          'AppleWebKit/537.36 (KHTML, like Gecko) '
          'Chrome/126.0.0.0 Safari/537.36',
    ),
    DeviceProfile(
      id: 'android_phone',
      label: '安卓手机',
      userAgent: 'Mozilla/5.0 (Linux; Android 14; 24031PN0DC) '
          'AppleWebKit/537.36 (KHTML, like Gecko) '
          'Chrome/126.0.0.0 Mobile Safari/537.36',
    ),
    DeviceProfile(
      id: 'iphone',
      label: 'iPhone',
      userAgent: 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) '
          'AppleWebKit/605.1.15 (KHTML, like Gecko) '
          'Version/17.5 Mobile/15E148 Safari/604.1',
    ),
    DeviceProfile(
      id: 'ipad',
      label: 'iPad',
      userAgent: 'Mozilla/5.0 (iPad; CPU OS 17_5 like Mac OS X) '
          'AppleWebKit/605.1.15 (KHTML, like Gecko) '
          'Version/17.5 Mobile/15E148 Safari/604.1',
    ),
    DeviceProfile(id: 'custom', label: '自定义', userAgent: ''),
  ];

  static DeviceProfile byId(String id) {
    return presets.firstWhere((p) => p.id == id, orElse: () => presets.first);
  }
}
