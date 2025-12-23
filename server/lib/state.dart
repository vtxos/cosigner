import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:grpc/grpc.dart';
import 'package:threshold/threshold.dart' as threshold;
import 'package:threshold/frost/signing.dart' as frost;
import 'package:threshold/frost/commitment.dart' as frost_comm;
import 'package:fixnum/fixnum.dart';

import 'package:bitcoin_base/bitcoin_base.dart';
import 'package:blockchain_utils/blockchain_utils.dart'; // for hex

import 'package:protocol/protocol.dart';
import 'persistence/store.dart';
import 'policy.dart';

// --- Session State ---
// This class is serialized to JSON for Hive persistence.
// For brevity, we are keeping it as an in-memory object and manually serializing parts of it
// or relying on re-computation where state is ephemeral.
// DKG state is somewhat ephemeral (only needed during DKG).
// KeyPackage is persistent.
class DKGSessionState {
  final String deviceId;

  // Ephemeral DKG locks/signals (Not persisted directly, recreated on load)
  Completer<void> completerStep1 = Completer<void>();
  Completer<void> completerStep2 = Completer<void>();
  Completer<void> completerStep3 = Completer<void>();

  // DKG Data (Persisted)
  final round1Packages = <String, String>{}; // HexID -> JSON

  threshold.SecretKey? serverInternalSecret;
  threshold.Round1SecretPackage? serverRound1SecretPackage;
  threshold.Round2SecretPackage? serverRound2Secret;

  // Round 2
  final dkgRound2PackagesReceived =
      <threshold.Identifier, threshold.Round2Package>{};
  final dkgRound2PackagesLocal =
      <threshold.Identifier, threshold.Round2Package>{};
  final dkgRound2PackagesForRelay = <threshold.Identifier,
      Map<threshold.Identifier, threshold.Round2Package>>{};

  DKGSessionState(this.deviceId);
}

class PolicyState {
  final String deviceId;

  // normal Policy
  NormalPolicy? normalPolicy;
  // protected Policies
  final protectedPolicies = Map<String, ProtectedPolicy>();

  final spendingHistory = <SpendingEntry>[];

  PolicyState(this.deviceId);
}

class RefreshSessionState {
  final String deviceId;

  // Refresh Ephemeral
  final refreshRound1Packages = <String, String>{};
  threshold.Round1SecretPackage? serverRefreshRound1Secret;
  threshold.Round2SecretPackage? serverRefreshRound2Secret;

  final refreshRound2PackagesReceived =
      <threshold.Identifier, threshold.Round2Package>{};
  final refreshRound2PackagesLocal =
      <threshold.Identifier, threshold.Round2Package>{};
  final refreshRound2PackagesForRelay = <threshold.Identifier,
      Map<threshold.Identifier, threshold.Round2Package>>{};

  DateTime? refreshCreationTime;
  String? refreshId;
  Int64? refreshThresholdAmount;
  int? refreshInterval;

  Completer<void> completerRefreshStep1 = Completer<void>();
  Completer<void> completerRefreshStep2 = Completer<void>();
  Completer<void> completerRefreshStep3 = Completer<void>();

  RefreshSessionState(this.deviceId);
}

class SigningSessionState {
  final String deviceId;

  // Signing (Ephemeral per request usually, but if we need persistent sessions for signing...)
  // The prompt implies "session for each DKG", so DKG is the session scope.
  // Signing refers to the DKG session (device_id) to get keys.
  Completer<void> completerSignStep1 = Completer<void>();
  Completer<void> completerSignStep2 = Completer<void>();

  frost_comm.SigningNonce? serverNonce;
  frost_comm.SigningCommitments? serverCommitments;
  final signCommitmentsReceived =
      <threshold.Identifier, frost_comm.SigningCommitments>{};
  Uint8List? messageToSign;
  final signRound2Shares = <threshold.Identifier, BigInt>{};

  // current session PolicyID
  String? currentPolicyId;
  BigInt? pendingAmount;

  SigningSessionState(this.deviceId);
}

class SpendingEntry {
  final DateTime timestamp;
  final BigInt amount;
  SpendingEntry(this.timestamp, this.amount);
}

class UtxoState {
  final String deviceId;
  List<Utxo> utxos;

  UtxoState(this.deviceId) : utxos = [];

  void addUtxoList(List<Utxo> utxos) {
    this.utxos.addAll(utxos);
  }
}

class Utxo {
  final BigInt amount;
  final String txid;
  final int vout;

  Utxo(this.amount, this.txid, this.vout);
}
