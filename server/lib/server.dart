import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:grpc/grpc.dart';
import 'package:threshold/threshold.dart' as threshold;
import 'package:threshold/frost/signing.dart' as frost;
import 'package:threshold/frost/commitment.dart' as frost_comm;
import 'package:fixnum/fixnum.dart';

import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:hive/hive.dart';
import 'package:bitcoin_base/bitcoin_base.dart';
import 'package:blockchain_utils/blockchain_utils.dart'; // for hex

import 'package:protocol/protocol.dart';
import 'persistence/store.dart';
import 'state.dart';
import 'dart:math';

import 'policy.dart';
import 'bitcoin.dart';
import 'bitcoin_service.dart';

class MPCWalletService extends MPCWalletServiceBase {
  // Hardcoded Regtest credentials (as per E2E tests)

  // In-memory cache of active sessions
  final Map<String, DKGSessionState> _dkgSessions = {};
  final Map<String, SigningSessionState> _signingSessions = {};
  final Map<String, RefreshSessionState> _refreshSessions = {};
  final Map<String, PolicyState> _policies = {};
  final Map<String, UtxoState> _utxos = {};

  // Persistence
  final DKGSessionStore dkgStore;
  final SigningSessionStore signingStore;
  final RefreshSessionStore refreshStore;
  final PolicyStore policyStore;
  final UtxoStore utxoStore;

  final BitcoinService bitcoinService;
  final BitcoinHistoryService historyService;

  // Server Identity: ID=3
  static final serverId = threshold.Identifier(BigInt.from(3));
  static final serverIdHex =
      _idToString(threshold.bigIntToBytes(serverId.toScalar()));
  static const int totalParticipants = 3;
  static const int thresholdCount = 2;

  MPCWalletService({
    required this.dkgStore,
    required this.signingStore,
    required this.refreshStore,
    required this.policyStore,
    required this.utxoStore,
    required this.bitcoinService,
    required this.historyService,
  });

  DKGSessionState _getDKGSession(String deviceId) {
    if (!_dkgSessions.containsKey(deviceId)) {
      // Try load
      final jsonStr = dkgStore.getSession(deviceId);
      if (jsonStr != null) {
        try {
          _dkgSessions[deviceId] =
              DKGSessionState.fromJson(jsonDecode(jsonStr));
          print('[$deviceId] Loaded DKG session from store.');
        } catch (e) {
          print('[$deviceId] Error loading DKG session: $e');
        }
      }

      if (!_dkgSessions.containsKey(deviceId)) {
        _dkgSessions[deviceId] = DKGSessionState(deviceId);
        print('New Session Created: $deviceId');
      }
    }
    return _dkgSessions[deviceId]!;
  }

  RefreshSessionState _getRefreshSession(String deviceId) {
    if (!_refreshSessions.containsKey(deviceId)) {
      // Try load
      final jsonStr = refreshStore.getSession(deviceId);
      if (jsonStr != null) {
        try {
          _refreshSessions[deviceId] =
              RefreshSessionState.fromJson(jsonDecode(jsonStr));
          print('[$deviceId] Loaded Refresh session from store.');
        } catch (e) {
          print('[$deviceId] Error loading Refresh session: $e');
        }
      }

      if (!_refreshSessions.containsKey(deviceId)) {
        _refreshSessions[deviceId] = RefreshSessionState(deviceId);
        print('New Session Created: $deviceId');
      }
    }
    return _refreshSessions[deviceId]!;
  }

  SigningSessionState _getSigningSession(String deviceId) {
    if (!_signingSessions.containsKey(deviceId)) {
      // Check store? (For now, we just create new in-memory if not found,
      // strictly implies DKG Step 1 starts it).
      _signingSessions[deviceId] = SigningSessionState(deviceId);
      print('New Session Created: $deviceId');
    }
    return _signingSessions[deviceId]!;
  }

  PolicyState _getPolicyState(String deviceId) {
    if (!_policies.containsKey(deviceId)) {
      // Try load
      final jsonStr = policyStore.getPolicy(deviceId);
      if (jsonStr != null) {
        try {
          _policies[deviceId] = PolicyState.fromJson(jsonDecode(jsonStr));
          print('[$deviceId] Loaded Policy state from store.');
        } catch (e) {
          print('[$deviceId] Error loading Policy state: $e');
        }
      }
      if (!_policies.containsKey(deviceId)) {
        _policies[deviceId] = PolicyState(deviceId);
        print('New Session Created: $deviceId');
      }
    }
    return _policies[deviceId]!;
  }

