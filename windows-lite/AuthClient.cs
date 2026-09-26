using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace GiWifiLite;

internal enum PortalStatus { Online, Offline, Unknown }

internal sealed record DeviceProfile(string Id, string Label, string UserAgent)
{
    public override string ToString() => Label;

    public static readonly DeviceProfile[] Presets =
    [
        new("pc", "电脑", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"),
        new("android_phone", "安卓手机", "Mozilla/5.0 (Linux; Android 14; 24031PN0DC) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Mobile Safari/537.36"),
        new("iphone", "iPhone", "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1"),
        new("ipad", "iPad", "Mozilla/5.0 (iPad; CPU OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1"),
        new("android_tablet", "安卓平板", "Mozilla/5.0 (Linux; Android 14; SM-X710) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"),
        new("custom", "自定义 UA", "")
    ];
}

internal sealed record LoginResult(bool Success, string Message, bool NeedsRebind = false, string? RebindUrl = null, string? RedirectUrl = null, bool AlreadyOnline = false);

/// <summary>GiWiFi portal protocol: hidden form extraction, ordered form serialization, AES-128-CBC/ZeroPadding and portal state handling.</summary>
internal sealed class AuthClient : IDisposable
{
    private const string Key = "1234567887654321";
    private const string LoginPath = "/gportal/web/login";
    private const string LogoutPath = "/gportal/web/logout";
    private const string LoginAction = "/gportal/Web/loginAction";
    private const string LogoutAction = "/gportal/Web/logoutAction";
    private static readonly string[] FormOrder = ["sign", "sta_vlan", "sta_port", "sta_ip", "nas_ip", "nas_name", "last_url", "request_ip", "device_mode", "device_type", "device_os_type", "is_mobile", "iv", "login_type", "account_type", "user_account", "user_password"];
    private readonly HttpClient _http;
    private readonly CookieContainer _cookies = new();
    private readonly CancellationToken _ct;
    private string _baseUrl;
    private readonly string _wlanAcName;
    private readonly NetworkAdapter? _networkAdapter;

    public AuthClient(string baseUrl, CancellationToken ct, string wlanAcName = "GiWiFi_lnsfHG", string networkAdapterId = "", string networkAddress = "")
    {
        _baseUrl = NormalizeBaseUrl(baseUrl);
        _wlanAcName = wlanAcName.Trim();
        _ct = ct;
        _networkAdapter = string.IsNullOrEmpty(networkAdapterId) ? null : NetworkAdapter.Resolve(networkAdapterId, networkAddress, NetworkAdapter.ListAvailable());
        var handler = new SocketsHttpHandler { CookieContainer = _cookies, UseCookies = true, AllowAutoRedirect = true, MaxAutomaticRedirections = 5 };
        if (_networkAdapter is not null)
        {
            handler.UseProxy = false;
            handler.ConnectCallback = _networkAdapter.ConnectAsync;
        }
        _http = new HttpClient(handler) { Timeout = TimeSpan.FromSeconds(12) };
    }

    public static string NormalizeBaseUrl(string value)
    {
        if (!value.Contains("://", StringComparison.Ordinal)) value = "http://" + value;
        return value.Trim().TrimEnd('/');
    }

