import 'dart:typed_data';
import 'package:threshold/auth/auth_message.dart';
import 'package:threshold/auth/auth_signer.dart';
import 'package:grpc/grpc.dart';
import 'package:logging/logging.dart';

final _log = Logger('AuthVerifier');

/// Server-side authentication verifier for MPC Wallet requests.
///
/// Validates Schnorr signatures over authentication messages to ensure
/// requests are properly authorized by the wallet owner.
class AuthVerifier {
  /// Maximum allowed clock skew between client and server (5 minutes)
  final int maxClockSkewMs;

  /// Optional: Set of recently used timestamps to prevent replay attacks
  /// In production, use a distributed cache like Redis with TTL
  final Set<String> _usedNonces = {};

  /// Maximum size of nonce cache before cleanup
  final int _maxNonceCacheSize;

  AuthVerifier({
    this.maxClockSkewMs = AuthMessage.maxTimestampDriftMs,
    int maxNonceCacheSize = 10000,
  }) : _maxNonceCacheSize = maxNonceCacheSize;

  /// Verifies an authentication signature for a request.
  ///
  /// [publicKeyCompressed] - The user's compressed public key (33 bytes)
  /// [signatureBytes] - The 64-byte Schnorr signature
  /// [operation] - The expected operation type
  /// [timestampMs] - The timestamp from the request
  /// [userIdHex] - The user ID in hex format
  ///
  /// Throws [GrpcError] if verification fails.
  void verifyAuth({
    required Uint8List publicKeyCompressed,
    required Uint8List signatureBytes,
    required String operation,
    required int timestampMs,
    required String userIdHex,
  }) {
    // 1. Validate timestamp to prevent replay attacks
    _validateTimestamp(timestampMs, userIdHex, operation);

    // 2. Build the auth message that should have been signed
    final authMessage = AuthMessage(
      operation: operation,
      timestampMs: timestampMs,
      userIdHex: userIdHex,
    );

    // 3. Verify the signature
    final isValid = verifySchnorrSignature(
      publicKeyCompressed: publicKeyCompressed,
      message: authMessage.messageBytes,
      signatureBytes: signatureBytes,
    );

    if (!isValid) {
      _log.warning('[$userIdHex] Signature verification failed for $operation');
      throw GrpcError.unauthenticated('Invalid authentication signature');
    }

    // 4. Record the nonce to prevent replay
    _recordNonce(timestampMs, userIdHex, operation);

    _log.fine('[$userIdHex] Auth verified for $operation');
  }

  /// Validates that the timestamp is within acceptable bounds.
  void _validateTimestamp(int timestampMs, String userIdHex, String operation) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final diff = (now - timestampMs).abs();

    if (diff > maxClockSkewMs) {
      _log.warning(
          '[$userIdHex] Timestamp validation failed for $operation: '
          'diff=${diff}ms, max=${maxClockSkewMs}ms');
      throw GrpcError.unauthenticated(
          'Request timestamp is outside acceptable range');
    }

    // Check for replay (same timestamp + user + operation)
    final nonceKey = _buildNonceKey(timestampMs, userIdHex, operation);
    if (_usedNonces.contains(nonceKey)) {
      _log.warning('[$userIdHex] Replay detected for $operation');
      throw GrpcError.unauthenticated('Request replay detected');
    }
  }

  /// Records a nonce to prevent replay attacks.
  void _recordNonce(int timestampMs, String userIdHex, String operation) {
    final nonceKey = _buildNonceKey(timestampMs, userIdHex, operation);

    // Simple cache cleanup when too large
    if (_usedNonces.length >= _maxNonceCacheSize) {
      // In production, use TTL-based eviction
      // For now, clear half the cache (oldest entries would be expired anyway)
      final toRemove = _usedNonces.take(_maxNonceCacheSize ~/ 2).toList();
      for (final key in toRemove) {
        _usedNonces.remove(key);
      }
    }

    _usedNonces.add(nonceKey);
  }

  String _buildNonceKey(int timestampMs, String userIdHex, String operation) {
    return '$timestampMs:$userIdHex:$operation';
  }

  /// Validates timestamp and records nonce without verifying a signature.
  ///
  /// Used for FROST-signed requests where the signature verification
  /// is handled separately (not single-key Schnorr).
  void validateRequestTiming({
    required int timestampMs,
    required String userIdHex,
    required String operation,
  }) {
    _validateTimestamp(timestampMs, userIdHex, operation);
    _recordNonce(timestampMs, userIdHex, operation);
  }

  /// Clears the nonce cache. Primarily for testing.
  void clearNonceCache() {
    _usedNonces.clear();
  }
}

