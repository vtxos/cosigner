import 'dart:async';
import 'package:server/state.dart';
import 'package:protocol/protocol.dart';
import 'package:blockchain_utils/blockchain_utils.dart'; // hex
import 'package:threshold/threshold.dart' as threshold;
import 'package:bitcoin_base/bitcoin_base.dart';
import 'package:fixnum/fixnum.dart';

import 'package:server/services/electrum_service_impl.dart';

class BitcoinHistoryService {
  final String electrumUrl;
  final int electrumPort;

  // Active subscriptions: DeviceId -> StreamController
  final _deviceStreams = <String, StreamController<TransactionNotification>>{};

  // The new robust client from bitcoin_base (BitcoinBase ElectrumProvider + Custom Service)
  ElectrumProvider? _provider;
  ElectrumTcpServiceImpl? _serviceImpl;

  BitcoinHistoryService(
      {
      // Default to Regtest local
      this.electrumUrl = '127.0.0.1',
      this.electrumPort = 50001});

  Future<void> init() async {
    if (_provider != null) return;

    _serviceImpl =
        ElectrumTcpServiceImpl(domain: electrumUrl, port: electrumPort);
    _provider = ElectrumProvider(_serviceImpl!);

    // Retry loop for initial connection and sync check
    while (true) {
      try {
        print(
            "BitcoinHistoryService: Attempting confirmation with Electrum...");
        await _serviceImpl!.connect();

        print("BitcoinHistoryService: Connected and verified Electrum status.");
        break;
      } catch (e) {
        print(
            "BitcoinHistoryService: Waiting for Electrum ($electrumUrl:$electrumPort) to be ready... (${e.toString().split('\n').first})");
        // Clean up partial state
        await _serviceImpl?.disconnect();
        await Future.delayed(Duration(seconds: 5));
      }
    }
  }

  Future<void> close() async {
    for (final controller in _deviceStreams.values) {
      await controller.close();
    }
    _deviceStreams.clear();
    await _serviceImpl?.disconnect();
    _provider = null;
    _serviceImpl = null;
  }

  // Fetch UTXOs for a device (aggregating all active policies)
  Future<List<UtxoInfo>> getUtxos(
      String deviceId, PolicyState policyState) async {
    final utxos = <UtxoInfo>[];

    // 1. Get all relevant addresses/scripts from policies
    if (policyState.normalPolicy != null) {
      utxos.addAll(
          await _fetchForPolicy(policyState.normalPolicy!.publicKeyPackage));
    }
    for (final p in policyState.protectedPolicies.values) {
      utxos.addAll(await _fetchForPolicy(p.publicKeyPackage));
    }

    return utxos;
  }

  Future<List<UtxoInfo>> _fetchForPolicy(
      threshold.PublicKeyPackage pubKeyPkg) async {
    if (_provider == null) await init();

    final tweakedPkg = pubKeyPkg.tweak(null);
    final scriptHash = _deriveScriptHash(tweakedPkg);

    // List Unspent
    final request =
        ElectrumRequestScriptHashListUnspent(scriptHash: scriptHash);
    final listUnspent = await _provider!.request(request);

    return listUnspent.map((u) {
      return UtxoInfo()
        ..txHash = u.txId
        ..vout = u.vout
        ..amount = Int64(u.value.toInt()); // value is BigInt?
    }).toList();
  }

  String _deriveScriptHash(threshold.PublicKeyPackage pubKeyPkg) {
    final publicKey = pubKeyPkg.verifyingKey.E;
    final pointBytes = threshold.elemSerializeCompressed(publicKey);
    final pointHex = BytesUtils.toHexString(pointBytes);

    final ecPub = ECPublic.fromHex(pointHex);
    final address = P2trAddress.fromProgram(
        program: BytesUtils.toHexString(ecPub.toXOnly()));

    return address.pubKeyHash();
  }

  // Stream updates
  Stream<TransactionNotification> subscribe(
      String deviceId, PolicyState policyState) {
    // Reuse specific stream for this device if exists
    if (_deviceStreams.containsKey(deviceId)) {
      return _deviceStreams[deviceId]!.stream;
    }

    final controller =
        StreamController<TransactionNotification>.broadcast(onCancel: () {
      _deviceStreams.remove(deviceId);
    });
    _deviceStreams[deviceId] = controller;

    _registerSubscriptions(controller, policyState).catchError((e) {
      print("Subscription registration failed (CAUGHT) for $deviceId: $e");
    });

    return controller.stream;
  }

  Future<void> _registerSubscriptions(
      StreamController<TransactionNotification> controller,
      PolicyState policyState) async {
    try {
      if (_provider == null) await init();

      final policies = [
        if (policyState.normalPolicy != null)
          policyState.normalPolicy!.publicKeyPackage,
        ...policyState.protectedPolicies.values.map((e) => e.publicKeyPackage)
      ];

      for (var pkg in policies) {
        final tweakedPkg = pkg.tweak(null);
        final scriptHash = _deriveScriptHash(tweakedPkg);

        final request =
            ElectrumRequestScriptHashSubscribe(scriptHash: scriptHash);
        await _provider!.request(request);
      }

      // Listen to service notifications
      // We listen to the global notification stream from our implementation
      _serviceImpl!.notifications.listen((event) {
        if (event.method == 'blockchain.scripthash.subscribe') {
          // params: [scripthash, status]
          // We mapped List params to Map {'0': scripthash, '1': status} in service impl
          final params = event.params;
          if (params.containsKey('0')) {
            final scriptHash = params['0'];

            // Check if it belongs to this device
            // (Inefficient O(N) lookup but fine for now)
            final belongs = policies.any((p) {
              final tweaked = p.tweak(null);
              return _deriveScriptHash(tweaked) == scriptHash;
            });

            if (belongs) {
              controller.add(TransactionNotification()..height = -1);
            }
          }
        }
      });
    } catch (e) {
      print("_registerSubscriptions internal error: $e");
      rethrow;
    }
  }
}