  UtxoState _getUtxoState(String deviceId) {
    if (!_utxos.containsKey(deviceId)) {
      final newState = UtxoState(deviceId);

      // Load from persistence
      final existingJson = utxoStore.getUtxo(deviceId);
      if (existingJson != null) {
        try {
          final List<dynamic> list = jsonDecode(existingJson);
          final loadedUtxos = list.map((item) {
            final amount = BigInt.parse(item['amount'].toString());
            final txid = item['tx_hash'] as String;
            final vout = item['vout'] as int;
            return Utxo(amount, txid, vout);
          }).toList();
          newState.addUtxoList(loadedUtxos);
          print('[$deviceId] Loaded ${loadedUtxos.length} UTXOs from store.');
        } catch (e) {
          print('[$deviceId] Error loading UTXOs: $e');
        }
      }

      _utxos[deviceId] = newState;
    }
    return _utxos[deviceId]!;
  }

  static String _idToString(List<int> id) {
    return id.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  static threshold.Identifier _stringToId(String s) {
    return threshold.Identifier(BigInt.parse(s, radix: 16));
  }

  // --- DKG ---
  @override
  Future<DKGStep1Response> dKGStep1(
      ServiceCall call, DKGStep1Request request) async {
    final session = _getDKGSession(request.deviceId);
    try {
      final clientIdHex = _idToString(request.identifier);
      print(
          '[${request.deviceId}] DKGStep1: Received PubPackage from $clientIdHex');

      session.round1Packages[clientIdHex] = request.round1Package;

      // Server Init for this session
      if (session.serverRound1SecretPackage == null) {
        print('[${request.deviceId}] Server: Generating DKG secrets...');
        final secret = threshold.SecretKey(threshold.modNRandom());
        final coeffs = threshold.generateCoefficients(thresholdCount - 1);
        final (r1Secret, r1Public) = threshold.dkgPart1(
            serverId, totalParticipants, thresholdCount, secret, coeffs);

        session.serverInternalSecret = secret;
        session.serverRound1SecretPackage = r1Secret;
        session.round1Packages[serverIdHex] = jsonEncode(r1Public.toJson());
      }

      if (session.round1Packages.length == totalParticipants) {
        if (!session.completerStep1.isCompleted)
          session.completerStep1.complete();
      } else {
        await session.completerStep1.future;
      }

      return DKGStep1Response()..round1Packages.addAll(session.round1Packages);
    } catch (e) {
      print('[${request.deviceId}] DKGStep1 Error: $e');
      session.reset();
      rethrow;
    }
  }

  @override
  Future<DKGStep2Response> dKGStep2(
      ServiceCall call, DKGStep2Request request) async {
    final session = _getDKGSession(request.deviceId);
    try {
      await session.completerStep1.future;

      if (session.dkgRound2PackagesLocal.isEmpty) {
        print('[${request.deviceId}] DKGStep2: Server computing shares...');
        final round1Pkgs = <threshold.Identifier, threshold.Round1Package>{};
        session.round1Packages.forEach((k, v) {
          final id = threshold.Identifier(BigInt.parse(k, radix: 16));
          if (id != serverId) {
            round1Pkgs[id] = threshold.Round1Package.fromJson(jsonDecode(v));
          }
        });

        if (session.serverRound1SecretPackage == null) {
          throw StateError(
              'Server secrets missing for session ${request.deviceId}');
        }

        final (serverRound2Secret, serverRound2Pkgs) =
            threshold.dkgPart2(session.serverRound1SecretPackage!, round1Pkgs);

        session.serverRound2Secret = serverRound2Secret;
        session.dkgRound2PackagesLocal.addAll(serverRound2Pkgs);
      }

      if (!session.completerStep2.isCompleted)
        session.completerStep2.complete();

      return DKGStep2Response()
        ..allRound1Packages.addAll(session.round1Packages);
    } catch (e) {
      print('[${request.deviceId}] DKGStep2 Error: $e');
      session.reset();
      rethrow;
    }
  }

  @override
  Future<DKGStep3Response> dKGStep3(
      ServiceCall call, DKGStep3Request request) async {
    final session = _getDKGSession(request.deviceId);
    try {
      final senderId = threshold.Identifier.deserialize(
          Uint8List.fromList(request.identifier));
      print(
          '[${request.deviceId}] DKGStep3: Received Shares from ${_idToString(request.identifier)}');

      await session.completerStep2.future;

      final sharesFromSenderForOthers =
          <threshold.Identifier, threshold.Round2Package>{};
      for (final entry in request.round2PackagesForOthers.entries) {
        final recipientId = _stringToId(entry.key);
        final pkg = threshold.Round2Package.fromJson(jsonDecode(entry.value));
        sharesFromSenderForOthers[recipientId] = pkg;

        if (recipientId == serverId) {
          session.dkgRound2PackagesReceived[senderId] = pkg;
        }
      }
      session.dkgRound2PackagesForRelay[senderId] = sharesFromSenderForOthers;

      if (session.dkgRound2PackagesForRelay.length == totalParticipants - 1) {
        session.dkgRound2PackagesForRelay[serverId] =
            session.dkgRound2PackagesLocal;
        if (!session.completerStep3.isCompleted)
          session.completerStep3.complete();
      } else {
        await session.completerStep3.future;
      }

      final packagesForRequester = <String, String>{};
      for (final participantId in session.dkgRound2PackagesForRelay.keys) {
        final participantShares =
            session.dkgRound2PackagesForRelay[participantId]!;
        if (participantShares.containsKey(senderId)) {
          packagesForRequester[_idToString(
                  threshold.bigIntToBytes(participantId.toScalar()))] =
              jsonEncode(participantShares[senderId]!.toJson());
        }
      }

      final policyState = _getPolicyState(request.deviceId);

      if (policyState.normalPolicy == null &&
          session.completerStep3.isCompleted) {
        print('[${request.deviceId}] DKGStep3: Server computing KeyPackage...');
        final allRound1Pkgs = <threshold.Identifier, threshold.Round1Package>{};
        session.round1Packages.forEach((k, v) {
          final id = threshold.Identifier(BigInt.parse(k, radix: 16));
          if (id != serverId) {
            allRound1Pkgs[id] = threshold.Round1Package.fromJson(jsonDecode(v));
          }
        });

        final allReceivedSharesPoints =
            <threshold.Identifier, threshold.Round2Package>{};
        allReceivedSharesPoints.addAll(session.dkgRound2PackagesReceived);

        final (keyPkg, pubKeyPkg) = threshold.dkgPart3(
            session.serverRound1SecretPackage!,
            session.serverRound2Secret!,
            allRound1Pkgs,
            allReceivedSharesPoints);

        policyState.normalPolicy = NormalPolicy(
          id: "normal policies",
          keyPackage: keyPkg,
          publicKeyPackage: pubKeyPkg,
        );
        print(
            '[${request.deviceId}] DKG Complete. PK: ${pubKeyPkg.verifyingKey.E}');

        // Persistence
        try {
          await policyStore.savePolicy(
              request.deviceId, jsonEncode(policyState.toJson()));
          await dkgStore.saveSession(
              request.deviceId, jsonEncode(session.toJson()));
          print('[${request.deviceId}] Saved DKG completion state.');
        } catch (e) {
          print('[${request.deviceId}] Error saving DKG complete state: $e');
        }
      }

      return DKGStep3Response()
        ..round2PackagesForMe.addAll(packagesForRequester);
    } catch (e) {
      print('[${request.deviceId}] DKGStep3 Error: $e');
      session.reset();
      rethrow;
    }
  }

  // --- Signing ---

  // Helper to decode tx and calculate spent amount
  BigInt _calculateSpentAmount(Uint8List fullTxBytes,
      threshold.PublicKeyPackage groupKey, String deviceId) {
    if (fullTxBytes.isEmpty) return BigInt.zero;

    try {
      final tx = BtcTransaction.deserialize(fullTxBytes);

      BigInt totalIn = BigInt.zero;
      for (final input in tx.inputs) {
        // Ensure state is loaded
        final utxoState = _getUtxoState(deviceId);
        final clientUtxos = utxoState.utxos;
        for (final y in clientUtxos) {
          if (y.txid == input.txId && y.vout == input.txIndex) {
            totalIn += y.amount;
          }
        }
      }
      BigInt changeValue = BigInt.zero;

      final tweakedPk = groupKey.tweak(null);
      final point = tweakedPk.verifyingKey.E;
      final pointBytes = threshold.elemSerializeCompressed(point);
      // P2TR script is: 5120 <32-byte-x-only-pubkey>
      // Use bitcoin_base to generate address/program to be safe
      final ecPub = ECPublic.fromHex(BytesUtils.toHexString(pointBytes));
      final p2tr = P2trAddress.fromProgram(
          program: BytesUtils.toHexString(ecPub.toXOnly()));
      final groupScript = p2tr.toScriptPubKey().toHex();
      for (final out in tx.outputs) {
        final outScript = out.scriptPubKey.toHex();
        if (groupScript == outScript) {
          changeValue += out.amount;
        }
      }

      final spent = totalIn - changeValue;
      // Note: This 'spent' includes Fee + Destination Amount.
      // Policy usually applies to "Amount leaving the wallet".
      // So this is correct.
      return spent;
    } catch (e) {
      print("Error decoding transaction: $e");
      // Fallback/Fail safe
      return BigInt.zero;
    }
  }

  ProtectedPolicy? _getPolicy(
    List<int> txMessage,
    threshold.PublicKeyPackage groupKey,
    String deviceId,
  ) {
    final policies = _getPolicyState(deviceId);
    final spent = _calculateSpentAmount(
        Uint8List.fromList(txMessage), groupKey, deviceId);

    // Check cumulative spending for active policies
    final now = DateTime.now();

    // Iterate policies
    for (final p in policies.protectedPolicies.values) {
      // Calculate policy window
      // Window Start = startTime + (N * interval) such that Window Start <= now
      final diff = now.difference(p.startTime);
      if (diff.isNegative) continue; // Not started yet

      final intervalsPassed = diff.inSeconds ~/ p.interval.inSeconds;
      final currentWindowStart = p.startTime.add(p.interval * intervalsPassed);

      // Sum historical spending in this window
      BigInt cumulativeSpent = BigInt.zero;
      for (final entry in policies.spendingHistory) {
        if (entry.timestamp.isAfter(currentWindowStart) ||
            entry.timestamp.isAtSameMomentAs(currentWindowStart)) {
          cumulativeSpent += entry.amount;
        }
      }

      // Add current spending
      final totalSpent = cumulativeSpent + spent;

      if (totalSpent > p.thresholdSats) {
        return p;
      }
    }
    return null;
  }

  @override
  Future<SignStep1Response> signStep1(
      ServiceCall call, SignStep1Request request) async {
    final session = _getSigningSession(request.deviceId);
    try {
      final policyState = _getPolicyState(request.deviceId);
      final senderId = threshold.Identifier.deserialize(
          Uint8List.fromList(request.identifier));
      print(
          '[${request.deviceId}] SignStep1: Received from ${_idToString(request.identifier)}');

      // Ensure we have a key for this session
      if (policyState.normalPolicy == null) {
        throw GrpcError.failedPrecondition(
            "DKG not completed for device ${request.deviceId}");
      }

      var serverKeyPackage = policyState.normalPolicy!.keyPackage;

      final policy = _getPolicy(
        request.fullTransaction,
        policyState.normalPolicy!.publicKeyPackage,
        request.deviceId,
      );

      if (policy != null) {
        serverKeyPackage = policy.keyPackage;
        session.currentPolicyId = policy.id;
        print(
            '[${request.deviceId}] SignStep1: Switched to Protected Policy: ${policy.id}');
      } else {
        print('[${request.deviceId}] SignStep1: Using Normal Policy (Default)');
      }

      // ---------------------------

      final hidingP = threshold.elemDeserializeCompressed(
          Uint8List.fromList(request.hidingCommitment));
      final bindingP = threshold.elemDeserializeCompressed(
          Uint8List.fromList(request.bindingCommitment));
      session.signCommitmentsReceived[senderId] =
          frost_comm.SigningCommitments(bindingP, hidingP);

      if (session.serverNonce == null) {
        print(
            '[${request.deviceId}] SignStep1: Server generating commitments...');
        session.serverNonce = frost_comm.newNonce(serverKeyPackage.secretShare);
        session.serverCommitments = session.serverNonce!.commitments;
        session.signCommitmentsReceived[serverId] = session.serverCommitments!;
      }

      if (session.messageToSign == null && request.messageToSign.isNotEmpty) {
        session.messageToSign = Uint8List.fromList(request.messageToSign);
      }

      // Calculate spent amount for history tracking
      final spent = _calculateSpentAmount(
          Uint8List.fromList(request.fullTransaction),
          policyState.normalPolicy!.publicKeyPackage,
          request.deviceId);
      session.pendingAmount = spent;

      if (session.signCommitmentsReceived.length >= thresholdCount) {
        if (!session.completerSignStep1.isCompleted)
          session.completerSignStep1.complete();
      } else {
        await session.completerSignStep1.future;
      }

      final responseCommitments = <String, SignStep1Response_Commitment>{};
      for (final entry in session.signCommitmentsReceived.entries) {
        final comm = entry.value;
        responseCommitments[
                _idToString(threshold.bigIntToBytes(entry.key.toScalar()))] =
            SignStep1Response_Commitment(
          hiding: threshold.elemSerializeCompressed(comm.hiding),
          binding: threshold.elemSerializeCompressed(comm.binding),
        );
      }

      return SignStep1Response()
        ..commitments.addAll(responseCommitments)
        ..messageToSign = session.messageToSign!;
    } catch (e) {
      print('[${request.deviceId}] SignStep1 Error: $e');
      session.reset();
      rethrow;
    }
  }

  @override
  Future<SignStep2Response> signStep2(
      ServiceCall call, SignStep2Request request) async {
    final session = _getSigningSession(request.deviceId);
    try {
      final policyState = _getPolicyState(request.deviceId);

      final senderId = threshold.Identifier.deserialize(
          Uint8List.fromList(request.identifier));
      print(
          '[${request.deviceId}] SignStep2: Received from ${_idToString(request.identifier)}');

      var serverKeyPackage = policyState.normalPolicy!.keyPackage;
      var serverPubPackage = policyState.normalPolicy!.publicKeyPackage;

      if (session.currentPolicyId != null) {
        serverKeyPackage =
            policyState.protectedPolicies[session.currentPolicyId!]!.keyPackage;
        serverPubPackage = policyState
            .protectedPolicies[session.currentPolicyId!]!.publicKeyPackage;
      }

      final share =
          threshold.bytesToBigInt(Uint8List.fromList(request.signatureShare));
      session.signRound2Shares[senderId] = share;

      print('DEBUG: Current Policy ID: ${session.currentPolicyId}');

      if (!session.signRound2Shares.containsKey(serverId) &&
          session.serverNonce != null) {
        print('[${request.deviceId}] SignStep2: Server computing share...');
        final signingPkg = frost_comm.SigningPackage(
            session.signCommitmentsReceived, session.messageToSign!);
        print('[${request.deviceId}] SignStep2: Generating Server Share...');

        print('DEBUG: Current Policy ID: ${session.currentPolicyId}');
        print('DEBUG: Server Key ID: ${serverKeyPackage.identifier.s}');
        print(
            'DEBUG: Server Secret (partial): ${serverKeyPackage.secretShare.toString().substring(0, 10)}...');

        // Explicitly apply Taproot tweak (Key Path Spending)
        serverKeyPackage = serverKeyPackage.tweak(null);
        serverPubPackage = serverPubPackage.tweak(null);

        final serverShareObj =
            frost.sign(signingPkg, session.serverNonce!, serverKeyPackage);
        session.signRound2Shares[serverId] = serverShareObj.s;
      }

      if (session.signRound2Shares.length >= thresholdCount) {
        if (!session.completerSignStep2.isCompleted)
          session.completerSignStep2.complete();
      } else {
        await session.completerSignStep2.future;
      }

      final signingPkg = frost_comm.SigningPackage(
          session.signCommitmentsReceived, session.messageToSign!);
      final sharesMap = <threshold.Identifier, frost.SignatureShare>{};
      session.signRound2Shares.forEach((id, val) {
        sharesMap[id] = frost.SignatureShare(val);
      });

      final signature =
          frost.aggregate(signingPkg, sharesMap, serverPubPackage);
      print('[${request.deviceId}] SignStep2: Aggregated.');

      // Commit Pending Amount to History
      if (session.pendingAmount != null &&
          session.pendingAmount! > BigInt.zero) {
        policyState.spendingHistory
            .add(SpendingEntry(DateTime.now(), session.pendingAmount!));
        print(
            '[${request.deviceId}] Policy Update: Added spending of ${session.pendingAmount} sats. Total History: ${policyState.spendingHistory.length}');

        // Persist Policy State (spending history update)
        try {
          await policyStore.savePolicy(
              request.deviceId, jsonEncode(policyState.toJson()));
        } catch (e) {
          print(
              '[${request.deviceId}] Error saving policy spending history: $e');
        }
      }

      final response = SignStep2Response()
        ..rPoint = threshold.elemSerializeCompressed(signature.R)
        ..zScalar = threshold.bigIntToBytes(signature.Z);

      return response;
    } catch (e) {
      print('[${request.deviceId}] SignStep2 Error: $e');
      session.reset();
      rethrow;
    }
  }

  // --- Refresh ---

  @override
  Future<RefreshStep1Response> refreshStep1(
      ServiceCall call, RefreshStep1Request request) async {
    final session = _getRefreshSession(request.deviceId);
    try {
      final policyState = _getPolicyState(request.deviceId);
      final clientIdHex = _idToString(request.identifier);
      print(
          '[${request.deviceId}] RefreshStep1: Received PubPackage from $clientIdHex');

      // Auto-Reset if previous session finished
      if (session.completerRefreshStep3.isCompleted) {
        print(
            '[${request.deviceId}] RefreshStep1: Resetting previous refresh session...');
        session.reset();
        // Since reset() clears everything including refreshCreationTime, we need to re-initialize below
      }

      session.refreshRound1Packages[clientIdHex] = request.round1Package;

      // Server Init for this refresh session
      if (session.serverRefreshRound1Secret == null) {
        print('[${request.deviceId}] Server: Generating Refresh secrets...');
        if (policyState.normalPolicy == null) {
          throw GrpcError.failedPrecondition("No key to refresh");
        }

        final (r1Secret, r1Public) = threshold.dkgRefreshPart1(
          serverId,
          2,
          thresholdCount,
        );

        if (session.refreshCreationTime == null) {
          session.refreshCreationTime = DateTime.now();
          session.refreshId = randomBase64(32);
          session.refreshThresholdAmount = request.thresholdAmount;
          session.refreshInterval = request.interval.toInt();
        }

        session.serverRefreshRound1Secret = r1Secret;
        session.refreshRound1Packages[serverIdHex] =
            jsonEncode(r1Public.toJson());
      }

      if (session.refreshRound1Packages.length == 2) {
        if (!session.completerRefreshStep1.isCompleted)
          session.completerRefreshStep1.complete();
      } else {
        await session.completerRefreshStep1.future;
      }

      return RefreshStep1Response()
        ..round1Packages.addAll(session.refreshRound1Packages)
        ..startTime = Int64(session.refreshCreationTime!.millisecondsSinceEpoch)
        ..policyId = session.refreshId!;
    } catch (e) {
      print('[${request.deviceId}] RefreshStep1 Error: $e');
      session.reset();
      rethrow;
    }
  }

  @override
  Future<RefreshStep2Response> refreshStep2(
      ServiceCall call, RefreshStep2Request request) async {
    final session = _getRefreshSession(request.deviceId);
    try {
      await session.completerRefreshStep1.future;

      if (session.refreshRound2PackagesLocal.isEmpty) {
        print('[${request.deviceId}] RefreshStep2: Server computing shares...');
        final round1Pkgs = <threshold.Identifier, threshold.Round1Package>{};
        session.refreshRound1Packages.forEach((k, v) {
          final id = threshold.Identifier(BigInt.parse(k, radix: 16));
          if (id != serverId) {
            round1Pkgs[id] = threshold.Round1Package.fromJson(jsonDecode(v));
          }
        });

        final (serverRound2Secret, serverRound2Pkgs) = threshold
            .dkgRefreshPart2(session.serverRefreshRound1Secret!, round1Pkgs);

        session.serverRefreshRound2Secret = serverRound2Secret;
        session.refreshRound2PackagesLocal.addAll(serverRound2Pkgs);
      }

      if (!session.completerRefreshStep2.isCompleted)
        session.completerRefreshStep2.complete();

      return RefreshStep2Response()
        ..allRound1Packages.addAll(session.refreshRound1Packages);
    } catch (e) {
      print('[${request.deviceId}] RefreshStep2 Error: $e');
      session.reset();
      rethrow;
    }
  }

  @override
  Future<RefreshStep3Response> refreshStep3(
      ServiceCall call, RefreshStep3Request request) async {
    final session = _getRefreshSession(request.deviceId);
    try {
      final policyState = _getPolicyState(request.deviceId);

      final senderId = threshold.Identifier.deserialize(
          Uint8List.fromList(request.identifier));
      print(
          '[${request.deviceId}] RefreshStep3: Received Shares from ${_idToString(request.identifier)}');

      await session.completerRefreshStep2.future;

      final sharesFromSenderForOthers =
          <threshold.Identifier, threshold.Round2Package>{};
      for (final entry in request.round2PackagesForOthers.entries) {
        final recipientId = _stringToId(entry.key);
        final pkg = threshold.Round2Package.fromJson(jsonDecode(entry.value));
        sharesFromSenderForOthers[recipientId] = pkg;

        if (recipientId == serverId) {
          session.refreshRound2PackagesReceived[senderId] = pkg;
        }
      }
      session.refreshRound2PackagesForRelay[senderId] =
          sharesFromSenderForOthers;

      // Determine N based on session state
      int n = 2;

      if (session.refreshRound2PackagesForRelay.length == n - 1) {
        session.refreshRound2PackagesForRelay[serverId] =
            session.refreshRound2PackagesLocal;
        if (!session.completerRefreshStep3.isCompleted)
          session.completerRefreshStep3.complete();
      } else {
        await session.completerRefreshStep3.future;
      }

      final packagesForRequester = <String, String>{};
      for (final participantId in session.refreshRound2PackagesForRelay.keys) {
        final participantShares =
            session.refreshRound2PackagesForRelay[participantId]!;
        if (participantShares.containsKey(senderId)) {
          packagesForRequester[_idToString(
                  threshold.bigIntToBytes(participantId.toScalar()))] =
              jsonEncode(participantShares[senderId]!.toJson());
        }
      }

      if (session.completerRefreshStep3.isCompleted) {
        if (session.serverRefreshRound2Secret != null) {
          // Compute logical "server" share receipt (handled in loop above).
          // Already added to relay map.

          print(
              '[${request.deviceId}] RefreshStep3: Server computing New Key...');

          final allRound1Pkgs =
              <threshold.Identifier, threshold.Round1Package>{};
          session.refreshRound1Packages.forEach((k, v) {
            final id = threshold.Identifier(BigInt.parse(k, radix: 16));
            if (id != serverId) {
              allRound1Pkgs[id] =
                  threshold.Round1Package.fromJson(jsonDecode(v));
            }
          });

          final allReceivedSharesPoints =
              <threshold.Identifier, threshold.Round2Package>{};
          allReceivedSharesPoints.addAll(session.refreshRound2PackagesReceived);

          final normalKey = policyState.normalPolicy!.keyPackage;
          final normalPub = policyState.normalPolicy!.publicKeyPackage;

          final (keyPkg, pubKeyPkg) = threshold.dkgRefreshPart3(
              session.serverRefreshRound2Secret!,
              allRound1Pkgs,
              allReceivedSharesPoints,
              normalPub,
              normalKey);

          final newPolicy = ProtectedPolicy(
            id: session.refreshId!,
            thresholdSats: BigInt.from(session.refreshThresholdAmount!.toInt()),
            startTime: session.refreshCreationTime!,
            interval: Duration(seconds: session.refreshInterval!),
            keyPackage: keyPkg,
            publicKeyPackage: pubKeyPkg,
          );

          policyState.protectedPolicies[newPolicy.id] = newPolicy;

          // Persist New Policy and Refresh Session
          try {
            await policyStore.savePolicy(
                request.deviceId, jsonEncode(policyState.toJson()));
            await refreshStore.saveSession(
                request.deviceId, jsonEncode(session.toJson()));
          } catch (e) {
            print('[${request.deviceId}] Error saving Refreshed Policy: $e');
          }

          // Prevent re-computation
          session.serverRefreshRound2Secret = null;

          // Verify invariant
          if (normalPub.verifyingKey.E.getEncoded(true).toString() !=
              pubKeyPkg.verifyingKey.E.getEncoded(true).toString()) {
            print(
                "WARNING: Group key changed during refresh! This indicates a protocol failure or attack.");
          }

          if (!session.completerRefreshStep3.isCompleted)
            session.completerRefreshStep3.complete();
        }
      }

      // Wait for completion if we weren't the trigger
      await session.completerRefreshStep3.future;

      return RefreshStep3Response()
        ..round2PackagesForMe.addAll(packagesForRequester);
    } catch (e) {
      print('[${request.deviceId}] RefreshStep3 Error: $e');
      session.reset();
      rethrow;
    }
  }

  @override
  Future<GetPolicyIdResponse> getPolicyId(
      ServiceCall call, GetPolicyIdRequest request) async {
    final policyState = _getPolicyState(request.deviceId);

    if (policyState.normalPolicy == null) {
      throw GrpcError.failedPrecondition(
          "DKG not completed for device ${request.deviceId}");
    }

    // request.txMessage is already List<int> (bytes)
    final policy = _getPolicy(
      request.txMessage,
      policyState.normalPolicy!.publicKeyPackage,
      request.deviceId,
    );

    return GetPolicyIdResponse()..policyId = policy?.id ?? "";
  }

  @override
  Future<CreateSpendingPolicyResponse> createSpendingPolicy(
      ServiceCall call, CreateSpendingPolicyRequest request) async {
    throw GrpcError.unimplemented("Use Refresh flow to create policies");
  }

  @override
  Future<BroadcastTransactionResponse> broadcastTransaction(
      ServiceCall call, BroadcastTransactionRequest request) async {
    print(
        '[${request.deviceId}] Broadcasting Tx: ${request.txHex.substring(0, 20)}...');

    // We assume bitcoinService is available (dependency injection or member).
    // Let's assume we added `bitcoinService` to the class, see initialization below.
    // Wait, I need to add the field first.
    // I will do this in a multi-step or separate replacement if needed,
    // but here I strictly replace the method body.
    // I'll assume `bitcoinService` is injected.

    final policyState = _getPolicyState(request.deviceId);
    final (txId, _) = await bitcoinService.broadcastTransaction(
        request.deviceId, request.txHex, policyState);

    return BroadcastTransactionResponse()..txId = txId;
  }

  @override
  Future<FetchHistoryResponse> fetchHistory(
      ServiceCall call, FetchHistoryRequest request) async {
    final policyState = _getPolicyState(request.deviceId);

    // Fetch from BitcoinHistoryService
    final utxos = await historyService.getUtxos(request.deviceId, policyState);

    return FetchHistoryResponse()..utxos.addAll(utxos);
  }

  @override
  Future<FetchRecentTransactionsResponse> fetchRecentTransactions(
      ServiceCall call, FetchRecentTransactionsRequest request) async {
    final policyState = _getPolicyState(request.deviceId);
    try {
      final txs = await historyService.getRecentTransactions(
          request.deviceId, policyState);

      print(
          '[${request.deviceId}] FetchRecentTransactionsResponse: ${txs.length} txs');
      return FetchRecentTransactionsResponse()..transactions.addAll(txs);
    } catch (e) {
      print('[${request.deviceId}] fetchRecentTransactions Error: $e');
      rethrow;
    }
  }

  @override
  Stream<TransactionNotification> subscribeToHistory(
      ServiceCall call, SubscribeToHistoryRequest request) {
    final policyState = _getPolicyState(request.deviceId);
    return historyService.subscribe(request.deviceId, policyState);
  }
} // End of MPCWalletService

Future<void> main(List<String> args) async {
  Server? server;
  BitcoinHistoryService? historyService;
  var shuttingDown = false;

  Future<void> shutdown(
      {int exitCode = 0, Object? error, StackTrace? stack}) async {
    if (shuttingDown) return;
    shuttingDown = true;

    if (error != null) {
      stderr.writeln('Unhandled exception: $error');
      if (stack != null) {
        stderr.writeln(stack);
      }
    } else {
      print('Shutting down...');
    }

    // Close services first to terminate active streams (prevents gRPC shutdown hang)
    try {
      if (historyService != null) {
        await historyService!.close().timeout(const Duration(seconds: 2),
            onTimeout: () {
          print("History service close timed out.");
        });
      }
    } catch (e) {
      stderr.writeln('Error closing history service: $e');
    }

    try {
      // Shutdown gRPC server
      if (server != null) {
        await server!.shutdown().timeout(const Duration(seconds: 2),
            onTimeout: () {
          print("Server shutdown timed out.");
        });
      }
    } catch (e) {
      stderr.writeln('Error shutting down server: $e');
    }

    try {
      await Hive.close().timeout(const Duration(seconds: 2), onTimeout: () {
        print("Hive close timed out.");
        return [];
      });
    } catch (e) {
      stderr.writeln('Error closing Hive: $e');
    }

    exit(exitCode);
  }

  void handleSignal(ProcessSignal signal) {
    stderr.writeln('Received $signal, shutting down.');
    shutdown(exitCode: 0);
  }

  for (final signal in [
    ProcessSignal.sigint,
    ProcessSignal.sigterm,
  ]) {
    try {
      signal.watch().listen(handleSignal);
    } catch (e) {
      stderr.writeln('Signal $signal not supported: $e');
    }
  }

  await runZonedGuarded(() async {
    // Persistence Init
    final home = Platform.environment['HOME'] ?? Directory.current.path;
    final serverStorePath = p.join(home, '.mpc_wallet', 'server');
    final dir = Directory(serverStorePath);
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    Hive.init(serverStorePath);
    print('Persistence Path: $serverStorePath');

    final dkgStore = DKGSessionStore();
    final policyStore = PolicyStore();
    final refreshStore = RefreshSessionStore();
    final signingStore = SigningSessionStore();
    final utxoStore = UtxoStore();

    await dkgStore.init();
    await policyStore.init();
    await refreshStore.init();
    await signingStore.init();
    await utxoStore.init();
    print('Store initialized.');

    // Bitcoin Services Init
    final bitcoinService = BitcoinService(utxoStore); // Legacy/RPC/Broadcast

    final electrumUrl =
        Platform.environment['ELECTRUM_URL'] ?? 'electrum.blockstream.info';
    final electrumPort =
        int.tryParse(Platform.environment['ELECTRUM_PORT'] ?? '60002') ?? 60002;
    print("Connecting to Electrum at $electrumUrl:$electrumPort");

    historyService = BitcoinHistoryService(
        electrumUrl: electrumUrl,
        electrumPort: electrumPort); // Electrum/History
    await historyService!.init();

    final serverPort =
        int.tryParse(Platform.environment['PORT'] ?? '') ?? 50051;
    server = Server.create(
      services: [
        MPCWalletService(
            dkgStore: dkgStore,
            signingStore: signingStore,
            refreshStore: refreshStore,
            policyStore: policyStore,
            utxoStore: utxoStore,
            bitcoinService: bitcoinService,
            historyService: historyService!)
      ],
    );
    await server!.serve(port: serverPort);
    print('Server listening on port ${server!.port}...');
  }, (error, stack) async {
    await shutdown(exitCode: 1, error: error, stack: stack);
  });
}

String randomBase64(int bytes) {
  final rand = Random.secure();
  final values = List<int>.generate(bytes, (_) => rand.nextInt(256));
  return base64UrlEncode(values);
}
