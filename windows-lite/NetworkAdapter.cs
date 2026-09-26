using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;

namespace GiWifiLite;

internal sealed record NetworkAdapter(string Id, string Name, string Address, int InterfaceIndex)
{
    internal const SocketOptionName IpUnicastInterface = (SocketOptionName)31;
    public static readonly NetworkAdapter SystemDefault = new("", "系统默认", "", 0);
    public override string ToString() => Id.Length == 0 ? Name : $"{Name} · {Address}{(InterfaceIndex < 0 ? "（不可用）" : "")}";

    public static List<NetworkAdapter> ListAvailable()
    {
        var result = new List<NetworkAdapter>();
        foreach (var adapter in NetworkInterface.GetAllNetworkInterfaces())
        {
            if (adapter.OperationalStatus != OperationalStatus.Up || adapter.NetworkInterfaceType == NetworkInterfaceType.Loopback) continue;
            try
            {
                var properties = adapter.GetIPProperties();
                var index = properties.GetIPv4Properties()?.Index;
                if (index is null or <= 0) continue;
                foreach (var unicast in properties.UnicastAddresses)
                {
                    var address = unicast.Address;
                    if (address.AddressFamily != AddressFamily.InterNetwork || IPAddress.IsLoopback(address) || address.Equals(IPAddress.Any)) continue;
                    if (unicast.DuplicateAddressDetectionState != DuplicateAddressDetectionState.Preferred) continue;
                    result.Add(new(adapter.Id, adapter.Name, address.ToString(), index.Value));
                }
            }
            catch (NetworkInformationException) { /* Adapter may disappear during enumeration. */ }
        }
        return result.OrderBy(a => a.Name).ThenBy(a => a.Address, StringComparer.Ordinal).ToList();
    }

    public static NetworkAdapter? Resolve(string id, string address, IEnumerable<NetworkAdapter> available)
    {
        if (string.IsNullOrEmpty(id)) return null;
        return available.FirstOrDefault(a => a.Id == id && a.Address == address && a.InterfaceIndex > 0)
            ?? throw new InvalidOperationException("所选网卡已断开或 IPv4 地址已变化，请连接校园网后刷新网卡并重新选择。不会自动改用其他网卡。");
    }

    public void Validate()
    {
        var current = Resolve(Id, Address, ListAvailable());
        if (current?.InterfaceIndex != InterfaceIndex)
            throw new InvalidOperationException("所选网卡接口已变化，请刷新网卡后重试。");
    }

    internal Socket CreateBoundSocket()
    {
        var socket = new Socket(AddressFamily.InterNetwork, SocketType.Stream, ProtocolType.Tcp) { NoDelay = true };
        try
        {
            // Windows IP_UNICAST_IF expects the interface index in network byte order.
            // https://learn.microsoft.com/windows/win32/winsock/ipproto-ip-socket-options
            socket.SetSocketOption(SocketOptionLevel.IP, IpUnicastInterface, IPAddress.HostToNetworkOrder(InterfaceIndex));
            socket.Bind(new IPEndPoint(IPAddress.Parse(Address), 0));
            return socket;
        }
        catch { socket.Dispose(); throw; }
    }

    public async ValueTask<Stream> ConnectAsync(SocketsHttpConnectionContext context, CancellationToken ct)
    {
        Validate();
        var addresses = await Dns.GetHostAddressesAsync(context.DnsEndPoint.Host, AddressFamily.InterNetwork, ct);
        Exception? lastError = null;
        foreach (var address in addresses)
        {
            ct.ThrowIfCancellationRequested();
            var socket = CreateBoundSocket();
            try
            {
                await socket.ConnectAsync(new IPEndPoint(address, context.DnsEndPoint.Port), ct);
                return new NetworkStream(socket, ownsSocket: true);
            }
            catch (OperationCanceledException) { socket.Dispose(); throw; }
            catch (Exception ex) { socket.Dispose(); lastError = ex; }
        }
        throw new HttpRequestException("所选网卡无法连接认证服务器，请检查校园网连接和服务器 IPv4 地址。", lastError);
    }
}
