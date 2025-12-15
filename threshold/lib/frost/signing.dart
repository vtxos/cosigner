import 'dart:typed_data';

import 'package:pointycastle/ecc/api.dart';
import 'package:threshold/core/dkg.dart'; // For KeyPackage, PublicKeyPackage, Signature
import 'package:threshold/core/identifier.dart';
import 'package:threshold/core/share.dart';
import 'package:threshold/core/utils.dart'; // for constants, BigInt utils
import 'package:threshold/frost/errors.dart';
import 'package:threshold/frost/utils.dart';
import 'package:threshold/frost/commitment.dart';
import 'package:threshold/frost/binding.dart';
import 'package:threshold/frost/signature.dart';

class SignatureShare {
  final BigInt s;
  SignatureShare(this.s);
}

// Sign implements [sign] from the spec.
// Returns a signature share.
// Sign implements [sign] from the spec.
// Returns a signature share.
SignatureShare sign(
  SigningPackage signingPackage,
  SigningNonce signingNonce,
  KeyPackage keyPackage,
) {
  if (signingPackage.commitments.length < keyPackage.minSigners) {
    throw errIncorrectNumberOfCommitments;
  }

  // ensure keyPackage Public key is even
  keyPackage = keyPackage.intoEvenY();

  final commitment = signingPackage.commitments[keyPackage.identifier];
  if (commitment == null) {
    // This participant is not in the signing set
    throw errInvalidCommitment; // Using similar error
  }

  // Check if nonce matches commitment.
  if (!pointsEqual(signingNonce.commitments.binding, commitment.binding) ||
      !pointsEqual(signingNonce.commitments.hiding, commitment.hiding)) {
    throw errInvalidCommitment;
  }

  final bfl = computeBindingFactorList(signingPackage, keyPackage.verifyingKey);
  final groupCommitment = computeGroupCommitment(signingPackage, bfl);

  // BIP-340: If R has odd Y, we must negate the nonces (d and e)
  // effectively signing for -R (which is even).
  final isROdd = groupCommitment.elem.y!.toBigInteger()!.isOdd;

  final lambdaI = deriveInterpolatingValue(
    keyPackage.identifier,
    signingPackage,
  );

  // Compute challenge using R (computeChallenge handles x-only serialization)
  final challenge = computeChallenge(
    groupCommitment.elem,
    keyPackage.verifyingKey,
    signingPackage.message,
  );

  // Compute Signature Share
  // z_i = d_i + (e_i * rho_i) + lambda_i * s_i * c
  final bf = bfl.get(keyPackage.identifier);
  if (bf == null) throw errIncorrectBindingFactorPreimages; // Should not happen

  return computeSignatureShare(
    signingNonce,
    bf.scalar,
    lambdaI,
    keyPackage,
    challenge,
    negateNonce: isROdd,
  );
}

BigInt deriveInterpolatingValue(Identifier id, SigningPackage pkg) {
  final ids = sortedCommitmentIDs(pkg.commitments.keys.toList());
  return lagrangeCoeffAtZero(id, ids);
}

// Helper to compute signature share
SignatureShare computeSignatureShare(
  SigningNonce nonce,
  BigInt rhoI,
  BigInt lambdaI,
  KeyPackage keyPackage,
  BigInt challenge, {
  bool negateNonce = false,
}) {
  var d = nonce.hiding;
  var e = nonce.binding;

  if (negateNonce) {
    final n = secp256k1Curve.n;
    d = (n - d) % n;
    e = (n - e) % n;
  }

  final s = keyPackage.secretShare;
  final c = challenge;

  final modulus = secp256k1Curve.n;

  final eRho = (e * rhoI) % modulus;
  final lsc = (lambdaI * s * c) % modulus;

  final z = (d + eRho + lsc) % modulus;

  return SignatureShare(z);
}

