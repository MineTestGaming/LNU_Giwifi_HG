import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/device_profile.dart';
import '../services/auth_service.dart';
import '../services/settings_service.dart';
import '../theme.dart';

/// 项目仓库地址（右上角入口按钮跳转）。
const String kRepoUrl = 'https://github.com/Yanmo552/giwifi-ua-switcher';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final TextEditingController _usernameCtrl = TextEditingController();
  final TextEditingController _passwordCtrl = TextEditingController();
  final TextEditingController _serverCtrl = TextEditingController(
    text: 'http://100.100.9.2',
  );
  final TextEditingController _customUaCtrl = TextEditingController();

  String _profileId = 'pc';
  bool _remember = true;
  bool _obscurePassword = true;
  bool _busy = false;
  bool _checking = false;
  bool _keepAlive = false;

  String? _resultMessage;
  bool _resultSuccess = false;
  OnlineStatus? _status;

  List<LogEntry> _log = <LogEntry>[];
  Timer? _keepAliveTimer;
  AuthService? _activeAuth;

  AuthService get _auth => AuthService(baseUrl: _serverCtrl.text.trim());

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  @override
  void dispose() {
    _keepAliveTimer?.cancel();
    _activeAuth?.cancel();
    _usernameCtrl.dispose();
    _passwordCtrl.dispose();
    _serverCtrl.dispose();
    _customUaCtrl.dispose();
    super.dispose();
  }

  DeviceProfile get _selectedProfile {
    if (_profileId == 'custom') {
      return DeviceProfile(
        id: 'custom',
        label: '自定义',
        userAgent: _customUaCtrl.text.trim(),
      );
    }
    return DeviceProfile.byId(_profileId);
  }

  // ================= 数据 =================

  Future<void> _loadSettings() async {
    final s = await SettingsService.loadLoginInfo();
    if (!mounted) return;
    setState(() {
      _usernameCtrl.text = s[SettingsService.kUsername] as String;
      _passwordCtrl.text = s[SettingsService.kPassword] as String;
      _serverCtrl.text = s[SettingsService.kServerUrl] as String;
      _profileId = s[SettingsService.kProfileId] as String;
      _customUaCtrl.text = s[SettingsService.kCustomUa] as String;
      _remember = s[SettingsService.kRemember] as bool;
    });
    final log = await SettingsService.loadLog();
    if (!mounted) return;
    setState(() => _log = log);
  }

  Future<void> _saveSettings() => SettingsService.saveLoginInfo(
        username: _usernameCtrl.text.trim(),
        password: _passwordCtrl.text,
        serverUrl: _serverCtrl.text.trim(),
        profileId: _profileId,
        customUa: _customUaCtrl.text.trim(),
        remember: _remember,
      );

  void _showSnack(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _appendLog(LogEntry entry) async {
    if (!mounted) return;
    setState(() => _log.insert(0, entry));
    await SettingsService.appendLog(entry);
  }

  String _friendlyError(Object e) {
    if (e is SocketException) {
      return '无法连接认证服务器，请确认已连接校园网 WiFi';
    }
    if (e is TimeoutException) {
      return '连接认证服务器超时，请稍后重试';
    }
    return '请求异常：$e';
  }

  // ================= 动作 =================

  Future<void> _doLogin() async {
    final username = _usernameCtrl.text.trim();
    final password = _passwordCtrl.text;
    if (username.isEmpty || password.isEmpty) {
      _showSnack('请先填写账号和密码');
      return;
    }
    final profile = _selectedProfile;
    if (profile.userAgent.isEmpty) {
      _showSnack('请选择设备类型（自定义模式需填写 UA）');
      return;
    }

    setState(() {
      _busy = true;
      _resultMessage = null;
    });
    await _saveSettings();

    final auth = _auth;
    _activeAuth = auth;
    try {
      final result = await auth.login(
        username: username,
        password: password,
        userAgent: profile.userAgent,
        onStatus: (status) {
          if (!mounted) return;
          setState(() {
            _resultMessage = status;
            _resultSuccess = false;
          });
        },
        onRebindConfirm: _confirmRebindDialog,
        onSwitchConfirm: _confirmSwitchDialog,
      );
      if (!mounted) return;
      setState(() {
        _resultMessage = result.message;
        _resultSuccess = result.success;
        _status = result.success ? OnlineStatus.online : OnlineStatus.offline;
      });
      await _appendLog(
        LogEntry(
          time: DateTime.now(),
          device: profile.label,
          success: result.success,
          message: result.message,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      final msg = e is AuthCancelledException || auth.isCancelled
          ? '认证已停止'
          : _friendlyError(e);
      setState(() {
        _resultMessage = msg;
        _resultSuccess = false;
        _status = OnlineStatus.unknown;
      });
      await _appendLog(
        LogEntry(
          time: DateTime.now(),
          device: profile.label,
          success: false,
          message: msg,
        ),
      );
    } finally {
      if (identical(_activeAuth, auth)) _activeAuth = null;
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 服务器要求更换绑定设备时弹窗确认（resultCode=124）。
  Future<bool> _confirmRebindDialog(String info) async {
    if (!mounted) return false;
    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        final scheme = Theme.of(dialogContext).colorScheme;
        return AlertDialog(
          icon: Icon(Icons.devices_other_rounded, color: scheme.primary),
          title: const Text('确认更换绑定设备'),
          content: Text(
            info,
            style: const TextStyle(fontSize: 13.5, height: 1.5),
          ),
          actionsPadding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('取消'),
            ),
            FilledButton.icon(
              onPressed: () => Navigator.pop(dialogContext, true),
              icon: const Icon(Icons.check_rounded, size: 18),
              label: const Text('确认换绑'),
            ),
          ],
        );
      },
    );
    return confirmed ?? false;
  }

  /// 当前设备已在线时弹窗询问是否下线切换。
  Future<bool> _confirmSwitchDialog() async {
    if (!mounted) return false;
    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        final scheme = Theme.of(dialogContext).colorScheme;
        return AlertDialog(
          icon: Icon(Icons.swap_horiz_rounded, color: scheme.primary),
          title: const Text('当前设备已在线'),
          content: const Text(
            '要继续切换设备吗？将先注销当前在线设备，'
            '再按所选设备类型重新认证（会校验账号密码）。',
            style: TextStyle(fontSize: 13.5, height: 1.5),
          ),
          actionsPadding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('取消'),
            ),
            FilledButton.icon(
              onPressed: () => Navigator.pop(dialogContext, true),
              icon: const Icon(Icons.logout_rounded, size: 18),
              label: const Text('下线并切换'),
            ),
          ],
        );
      },
    );
    return confirmed ?? false;
  }

  void _cancelLogin() {
    if (!_busy) return;
    _activeAuth?.cancel();
    if (mounted) setState(() => _resultMessage = '正在停止认证…');
  }

  Future<void> _checkOnline() async {
    final profile = _selectedProfile;
    if (profile.userAgent.isEmpty) {
      _showSnack('请选择设备类型（自定义模式需填写 UA）');
      return;
    }
    setState(() => _checking = true);
    try {
      final status = await _auth.checkOnline(profile.userAgent);
      if (!mounted) return;
      const map = <OnlineStatus, String>{
        OnlineStatus.online: '当前设备已在线',
        OnlineStatus.offline: '当前设备未认证（离线）',
        OnlineStatus.unknown: '状态未知（可能不在校园网）',
      };
      setState(() {
        _resultMessage = map[status];
        _resultSuccess = status == OnlineStatus.online;
        _status = status;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _resultMessage = _friendlyError(e);
        _resultSuccess = false;
        _status = OnlineStatus.unknown;
      });
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  void _toggleKeepAlive(bool value) {
    setState(() => _keepAlive = value);
    _keepAliveTimer?.cancel();
    if (value) {
      _keepAliveTimer = Timer.periodic(
        const Duration(seconds: 60),
        (_) => _keepAliveTick(),
      );
      _showSnack('已开启断线自动重连（每 60 秒检测一次）');
    }
  }

  Future<void> _keepAliveTick() async {
    if (_busy) return;
    final profile = _selectedProfile;
    if (profile.userAgent.isEmpty) return;
    try {
      final status = await _auth.checkOnline(profile.userAgent);
      if (status == OnlineStatus.offline && mounted) {
        await _doLogin();
      }
    } catch (_) {
      // 下个周期重试
    }
  }

  Future<void> _clearLog() async {
    await SettingsService.clearLog();
    if (!mounted) return;
    setState(() => _log = <LogEntry>[]);
    _showSnack('日志已清除');
  }

  String _fmtTime(DateTime t) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }

  IconData _iconFor(String id) => switch (id) {
        'pc' => Icons.computer_rounded,
        'android_phone' => Icons.smartphone_rounded,
        'iphone' => Icons.phone_iphone_rounded,
        'ipad' => Icons.tablet_mac_rounded,
        'android_tablet' => Icons.tablet_android_rounded,
        'custom' => Icons.tune_rounded,
        _ => Icons.devices_rounded,
      };

  // ================= UI =================

  @override
  Widget build(BuildContext context) {
    final profile = _selectedProfile;
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            _buildHeader(),
            Expanded(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 720),
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(20, 20, 20, 28),
                    children: [
                      _buildDeviceCard(),
                      const SizedBox(height: 16),
                      _buildAccountCard(),
                      if (profile.id == 'custom') ...[
                        const SizedBox(height: 16),
                        _buildCustomUaCard(),
                      ],
                      const SizedBox(height: 16),
                      _buildAdvancedCard(),
                      const SizedBox(height: 20),
                      _buildActionRow(),
                      _buildResultBanner(),
                      const SizedBox(height: 16),
                      _buildLogCard(),
                      _buildFooter(),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    final (String label, Color dotColor) = switch (_status) {
      OnlineStatus.online => ('已认证', const Color(0xFF4ADE80)),
      OnlineStatus.offline => ('未认证', const Color(0xFFFBBF24)),
      OnlineStatus.unknown => ('状态未知', const Color(0xFFE2E8F0)),
      null => ('未检测', const Color(0xFFE2E8F0)),
    };
    return Container(
      width: double.infinity,
      decoration: const BoxDecoration(
        gradient: kBrandGradient,
        borderRadius: BorderRadius.vertical(bottom: Radius.circular(28)),
      ),
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 26),
      child: Row(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: kBrandInk.withValues(alpha: .14),
              borderRadius: BorderRadius.circular(14),
            ),
            child: const Icon(Icons.wifi_rounded, color: kBrandInk, size: 26),
          ),
          const SizedBox(width: 14),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'GiWiFi 一键认证',
                  style: TextStyle(
                    color: kBrandInk,
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                    letterSpacing: .2,
                  ),
                ),
                SizedBox(height: 3),
                Text(
                  '校园网终端 · 一键切换 · 极速认证',
                  style: TextStyle(color: kBrandInkSoft, fontSize: 12.5),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: kBrandInk.withValues(alpha: .14),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: dotColor,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  label,
                  style: const TextStyle(
                    color: kBrandInk,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          _buildRepoButton(),
        ],
      ),
    );
  }

  /// 右上角仓库入口：点击用系统浏览器打开 GitHub 仓库。
  Widget _buildRepoButton() {
    return Tooltip(
      message: '打开 GitHub 仓库',
      child: Material(
        color: kBrandInk.withValues(alpha: .14),
        borderRadius: BorderRadius.circular(999),
        child: InkWell(
          borderRadius: BorderRadius.circular(999),
          onTap: _openRepo,
          child: const Padding(
            padding: EdgeInsets.all(7),
            child: Icon(Icons.code_rounded, color: kBrandInk, size: 20),
          ),
        ),
      ),
    );
  }

  Future<void> _openRepo() async {
    try {
      final opened = await launchUrl(
        Uri.parse(kRepoUrl),
        mode: LaunchMode.externalApplication,
      );
      if (!opened) _showSnack('未能打开浏览器，仓库地址：$kRepoUrl');
    } catch (_) {
      _showSnack('未能打开浏览器，仓库地址：$kRepoUrl');
    }
  }

  Widget _buildSectionTitle(IconData icon, String title, String subtitle) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: scheme.primary.withValues(alpha: .10),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, size: 19, color: scheme.primary),
        ),
        const SizedBox(width: 11),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 1),
            Text(
              subtitle,
              style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildDeviceCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildSectionTitle(Icons.devices_rounded, '认证设备', '决定占用哪个终端槽位'),
            const SizedBox(height: 16),
            LayoutBuilder(
              builder: (context, constraints) {
                const spacing = 10.0;
                final width = (constraints.maxWidth - spacing * 2) / 3;
                return Wrap(
                  spacing: spacing,
                  runSpacing: spacing,
                  children: [
                    for (final p in DeviceProfile.presets)
                      _buildDeviceTile(width, p, selected: _profileId == p.id),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDeviceTile(
    double width,
    DeviceProfile profile, {
    required bool selected,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final fg = selected ? scheme.onPrimary : scheme.onSurfaceVariant;
    return SizedBox(
      width: width,
      child: Material(
        color: selected
            ? scheme.primary
            : scheme.surfaceContainerHighest.withValues(alpha: .45),
        animationDuration: const Duration(milliseconds: 160),
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () => setState(() => _profileId = profile.id),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            height: 86,
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: selected
                    ? scheme.primary
                    : scheme.outlineVariant.withValues(alpha: .55),
                width: selected ? 1.6 : 1,
              ),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(_iconFor(profile.id), size: 24, color: fg),
                const SizedBox(height: 7),
                Text(
                  profile.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: selected ? scheme.onPrimary : scheme.onSurface,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildAccountCard() {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildSectionTitle(
              Icons.person_outline_rounded,
              '账号信息',
              '仅保存在本机，不会上传',
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _usernameCtrl,
              decoration: const InputDecoration(
                labelText: '上网账号',
                hintText: '学号 / 手机号',
                prefixIcon: Icon(Icons.person_outline_rounded),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _passwordCtrl,
              obscureText: _obscurePassword,
              decoration: InputDecoration(
                labelText: '密码',
                prefixIcon: const Icon(Icons.lock_outline_rounded),
                suffixIcon: IconButton(
                  tooltip: _obscurePassword ? '显示密码' : '隐藏密码',
                  icon: Icon(
                    _obscurePassword
                        ? Icons.visibility_off_outlined
                        : Icons.visibility_outlined,
                  ),
                  onPressed: () =>
                      setState(() => _obscurePassword = !_obscurePassword),
                ),
              ),
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                Switch(
                  value: _remember,
                  onChanged: (v) => setState(() => _remember = v),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        '记住账号密码',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 1),
                      Text(
                        '明文保存在本机配置文件，仅建议个人设备使用',
                        style: TextStyle(
                          fontSize: 11.5,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCustomUaCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildSectionTitle(
              Icons.code_rounded,
              '自定义 User-Agent',
              '选择“自定义”设备后生效',
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _customUaCtrl,
              minLines: 2,
              maxLines: 4,
              decoration: const InputDecoration(
                labelText: '完整 UA 字符串',
                hintText: '粘贴浏览器开发者工具中的完整 UA',
                alignLabelWithHint: true,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAdvancedCard() {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 6),
          childrenPadding: const EdgeInsets.fromLTRB(18, 4, 18, 18),
          iconColor: scheme.onSurfaceVariant,
          collapsedIconColor: scheme.onSurfaceVariant,
          title: Row(
            children: [
              Icon(Icons.tune_rounded,
                  size: 20, color: scheme.onSurfaceVariant),
              const SizedBox(width: 8),
              const Text(
                '高级设置',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
              ),
            ],
          ),
          children: [
            TextField(
              controller: _serverCtrl,
              decoration: const InputDecoration(
                labelText: '认证服务器地址',
                hintText: 'http://100.100.9.2',
                prefixIcon: Icon(Icons.dns_outlined),
              ),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Switch(
                  value: _keepAlive,
                  onChanged: _toggleKeepAlive,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        '断线自动重连',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 1),
                      Text(
                        '每 60 秒检测一次，掉线自动用当前设备类型重新认证',
                        style: TextStyle(
                          fontSize: 11.5,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildActionRow() {
    return Row(
      children: [
        Expanded(flex: 11, child: _buildPrimaryButton()),
        const SizedBox(width: 12),
        Expanded(
          flex: 8,
          child: OutlinedButton.icon(
            onPressed: _busy || _checking ? null : _checkOnline,
            icon: _checking
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.wifi_tethering_rounded, size: 20),
            label: Text(_checking ? '检测中…' : '检查状态'),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(56),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildPrimaryButton() {
    final scheme = Theme.of(context).colorScheme;
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: _checking
              ? LinearGradient(
                  colors: [
                    scheme.surfaceContainerHighest,
                    scheme.surfaceContainerHighest,
                  ],
                )
              : kBrandGradient,
        ),
        child: FilledButton(
          onPressed: _checking ? null : (_busy ? _cancelLogin : _doLogin),
          style: FilledButton.styleFrom(
            backgroundColor: Colors.transparent,
            disabledBackgroundColor: Colors.transparent,
            foregroundColor: kBrandInk,
            disabledForegroundColor:
                _checking ? scheme.onSurfaceVariant : kBrandInk,
            elevation: 0,
            minimumSize: const Size.fromHeight(56),
            shape: const RoundedRectangleBorder(),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (_busy)
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: kBrandInk,
                  ),
                )
              else
                const Icon(Icons.login_rounded, size: 20),
              const SizedBox(width: 8),
              Text(_busy ? '停止认证' : '一键认证'),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildResultBanner() {
    final message = _resultMessage;
    if (message == null) return const SizedBox.shrink();
    final ok = _resultSuccess;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = isDark
        ? (ok ? const Color(0xFF14331F) : const Color(0xFF3A1B1E))
        : (ok ? const Color(0xFFE8F8EF) : const Color(0xFFFDECEC));
    final fg = isDark
        ? (ok ? const Color(0xFF7BE3AB) : const Color(0xFFFFA6A0))
        : (ok ? const Color(0xFF14794A) : const Color(0xFFB3261E));
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 220),
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation,
        child: SizeTransition(sizeFactor: animation, child: child),
      ),
      child: Container(
        key: ValueKey<String>('$ok:$message'),
        margin: const EdgeInsets.only(top: 16),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: fg.withValues(alpha: .35)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              ok ? Icons.check_circle_rounded : Icons.error_outline_rounded,
              color: fg,
              size: 20,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                message,
                style: TextStyle(
                  color: fg,
                  fontSize: 13.5,
                  fontWeight: FontWeight.w500,
                  height: 1.45,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLogCard() {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.history_rounded,
                  size: 20,
                  color: scheme.onSurfaceVariant,
                ),
                const SizedBox(width: 8),
                const Text(
                  '最近记录',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                ),
                const Spacer(),
                if (_log.isNotEmpty)
                  TextButton(onPressed: _clearLog, child: const Text('清空')),
              ],
            ),
            if (_log.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 14),
                child: Center(
                  child: Text(
                    '暂无认证记录，完成一次认证后在此显示',
                    style: TextStyle(
                      fontSize: 12.5,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              )
            else
              for (final e in _log.take(8))
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Row(
                    children: [
                      Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: e.success
                              ? const Color(0xFF22C55E)
                              : const Color(0xFFEF4444),
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        _fmtTime(e.time),
                        style: TextStyle(
                          fontSize: 11.5,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: scheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          e.device,
                          style: TextStyle(
                            fontSize: 11,
                            color: scheme.onSurfaceVariant,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          e.message,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12.5,
                            color: scheme.onSurfaceVariant,
                            height: 1.35,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
          ],
        ),
      ),
    );
  }

  Widget _buildFooter() {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 20, 6, 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.info_outline_rounded,
            size: 14,
            color: scheme.onSurfaceVariant.withValues(alpha: .7),
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              '请先连接校园 WiFi（未认证状态）再使用。'
              '本工具仅用于自己已购套餐的账号。',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 11.5,
                color: scheme.onSurfaceVariant.withValues(alpha: .8),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
