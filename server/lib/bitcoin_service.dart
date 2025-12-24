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
    _registerSubscriptions(controller, policyState);

    return controller.stream;
  }

  Future<void> _registerSubscriptions(
      StreamController<TransactionNotification> controller,
      PolicyState policyState) async {
    if (_client == null) await init();

    final policies = [
      if (policyState.normalPolicy != null)
        policyState.normalPolicy!.publicKeyPackage,
      ...policyState.protectedPolicies.values.map((e) => e.publicKeyPackage)
    ];

    for (var pkg in policies) {
      final tweakedPkg = pkg.tweak(null);
      final scriptHash = _deriveScriptHash(tweakedPkg);
      // 1. Subscribe
      // We assume our client handles subscription state internally or simply sends request.
      // We need to listen to notifications.
      await _client!.subscribeToScriptHash(scriptHash);
    }

    // forward notifications
    _client!.notifications.listen((notification) {
      // notification is (scriptHash, status)
      // We should ideally filter by device's script hashes?
      // For now, simpler: just broadcast to all or map back?
      // Mapping scriptHash -> Device is hard without index.
      // But we have _deriveScriptHash capability.

      // Optimization: Pre-calculate script hashes for this device and filter?
      // Or just broadcast everything and let client filter? Client doesn't know scriptHash from proto easily?
      // We should map back to TransactionNotification.
      // Fetch logic is needed to know WHAT changed (add vs spent).
      // Subscription only gives "status changed".
      // So on notification, we should call getUtxos?
      // But getUtxos returns ALL.

      // Implementation Plan: "Server detects update via Electrum subscription. Server pushes update."
      // We can push a "State Changed" notification or fetch diff.
      // Let's implement full fetch and diff for robust update? Or just push full UTXO set?
      // Proto says: repeated UtxoInfo added_utxos, repeated UtxoInfo spent_utxos.

      // For simplicity in this iteration:
      // We won't strictly split add/spent perfectly without state tracking.
      // We can push the Notification with just "something changed" (height/hash) if generic.
      // But proto expects UTXOs.

      // Let's just forward a generic event if possible or do a quick fetch.
      // We will fetch new UTXOs for the specific scriptHash (address) that changed.
      // And send them as "added"? (Naive but works for "receive").

      // TODO: Implement proper diffing.
      // For now: Just emit notification with empty lists to signal "Refetch".
      // The client can call FetchHistory.
      // Or we utilize the fact that SubscribeToHistory returns TransactionNotification.
      // We can populate `tx_hash` if available from history api.

      final scriptHash = notification['scripthash'];
      // Check if this scriptHash belongs to the device.
      final belongs = policies.any((p) {
        final tweaked = p.tweak(null);
        return _deriveScriptHash(tweaked) == scriptHash;
      });
      if (!belongs) return;

      // Determine Transaction ID?
      // Electrum notify params: [scripthash, status]
      // We need fetchHistory(scriptHash) to see what changed?
      // Let's leave detailed diffing for future, and just notify client to fetch.
      // Can we send a special flag? "Fetch required".

      // We'll send a dummy notification.
      controller.add(TransactionNotification()..height = -1); // Signal refresh
    });
  }
}

// Minimal Electrum Client
class _ElectrumClient {
  final String host;
  final int port;
  Socket? _socket;
  int _id = 0;
  final Map<int, Completer> _pending = {};
  final _notificationController =
      StreamController<Map<String, dynamic>>.broadcast();

  Stream<Map<String, dynamic>> get notifications =>
      _notificationController.stream;

  _ElectrumClient(this.host, this.port);

  Future<void> connect() async {
    try {
      // Use secure socket for SSL port (60002 typically)
      // If port is 50001 use Socket.
      if (port == 50002 || port == 60002) {
        _socket = await SecureSocket.connect(host, port);
      } else {
        _socket = await Socket.connect(host, port);
      }

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
            // Notification
            // params: [scripthash, status]
            if (msg['params'] is List && msg['params'].isNotEmpty) {
              // We normalize to Map
              _notificationController.add({
                'scripthash': msg['params'][0],
                'status': (msg['params'].length > 1) ? msg['params'][1] : null
              });
            }
          }
        } catch (e) {
          print("Electrum parse error: $e");
        }
      },
              onDone: () => print("Electrum Disconnected"),
              onError: (e) => print("Electrum Error: $e"));
    } catch (e) {
      print("Electrum connection failed: $e");
      rethrow;
    }
  }

  Future<dynamic> request(String method, List<dynamic> params) async {
    if (_socket == null) await connect();
    final id = _id++;
    final payload = {
      "id": id,
      "method": method,
      "params": params,
      "jsonrpc": "2.0"
    };
    final completer = Completer();
    _pending[id] = completer;
    _socket!.write(jsonEncode(payload) + '\n');
    return completer.future;
  }

  Future<List<ElectrumUtxo>> listUnspent(String scriptHash) async {
    final resp =
        await request('blockchain.scripthash.listunspent', [scriptHash]);
    if (resp['error'] != null) throw Exception(resp['error']);
    final list = resp['result'] as List;
    return list
        .map((e) => ElectrumUtxo(
            txHash: e['tx_hash'], txPos: e['tx_pos'], value: e['value']))
        .toList();
  }

  Future<void> subscribeToScriptHash(String scriptHash) async {
    await request('blockchain.scripthash.subscribe', [scriptHash]);
  }
}

class ElectrumUtxo {
  final String txHash;
  final int txPos;
  final int value;
  ElectrumUtxo(
      {required this.txHash, required this.txPos, required this.value});
}
