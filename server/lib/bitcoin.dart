import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:fixnum/fixnum.dart';
import 'package:grpc/grpc.dart';

import 'package:bitcoin_base/bitcoin_base.dart';
import 'package:blockchain_utils/blockchain_utils.dart';

import 'package:threshold/threshold.dart' as threshold;
import 'package:protocol/protocol.dart';
import 'persistence/store.dart';
import 'state.dart';

class BitcoinService {
  final UtxoStore _utxoStore;
  final String _rpcUrl;
  final String _rpcUser;
  final String _rpcPassword;

  /// Create BitcoinService with explicit credentials.
  /// For production use, pass credentials from ServerConfig.
  BitcoinService(
    this._utxoStore, {
    required String rpcUrl,
    required String rpcUser,
    required String rpcPassword,
  })  : _rpcUrl = rpcUrl,
        _rpcUser = rpcUser,
        _rpcPassword = rpcPassword;

  String get _authHeader {
    return 'Basic ' + base64Encode(utf8.encode('$_rpcUser:$_rpcPassword'));
  }

  Future<dynamic> _callRpc(String method, [List<dynamic>? params]) async {
    final payload = {
      'jsonrpc': '1.0',
      'id': 'mpc_server',
      'method': method,
      'params': params ?? []
    };

    try {
      final response = await http.post(
        Uri.parse(_rpcUrl),
        headers: {
          'content-type': 'text/plain',
          'authorization': _authHeader,
        },
        body: jsonEncode(payload),
      );

      if (response.statusCode != 200) {
        throw GrpcError.internal(
            'Bitcoind RPC Error: ${response.statusCode} - ${response.body}');
      }

      final body = jsonDecode(response.body);
      if (body['error'] != null) {
        throw GrpcError.internal('Bitcoind RPC Error Body: ${body['error']}');
      }

      return body['result'];
    } catch (e) {
      print("RPC Call Failed to $_rpcUrl: $e");
      throw GrpcError.internal('Failed to connect to Bitcoind: $e');
    }
  }

  /// Broadcasts a transaction and auto-detects/saves change UTXOs.
  Future<(String, BigInt)> broadcastTransaction(
      String userId, String txHex, PolicyState policyState) async {
    final txId = (await _callRpc('sendrawtransaction', [txHex])) as String;
    var spentAmount = BigInt.zero;

    // Server-side Change Calculation & Input Removal
    try {
      final pubKeyPkg = policyState.normalPolicy.publicKeyPackage;

        // Deduce expected Change Script (P2TR)
        final tweakedPk = pubKeyPkg.tweak(null);
        final point = tweakedPk.verifyingKey.E;
        final pointBytes = threshold.elemSerializeCompressed(point);
        final ecPub = ECPublic.fromHex(BytesUtils.toHexString(pointBytes));
        final p2tr = P2trAddress.fromProgram(
            program: BytesUtils.toHexString(ecPub.toXOnly()));
        final myScript = p2tr.toScriptPubKey().toHex();

        // Parse Tx
        final tx = BtcTransaction.deserialize(BytesUtils.fromHexString(txHex));

        List<UtxoInfo> detectedChange = [];
        BigInt totalChangeAmount = BigInt.zero;

        for (int i = 0; i < tx.outputs.length; i++) {
          final output = tx.outputs[i];
          if (output.scriptPubKey.toHex() == myScript) {
            detectedChange.add(UtxoInfo()
              ..vout = i
              ..amount = Int64(output.amount.toInt()));
            totalChangeAmount += output.amount;
          }
        }

        final existingJson = _utxoStore.getUtxo(userId);
        List<dynamic> currentList = [];
        if (existingJson != null) {
          try {
            currentList = jsonDecode(existingJson);
          } catch (e) {
            print("Error parsing existing UTXOs: $e");
          }
        }

        BigInt totalInputAmount = BigInt.zero;
        int inputsRemoved = 0;

        // Remove Inputs and Sum Input Amount
        for (final input in tx.inputs) {
          // We need to match txId and vout
          // using removeWhere might iterate multiple times.
          // Reverse iteration or removeWhere is fine for small lists.
          final index = currentList.indexWhere(
              (u) => u['tx_hash'] == input.txId && u['vout'] == input.txIndex);
          if (index != -1) {
            final u = currentList[index];
            totalInputAmount += BigInt.parse(u['amount'].toString());
            currentList.removeAt(index);
            inputsRemoved++;
          }
        }

        spentAmount = totalInputAmount - totalChangeAmount;

      if (detectedChange.isNotEmpty || inputsRemoved > 0) {
        for (final utxo in detectedChange) {
          currentList.add({
            'tx_hash': txId,
            'vout': utxo.vout,
            'amount': utxo.amount.toString(),
          });
        }

        await _utxoStore.saveUtxo(userId, jsonEncode(currentList));
        print(
            '[$userId] Updated UTXOs: Removed $inputsRemoved inputs, Added ${detectedChange.length} change. Net Spent: $spentAmount sats.');
      }
    } catch (e) {
      print('[$userId] Error processing change outputs: $e');
      // Do not fail the broadcast response if saving change fails, just log it.
    }

    return (txId, spentAmount);
  }
}