// Aggregate
// Returns Signature (R, z)
Signature aggregate(
  SigningPackage signingPackage,
  Map<Identifier, SignatureShare> signatureShares,
  PublicKeyPackage pubkeys,
) {
  // 1. Check identifiers
  if (signingPackage.commitments.length != signatureShares.length) {
    throw errUnknownIdentifier;
  }

  // ensure pubkeys Public key is even
  pubkeys = pubkeys.intoEvenY();

  for (final id in signingPackage.commitments.keys) {
    if (!signatureShares.containsKey(id) ||
        !pubkeys.verifyingShares.containsKey(id)) {
      throw errUnknownIdentifier;
    }
  }

  final bfl = computeBindingFactorList(signingPackage, pubkeys.verifyingKey);
  final groupCommitment = computeGroupCommitment(signingPackage, bfl);

  final isROdd = groupCommitment.elem.y!.toBigInteger()!.isOdd;

  // Aggregate z = sum(z_i)
  var z = BigInt.zero;
  final modulus = secp256k1Curve.n;

  for (final entry in signatureShares.entries) {
    final id = entry.key;
    final share = entry.value;

    // Verify share (optional but recommended)
    verifySignatureShare(
      id,
      pubkeys.verifyingShares[id]!,
      share,
      signingPackage,
      pubkeys.verifyingKey,
      negateR: isROdd,
    );

    z = (z + share.s) % modulus;
  }

  // If R was odd, the aggregated z is for -R (which is even).
  // We return R as the point used for verification (implicit even in BIP340).
  // Ideally we return the Even version of R.

  ECPoint effectiveR = groupCommitment.elem;
  if (isROdd) {
    // Negate R logic (multiply by n-1)
    final n = secp256k1Curve.n;
    effectiveR = (effectiveR * (n - BigInt.one))!;
  }

  final sig = Signature(effectiveR, z);

  // Verify final signature
  final challenge = computeChallenge(
    effectiveR, // Use Even R
    pubkeys.verifyingKey,
    signingPackage.message,
  );

  // Verify: z * G == R + c * Y
  final zG = (secp256k1Curve.G * z)!;

  final cY = (pubkeys.verifyingKey.E * challenge)!;
  final R_plus_cY = (effectiveR + cY)!;

  if (pointsEqual(zG, R_plus_cY)) {
    return sig;
  }

  // Cheater detection would go here (verifySignatureShare)
  throw errorInvalidSignature;
}

// Verify Signature Share
void verifySignatureShare(
  Identifier identifier,
  ECPoint verifyingShare,
  SignatureShare signatureShare,
  SigningPackage signingPackage,
  VerifyingKey verifyingKey, {
  bool negateR = false,
}) {
  // Binding factors and group commitment
  final bfl = computeBindingFactorList(signingPackage, verifyingKey);

  // R_share check needs global challenge?
  // challenge depends on GLOBAL R.
  // We need to compute global R to get challenge.

  // Optimization: pass challenge in? For now recompute.
  final groupCommitment = computeGroupCommitment(signingPackage, bfl);
  // effectiveR needed for challenge
  ECPoint effectiveR = groupCommitment.elem;
  if (effectiveR.y!.toBigInteger()!.isOdd) {
    // Must match negating logic.
    // If we are calling verifySignatureShare inside aggregate, we assume parity check matched.
  }
  // Bip340 challenge always uses x-only R. So parity doesn't matter for challenge hash.

  final challenge = computeChallenge(
    groupCommitment.elem,
    verifyingKey,
    signingPackage.message,
  );

  // Verify:
  // z_i * G == R_share + c * lambda_i * Y_i
  // If negateR is true, LHS z_i is negated nonces.
  // So z_i corresponds to -R_share.
  // So z_i * G == -R_share + ...

  final comm = signingPackage.commitments[identifier];
  if (comm == null) throw errUnknownIdentifier;

  final bf = bfl.get(identifier);
  if (bf == null) throw errUnknownIdentifier;

  var R_share = comm.toGroupCommitmentShare(bf.scalar).elem; // H + rho*B

  if (negateR) {
    final n = secp256k1Curve.n;
    R_share = (R_share * (n - BigInt.one))!;
  }

  final lambdaI = deriveInterpolatingValue(identifier, signingPackage);

  // LHS: z_i * G
  final LHS = (secp256k1Curve.G * signatureShare.s)!;

  // RHS: R_share + c * lambda_i * Y_i
  final c_lambda = (challenge * lambdaI) % secp256k1Curve.n;
  final term2 =
      (verifyingShare *
      c_lambda)!; // verifyingShare should be EvenY? passed in pubkeys are EvenY

  final RHS = (R_share + term2)!;

  if (!pointsEqual(LHS, RHS)) {
    throw errorInvalidSignature;
  }
}
