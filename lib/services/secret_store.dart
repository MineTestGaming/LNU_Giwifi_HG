import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// The platform encrypts values using its protected storage backend.
abstract interface class SecretStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

/// Allows tests to supply an isolated backend without a platform channel.
class SecretStores {
  static SecretStore? override;
  static SecretStore get current => override ?? const PlatformSecretStore();
}

class PlatformSecretStore implements SecretStore {
  const PlatformSecretStore();

  static const _storage = FlutterSecureStorage();

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}