/// Extension to simplify auth verification in gRPC handlers.
extension AuthVerifierExtension on AuthVerifier {
  /// Verifies authentication for SignStep1 requests.
  void verifySignStep1({
    required Uint8List userId,
    required Uint8List signature,
    required int timestampMs,
  }) {
    final userIdHex = _bytesToHex(userId);
    verifyAuth(
      publicKeyCompressed: userId,
      signatureBytes: signature,
      operation: AuthMessage.opSignStep1,
      timestampMs: timestampMs,
      userIdHex: userIdHex,
    );
  }

  /// Verifies authentication for SignStep2 requests.
  void verifySignStep2({
    required Uint8List userId,
    required Uint8List signature,
    required int timestampMs,
  }) {
    final userIdHex = _bytesToHex(userId);
    verifyAuth(
      publicKeyCompressed: userId,
      signatureBytes: signature,
      operation: AuthMessage.opSignStep2,
      timestampMs: timestampMs,
      userIdHex: userIdHex,
    );
  }

  /// Verifies authentication for RefreshStep1 requests.
  void verifyRefreshStep1({
    required Uint8List userId,
    required Uint8List signature,
    required int timestampMs,
  }) {
    final userIdHex = _bytesToHex(userId);
    verifyAuth(
      publicKeyCompressed: userId,
      signatureBytes: signature,
      operation: AuthMessage.opRefreshStep1,
      timestampMs: timestampMs,
      userIdHex: userIdHex,
    );
  }

  /// Verifies authentication for RefreshStep2 requests.
  void verifyRefreshStep2({
    required Uint8List userId,
    required Uint8List signature,
    required int timestampMs,
  }) {
    final userIdHex = _bytesToHex(userId);
    verifyAuth(
      publicKeyCompressed: userId,
      signatureBytes: signature,
      operation: AuthMessage.opRefreshStep2,
      timestampMs: timestampMs,
      userIdHex: userIdHex,
    );
  }

  /// Verifies authentication for RefreshStep3 requests.
  void verifyRefreshStep3({
    required Uint8List userId,
    required Uint8List signature,
    required int timestampMs,
  }) {
    final userIdHex = _bytesToHex(userId);
    verifyAuth(
      publicKeyCompressed: userId,
      signatureBytes: signature,
      operation: AuthMessage.opRefreshStep3,
      timestampMs: timestampMs,
      userIdHex: userIdHex,
    );
  }

  /// Verifies authentication for GetPolicyId requests.
  void verifyGetPolicyId({
    required Uint8List userId,
    required Uint8List signature,
    required int timestampMs,
  }) {
    final userIdHex = _bytesToHex(userId);
    verifyAuth(
      publicKeyCompressed: userId,
      signatureBytes: signature,
      operation: AuthMessage.opGetPolicyId,
      timestampMs: timestampMs,
      userIdHex: userIdHex,
    );
  }

  /// Verifies authentication for FetchHistory requests.
  void verifyFetchHistory({
    required Uint8List userId,
    required Uint8List signature,
    required int timestampMs,
  }) {
    final userIdHex = _bytesToHex(userId);
    verifyAuth(
      publicKeyCompressed: userId,
      signatureBytes: signature,
      operation: AuthMessage.opFetchHistory,
      timestampMs: timestampMs,
      userIdHex: userIdHex,
    );
  }

  /// Verifies authentication for FetchRecentTransactions requests.
  void verifyFetchRecentTransactions({
    required Uint8List userId,
    required Uint8List signature,
    required int timestampMs,
  }) {
    final userIdHex = _bytesToHex(userId);
    verifyAuth(
      publicKeyCompressed: userId,
      signatureBytes: signature,
      operation: AuthMessage.opFetchRecentTxs,
      timestampMs: timestampMs,
      userIdHex: userIdHex,
    );
  }

  /// Verifies authentication for SubscribeToHistory requests.
  void verifySubscribeHistory({
    required Uint8List userId,
    required Uint8List signature,
    required int timestampMs,
  }) {
    final userIdHex = _bytesToHex(userId);
    verifyAuth(
      publicKeyCompressed: userId,
      signatureBytes: signature,
      operation: AuthMessage.opSubscribeHistory,
      timestampMs: timestampMs,
      userIdHex: userIdHex,
    );
  }

  String _bytesToHex(Uint8List bytes) {
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }
}
