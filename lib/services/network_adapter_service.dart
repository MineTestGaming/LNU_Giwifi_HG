import 'dart:io';

/// A desktop interface and one of its IPv4 addresses. Interface names survive
/// index changes; a missing saved interface must never become system default.
class NetworkAdapter {
  const NetworkAdapter({required this.name, required this.address});

  final String name;
  final String address;
  String get label => '$name · $address';

  @override
  bool operator ==(Object other) =>
      other is NetworkAdapter && other.name == name && other.address == address;

  @override
  int get hashCode => Object.hash(name, address);
}

class NetworkAdapterUnavailableException implements Exception {
  const NetworkAdapterUnavailableException([
    this.message = '所选网卡不可用或 IPv4 已变化，请连接校园网后刷新网卡。不会自动改用其他网卡。',
  ]);
  final String message;
  @override
  String toString() => message;
}

class NetworkAdapterService {
  const NetworkAdapterService({this.listAdapters});

  final Future<List<NetworkAdapter>> Function()? listAdapters;

  Future<List<NetworkAdapter>> listAvailable() async {
    if (listAdapters != null) return listAdapters!();
    final interfaces =
        await NetworkInterface.list(type: InternetAddressType.IPv4);
    final result = [
      for (final interface in interfaces)
        for (final address in interface.addresses)
          if (!address.isLoopback && address.address != '0.0.0.0')
            NetworkAdapter(name: interface.name, address: address.address),
    ];
    result.sort((a, b) => a.label.compareTo(b.label));
    return result.toSet().toList();
  }

  Future<void> validate(NetworkAdapter adapter) async {
    final available = await listAvailable();
    if (!available.contains(adapter)) {
      throw const NetworkAdapterUnavailableException();
    }
    if (available
        .any((a) => a.address == adapter.address && a.name != adapter.name)) {
      throw const NetworkAdapterUnavailableException(
        '多个网卡使用相同 IPv4，无法通过源地址区分，请调整网卡地址后重试。',
      );
    }
  }

  /// Refresh may adopt a new address on the same interface, never another one.
  NetworkAdapter? refreshSelection(
      NetworkAdapter? selected, List<NetworkAdapter> available) {
    if (selected == null || available.contains(selected)) return selected;
    for (final adapter in available) {
      if (adapter.name == selected.name) return adapter;
    }
    return selected;
  }
}
