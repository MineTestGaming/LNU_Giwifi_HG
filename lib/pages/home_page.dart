import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/device_profile.dart';
import '../services/auth_service.dart';
import '../services/settings_service.dart';
import '../services/network_adapter_service.dart';

/// 项目仓库地址（右上角入口按钮跳转）。
const String kRepoUrl = 'https://github.com/Eternite-0/LNU_Giwifi_HG';

class HomePage extends StatefulWidget {
  const HomePage(
      {super.key, this.networkAdapters = const NetworkAdapterService()});

  final NetworkAdapterService networkAdapters;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final TextEditingController _usernameCtrl = TextEditingController();
  final TextEditingController _passwordCtrl = TextEditingController();
  final TextEditingController _serverCtrl = TextEditingController(
    text: 'http://100.100.9.2',
  );
  final TextEditingController _acNameCtrl = TextEditingController(
    text: 'GiWiFi_lnsfHG',
  );
  final TextEditingController _customUaCtrl = TextEditingController();

  String _profileId = 'pc';
  bool _remember = true;
  bool _obscurePassword = true;
  bool _busy = false;
  bool _checking = false;
  bool _keepAlive = false;
  bool _refreshingAdapters = false;
  bool _settingsLoaded = false;
  NetworkAdapter? _networkAdapter;
  List<NetworkAdapter> _networkAdapters = [];
  String? _adapterError;

  bool get _isDesktop => switch (defaultTargetPlatform) {
        TargetPlatform.windows ||
        TargetPlatform.macOS ||
        TargetPlatform.linux =>
          true,
        _ => false,
      };
  bool get _operationActive =>
      _busy ||
      _checking ||
      _refreshingAdapters ||
      (_isDesktop && !_settingsLoaded);

  String? _resultMessage;
  bool _resultSuccess = false;
  OnlineStatus? _status;

  List<LogEntry> _log = <LogEntry>[];
  Timer? _keepAliveTimer;
  AuthService? _activeAuth;