    public async Task<LoginResult> LoginAsync(string username, string password, string userAgent, Func<string, bool> confirmRebind, Func<bool> confirmSwitch, Action<string> progress)
    {
        var rebindDone = false;
        for (var round = 1; round <= 6; round++)
        {
            _ct.ThrowIfCancellationRequested();
            progress(round == 1 ? "正在提交认证…" : $"正在重新提交认证（第 {round} 次）…");
            var result = await SubmitLoginAsync(username, password, userAgent);
            if (result.AlreadyOnline)
            {
                if (!confirmSwitch()) return new(false, "当前设备已在线，已取消切换（未验证账号密码）");
                progress("正在注销当前在线设备…");
                if (!await LogoutAsync(userAgent)) return new(false, "注销失败，无法切换设备；请先在网页端手动下线后重试");
                progress("已下线，等待 6 秒后重新认证…");
                await Task.Delay(TimeSpan.FromSeconds(6), _ct);
                continue;
            }
            if (result.Success)
            {
                progress("服务器返回成功，正在等待设备上线…");
                var verified = false;
                for (var i = 0; i < 6; i++)
                {
                    try
                    {
                        var html = await GetTextAsync(_baseUrl + LogoutPath, userAgent);
                        if (HasPasswordInput(html)) return new(false, "服务器提示成功，但设备仍未上线，请核对账号密码后重试");
                        if (HasNamedInput(html, "si")) { verified = true; break; }
                    }
                    catch (OperationCanceledException) { throw; }
                    catch { }
                    if (i < 5) await Task.Delay(TimeSpan.FromSeconds(2), _ct);
                }
                if (!verified) return new(false, "服务器提示成功，但设备未检测到在线，请核对账号密码后重试");
                var duration = await FetchDurationAsync(userAgent);
                return new(true, duration is null ? "认证成功" : $"认证成功，当前在线时长 {duration}");
            }
            if (result.NeedsRebind)
            {
                if (rebindDone) { progress("换绑后仍需确认，等待 8 秒后重试…"); await Task.Delay(TimeSpan.FromSeconds(8), _ct); continue; }
                if (!confirmRebind(result.Message)) return new(false, "已取消换绑，认证未完成");
                progress("正在提交换绑确认…");
                await PostTextAsync(Resolve(result.RebindUrl ?? ""), userAgent, "");
                rebindDone = true;
                progress("换绑已提交，等待 6 秒冷却后自动再次认证…");
                await Task.Delay(TimeSpan.FromSeconds(6), _ct);
                continue;
            }
            if (!string.IsNullOrWhiteSpace(result.RedirectUrl))
            {
                progress("服务器要求跳转页面，正在处理…");
                try { await GetTextAsync(Resolve(result.RedirectUrl), userAgent); } catch (OperationCanceledException) { throw; } catch { }
                await Task.Delay(TimeSpan.FromSeconds(2), _ct);
                continue;
            }
            return result;
        }
        return new(false, "多次尝试仍未成功，请稍后重试");
    }

    private async Task<LoginResult> SubmitLoginAsync(string username, string password, string ua)
    {
        var html = await FetchLoginPageAsync(ua);
        if (!HasPasswordInput(html))
        {
            if (await HasActiveSessionAsync(ua)) return new(false, "当前设备已在线", AlreadyOnline: true);
            return new(false, "响应不是登录页。请确认已连接当前校区 Wi-Fi，并核对“校园 AC 名称”与门户地址中的 wlanacname 一致。");
        }
        if (await HasActiveSessionAsync(ua)) return new(false, "当前设备已在线", AlreadyOnline: true);
        var hidden = ParseHiddenInputs(html);
        string V(string name, string fallback = "") => hidden.GetValueOrDefault(name, fallback);
        var iv = V("iv");
        var sign = V("sign");
        if (iv.Length == 0 || sign.Length == 0) return new(false, $"登录页缺少 {(iv.Length == 0 ? "iv" : "sign")} 参数，门户页面结构可能已变化");
        var fields = new Dictionary<string, string>
        {
            ["sign"] = sign, ["sta_vlan"] = V("sta_vlan"), ["sta_port"] = V("sta_port"), ["sta_ip"] = V("sta_ip"),
            ["nas_ip"] = V("nas_ip"), ["nas_name"] = V("nas_name"), ["last_url"] = V("last_url"), ["request_ip"] = V("request_ip"),
            ["device_mode"] = V("device_mode"), ["device_type"] = V("device_type", "1"), ["device_os_type"] = V("device_os_type", "3"),
            ["is_mobile"] = V("is_mobile", "0"), ["iv"] = iv, ["login_type"] = V("login_type", "1"),
            ["account_type"] = "2", ["user_account"] = username, ["user_password"] = password
        };
        var form = string.Join("&", FormOrder.Select(k => Encode(k) + "=" + Encode(fields.GetValueOrDefault(k, ""))));
        var encrypted = EncryptAes(form, Key, iv);
        var body = "data=" + Encode(encrypted) + "&iv=" + Encode(iv);
        return ParseLoginResponse(await PostTextAsync(_baseUrl + LoginAction, ua, body));
    }

    private async Task<string> FetchLoginPageAsync(string ua)
    {
        var acName = Uri.EscapeDataString(_wlanAcName);
        var urls = new[]
        {
            _baseUrl + LoginPath + "?wlanacname=" + acName,
            _baseUrl + LoginPath + "?wlanacname=" + acName + "&is_mobile=1&pagetype=login&logintype=1",
            _baseUrl + LoginPath,
            _baseUrl + LoginPath + "?is_mobile=1&pagetype=login&logintype=1",
            _baseUrl + LoginPath + "?wlanuserip=10.0.0.1&wlanacname=GiWiFi"
        };
        string? firstPage = null;
        Exception? lastError = null;
        foreach (var url in urls)
        {
            try { var html = await GetTextAsync(url, ua); firstPage ??= html; if (HasPasswordInput(html)) return html; }
            catch (OperationCanceledException) { throw; }
            catch (Exception ex) { lastError = ex; }
        }
        if (firstPage is not null) return firstPage;
        throw lastError ?? new HttpRequestException("无法连接认证服务器");
    }

