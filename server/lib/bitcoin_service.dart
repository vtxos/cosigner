import 'dart:async';
import 'dart:typed_data'; // for Uint8List, ByteData, Endian
import 'package:crypto/crypto.dart'; // for sha256
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

  // Fetch comprehensive transaction history for a device
  Future<List<TransactionSummary>> getRecentTransactions(
      String deviceId, PolicyState policyState) async {
    final summaries = <TransactionSummary>[];

    // 1. Get all script hashes
    final scriptHash = _deriveScriptHash(
        policyState.normalPolicy!.publicKeyPackage.tweak(null));

    print('[$deviceId] Fetching history for scriptHash: $scriptHash');

    final txsOfInterest = <String, int>{};

    try {
      final request =
          ElectrumRequestScriptHashGetHistory(scriptHash: scriptHash);
      final history = await _provider!.request(request);
      print('[$deviceId] History fetched. Count: ${history.length}');

      // print the history
      print('[$deviceId] History: $history');

      for (final h in history) {
        txsOfInterest[h['tx_hash']] = h['height'];
      }
      print('[$deviceId] Processing ${txsOfInterest.length} unique txs...');
    } catch (e) {
      print('[$deviceId] Error fetching history: $e');
      return [];
    }

    // 3. Fetch full transaction details and calculate net for each unique Tx
    for (final entry in txsOfInterest.entries) {
      final txHash = entry.key;
      final height = entry.value;

      // print txheigh and height
      print('[$deviceId] Processing txHash: $txHash, height: $height');

      try {
        final txHex = await _provider!
            .request(ElectrumRequestGetTransaction(transactionHash: txHash));

        print('[$deviceId] Fetched txHex: $txHex');
        final tx = BtcTransaction.deserialize(BytesUtils.fromHexString(txHex));

        // Parse inputs and outputs to calculate net amount
        // Net = (Sum of my outputs) - (Sum of my inputs)
        // If Net > 0: Received
        // If Net < 0: Sent (includes fee)

        BigInt myOutputs = BigInt.zero;
        BigInt myInputs = BigInt.zero;

        // Check Outputs
        for (final out in tx.outputs) {
          final scriptHex = out.scriptPubKey.toHex();
          final scriptBytes = BytesUtils.fromHexString(scriptHex);
          final h = BytesUtils.toHexString(
              sha256.convert(scriptBytes).bytes.reversed.toList());

          if (scriptHash == h) {
            myOutputs += out.amount;
          }
        }

        // Check Inputs
        for (final input in tx.inputs) {
          final inputTxId = input.txId;

          if (txsOfInterest.containsKey(inputTxId)) {
            final prevTxHex = await _provider!.request(
                ElectrumRequestGetTransaction(transactionHash: inputTxId));
            final prevTx =
                BtcTransaction.deserialize(BytesUtils.fromHexString(prevTxHex));

            if (input.txIndex < prevTx.outputs.length) {
              final prevOut = prevTx.outputs[input.txIndex];
              final scriptHex = prevOut.scriptPubKey.toHex();
              final scriptBytes = BytesUtils.fromHexString(scriptHex);
              final h = BytesUtils.toHexString(
                  sha256.convert(scriptBytes).bytes.reversed.toList());

              if (scriptHash == h) {
                myInputs += prevOut.amount;
              }
            }
          }
        }

        final net = myOutputs - myInputs;

        // Get Timestamp
        int time = 0;
        if (height > 0) {
          time = await _fetchBlockTime(height);
        } else {
          time = DateTime.now().millisecondsSinceEpoch ~/ 1000;
        }

        // print the net amount
        print('[$deviceId] Net amount: $net');

        summaries.add(TransactionSummary(
            txHash: txHash,
            amountSats: Int64(net.toInt()),
            timestamp: Int64(time),
            isPending: height <= 0));
      } catch (e) {
        print("Error processing tx $txHash: $e");
      }
    }

    // Sort by timestamp desc
    summaries
        .sort((a, b) => b.timestamp.toInt().compareTo(a.timestamp.toInt()));

    return summaries;
  }

  final _blockTimeCache = <int, int>{};

  Future<int> _fetchBlockTime(int height) async {
    if (_blockTimeCache.containsKey(height)) return _blockTimeCache[height]!;
    try {
      final header = await _provider!.request(
          ElectrumRequestBlockHeader(startHeight: height, cpHeight: 0));
      // header is hex string
      if (header.length >= 160) {
        final bytes = BytesUtils.fromHexString(header);
        // Time is at offset 68 (4 bytes little endian) in standard bitcoin header
        // 4 (version) + 32 (prev) + 32 (merkle) = 68
        final timeBytes = bytes.sublist(68, 72);
        final time = ByteData.sublistView(Uint8List.fromList(timeBytes))
            .getUint32(0, Endian.little);
        _blockTimeCache[height] = time;
        return time;
      }
    } catch (_) {}
    return 0;
  }
}