  AuthService get _auth => AuthService(
        baseUrl: _serverCtrl.text.trim(),
        wlanAcName: _acNameCtrl.text.trim(),
        networkAdapter: _isDesktop ? _networkAdapter : null,
        networkAdapters: widget.networkAdapters,
      );

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
    _acNameCtrl.dispose();
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
    final adapter =
        _isDesktop ? await SettingsService.loadNetworkAdapter() : null;
    if (!mounted) return;
    setState(() {
      _usernameCtrl.text = s[SettingsService.kUsername] as String;
      _passwordCtrl.text = s[SettingsService.kPassword] as String;
      _serverCtrl.text = s[SettingsService.kServerUrl] as String;
      _acNameCtrl.text = s[SettingsService.kWlanAcName] as String;
      _profileId = s[SettingsService.kProfileId] as String;
      _customUaCtrl.text = s[SettingsService.kCustomUa] as String;
      _remember = s[SettingsService.kRemember] as bool;
      _networkAdapter = adapter;
      _settingsLoaded = true;
    });
    final log = await SettingsService.loadLog();
    if (!mounted) return;
    setState(() => _log = log);
    if (_isDesktop) await _refreshNetworkAdapters(persist: false);
  }

  Future<void> _refreshNetworkAdapters({bool persist = true}) async {
    if (_operationActive) return;
    setState(() => _refreshingAdapters = true);
    try {
      final adapters = await widget.networkAdapters
          .listAvailable()
          .timeout(const Duration(seconds: 5));
      if (!mounted) return;
      setState(() {
        _networkAdapters = adapters;
        _networkAdapter =
            widget.networkAdapters.refreshSelection(_networkAdapter, adapters);
        _adapterError = null;
        _status = null;
        _resultMessage = null;
      });
      if (persist) await SettingsService.saveNetworkAdapter(_networkAdapter);
    } catch (e) {
      if (mounted) setState(() => _adapterError = '刷新网卡失败：$e');
    } finally {
      if (mounted) setState(() => _refreshingAdapters = false);
    }
  }

  Future<void> _selectNetworkAdapter(NetworkAdapter? adapter) async {
    if (_operationActive) return;
    _activeAuth?.dispose();
    _activeAuth = null;
    setState(() {
      _networkAdapter = adapter;
      _status = null;
      _resultMessage = null;
      _resultSuccess = false;
      _refreshingAdapters = true;
    });
    try {
      await SettingsService.saveNetworkAdapter(adapter);
    } catch (e) {
      if (mounted) _showSnack('网卡选择保存失败：$e');
    } finally {
      if (mounted) setState(() => _refreshingAdapters = false);
    }
  }

  Future<void> _saveSettings() => SettingsService.saveLoginInfo(
        username: _usernameCtrl.text.trim(),
        password: _passwordCtrl.text,
        serverUrl: _serverCtrl.text.trim(),
        wlanAcName: _acNameCtrl.text.trim(),
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
    if (e is NetworkAdapterUnavailableException) return e.message;
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
    if (_operationActive) return;
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
    final auth = _auth;
    _activeAuth = auth;
    try {
      await _saveSettings();
      if (!mounted) return;
      if (auth.isCancelled) throw const AuthCancelledException();
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
      auth.dispose();
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
          content: Text(info),
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
          ),
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
    if (_operationActive) return;
    final profile = _selectedProfile;
    if (profile.userAgent.isEmpty) {
      _showSnack('请选择设备类型（自定义模式需填写 UA）');
      return;
    }
    setState(() => _checking = true);
    final auth = _auth;
    _activeAuth = auth;
    try {
      final status = await auth.checkOnline(profile.userAgent);
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
      auth.dispose();
      if (identical(_activeAuth, auth)) _activeAuth = null;
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
    if (_operationActive) return;
    final profile = _selectedProfile;
    if (profile.userAgent.isEmpty) return;
    setState(() => _checking = true);
    final auth = _auth;
    _activeAuth = auth;
    var reconnect = false;
    try {
      final status = await auth.checkOnline(profile.userAgent);
      reconnect = status == OnlineStatus.offline;
    } catch (e) {
      if (mounted)
        setState(() {
          _resultMessage = _friendlyError(e);
          _resultSuccess = false;
          _status = OnlineStatus.unknown;
        });
    } finally {
      auth.dispose();
      if (identical(_activeAuth, auth)) _activeAuth = null;
      if (mounted) setState(() => _checking = false);
    }
    if (reconnect && mounted && _keepAlive) await _doLogin();
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
    return Scaffold(
      appBar: AppBar(
        title: const Text('GiWiFi 一键认证'),
        actions: [
          IconButton(
            tooltip: '打开 GitHub 仓库',
            onPressed: _openRepo,
            icon: const Icon(Icons.code_rounded),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _buildStatusCard(),
                const SizedBox(height: 16),
                _buildDeviceCard(),
                const SizedBox(height: 16),
                _buildAccountCard(),
                if (_isDesktop) ...[
                  const SizedBox(height: 16),
                  _buildNetworkCard(),
                ],
                if (_profileId == 'custom') ...[
                  const SizedBox(height: 16),
                  _buildCustomUaCard(),
                ],
                const SizedBox(height: 16),
                _buildAdvancedCard(),
                const SizedBox(height: 24),
                _buildActionRow(),
                _buildResultBanner(),
                const SizedBox(height: 24),
                _buildLogCard(),
                _buildFooter(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildStatusCard() {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final (label, icon) = switch (_status) {
      OnlineStatus.online => ('已认证', Icons.wifi_rounded),
      OnlineStatus.offline => ('未认证', Icons.wifi_off_rounded),
      OnlineStatus.unknown => ('状态未知', Icons.help_outline_rounded),
      null => ('未检测', Icons.wifi_find_rounded),
    };
    return Card.filled(
      margin: EdgeInsets.zero,
      color: scheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Row(
          children: [
            Icon(icon, size: 32, color: scheme.onPrimaryContainer),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Semantics(
                    liveRegion: true,
                    child: Text(label,
                        style: theme.textTheme.headlineSmall
                            ?.copyWith(color: scheme.onPrimaryContainer)),
                  ),
                  const SizedBox(height: 4),
                  Text('连接校园 WiFi 后，选择设备并认证',
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(color: scheme.onPrimaryContainer)),
                ],
              ),
            ),
          ],
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
      if (!mounted) return;
      if (!opened) _showSnack('未能打开浏览器，仓库地址：$kRepoUrl');
    } catch (_) {
      if (mounted) _showSnack('未能打开浏览器，仓库地址：$kRepoUrl');
    }
  }

  Widget _buildSectionTitle(IconData icon, String title, String subtitle) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, color: theme.colorScheme.primary),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: theme.textTheme.titleMedium),
              const SizedBox(height: 4),
              Text(subtitle,
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildDeviceCard() {
    return Card.filled(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildSectionTitle(Icons.devices_rounded, '认证设备', '决定占用哪个终端槽位'),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final profile in DeviceProfile.presets)
                  ChoiceChip(
                    avatar: _profileId == profile.id
                        ? null
                        : Icon(_iconFor(profile.id), size: 18),
                    label: Text(profile.label),
                    selected: _profileId == profile.id,
                    onSelected: _operationActive
                        ? null
                        : (_) => setState(() => _profileId = profile.id),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAccountCard() {
    return Card.outlined(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildSectionTitle(
                Icons.person_outline_rounded, '账号信息', '使用你的校园网上网账号'),
            const SizedBox(height: 24),
            TextField(
              controller: _usernameCtrl,
              enabled: !_operationActive,
              textInputAction: TextInputAction.next,
              autofillHints: const [AutofillHints.username],
              decoration: const InputDecoration(
                labelText: '上网账号',
                hintText: '学号 / 手机号',
                prefixIcon: Icon(Icons.person_outline_rounded),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _passwordCtrl,
              enabled: !_operationActive,
              obscureText: _obscurePassword,
              autocorrect: false,
              enableSuggestions: false,
              autofillHints: const [AutofillHints.password],
              decoration: InputDecoration(
                labelText: '密码',
                prefixIcon: const Icon(Icons.lock_outline_rounded),
                suffixIcon: IconButton(
                  tooltip: _obscurePassword ? '显示密码' : '隐藏密码',
                  icon: Icon(_obscurePassword
                      ? Icons.visibility_off_outlined
                      : Icons.visibility_outlined),
                  onPressed: () =>
                      setState(() => _obscurePassword = !_obscurePassword),
                ),
              ),
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('记住账号密码'),
              subtitle: const Text('明文保存在本机配置文件，仅建议个人设备使用'),
              value: _remember,
              onChanged: _operationActive
                  ? null
                  : (value) => setState(() => _remember = value),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCustomUaCard() {
    return Card.outlined(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildSectionTitle(
                Icons.code_rounded, '自定义 User-Agent', '选择“自定义”设备后生效'),
            const SizedBox(height: 24),
            TextField(
              controller: _customUaCtrl,
              enabled: !_operationActive,
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

  Widget _buildNetworkCard() {
    final selected = _networkAdapter;
    final unavailable =
        selected != null && !_networkAdapters.contains(selected);
    final choices = [..._networkAdapters, if (unavailable) selected];
    return Card.outlined(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildSectionTitle(
                Icons.settings_ethernet_rounded, '认证网卡', '选择连接校园网的网卡'),
            const SizedBox(height: 16),
            InputDecorator(
              decoration: const InputDecoration(labelText: '网卡 / IPv4'),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<NetworkAdapter>(
                  key: const ValueKey('network-adapter-selector'),
                  value: selected,
                  isExpanded: true,
                  hint: const Text('系统默认'),
                  items: [
                    const DropdownMenuItem<NetworkAdapter>(
                        value: null, child: Text('系统默认')),
                    for (final adapter in choices)
                      DropdownMenuItem(
                          value: adapter,
                          child: Text(
                            '${adapter.label}${unavailable && adapter == selected ? '（不可用）' : ''}',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          )),
                  ],
                  onChanged: _operationActive || !_settingsLoaded
                      ? null
                      : _selectNetworkAdapter,
                ),
              ),
            ),
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: _operationActive || !_settingsLoaded
                  ? null
                  : () => _refreshNetworkAdapters(),
              icon: const Icon(Icons.refresh_rounded),
              label: Text(_refreshingAdapters ? '正在刷新…' : '刷新网卡'),
            ),
            Text(_adapterError ??
                (unavailable
                    ? '所选网卡不可用，请连接后刷新或重新选择。'
                    : '认证、状态检测和自动重连使用所选网卡的 IPv4；不修改系统默认路由。')),
          ],
        ),
      ),
    );
  }

  Widget _buildAdvancedCard() {
    return Card.outlined(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        leading: const Icon(Icons.tune_rounded),
        title: const Text('高级设置'),
        shape: const Border(),
        collapsedShape: const Border(),
        childrenPadding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        children: [
          TextField(
            controller: _serverCtrl,
            enabled: !_operationActive,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(
              labelText: '认证服务器地址',
              hintText: 'http://100.100.9.2',
              prefixIcon: Icon(Icons.dns_outlined),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _acNameCtrl,
            enabled: !_operationActive,
            decoration: const InputDecoration(
              labelText: '校园 AC 名称（wlanacname）',
              hintText: 'GiWiFi_lnsfHG',
              prefixIcon: Icon(Icons.router_outlined),
            ),
          ),
          const SizedBox(height: 8),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('断线自动重连'),
            subtitle: const Text('每 60 秒检测一次，掉线自动用当前设备类型重新认证'),
            value: _keepAlive,
            onChanged: _toggleKeepAlive,
          ),
        ],
      ),
    );
  }

  Widget _buildActionRow() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final primary = FilledButton.icon(
          onPressed:
              _busy ? _cancelLogin : (_operationActive ? null : _doLogin),
          icon: Icon(_busy ? Icons.stop_rounded : Icons.login_rounded),
          label: Text(_busy ? '停止认证' : '一键认证'),
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
        );
        final secondary = OutlinedButton.icon(
          onPressed: _operationActive ? null : _checkOnline,
          icon: const Icon(Icons.wifi_tethering_rounded),
          label: Text(_checking ? '检测中…' : '检查状态'),
          style:
              OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
        );
        final stacked = constraints.maxWidth < 360 ||
            MediaQuery.textScalerOf(context).scale(14) > 20;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (stacked) ...[
              primary,
              const SizedBox(height: 12),
              secondary,
            ] else
              Row(children: [
                Expanded(child: primary),
                const SizedBox(width: 16),
                Expanded(child: secondary),
              ]),
            if (_busy || _checking) ...[
              const SizedBox(height: 16),
              LinearProgressIndicator(
                semanticsLabel: _busy ? '正在认证' : '正在检查在线状态',
              ),
            ],
          ],
        );
      },
    );
  }

  Widget _buildResultBanner() {
    final message = _resultMessage;
    if (message == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final neutral = _busy || _checking || _status == OnlineStatus.unknown;
    final bg = neutral
        ? scheme.secondaryContainer
        : _resultSuccess
            ? scheme.tertiaryContainer
            : scheme.errorContainer;
    final fg = neutral
        ? scheme.onSecondaryContainer
        : _resultSuccess
            ? scheme.onTertiaryContainer
            : scheme.onErrorContainer;
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Semantics(
        liveRegion: true,
        child: Card.filled(
          margin: EdgeInsets.zero,
          color: bg,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                    neutral
                        ? Icons.info_outline_rounded
                        : _resultSuccess
                            ? Icons.check_circle_outline_rounded
                            : Icons.error_outline_rounded,
                    color: fg),
                const SizedBox(width: 12),
                Expanded(
                    child: Text(message,
                        style:
                            theme.textTheme.bodyMedium?.copyWith(color: fg))),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildLogCard() {
    final theme = Theme.of(context);
    return Card.outlined(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.history_rounded, color: theme.colorScheme.primary),
                const SizedBox(width: 16),
                Expanded(
                    child: Text('最近记录', style: theme.textTheme.titleMedium)),
                if (_log.isNotEmpty)
                  TextButton(
                      onPressed: _operationActive ? null : _clearLog,
                      child: const Text('清空')),
              ],
            ),
            if (_log.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Text('暂无认证记录，完成一次认证后在此显示',
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              )
            else
              for (final entry in _log.take(8))
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                      entry.success
                          ? Icons.check_circle_outline_rounded
                          : Icons.error_outline_rounded,
                      color: entry.success
                          ? theme.colorScheme.tertiary
                          : theme.colorScheme.error,
                      semanticLabel: entry.success ? '认证成功' : '认证失败'),
                  title: Text(entry.message),
                  subtitle: Text('${_fmtTime(entry.time)} · ${entry.device}'),
                ),
          ],
        ),
      ),
    );
  }

  Widget _buildFooter() {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 24),
      child: Text(
          '请先连接校园 WiFi（未认证状态）再使用。'
          '本工具仅用于自己已购套餐的账号。',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
    );
  }
}
