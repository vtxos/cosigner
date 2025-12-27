import 'dart:io';
import 'dart:convert';
import 'dart:async';
import 'package:server/state.dart';
import 'package:protocol/protocol.dart';
import 'package:blockchain_utils/blockchain_utils.dart'; // hex
import 'package:threshold/threshold.dart' as threshold;
import 'package:bitcoin_base/bitcoin_base.dart';
import 'package:fixnum/fixnum.dart';

class BitcoinHistoryService {
  // We share a single connection or pool?
  // Ideally one connection per server instance.
  // We need to manage subscriptions per device/policy.

  final String electrumUrl;
  final int electrumPort;

  // Active subscriptions: Map<ScriptHash, StreamController>
  // or Map<DeviceId, StreamController<TransactionNotification>>
  final _deviceStreams = <String, StreamController<TransactionNotification>>{};

  // We need to map DeviceID -> List<ScriptHash> (Policies)
  // Or better: The client subscribes, and we know which policies they have (from PolicyState)
  // For now, simpler: Client calls subscribe, we look up their policies, derive addresses, and subscribe to Electrum.

  // Internal client
  _ElectrumClient? _client;

  BitcoinHistoryService(
      {this.electrumUrl = 'electrum.blockstream.info',
      this.electrumPort = 60002});

  Future<void> init() async {
    // Re-connect logic handled by client on request if needed,
    // but we trigger connection now.
    _client = _ElectrumClient(electrumUrl, electrumPort);
    await _client!.connect();
  }

  Future<void> close() async {
    for (final controller in _deviceStreams.values) {
      await controller.close();
    }
    _deviceStreams.clear();
    await _client?.close();
    _client = null;
  }

  // Fetch UTXOs for a device (aggregating all active policies)
  Future<List<UtxoInfo>> getUtxos(
      String deviceId, PolicyState policyState) async {
    final utxos = <UtxoInfo>[];

    // 1. Get all relevant addresses/scripts from policies
    // Normal Policy
    if (policyState.normalPolicy != null) {
      utxos.addAll(
          await _fetchForPolicy(policyState.normalPolicy!.publicKeyPackage));
    }
    // Protected Policies
    for (final p in policyState.protectedPolicies.values) {
      utxos.addAll(await _fetchForPolicy(p.publicKeyPackage));
    }

    return utxos;
  }

  Future<List<UtxoInfo>> _fetchForPolicy(
      threshold.PublicKeyPackage pubKeyPkg) async {
    if (_client == null) await init();

    // Tweak the package to match Client's P2TR address derivation (Key Path Spending)
    final tweakedPkg = pubKeyPkg.tweak(null);
    final scriptHash = _deriveScriptHash(tweakedPkg);

    // Fetch Unspent
    final listUnspent = await _client!.listUnspent(scriptHash);

    // Map to UtxoInfo
    return listUnspent.map((u) {
      return UtxoInfo()
        ..txHash = u.txHash
        ..vout = u.txPos
        ..amount = Int64(u.value);
    }).toList();
  }

  String _deriveScriptHash(threshold.PublicKeyPackage pubKeyPkg) {
    // 1. Get Point
    final publicKey = pubKeyPkg.verifyingKey.E;
    // 2. Serialize compressed
    final pointBytes = threshold.elemSerializeCompressed(publicKey);
    final pointHex = BytesUtils.toHexString(pointBytes);

    // 3. ECPublic -> XOnly -> Program
    final ecPub = ECPublic.fromHex(pointHex);
    // Use P2trAddress
    final address = P2trAddress.fromProgram(
        program: BytesUtils.toHexString(ecPub.toXOnly()));

    return address.pubKeyHash();
  }

  // Stream updates
  Stream<TransactionNotification> subscribe(
      String deviceId, PolicyState policyState) {
    if (_client == null) {
      // Ideally await init(); but stream is sync.
      // We can init lazily in logic.
    }

    // Reuse specific stream for this device if exists
    if (_deviceStreams.containsKey(deviceId)) {
      return _deviceStreams[deviceId]!.stream;
    }

    final controller =
        StreamController<TransactionNotification>.broadcast(onCancel: () {
      _deviceStreams.remove(deviceId);
    });
    _deviceStreams[deviceId] = controller;

    // Register script hashes
    _registerSubscriptions(controller, policyState).catchError((e) {
      print("Subscription registration failed (CAUGHT) for $deviceId: $e");
      // Optionally add error to controller or just log
    });

    return controller.stream;
  }

  Future<void> _registerSubscriptions(
      StreamController<TransactionNotification> controller,
      PolicyState policyState) async {
    try {
      if (_client == null) await init();

      final policies = [
        if (policyState.normalPolicy != null)
          policyState.normalPolicy!.publicKeyPackage,
        ...policyState.protectedPolicies.values.map((e) => e.publicKeyPackage)
      ];

      for (var pkg in policies) {
        final tweakedPkg = pkg.tweak(null);
        final scriptHash = _deriveScriptHash(tweakedPkg);
        await _client!.subscribeToScriptHash(scriptHash);
      }

      // forward notifications
      _client!.notifications.listen((notification) {
        final scriptHash = notification['scripthash'];
        final belongs = policies.any((p) {
          final tweaked = p.tweak(null);
          return _deriveScriptHash(tweaked) == scriptHash;
        });
        if (!belongs) return;
        controller.add(TransactionNotification()..height = -1);
      });
    } catch (e) {
      print("_registerSubscriptions internal error: $e");
      rethrow;
    }
  }
}

