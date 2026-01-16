import 'package:hive/hive.dart';

/// Generic store for session/state persistence using Hive.
/// Reduces code duplication across DKGSessionStore, SigningSessionStore,
/// RefreshSessionStore, PolicyStore, and UtxoStore.
class GenericStore {
  final String boxName;
  late Box _box;
  bool _isInitialized = false;

  GenericStore(this.boxName);

  bool get isInitialized => _isInitialized;

  Future<void> init() async {
    if (_isInitialized) return;
    _box = await Hive.openBox(boxName);
    _isInitialized = true;
  }

  Future<void> save(String key, String jsonData) async {
    if (!_isInitialized) {
      throw StateError('Store "$boxName" not initialized. Call init() first.');
    }
    await _box.put(key, jsonData);
  }

  String? get(String key) {
    if (!_isInitialized) {
      throw StateError('Store "$boxName" not initialized. Call init() first.');
    }
    return _box.get(key);
  }

  Future<void> delete(String key) async {
    if (!_isInitialized) {
      throw StateError('Store "$boxName" not initialized. Call init() first.');
    }
    await _box.delete(key);
  }

  Future<void> clear() async {
    if (!_isInitialized) {
      throw StateError('Store "$boxName" not initialized. Call init() first.');
    }
    await _box.clear();
  }

  List<String> getAllKeys() {
    if (!_isInitialized) {
      throw StateError('Store "$boxName" not initialized. Call init() first.');
    }
    return _box.keys.cast<String>().toList();
  }

  Future<void> close() async {
    if (_isInitialized && _box.isOpen) {
      await _box.close();
      _isInitialized = false;
    }
  }
}

/// Specialized stores using GenericStore
class DKGSessionStore extends GenericStore {
  DKGSessionStore() : super('dkg_sessions');

  Future<void> saveSession(String userId, String jsonData) =>
      save(userId, jsonData);
  String? getSession(String userId) => get(userId);
}

class SigningSessionStore extends GenericStore {
  SigningSessionStore() : super('signing_sessions');

  Future<void> saveSession(String userId, String jsonData) =>
      save(userId, jsonData);
  String? getSession(String userId) => get(userId);
}

class RefreshSessionStore extends GenericStore {
  RefreshSessionStore() : super('refresh_sessions');

  Future<void> saveSession(String userId, String jsonData) =>
      save(userId, jsonData);
  String? getSession(String userId) => get(userId);
}

class PolicyStore extends GenericStore {
  PolicyStore() : super('policies');

  Future<void> savePolicy(String userId, String jsonData) =>
      save(userId, jsonData);
  String? getPolicy(String userId) => get(userId);
}

class UtxoStore extends GenericStore {
  UtxoStore() : super('utxos');

  Future<void> saveUtxo(String userId, String jsonData) =>
      save(userId, jsonData);
  String? getUtxo(String userId) => get(userId);
}
