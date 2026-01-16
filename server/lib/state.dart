import 'dart:async';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:threshold/threshold.dart' as threshold;
import 'package:threshold/frost/commitment.dart' as frost_comm;
import 'package:fixnum/fixnum.dart';

import 'policy.dart';

// --- Session State ---
// This class is serialized to JSON for Hive persistence.
// For brevity, we are keeping it as an in-memory object and manually serializing parts of it
// or relying on re-computation where state is ephemeral.
// DKG state is somewhat ephemeral (only needed during DKG).
// KeyPackage is persistent.
class DKGSessionState {
  final String userId;

  // Ephemeral DKG locks/signals (Not persisted directly, recreated on load)
  Completer<void> completerStep1 = Completer<void>();
  Completer<void> completerStep2 = Completer<void>();
  Completer<void> completerStep3 = Completer<void>();

  // DKG Data (Persisted)
  final round1Packages = <threshold.Identifier, String>{}; // Identifier -> JSON

  Uint8List? serverId;

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

  DKGSessionState(this.userId);

  Map<String, dynamic> toJson() {
    return {
      'userId': userId,
      'round1Packages': round1Packages.map(
        (k, v) => MapEntry(hex.encode(k.serialize()), v),
      ),
      // Secrets are not persisted to avoid complexity with missing toJson
      // DKG sessions will restart if server restarts
    };
  }

  static DKGSessionState fromJson(Map<String, dynamic> json) {
    final s = DKGSessionState(json['userId']);
    if (json['round1Packages'] != null) {
      final raw = Map<String, dynamic>.from(json['round1Packages']);
      raw.forEach((k, v) {
        final id = threshold.Identifier.deserialize(
            Uint8List.fromList(hex.decode(k)));
        s.round1Packages[id] = v as String;
      });
    }
    return s;
  }

  void reset() {
    completerStep1 = Completer<void>();
    completerStep2 = Completer<void>();
    completerStep3 = Completer<void>();
    round1Packages.clear();
    serverInternalSecret = null;
    serverRound1SecretPackage = null;
    serverRound2Secret = null;
    dkgRound2PackagesReceived.clear();
    dkgRound2PackagesLocal.clear();
    dkgRound2PackagesForRelay.clear();
  }
}

class PolicyState {
  final String userId;
  final String recoveryId;

  // normal Policy
  final NormalPolicy normalPolicy;
  // protected Policies
  final protectedPolicies = Map<String, ProtectedPolicy>();

  final spendingHistory = <SpendingEntry>[];

  PolicyState(this.userId, this.recoveryId, this.normalPolicy);

  Map<String, dynamic> toJson() {
    return {
      'userId': userId,
      'recoveryId': recoveryId,
      'normalPolicy': normalPolicy.toJson(),
      'protectedPolicies':
          protectedPolicies.map((k, v) => MapEntry(k, v.toJson())),
      'spendingHistory': spendingHistory.map((e) => e.toJson()).toList(),
    };
  }

  static PolicyState fromJson(Map<String, dynamic> json) {
    final s = PolicyState(json['userId'], json['recoveryId'],
        NormalPolicy.fromJson(json['normalPolicy']));

    if (json['protectedPolicies'] != null) {
      final Map<String, dynamic> map = json['protectedPolicies'];
      map.forEach((k, v) {
        s.protectedPolicies[k] = ProtectedPolicy.fromJson(v);
      });
    }
    if (json['spendingHistory'] != null) {
      final List list = json['spendingHistory'];
      s.spendingHistory.addAll(list.map((e) => SpendingEntry.fromJson(e)));
    }
    return s;
  }
}

class RefreshSessionState {
  final String userId;

  Uint8List? serverId;

  // Refresh Ephemeral
  final refreshRound1Packages = <threshold.Identifier, String>{};
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

  RefreshSessionState(this.userId);

  Map<String, dynamic> toJson() {
    return {
      'userId': userId,
      'refreshRound1Packages': refreshRound1Packages.map(
        (k, v) => MapEntry(hex.encode(k.serialize()), v),
      ),
      'refreshCreationTime': refreshCreationTime?.millisecondsSinceEpoch,
      'refreshId': refreshId,
      'refreshThresholdAmount': refreshThresholdAmount?.toString(),
      'refreshInterval': refreshInterval,
    };
  }

  static RefreshSessionState fromJson(Map<String, dynamic> json) {
    final s = RefreshSessionState(json['userId']);
    if (json['refreshRound1Packages'] != null) {
      final raw = Map<String, dynamic>.from(json['refreshRound1Packages']);
      raw.forEach((k, v) {
        final id = threshold.Identifier.deserialize(
            Uint8List.fromList(hex.decode(k)));
        s.refreshRound1Packages[id] = v as String;
      });
    }
    if (json['refreshCreationTime'] != null) {
      s.refreshCreationTime =
          DateTime.fromMillisecondsSinceEpoch(json['refreshCreationTime']);
    }
    s.refreshId = json['refreshId'];
    if (json['refreshThresholdAmount'] != null) {
      s.refreshThresholdAmount = Int64.parseInt(json['refreshThresholdAmount']);
    }
    s.refreshInterval = json['refreshInterval'];
    return s;
  }

  void reset() {
    refreshRound1Packages.clear();
    serverRefreshRound1Secret = null;
    serverRefreshRound2Secret = null;
    refreshRound2PackagesReceived.clear();
    refreshRound2PackagesLocal.clear();
    refreshRound2PackagesForRelay.clear();
    refreshCreationTime = null;
    refreshId = null;
    refreshThresholdAmount = null;
    refreshInterval = null;
    completerRefreshStep1 = Completer<void>();
    completerRefreshStep2 = Completer<void>();
    completerRefreshStep3 = Completer<void>();
  }
}

class SigningSessionState {
  final String userId;

  // Signing (Ephemeral per request usually, but if we need persistent sessions for signing...)
  // The prompt implies "session for each DKG", so DKG is the session scope.
  // Signing refers to the DKG session (user_id) to get keys.
  Completer<void> completerSignStep1 = Completer<void>();
  Completer<void> completerSignStep2 = Completer<void>();

  frost_comm.SigningNonce? serverNonce;
  frost_comm.SigningCommitments? serverCommitments;
  frost_comm.SigningCommitments? userCommitments;

  Uint8List? messageToSign;
  final signRound2Shares = <threshold.Identifier, BigInt>{};

  Map<threshold.Identifier, threshold.SigningCommitments> signCommitmentList =
      {};

  // current session PolicyID
  String? currentPolicyId;
  BigInt? pendingAmount;

  SigningSessionState(this.userId);

  void reset() {
    completerSignStep1 = Completer<void>();
    completerSignStep2 = Completer<void>();
    serverNonce = null;
    serverCommitments = null;
    userCommitments = null;
    messageToSign = null;
    signRound2Shares.clear();
    currentPolicyId = null;
    pendingAmount = null;
  }
}

class SpendingEntry {
  final DateTime timestamp;
  final BigInt amount;
  SpendingEntry(this.timestamp, this.amount);

  Map<String, dynamic> toJson() {
    return {
      'timestamp': timestamp.millisecondsSinceEpoch,
      'amount': amount.toString(),
    };
  }

  static SpendingEntry fromJson(Map<String, dynamic> json) {
    return SpendingEntry(
      DateTime.fromMillisecondsSinceEpoch(json['timestamp']),
      BigInt.parse(json['amount']),
    );
  }
}

class UtxoState {
  final String userId;
  List<Utxo> utxos;

  UtxoState(this.userId) : utxos = [];

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
