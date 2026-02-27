import 'package:hive/hive.dart';
import 'package:synchronized/synchronized.dart';

/// Generic store for session/state persistence using Hive.
class GenericStore {
  final String boxName;
  final HiveCipher? _cipher;
  late Box _box;
  bool _isInitialized = false;
  final Lock _lock = Lock();

  /// Creates a store with optional encryption.
  ///
  /// [boxName] - Name of the Hive box
  /// [cipher] - Optional cipher for encrypted storage
  GenericStore(this.boxName, {HiveCipher? cipher}) : _cipher = cipher;

  bool get isInitialized => _isInitialized;

  Future<void> init() async {
    await _lock.synchronized(() async {
      if (_isInitialized) return;
      _box = await Hive.openBox(boxName, encryptionCipher: _cipher);
      _isInitialized = true;
    });
  }

  void _ensureInitialized() {
    if (!_isInitialized) {
      throw StateError('Store "$boxName" not initialized. Call init() first.');
    }
  }

  Future<void> save(String key, String jsonData) async {
    await _lock.synchronized(() async {
      _ensureInitialized();
      await _box.put(key, jsonData);
    });
  }

  Future<String?> get(String key) async {
    return _lock.synchronized(() async {
      _ensureInitialized();
      return _box.get(key);
    });
  }

  Future<void> delete(String key) async {
    await _lock.synchronized(() async {
      _ensureInitialized();
      await _box.delete(key);
    });
  }

  Future<void> clear() async {
    await _lock.synchronized(() async {
      _ensureInitialized();
      await _box.clear();
    });
  }

  Future<List<String>> getAllKeys() async {
    return _lock.synchronized(() async {
      _ensureInitialized();
      return _box.keys.cast<String>().toList();
    });
  }

  Future<void> close() async {
    await _lock.synchronized(() async {
      if (_isInitialized && _box.isOpen) {
        await _box.close();
        _isInitialized = false;
      }
    });
  }
}

/// Specialized stores using GenericStore
class DKGSessionStore extends GenericStore {
  DKGSessionStore({HiveCipher? cipher}) : super('dkg_sessions', cipher: cipher);

  Future<void> saveSession(String userId, String jsonData) =>
      save(userId, jsonData);
  Future<String?> getSession(String userId) => get(userId);
}

class SigningSessionStore extends GenericStore {
  SigningSessionStore({HiveCipher? cipher})
      : super('signing_sessions', cipher: cipher);

  Future<void> saveSession(String userId, String jsonData) =>
      save(userId, jsonData);
  Future<String?> getSession(String userId) => get(userId);
}

class RefreshSessionStore extends GenericStore {
  RefreshSessionStore({HiveCipher? cipher})
      : super('refresh_sessions', cipher: cipher);

  Future<void> saveSession(String userId, String jsonData) =>
      save(userId, jsonData);
  Future<String?> getSession(String userId) => get(userId);
}

class PolicyStore extends GenericStore {
  PolicyStore({HiveCipher? cipher}) : super('policies', cipher: cipher);

  Future<void> savePolicy(String userId, String jsonData) =>
      save(userId, jsonData);
  Future<String?> getPolicy(String userId) => get(userId);

  Future<Map<String, String>> getAllPolicies() async {
    final keys = await getAllKeys();
    final result = <String, String>{};
    for (final key in keys) {
      final value = await get(key);
      if (value != null) result[key] = value;
    }
    return result;
  }
}

class UtxoStore extends GenericStore {
  UtxoStore({HiveCipher? cipher}) : super('utxos', cipher: cipher);

  Future<void> saveUtxo(String userId, String jsonData) =>
      save(userId, jsonData);
  Future<String?> getUtxo(String userId) => get(userId);
}