    public async Task<PortalStatus> CheckOnlineAsync(string ua)
    {
        _networkAdapter?.Validate();
        try { var html = await GetTextAsync(_baseUrl + LogoutPath, ua); return HasNamedInput(html, "si") ? PortalStatus.Online : HasPasswordInput(html) ? PortalStatus.Offline : PortalStatus.Unknown; }
        catch (OperationCanceledException) { throw; }
        catch (InvalidOperationException) { throw; }
        catch { return PortalStatus.Unknown; }
    }

    public async Task<bool> LogoutAsync(string ua)
    {
        var html = await GetTextAsync(_baseUrl + LogoutPath, ua);
        var si = ParseHiddenInputs(html).GetValueOrDefault("si", "");
        if (si.Length == 0) return false;
        using var response = await SendAsync(HttpMethod.Post, _baseUrl + LogoutAction, ua, "si=" + Encode(si));
        using var doc = JsonDocument.Parse(await response.Content.ReadAsStringAsync(_ct));
        return doc.RootElement.TryGetProperty("status", out var status) && status.ToString() == "1";
    }

    private async Task<bool> HasActiveSessionAsync(string ua)
    {
        try { return HasNamedInput(await GetTextAsync(_baseUrl + LogoutPath, ua), "si"); }
        catch (OperationCanceledException) { throw; }
        catch { return false; }
    }

    private async Task<string?> FetchDurationAsync(string ua)
    {
        try
        {
            var html = await GetTextAsync(_baseUrl + LogoutPath, ua);
            var match = Regex.Match(html, "data-timestamp=[\\\"']?(\\d{10})", RegexOptions.IgnoreCase);
            if (!match.Success) match = Regex.Match(html, "start\\s*=\\s*[\\\"']?(\\d{10})", RegexOptions.IgnoreCase);
            if (!match.Success || !long.TryParse(match.Groups[1].Value, out var seconds)) return null;
            var elapsed = DateTimeOffset.UtcNow - DateTimeOffset.FromUnixTimeSeconds(seconds);
            if (elapsed < TimeSpan.Zero) return null;
            return $"{(int)elapsed.TotalHours:00}:{elapsed.Minutes:00}:{elapsed.Seconds:00}";
        }
        catch { return null; }
    }

    private LoginResult ParseLoginResponse(string body)
    {
        try
        {
            using var doc = JsonDocument.Parse(body);
            var root = doc.RootElement;
            var status = root.TryGetProperty("status", out var s) ? s.ToString() : "";
            var info = root.TryGetProperty("info", out var i) ? i.ToString() : "未知响应";
            if (status == "1") return new(true, info);
            if (root.TryGetProperty("data", out var data) && data.ValueKind == JsonValueKind.Object)
            {
                var code = data.TryGetProperty("resultCode", out var c) ? c.ToString() : "";
                var resultData = data.TryGetProperty("resultData", out var rd) ? rd.ToString() : null;
                if (code == "124") return new(false, info, NeedsRebind: true, RebindUrl: resultData);
                if (code == "40") return new(false, info, RedirectUrl: resultData);
                if (code == "114") return new(false, "账号需要先设置密码，请到网页端操作：" + info);
                if (code == "152") return new(false, "账号需要修改密码，请到网页端操作：" + info);
            }
            return new(false, info);
        }
        catch (JsonException) { return new(false, "服务器响应解析失败：" + body[..Math.Min(120, body.Length)]); }
    }

    private async Task<string> GetTextAsync(string url, string ua)
    {
        using var response = await SendAsync(HttpMethod.Get, url, ua);
        var bytes = await response.Content.ReadAsByteArrayAsync(_ct);
        return DecodeResponse(bytes, response.Content.Headers.ContentType?.CharSet);
    }

    private async Task<string> PostTextAsync(string url, string ua, string body)
    {
        using var response = await SendAsync(HttpMethod.Post, url, ua, body);
        var bytes = await response.Content.ReadAsByteArrayAsync(_ct);
        return DecodeResponse(bytes, response.Content.Headers.ContentType?.CharSet);
    }

