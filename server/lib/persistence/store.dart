import 'dart:convert';
import 'package:hive/hive.dart';

class DKGSessionStore {
  static const _sessionBoxName = 'dkg_sessions';
  late Box _box;

  Future<void> init() async {
    // Initialize Hive in the current directory (for now)
    Hive.init('hive_db');
    _box = await Hive.openBox(_sessionBoxName);
  }

  Future<void> saveSession(String deviceId, String jsonData) async {
    await _box.put(deviceId, jsonData);
  }

  String? getSession(String deviceId) {
    return _box.get(deviceId);
  }

  // Clean up if needed
  Future<void> close() async {
    await _box.close();
  }
}

class SigningSessionStore {
  static const _sessionBoxName = 'signing_sessions';
  late Box _box;

  Future<void> init() async {
    // Initialize Hive in the current directory (for now)
    Hive.init('hive_db');
    _box = await Hive.openBox(_sessionBoxName);
  }

  Future<void> saveSession(String deviceId, String jsonData) async {
    await _box.put(deviceId, jsonData);
  }

  String? getSession(String deviceId) {
    return _box.get(deviceId);
  }

  // Clean up if needed
  Future<void> close() async {
    await _box.close();
  }
}

class RefreshSessionStore {
  static const _sessionBoxName = 'refresh_sessions';
  late Box _box;

  Future<void> init() async {
    // Initialize Hive in the current directory (for now)
    Hive.init('hive_db');
    _box = await Hive.openBox(_sessionBoxName);
  }

  Future<void> saveSession(String deviceId, String jsonData) async {
    await _box.put(deviceId, jsonData);
  }

  String? getSession(String deviceId) {
    return _box.get(deviceId);
  }

  // Clean up if needed
  Future<void> close() async {
    await _box.close();
  }
}

class PolicyStore {
  static const _policyBoxName = 'policies';
  late Box _box;

  Future<void> init() async {
    // Initialize Hive in the current directory (for now)
    Hive.init('hive_db');
    _box = await Hive.openBox(_policyBoxName);
  }

  Future<void> savePolicy(String deviceId, String jsonData) async {
    await _box.put(deviceId, jsonData);
  }

  String? getPolicy(String deviceId) {
    return _box.get(deviceId);
  }

  // Clean up if needed
  Future<void> close() async {
    await _box.close();
  }
}

class UtxoStore {
  static const _utxoBoxName = 'utxos';
  late Box _box;

  Future<void> init() async {
    // Initialize Hive in the current directory (for now)
    Hive.init('hive_db');
    _box = await Hive.openBox(_utxoBoxName);
  }

  Future<void> saveUtxo(String deviceId, String jsonData) async {
    await _box.put(deviceId, jsonData);
  }

  String? getUtxo(String deviceId) {
    return _box.get(deviceId);
  }

  // Clean up if needed
  Future<void> close() async {
    await _box.close();
  }
}
