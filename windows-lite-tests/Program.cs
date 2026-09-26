using GiWifiLite;
using System.Net;
using System.Net.Sockets;
using System.Text;

// No external test packages. A failed assertion produces a nonzero exit code.
var passed = 0;
void Assert(bool condition, string name)
{
    if (!condition) throw new Exception("FAIL: " + name);
    Console.WriteLine("PASS: " + name);
    passed++;
}
void Reject(Action action, string name)
{
    try { action(); }
    catch (InvalidOperationException) { Assert(true, name); return; }
    throw new Exception("FAIL: " + name);
}

Reject(() => { using var client = new AuthClient("http://127.0.0.1", CancellationToken.None, "test", "missing-adapter", "192.0.2.1"); }, "unavailable adapter never falls back to default");
var first = new NetworkAdapter("first", "Wi-Fi", "192.0.2.1", 11);
var second = new NetworkAdapter("second", "Ethernet", "192.0.2.1", 12);
Assert(NetworkAdapter.Resolve("", "", []) is null, "old settings use system default");
Assert(NetworkAdapter.Resolve("first", first.Address, [second, first]) == first, "adapter identity distinguishes identical IP addresses");
Reject(() => NetworkAdapter.Resolve("first", first.Address, [second]), "another adapter with the same IP cannot substitute");
Reject(() => NetworkAdapter.Resolve("first", "192.0.2.2", [first]), "stale DHCP address requires refresh");

var available = NetworkAdapter.ListAvailable();
if (available.Count == 0)
{
    Console.WriteLine("SKIP: bound HTTP integration requires an active IPv4 adapter.");
}
else
{
    var adapter = available[0];
    using (var socket = adapter.CreateBoundSocket())
    {
        Assert(((IPEndPoint)socket.LocalEndPoint!).Address.Equals(IPAddress.Parse(adapter.Address)), "socket binds selected source IPv4");
        Assert((int)socket.GetSocketOption(SocketOptionLevel.IP, NetworkAdapter.IpUnicastInterface)! == adapter.InterfaceIndex, "socket uses selected Windows outgoing interface");
    }
    Reject(() => (adapter with { InterfaceIndex = int.MaxValue }).Validate(), "changed interface index is rejected");

    using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(15));
    using var listener = new TcpListener(IPAddress.Parse(adapter.Address), 0);
    listener.Start();
    var endpoint = (IPEndPoint)listener.LocalEndpoint;
    var requests = new List<string>();
    var sourceAddresses = new List<IPAddress>();
    var server = Task.Run(async () =>
    {
        for (var i = 0; i < 4; i++)
        {
            using var connection = await listener.AcceptTcpClientAsync(timeout.Token);
            sourceAddresses.Add(((IPEndPoint)connection.Client.RemoteEndPoint!).Address);
            using var stream = connection.GetStream();
            using var reader = new StreamReader(stream, Encoding.ASCII, leaveOpen: true);
            var headers = new StringBuilder();
            while (await reader.ReadLineAsync(timeout.Token) is { Length: > 0 } line) headers.AppendLine(line);
            requests.Add(headers.ToString());
            var body = "<input name=\"si\" value=\"test-session\">";
            var response = i == 0
                ? "HTTP/1.1 302 Found\r\nLocation: /redirected\r\nSet-Cookie: session=test; Path=/\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                : $"HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: {Encoding.UTF8.GetByteCount(body)}\r\nConnection: close\r\n\r\n{body}";
            await stream.WriteAsync(Encoding.UTF8.GetBytes(response), timeout.Token);
        }
    }, timeout.Token);
    var url = $"http://{endpoint.Address}:{endpoint.Port}";
    using (var client = new AuthClient(url, timeout.Token, "test", adapter.Id, adapter.Address))
    {
        Assert(await client.CheckOnlineAsync("test-agent") == PortalStatus.Online, "bound portal status follows redirect");
        Assert(await client.CheckOnlineAsync("test-agent") == PortalStatus.Online, "same session can check again");
    }
    using (var client = new AuthClient(url, timeout.Token, "test", adapter.Id, adapter.Address))
        Assert(await client.CheckOnlineAsync("test-agent") == PortalStatus.Online, "new operation creates a fresh session");
    await server.WaitAsync(timeout.Token);
    Assert(sourceAddresses.All(ip => ip.Equals(endpoint.Address)), "all HTTP requests and redirects use selected source IPv4");
    Assert(requests[1].Contains("Cookie: session=test") && requests[2].Contains("Cookie: session=test"), "cookies persist within one authentication session");
    Assert(!requests[3].Contains("Cookie:", StringComparison.OrdinalIgnoreCase), "cookies do not leak to the next operation");

    using var cancelled = new CancellationTokenSource();
    cancelled.Cancel();
    using var cancelledClient = new AuthClient(url, cancelled.Token, "test", adapter.Id, adapter.Address);
    try
    {
        await cancelledClient.CheckOnlineAsync("test-agent");
        throw new Exception("FAIL: cancellation must interrupt requests");
    }
    catch (OperationCanceledException) { Assert(true, "cancellation interrupts bound requests"); }
}
Console.WriteLine($"{passed} checks passed.");
UiChecks.Run();
