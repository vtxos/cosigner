import 'dart:typed_data';
import 'package:pointycastle/ecc/api.dart';
import 'package:threshold/core/utils.dart';
import 'package:threshold/frost/signature.dart';
import 'package:threshold/core/share.dart';
import 'package:threshold/core/dkg.dart';
import 'auth_message.dart';

/// Single-key Schnorr signer for authentication.
///
/// This class provides BIP-340 compatible Schnorr signatures using
/// a single private key (not threshold). Used for authenticating
/// gRPC requests before MPC operations.
class AuthSigner {
  final BigInt _privateKey;
  final ECPoint _publicKey;

  AuthSigner._(this._privateKey, this._publicKey);

  /// Creates an AuthSigner from a secret key scalar.
  factory AuthSigner.fromSecretKey(BigInt secretKey) {
    final publicKey = elemBaseMul(secretKey);
    return AuthSigner._(secretKey, publicKey);
  }

  /// Creates an AuthSigner from a SecretKey object.
  factory AuthSigner.fromSecret(SecretKey secret) {
    return AuthSigner.fromSecretKey(secret.scalar);
  }

  /// Creates an AuthSigner from private key bytes (32 bytes, big-endian).
  factory AuthSigner.fromBytes(Uint8List privateKeyBytes) {
    if (privateKeyBytes.length != 32) {
      throw ArgumentError('Private key must be exactly 32 bytes');
    }
    final scalar = bytesToBigInt(privateKeyBytes);
    return AuthSigner.fromSecretKey(scalar);
  }

  /// Returns the public key point.
  ECPoint get publicKey => _publicKey;

  /// Returns the compressed public key bytes (33 bytes).
  Uint8List get publicKeyCompressed => elemSerializeCompressed(_publicKey);

  /// Returns the x-only public key bytes (32 bytes) for BIP-340.
  Uint8List get publicKeyXOnly => elemSerializeCompressed(_publicKey).sublist(1);

  /// Signs a message using BIP-340 Schnorr signature scheme.
  ///
  /// Returns a 64-byte signature (32-byte R x-coordinate + 32-byte s scalar).
  Signature sign(Uint8List message) {
    // Ensure public key has even Y (BIP-340 requirement)
    var privateKey = _privateKey;
    var publicKey = _publicKey;

    if (!publicKey.y!.toBigInteger()!.isEven) {
      privateKey = secp256k1Curve.n - privateKey;
      publicKey = elemBaseMul(privateKey);
    }

    // Generate deterministic nonce using RFC 6979 style approach
    // k = H(d || m) where d is private key, m is message
    final nonceInput = Uint8List(64);
    nonceInput.setRange(0, 32, bigIntToBytes(privateKey));
    nonceInput.setRange(32, 64, message);
    final k = taggedHash('BIP0340/nonce', nonceInput);

    // R = k * G
    var R = elemBaseMul(k);
    var kAdjusted = k;

    // Ensure R has even Y
    if (!R.y!.toBigInteger()!.isEven) {
      kAdjusted = secp256k1Curve.n - k;
      R = elemBaseMul(kAdjusted);
    }

    // e = H(R || P || m)
    final challenge = computeChallenge(R, VerifyingKey(E: publicKey), message);

    // s = k + e * d (mod n)
    final s = (kAdjusted + (challenge * privateKey)) % secp256k1Curve.n;

    return Signature(R, s);
  }

  /// Signs an AuthMessage and returns the serialized signature bytes.
  Uint8List signAuthMessage(AuthMessage authMessage) {
    final signature = sign(authMessage.messageBytes);
    return signature.serialize();
  }

  /// Creates a signature for a specific operation.
  ///
  /// This is a convenience method that builds the AuthMessage internally.
  Uint8List signOperation({
    required String operation,
    required String userIdHex,
    int? timestampMs,
  }) {
    final authMessage = AuthMessage(
      operation: operation,
      timestampMs: timestampMs ?? DateTime.now().millisecondsSinceEpoch,
      userIdHex: userIdHex,
    );
    return signAuthMessage(authMessage);
  }
}

/// Verifies a BIP-340 Schnorr signature against a public key.
///
/// This is a standalone verification function that can be used
/// without an AuthSigner instance.
bool verifySchnorrSignature({
  required Uint8List publicKeyCompressed,
  required Uint8List message,
  required Uint8List signatureBytes,
}) {
  if (signatureBytes.length != 64) {
    return false;
  }
  if (publicKeyCompressed.length != 33) {
    return false;
  }

  try {
    // Parse signature
    final rXBytes = Uint8List(33);
    // Determine the prefix byte based on convention (assume even Y for x-only)
    rXBytes[0] = 0x02;
    rXBytes.setRange(1, 33, signatureBytes.sublist(0, 32));

    final R = elemDeserializeCompressed(rXBytes);
    final z = bytesToBigInt(signatureBytes.sublist(32, 64));

    final signature = Signature(R, z);
    final publicKey = elemDeserializeCompressed(publicKeyCompressed);
    final verifyingKey = VerifyingKey(E: publicKey);

    // This will throw if verification fails
    signature.verify(verifyingKey, message);
    return true;
  } catch (e) {
    return false;
  }
}