// Minimal Electrum Client
class _ElectrumClient {
  final String host;
  final int port;
  Socket? _socket;
  bool _isConnected = false;
  Timer? _pingTimer;
  int _id = 0;
  final Map<int, Completer> _pending = {};
  final _notificationController =
      StreamController<Map<String, dynamic>>.broadcast();

  Stream<Map<String, dynamic>> get notifications =>
      _notificationController.stream;

  _ElectrumClient(this.host, this.port);

  Future<void> connect() async {
    print("Connecting to Electrum ($host:$port)...");
    try {
      if (port == 50002 || port == 60002) {
        _socket = await SecureSocket.connect(host, port);
      } else {
        _socket = await Socket.connect(host, port);
      }

      _isConnected = true;
      print("Electrum Connected.");

      _pingTimer?.cancel();
      _pingTimer = Timer.periodic(const Duration(seconds: 30), (_) async {
        if (!_isConnected) return;
        final resp = await request('server.ping', []);
        if (resp is Map && resp['error'] != null) {
          print("Electrum ping error: ${resp['error']}");
        }
      });

      final handshake = await request('server.version', ['mpc-wallet', '1.4']);
      if (handshake is Map && handshake['error'] != null) {
        print("Electrum handshake error: ${handshake['error']}");
      }

      _socket!.done.catchError((e) {
        print("Electrum socket closed with error: $e");
      }).whenComplete(() {
        _socket = null;
        _isConnected = false;
        _pingTimer?.cancel();
      });

      _socket!
          .cast<List<int>>()
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
        if (line.isEmpty) return;
        try {
          final msg = jsonDecode(line);
          if (msg.containsKey('id')) {
            final id = msg['id'];
            if (_pending.containsKey(id)) {
              _pending.remove(id)!.complete(msg);
            }
          } else if (msg.containsKey('method') &&
              msg['method'].toString().endsWith('.subscribe')) {
            if (msg['params'] is List && msg['params'].isNotEmpty) {
              _notificationController.add({
                'scripthash': msg['params'][0],
                'status': (msg['params'].length > 1) ? msg['params'][1] : null
              });
            }
          }
        } catch (e) {
          print("Electrum parse error: $e");
        }
      }, onDone: () {
        print("Electrum Disconnected (onDone)");
        _socket = null;
        _isConnected = false;
        _pingTimer?.cancel();
        _pending.forEach((id, completer) {
          if (!completer.isCompleted) completer.completeError('Disconnected');
        });
        _pending.clear();
      }, onError: (e) {
        print("Electrum Error (onError): $e");
        _socket = null;
        _isConnected = false;
        _pingTimer?.cancel();
        _pending.forEach((id, completer) {
          if (!completer.isCompleted) completer.completeError(e);
        });
        _pending.clear();
      });
    } catch (e) {
      print("Electrum connection failed: $e");
      rethrow;
    }
  }

  Future<void> close() async {
    for (final pending in _pending.values) {
      if (!pending.isCompleted) {
        pending.completeError(StateError('Electrum client closed.'));
      }
    }
    _pending.clear();
    await _socket?.close();
    _isConnected = false;
    _pingTimer?.cancel();
    await _notificationController.close();
  }

  Future<dynamic> request(String method, List<dynamic> params) async {
    try {
      if (_socket == null || !_isConnected) {
        await connect();
      }
    } catch (e) {
      return {'error': e.toString()};
    }
    final id = _id++;
    final payload = {
      "id": id,
      "method": method,
      "params": params,
      "jsonrpc": "2.0"
    };
    final completer = Completer();
    _pending[id] = completer;

    try {
      _socket!.write(jsonEncode(payload) + '\n');
    } catch (e) {
      print("Electrum write error (attempt 1): $e");
      _socket = null; // Mark dead
      _pending.remove(id);

      // Attempt retry once
      try {
        await connect();
        _socket!.write(jsonEncode(payload) + '\n');
        _pending[id] = completer;
      } catch (retryE) {
        print("Electrum write error (attempt 2): $retryE");
        _pending.remove(id); // Clean up
        return {'error': retryE.toString()};
      }
    }
    try {
      return await completer.future;
    } catch (e) {
      _pending.remove(id);
      return {'error': e.toString()};
    }
  }

  Future<List<ElectrumUtxo>> listUnspent(String scriptHash) async {
    try {
      final resp =
          await request('blockchain.scripthash.listunspent', [scriptHash]);
      if (resp['error'] != null) {
        print("Electrum listUnspent error: ${resp['error']}");
        return [];
      }
      final list = resp['result'] as List;
      return list
          .map((e) => ElectrumUtxo(
              txHash: e['tx_hash'], txPos: e['tx_pos'], value: e['value']))
          .toList();
    } catch (e) {
      print("Electrum listUnspent failed: $e");
      return [];
    }
  }

  Future<void> subscribeToScriptHash(String scriptHash) async {
    try {
      final resp =
          await request('blockchain.scripthash.subscribe', [scriptHash]);
      if (resp['error'] != null) {
        print("Electrum subscribe error: ${resp['error']}");
      }
    } catch (e) {
      print("Electrum subscribe failed: $e");
    }
  }
}

class ElectrumUtxo {
  final String txHash;
  final int txPos;
  final int value;
  ElectrumUtxo(
      {required this.txHash, required this.txPos, required this.value});
}