    private async Task<HttpResponseMessage> SendAsync(HttpMethod method, string url, string ua, string? body = null)
    {
        _ct.ThrowIfCancellationRequested();
        _networkAdapter?.Validate();
        using var request = new HttpRequestMessage(method, url);
        request.Headers.TryAddWithoutValidation("User-Agent", ua);
        request.Headers.TryAddWithoutValidation("X-Requested-With", "XMLHttpRequest");
        request.Headers.TryAddWithoutValidation("Accept", "text/html,application/xhtml+xml,application/json, text/javascript, */*; q=0.01");
        if (body is not null) request.Content = new StringContent(body, Encoding.UTF8, "application/x-www-form-urlencoded");
        var response = await _http.SendAsync(request, HttpCompletionOption.ResponseContentRead, _ct);
        response.EnsureSuccessStatusCode();
        return response;
    }

    private string Resolve(string pathOrUrl) => Uri.TryCreate(pathOrUrl, UriKind.Absolute, out var uri) ? uri.ToString() : new Uri(new Uri(_baseUrl + "/"), pathOrUrl.TrimStart('/')).ToString();
    // Match Dart Uri.encodeComponent used by the original Flutter client.
    private static string Encode(string value)
    {
        var bytes = Encoding.UTF8.GetBytes(value);
        var output = new StringBuilder(bytes.Length);
        foreach (var b in bytes)
        {
            var safe = b is >= (byte)'A' and <= (byte)'Z'
                or >= (byte)'a' and <= (byte)'z'
                or >= (byte)'0' and <= (byte)'9'
                or (byte)'-' or (byte)'_' or (byte)'.' or (byte)'!' or (byte)'~'
                or (byte)'*' or (byte)'\'' or (byte)'(' or (byte)')';
            if (safe) output.Append((char)b);
            else output.Append('%').Append(b.ToString("X2"));
        }
        return output.ToString();
    }
    private static string DecodeResponse(byte[] bytes, string? charset)
    {
        try { if (!string.IsNullOrWhiteSpace(charset)) return Encoding.GetEncoding(charset.Trim('"', '\'')).GetString(bytes); } catch { }
        return Encoding.UTF8.GetString(bytes);
    }
    private static bool HasPasswordInput(string html) => Regex.IsMatch(html, "type\\s*=\\s*[\\\"']?password", RegexOptions.IgnoreCase);
    private static bool HasNamedInput(string html, string name) => Regex.IsMatch(html, "name\\s*=\\s*[\\\"']?" + Regex.Escape(name) + "[\\\"'\\s>]", RegexOptions.IgnoreCase);
    private static Dictionary<string, string> ParseHiddenInputs(string html)
    {
        var result = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (Match input in Regex.Matches(html, "<input\\b[^>]*>", RegexOptions.IgnoreCase))
        {
            var tag = input.Value;
            var type = ReadAttribute(tag, "type");
            if (!string.Equals(type, "hidden", StringComparison.OrdinalIgnoreCase)) continue;
            var name = ReadAttribute(tag, "name");
            if (!string.IsNullOrEmpty(name)) result[name] = WebUtility.HtmlDecode(ReadAttribute(tag, "value") ?? "");
        }
        return result;
    }
    private static string? ReadAttribute(string tag, string name)
    {
        var m = Regex.Match(tag, "(?:^|\\s)" + Regex.Escape(name) + "\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s>]+))", RegexOptions.IgnoreCase);
        return !m.Success ? null : m.Groups[1].Success ? m.Groups[1].Value : m.Groups[2].Success ? m.Groups[2].Value : m.Groups[3].Value;
    }

    private static string EncryptAes(string plaintext, string key, string iv)
    {
        var input = Encoding.UTF8.GetBytes(plaintext);
        var padded = new byte[(input.Length + 15) / 16 * 16];
        input.CopyTo(padded, 0);
        using var aes = Aes.Create();
        aes.Key = Encoding.UTF8.GetBytes(key);
        aes.IV = Encoding.UTF8.GetBytes(iv);
        aes.Mode = CipherMode.CBC;
        aes.Padding = PaddingMode.None;
        using var encryptor = aes.CreateEncryptor();
        return Convert.ToBase64String(encryptor.TransformFinalBlock(padded, 0, padded.Length));
    }

    public void Dispose() => _http.Dispose();
}
