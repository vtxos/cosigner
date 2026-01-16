import 'package:threshold/threshold.dart';
import 'package:convert/convert.dart';

void main() {
  // --- 1. Setup DKG Parameters ---
  const int minSigners = 2; // t
  const int maxSigners = 3; // n

  // --- 2. Initialize Participants ---
  // In a real scenario, these would be distinct entities.
  // For demonstration, we'll simulate them locally.

  final participants = <Participant>[];
  for (var i = 1; i <= maxSigners; i++) {
    final secretKey = newSecretKey(); // a_i0 (random secret for participant's polynomial)
    final coefficients = generateCoefficients(minSigners - 1); // a_i1, ..., a_i(t-1)
    participants.add(Participant(secretKey, coefficients));
  }

  // --- 3. DKG Round 1: Generate Commitments and Proofs of Knowledge ---
  print('--- DKG Round 1 ---');
  final r1Secrets = <Identifier, Round1SecretPackage>{};
  final r1Pkgs = <Identifier, Round1Package>{};

  for (var i = 0; i < participants.length; i++) {
    final participant = participants[i];
    final (secretPkg, pubPkg) = dkgPart1(
      maxSigners,
      minSigners,
      participant.secretKey,
      participant.coefficients,
    );
    r1Secrets[secretPkg.identifier] = secretPkg;
    r1Pkgs[secretPkg.identifier] = pubPkg;
    print('Participant ${i + 1}: Generated R1 Package (Commitment & PoK)');
  }

  // --- 4. DKG Round 2: Generate Shares for Peers ---
  print('\n--- DKG Round 2 ---');
  final r2Secrets = <Identifier, Round2SecretPackage>{};
  final r2Outgoing = <Identifier, Map<Identifier, Round2Package>>{};

  final ids = r1Secrets.keys.toList();
  for (var i = 0; i < ids.length; i++) {
    final id = ids[i];
    final r1Secret = r1Secrets[id]!;

    // Collect all other participants' R1 packages
    final othersR1Pkgs = <Identifier, Round1Package>{};
    for (final otherId in ids) {
      if (otherId != id) {
        othersR1Pkgs[otherId] = r1Pkgs[otherId]!;
      }
    }

    final (r2s, out) = dkgPart2(r1Secret, othersR1Pkgs);
    r2Secrets[id] = r2s;
    r2Outgoing[id] = out;
    print('Participant ${i + 1}: Generated R2 Secret & Shares for Peers');
  }

  // --- 5. DKG Round 3: Combine Shares and Form Key Packages ---
  print('\n--- DKG Round 3 ---');
  final keyPackages = <Identifier, KeyPackage>{};
  PublicKeyPackage? publicKeyPackage; // The final combined public key package

  for (var i = 0; i < ids.length; i++) {
    final id = ids[i];
    final r1Secret = r1Secrets[id]!;
    final r2Secret = r2Secrets[id]!;

    // Collect R2 shares sent *to this participant* from others
    final inboundR2Pkgs = <Identifier, Round2Package>{};
    for (final otherId in ids) {
      if (otherId != id) {
        inboundR2Pkgs[otherId] = r2Outgoing[otherId]![id]!;
      }
    }

    // All R1 packages (including own for verification purposes)
    final allR1Pkgs = <Identifier, Round1Package>{};
    for (final r1PkgEntry in r1Pkgs.entries) {
      allR1Pkgs[r1PkgEntry.key] = r1PkgEntry.value;
    }


    final (kp, pkp) = dkgPart3(
      r1Secret,
      r2Secret,
      allR1Pkgs, // All Round 1 packages are needed here
      inboundR2Pkgs,
    );
    keyPackages[kp.identifier] = kp;
    publicKeyPackage ??= pkp; // Store the first one, they should all be identical
    print('Participant ${i + 1}: Formed Key Package');
  }

  // --- 6. Verification ---
  print('\n--- Verification ---');
  // The combined public key for the group
  final groupVerifyingKey = publicKeyPackage!.verifyingKey;
  print('Group Public Key: ${hex.encode(elemSerializeCompressed(groupVerifyingKey.E))}');

  // Sum of all individual a_i0 values (secretKey.scalar from setup)
  var expectedCombinedSecret = modNZero();
  for (final participant in participants) {
    expectedCombinedSecret = (expectedCombinedSecret + participant.secretKey.scalar) % secp256k1Curve.n;
  }
  print('Expected Combined Secret (sum of a_i0): ${expectedCombinedSecret.toRadixString(16)}');

  // Reconstruct the combined secret from the KeyPackages
  final sharesForReconstruction = <Identifier, SecretShare>{};
  for (final kpEntry in keyPackages.entries) {
    sharesForReconstruction[kpEntry.key] = kpEntry.value.secretShare;
  }

  final reconstructedCombinedSecret = reconstruct(minSigners, sharesForReconstruction);
  print('Reconstructed Combined Secret (f(0)): ${reconstructedCombinedSecret.scalar.toRadixString(16)}');

  if (reconstructedCombinedSecret.scalar == expectedCombinedSecret) {
    print('Verification SUCCESS: Reconstructed secret matches expected combined secret.');
  } else {
    print('Verification FAILED: Reconstructed secret DOES NOT match expected combined secret.');
  }
  print('Verifying that the sum of the a_i0 from the DKG is the first coefficient of the group commitment');
  final finalGroupCommitment = publicKeyPackage.verifyingKey;
  final expectedGroupCommitment = elemBaseMul(expectedCombinedSecret);
  if (finalGroupCommitment.E == expectedGroupCommitment) {
    print('Verification SUCCESS: Group commitment matches expected.');
  } else {
    print('Verification FAILED: Group commitment DOES NOT match expected.');
  }


}

// Helper class for Participant state in this example
class Participant {
  final SecretKey secretKey;
  final List<BigInt> coefficients;

  Participant(this.secretKey, this.coefficients);
}
