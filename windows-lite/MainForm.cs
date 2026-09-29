using System.Text.Json;

namespace GiWifiLite;

internal sealed class MainForm : Form
{
    private readonly TextBox _username = new() { PlaceholderText = "校园网上网账号", Dock = DockStyle.Fill };
    private readonly TextBox _password = new() { PlaceholderText = "密码", UseSystemPasswordChar = true, Dock = DockStyle.Fill };
    private readonly TextBox _server = new() { Text = "http://100.100.9.2", Dock = DockStyle.Fill };
    private readonly ComboBox _acName = new() { Text = "GiWiFi_lnsfHG (湖光)", DropDownStyle = ComboBoxStyle.DropDown, Dock = DockStyle.Fill };
    private readonly ComboBox _profile = new() { DropDownStyle = ComboBoxStyle.DropDownList, Dock = DockStyle.Fill };
    private readonly ComboBox _adapter = new() { DropDownStyle = ComboBoxStyle.DropDownList, Dock = DockStyle.Fill, DropDownWidth = 480 };
    private readonly Button _refreshAdapters = new() { Text = "刷新", Dock = DockStyle.Fill };
    private readonly TextBox _customUa = new() { PlaceholderText = "仅自定义模式填写", Dock = DockStyle.Fill };
    private readonly CheckBox _remember = new() { Text = "在本机记住账号密码", Checked = true, AutoSize = true };
    private readonly CheckBox _autoReconnect = new() { Text = "掉线后自动重连（每 60 秒检查）", AutoSize = true };
    private readonly Button _login = new() { Text = "一键认证", Height = 42, Dock = DockStyle.Fill, UseVisualStyleBackColor = false, BackColor = Color.FromArgb(30, 90, 78), ForeColor = Color.White, FlatStyle = FlatStyle.Flat };
    private readonly Button _check = new() { Text = "检查在线状态", AutoSize = true };
    private readonly Label _status = new() { Text = "就绪 · 请先连接校园 Wi-Fi", AutoSize = false, Height = 42, Dock = DockStyle.Fill, TextAlign = ContentAlignment.MiddleLeft, ForeColor = Color.FromArgb(75, 85, 99) };
    private readonly ListBox _logs = new() { Dock = DockStyle.Fill, IntegralHeight = false };
    private readonly System.Windows.Forms.Timer _reconnectTimer = new() { Interval = 60_000 };
    private readonly string _settingsPath = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "giwifi_ua_switcher", "settings.json");
    private CancellationTokenSource? _activeCts;
    private bool _busy;
    private bool _checking;
    private bool _loadingSettings = true;
    private bool _refreshingAdapters;
    private List<LogEntry> _entries = [];
    private static readonly JsonSerializerOptions JsonOptions = new() { WriteIndented = true };

    public MainForm(string? settingsPath = null)
    {
        if (settingsPath is not null) _settingsPath = settingsPath;
        Text = "GiWiFi 轻量认证工具";
        StartPosition = FormStartPosition.CenterScreen;
        MinimumSize = new Size(540, 730);
        ClientSize = new Size(600, 800);
        Font = new Font("Microsoft YaHei UI", 9.5f);
        _customUa.Enabled = false;
        BackColor = Color.FromArgb(247, 249, 248);
        BuildUi();
        _acName.Items.AddRange(["GiWiFi_lnsfHG (湖光)", "GiWiFi_lnsf (寸金)"]);
        _profile.Items.AddRange(DeviceProfile.Presets.Cast<object>().ToArray());
        _profile.SelectedIndex = 0;
        _profile.SelectedIndexChanged += (_, _) => _customUa.Enabled = _profile.SelectedItem is DeviceProfile { Id: "custom" };
        _login.Click += async (_, _) => { if (_busy) { _activeCts?.Cancel(); return; } if (!_checking) await DoLoginAsync(); };
        _check.Click += async (_, _) => await CheckOnlineAsync();
        _autoReconnect.CheckedChanged += (_, _) => _reconnectTimer.Enabled = _autoReconnect.Checked;
        _reconnectTimer.Tick += async (_, _) => await KeepAliveTickAsync();
        _remember.CheckedChanged += (_, _) => SaveSettings();
        _adapter.Items.Add(NetworkAdapter.SystemDefault);
        _adapter.SelectedIndex = 0;
        LoadSettings();
        RefreshAdapters();
        _loadingSettings = false;
        _refreshAdapters.Click += (_, _) => RefreshAdapters();
        _adapter.SelectedIndexChanged += (_, _) =>
        {
            if (_refreshingAdapters) return;
            _status.Text = $"已选择 {SelectedAdapter}；请重新检查在线状态或认证。";
            _status.ForeColor = Color.FromArgb(75, 85, 99);
            SaveSettings();
        };
        FormClosing += (_, _) => { _reconnectTimer.Stop(); _activeCts?.Cancel(); SaveSettings(); };
    }

    private void BuildUi()
    {
        var page = new TableLayoutPanel { Dock = DockStyle.Fill, Padding = new Padding(24, 18, 24, 18), ColumnCount = 1, RowCount = 6 };
        page.RowStyles.Add(new RowStyle(SizeType.Absolute, 82));
        page.RowStyles.Add(new RowStyle(SizeType.Absolute, 398));
        page.RowStyles.Add(new RowStyle(SizeType.Absolute, 54));
        page.RowStyles.Add(new RowStyle(SizeType.Absolute, 44));
        page.RowStyles.Add(new RowStyle(SizeType.Absolute, 42));
        page.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        Controls.Add(page);

        var header = new Panel { Dock = DockStyle.Fill };
        var title = new Label { Text = "GiWiFi", Font = new Font(Font.FontFamily, 23, FontStyle.Bold), ForeColor = Color.FromArgb(26, 62, 54), AutoSize = true, Location = new Point(0, 2) };
        var subtitle = new Label { Text = "岭南师范学院 · 设备类型切换与一键认证", AutoSize = true, ForeColor = Color.FromArgb(100, 110, 107), Location = new Point(2, 47) };
        header.Controls.Add(title); header.Controls.Add(subtitle); page.Controls.Add(header, 0, 0);

        var form = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 2, RowCount = 10, Padding = new Padding(16), BackColor = Color.White, Margin = new Padding(0, 5, 0, 10) };
        form.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 112)); form.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        for (var i = 0; i < 7; i++) form.RowStyles.Add(new RowStyle(SizeType.Absolute, 38));
        form.RowStyles.Add(new RowStyle(SizeType.Absolute, 28));
        form.RowStyles.Add(new RowStyle(SizeType.Absolute, 28));
        form.RowStyles.Add(new RowStyle(SizeType.Absolute, 24));
        AddField(form, 0, "上网账号", _username);
        AddField(form, 1, "上网密码", _password);
        AddField(form, 2, "设备类型", _profile);
        AddField(form, 3, "自定义 UA", _customUa);
        AddField(form, 4, "认证服务器", _server);
        AddField(form, 5, "校园 AC 名称", _acName);
        var adapterRow = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 2, RowCount = 1, Margin = Padding.Empty };
        _adapter.Margin = Padding.Empty;
        _refreshAdapters.Margin = new Padding(4, 0, 0, 0);
        adapterRow.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        adapterRow.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 60));
        adapterRow.Controls.Add(_adapter, 0, 0); adapterRow.Controls.Add(_refreshAdapters, 1, 0);
        AddField(form, 6, "认证网卡", adapterRow);
        form.Controls.Add(_remember, 1, 7); form.Controls.Add(_autoReconnect, 1, 8);
        var note = new Label { Text = "账号密码仅在勾选时保存在本机 AppData 配置中。", AutoSize = true, ForeColor = Color.Gray, Anchor = AnchorStyles.Left };
        form.Controls.Add(note, 1, 9);
        page.Controls.Add(form, 0, 1);

        page.Controls.Add(_login, 0, 2);
        page.Controls.Add(_status, 0, 3);
        var actions = new FlowLayoutPanel { Dock = DockStyle.Fill, FlowDirection = FlowDirection.LeftToRight, Padding = new Padding(0, 5, 0, 0) };
        actions.Controls.Add(_check);
        var clear = new Button { Text = "清空日志", AutoSize = true };
        clear.Click += (_, _) => { _entries.Clear(); RenderLogs(); SaveSettings(); };
        actions.Controls.Add(clear); page.Controls.Add(actions, 0, 4);

        var historyPanel = new TableLayoutPanel { Dock = DockStyle.Fill, RowCount = 2, ColumnCount = 1 };
        historyPanel.RowStyles.Add(new RowStyle(SizeType.Absolute, 36)); historyPanel.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        historyPanel.Controls.Add(new Label { Text = "最近认证记录", Font = new Font(Font, FontStyle.Bold), AutoSize = true, TextAlign = ContentAlignment.MiddleLeft, Dock = DockStyle.Fill }, 0, 0);
        historyPanel.Controls.Add(_logs, 0, 1); page.Controls.Add(historyPanel, 0, 5);
    }

    private static void AddField(TableLayoutPanel panel, int row, string label, Control control)
    {
        panel.Controls.Add(new Label { Text = label, AutoSize = true, Anchor = AnchorStyles.Left, ForeColor = Color.FromArgb(74, 85, 81) }, 0, row);
        control.Margin = new Padding(3, 5, 3, 5);
        panel.Controls.Add(control, 1, row);
    }

    private string CurrentUserAgent()
    {
        if (_profile.SelectedItem is not DeviceProfile profile) return "";
        return profile.Id == "custom" ? _customUa.Text.Trim() : profile.UserAgent;
    }

    private NetworkAdapter SelectedAdapter => _adapter.SelectedItem as NetworkAdapter ?? NetworkAdapter.SystemDefault;

    private void RefreshAdapters()
    {
        if (_busy || _checking) return;
        var previous = SelectedAdapter;
        try
        {
            var available = NetworkAdapter.ListAvailable();
            var selected = previous.Id.Length == 0 ? NetworkAdapter.SystemDefault
                : available.FirstOrDefault(a => a.Id == previous.Id && a.Address == previous.Address)
                    ?? available.FirstOrDefault(a => a.Id == previous.Id)
                    ?? previous with { InterfaceIndex = -1 };
            _refreshingAdapters = true;
            _adapter.Items.Clear();
            _adapter.Items.Add(NetworkAdapter.SystemDefault);
            _adapter.Items.AddRange(available.Cast<object>().ToArray());
            if (selected.InterfaceIndex < 0) _adapter.Items.Add(selected);
            _adapter.SelectedItem = selected;
            _status.Text = selected.InterfaceIndex < 0 ? "所选网卡不可用，请连接后刷新或手动选择其他网卡。" : $"当前认证网卡：{selected}；待检查。";
            _status.ForeColor = selected.InterfaceIndex < 0 ? Color.Firebrick : Color.FromArgb(75, 85, 99);
            SaveSettings();
        }
        catch (Exception ex) { _status.Text = "刷新网卡失败：" + ex.Message; }
        finally { _refreshingAdapters = false; }
    }

    // Campus labels are presentation only; settings and authentication use raw AC names.
    private string AcNameValue => _acName.Text.Trim() switch
    {
        "GiWiFi_lnsfHG (湖光)" => "GiWiFi_lnsfHG",
        "GiWiFi_lnsf (寸金)" => "GiWiFi_lnsf",
        var custom => custom,
    };

    private AuthClient CreateClient(CancellationToken ct)
    {
        var adapter = SelectedAdapter;
        return new AuthClient(_server.Text, ct, AcNameValue, adapter.Id, adapter.Address);
    }

    private void UpdateOperationControls()
    {
        var idle = !_busy && !_checking;
        foreach (var control in new Control[] { _adapter, _refreshAdapters, _profile, _server, _acName, _username, _password }) control.Enabled = idle;
        _customUa.Enabled = idle && _profile.SelectedItem is DeviceProfile { Id: "custom" };
        _check.Enabled = idle;
        _login.Enabled = _busy || !_checking;
        _login.Text = _busy ? "停止认证" : "一键认证";
    }

    private async Task DoLoginAsync()
    {
        var username = _username.Text.Trim();
        var password = _password.Text;
        var ua = CurrentUserAgent();
        if (username.Length == 0 || password.Length == 0) { MessageBox.Show(this, "请填写上网账号和密码。", "信息不完整", MessageBoxButtons.OK, MessageBoxIcon.Information); return; }
        if (ua.Length == 0) { MessageBox.Show(this, "请选择设备类型；自定义模式需要填写 User-Agent。", "信息不完整", MessageBoxButtons.OK, MessageBoxIcon.Information); return; }
        SaveSettings();
        _busy = true; _login.Text = "停止认证"; _status.ForeColor = Color.FromArgb(30, 90, 78);
        _activeCts = new CancellationTokenSource();
        UpdateOperationControls();
        LoginResult result;
        try
        {
            using var client = CreateClient(_activeCts.Token);
            result = await client.LoginAsync(username, password, ua,
                info => MessageBox.Show(this, info, "确认更换绑定设备", MessageBoxButtons.OKCancel, MessageBoxIcon.Warning) == DialogResult.OK,
                () => MessageBox.Show(this, "当前设备已在线。是否先下线，再按所选设备类型重新认证？", "当前设备已在线", MessageBoxButtons.YesNo, MessageBoxIcon.Question) == DialogResult.Yes,
                message => _status.Text = message);
        }
        catch (OperationCanceledException) { result = new(false, "认证已停止"); }
        catch (Exception ex) { result = new(false, FriendlyError(ex)); }
        finally { _busy = false; _activeCts?.Dispose(); _activeCts = null; UpdateOperationControls(); }
        _status.Text = result.Message;
        _status.ForeColor = result.Success ? Color.FromArgb(22, 125, 79) : Color.FromArgb(172, 54, 49);
        var label = $"{(_profile.SelectedItem as DeviceProfile)?.Label ?? "设备"} / {SelectedAdapter}";
        _entries.Insert(0, new(DateTime.Now, label, result.Success, result.Message));
        _entries = _entries.Take(50).ToList(); RenderLogs(); SaveSettings();
    }

    private async Task CheckOnlineAsync()
    {
        if (_busy || _checking) return;
        var ua = CurrentUserAgent();
        if (ua.Length == 0) { _status.Text = "请先选择有效的设备 User-Agent"; return; }
        _checking = true; _check.Enabled = false; _status.Text = "正在检查在线状态…";
        UpdateOperationControls();
        using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(15));
        _activeCts = cts;
        try
        {
            using var client = CreateClient(cts.Token);
            var state = await client.CheckOnlineAsync(ua);
            _status.Text = state switch { PortalStatus.Online => "当前设备已在线", PortalStatus.Offline => "当前设备未认证（离线）", _ => "状态未知（请确认已连接校园网）" };
            _status.ForeColor = state == PortalStatus.Online ? Color.FromArgb(22, 125, 79) : Color.FromArgb(90, 100, 97);
        }
        catch (Exception ex) { _status.Text = FriendlyError(ex); _status.ForeColor = Color.Firebrick; }
        finally { _activeCts = null; _checking = false; UpdateOperationControls(); }
    }

    private async Task KeepAliveTickAsync()
    {
        if (_busy || _checking) return;
        _checking = true;
        UpdateOperationControls();
        using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(15));
        _activeCts = cts;
        try
        {
            using var client = CreateClient(cts.Token);
            var state = await client.CheckOnlineAsync(CurrentUserAgent());
            if (state == PortalStatus.Offline) { _status.Text = "检测到掉线，正在自动重连…"; await DoLoginAsync(); }
        }
        catch (Exception ex) { _status.Text = FriendlyError(ex); _status.ForeColor = Color.Firebrick; }
        finally { _activeCts = null; _checking = false; UpdateOperationControls(); }
    }

    private void LoadSettings()
    {
        try
        {
            if (!File.Exists(_settingsPath)) return;
            using var doc = JsonDocument.Parse(File.ReadAllText(_settingsPath));
            var root = doc.RootElement;
            string GetString(string key, string fallback = "") => root.TryGetProperty(key, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() ?? fallback : fallback;
            _username.Text = GetString("username"); _password.Text = GetString("password");
            _server.Text = GetString("server_url", "http://100.100.9.2"); _customUa.Text = GetString("custom_ua");
            _acName.Text = GetString("wlan_ac_name", "GiWiFi_lnsfHG") switch
            {
                "GiWiFi_lnsfHG" => "GiWiFi_lnsfHG (湖光)",
                "GiWiFi_lnsf" => "GiWiFi_lnsf (寸金)",
                var custom => custom,
            };
            var adapterId = GetString("network_adapter_id");
            if (adapterId.Length > 0)
            {
                var savedAdapter = new NetworkAdapter(adapterId, GetString("network_adapter_name", "已保存的网卡"), GetString("network_adapter_address"), -1);
                _adapter.Items.Add(savedAdapter); _adapter.SelectedItem = savedAdapter;
            }
            _remember.Checked = !root.TryGetProperty("remember", out var r) || r.ValueKind != JsonValueKind.False;
            var profileId = GetString("profile_id", "pc");
            var index = Array.FindIndex(DeviceProfile.Presets, p => p.Id == profileId);
            _profile.SelectedIndex = index < 0 ? 0 : index;
            _autoReconnect.Checked = root.TryGetProperty("auto_reconnect", out var ar) && ar.ValueKind == JsonValueKind.True;
            if (root.TryGetProperty("log", out var log) && log.ValueKind == JsonValueKind.Array)
                _entries = log.EnumerateArray().Select(e => new LogEntry(DateTimeOffset.FromUnixTimeMilliseconds(e.GetProperty("time").GetInt64()).LocalDateTime, e.GetProperty("device").GetString() ?? "", e.GetProperty("success").GetBoolean(), e.GetProperty("message").GetString() ?? "")).Take(50).ToList();
        }
        catch { _entries = []; }
        RenderLogs();
    }

    private void SaveSettings()
    {
        if (_loadingSettings) return;
        try
        {
            var directory = Path.GetDirectoryName(_settingsPath)!;
            Directory.CreateDirectory(directory);
            var profile = _profile.SelectedItem as DeviceProfile ?? DeviceProfile.Presets[0];
            var settings = new Settings(_remember.Checked ? _username.Text.Trim() : "", _remember.Checked ? _password.Text : "", AuthClient.NormalizeBaseUrl(_server.Text), profile.Id, _customUa.Text, AcNameValue, _remember.Checked, _autoReconnect.Checked, _entries.Select(e => new StoredLog(new DateTimeOffset(e.Time).ToUnixTimeMilliseconds(), e.Device, e.Success, e.Message)).ToList());
            Dictionary<string, object?> values = settings;
            values["network_adapter_id"] = SelectedAdapter.Id;
            values["network_adapter_name"] = SelectedAdapter.Name;
            values["network_adapter_address"] = SelectedAdapter.Address;
            File.WriteAllText(_settingsPath, JsonSerializer.Serialize(values, JsonOptions));
        }
        catch { }
    }

    private void RenderLogs()
    {
        _logs.BeginUpdate(); _logs.Items.Clear();
        foreach (var entry in _entries) _logs.Items.Add($"{entry.Time:MM-dd HH:mm:ss}  {(entry.Success ? "✓" : "·")}  {entry.Device}  {entry.Message}");
        _logs.EndUpdate();
    }

    private static string FriendlyError(Exception ex) => ex switch
    {
        HttpRequestException => "当前认证网卡连接服务器失败，请确认所选网卡已连接校园网、IPv4 地址未变化且服务器地址正确。",
        TaskCanceledException => "请求超时，请确认已连接校园 Wi-Fi 后重试。",
        _ => ex.Message
    };

    private sealed record Settings(string Username, string Password, string ServerUrl, string ProfileId, string CustomUa, string WlanAcName, bool Remember, bool AutoReconnect, List<StoredLog> Log)
    {
        public static implicit operator Dictionary<string, object?>(Settings s) => new()
        {
            ["username"] = s.Username, ["password"] = s.Password, ["server_url"] = s.ServerUrl,
            ["profile_id"] = s.ProfileId, ["custom_ua"] = s.CustomUa, ["wlan_ac_name"] = s.WlanAcName, ["remember"] = s.Remember,
            ["auto_reconnect"] = s.AutoReconnect, ["log"] = s.Log.Select(x => new { time = x.Time, device = x.Device, success = x.Success, message = x.Message })
        };
    }
    private sealed record StoredLog(long Time, string Device, bool Success, string Message);
    private sealed record LogEntry(DateTime Time, string Device, bool Success, string Message);
}
