import 'dart:typed_data';

import 'package:threshold/threshold.dart';
import 'package:test/test.dart';

void main() {
  group('2-Dealer DKG with Passive Receiver', () {
    test('DKG produces matching keys and all 2-of-3 signing works', () {
      const minSigners = 2;
      const maxSigners = 3;

      // --- Setup: two dealers generate secrets ---
      final dealer1Secret = SecretKey(modNRandom());
      final dealer1Coeffs = generateCoefficients(minSigners - 1);
      final dealer2Secret = SecretKey(modNRandom());
      final dealer2Coeffs = generateCoefficients(minSigners - 1);

      // --- Round 1: dealers only ---
      final (d1R1Sec, d1R1Pub) =
          dkgPart1(maxSigners, minSigners, dealer1Secret, dealer1Coeffs);
      final (d2R1Sec, d2R1Pub) =
          dkgPart1(maxSigners, minSigners, dealer2Secret, dealer2Coeffs);

      // Derive receiver identifier from dealer1's verifying key
      final d1VkBytes = elemSerializeCompressed(d1R1Pub.verifyingKey.E);
      final receiverIdInput = Uint8List.fromList(
        [...'wallet:'.codeUnits, ...d1VkBytes],
      );
      final receiverId = Identifier.derive(receiverIdInput);

      final allIds = [d1R1Sec.identifier, d2R1Sec.identifier, receiverId];

      // --- Round 2: dealers compute shares for each other AND receiver ---
      final (d1R2Sec, d1R2Out) = dkgPart2(
        d1R1Sec,
        {d2R1Sec.identifier: d2R1Pub},
        receiverIdentifiers: [receiverId],
      );
      final (d2R2Sec, d2R2Out) = dkgPart2(
        d2R1Sec,
        {d1R1Sec.identifier: d1R1Pub},
        receiverIdentifiers: [receiverId],
      );

      // --- Round 3: dealers finalize ---
      final (d1KeyPkg, d1Pkp) = dkgPart3(
        d1R1Sec,
        d1R2Sec,
        {d2R1Sec.identifier: d2R1Pub},
        {d2R1Sec.identifier: d2R2Out[d1R1Sec.identifier]!},
        receiverIdentifiers: [receiverId],
      );
      final (d2KeyPkg, d2Pkp) = dkgPart3(
        d2R1Sec,
        d2R2Sec,
        {d1R1Sec.identifier: d1R1Pub},
        {d1R1Sec.identifier: d1R2Out[d2R1Sec.identifier]!},
        receiverIdentifiers: [receiverId],
      );

      // --- Round 3 Receive: passive receiver ---
      final (receiverKeyPkg, receiverPkp) = dkgPart3Receive(
        receiverId,
        {
          d1R1Sec.identifier: d1R1Pub,
          d2R1Sec.identifier: d2R1Pub,
        },
        {
          d1R1Sec.identifier: d1R2Out[receiverId]!,
          d2R1Sec.identifier: d2R2Out[receiverId]!,
        },
        minSigners,
        maxSigners,
        allIds,
      );

      // --- Verify all 3 got the same public key ---
      final d1VkHex = elemSerializeCompressed(d1Pkp.verifyingKey.E);
      final d2VkHex = elemSerializeCompressed(d2Pkp.verifyingKey.E);
      final rVkHex = elemSerializeCompressed(receiverPkp.verifyingKey.E);

      expect(d1VkHex, equals(d2VkHex),
          reason: 'Dealer 1 and Dealer 2 public keys must match');
      expect(d1VkHex, equals(rVkHex),
          reason: 'Dealer and Receiver public keys must match');

      // --- Verify all 3 PKPs have verifying shares for all IDs ---
      for (final id in allIds) {
        expect(d1Pkp.verifyingShares.containsKey(id), isTrue);
        expect(d2Pkp.verifyingShares.containsKey(id), isTrue);
        expect(receiverPkp.verifyingShares.containsKey(id), isTrue);

        expect(
          elemSerializeCompressed(d1Pkp.verifyingShares[id]!),
          equals(elemSerializeCompressed(d2Pkp.verifyingShares[id]!)),
        );
        expect(
          elemSerializeCompressed(d1Pkp.verifyingShares[id]!),
          equals(elemSerializeCompressed(receiverPkp.verifyingShares[id]!)),
        );
      }

      // --- Verify group key = sum of dealer secrets only ---
      final n = secp256k1Curve.n;
      var expectedGroupKey =
          (dealer1Secret.scalar + dealer2Secret.scalar) % n;
      final groupPoint = (secp256k1Curve.G * expectedGroupKey)!;
      if (!groupPoint.y!.toBigInteger()!.isEven) {
        expectedGroupKey = n - expectedGroupKey;
      }

      // Reconstruct from all 2-of-3 combinations
      final shares = {
        d1KeyPkg.identifier: d1KeyPkg.secretShare,
        d2KeyPkg.identifier: d2KeyPkg.secretShare,
        receiverKeyPkg.identifier: receiverKeyPkg.secretShare,
      };
      final idList = shares.keys.toList();
      for (var i = 0; i < idList.length; i++) {
        for (var j = i + 1; j < idList.length; j++) {
          final subset = {
            idList[i]: shares[idList[i]]!,
            idList[j]: shares[idList[j]]!,
          };
          final reconstructed = reconstruct(minSigners, subset);
          expect(reconstructed.scalar, equals(expectedGroupKey),
              reason: 'Reconstruction from pair ($i,$j) must match group key');
        }
      }

      // --- Sign with dealer1 + receiver ---
      final message = Uint8List.fromList('2-dealer DKG test'.codeUnits);

      _verifySigningPair(
        d1KeyPkg, receiverKeyPkg, d1Pkp, message, 'dealer1+receiver');

      // --- Sign with dealer2 + receiver ---
      _verifySigningPair(
        d2KeyPkg, receiverKeyPkg, d2Pkp, message, 'dealer2+receiver');

      // --- Sign with dealer1 + dealer2 ---
      _verifySigningPair(
        d1KeyPkg, d2KeyPkg, d1Pkp, message, 'dealer1+dealer2');
    });

    test('receiver share verification rejects tampered share', () {
      const minSigners = 2;
      const maxSigners = 3;

      final (d1R1Sec, d1R1Pub) = dkgPart1(
        maxSigners, minSigners, SecretKey(modNRandom()),
        generateCoefficients(minSigners - 1));
      final (d2R1Sec, d2R1Pub) = dkgPart1(
        maxSigners, minSigners, SecretKey(modNRandom()),
        generateCoefficients(minSigners - 1));

      final receiverId = identifierFromUint16(42);

      final (_, d1R2Out) = dkgPart2(
        d1R1Sec,
        {d2R1Sec.identifier: d2R1Pub},
        receiverIdentifiers: [receiverId],
      );
      final (_, d2R2Out) = dkgPart2(
        d2R1Sec,
        {d1R1Sec.identifier: d1R1Pub},
        receiverIdentifiers: [receiverId],
      );

      // Tamper with dealer1's share for receiver
      final tamperedShare = Round2Package(
        d1R2Out[receiverId]!.secretShare + BigInt.one,
      );

      expect(
        () => dkgPart3Receive(
          receiverId,
          {d1R1Sec.identifier: d1R1Pub, d2R1Sec.identifier: d2R1Pub},
          {d1R1Sec.identifier: tamperedShare, d2R1Sec.identifier: d2R2Out[receiverId]!},
          minSigners,
          maxSigners,
          [d1R1Sec.identifier, d2R1Sec.identifier, receiverId],
        ),
        throwsA(isA<InvalidSecretShareException>()),
      );
    });
  });
}

void _verifySigningPair(
  KeyPackage kp1,
  KeyPackage kp2,
  PublicKeyPackage pkp,
  Uint8List message,
  String label,
) {
  final n1 = newNonce(kp1.secretShare);
  final n2 = newNonce(kp2.secretShare);

  final commitments = {
    kp1.identifier: n1.commitments,
    kp2.identifier: n2.commitments,
  };
  final signingPackage = SigningPackage(commitments, message);

  final s1 = sign(signingPackage, n1, kp1);
  final s2 = sign(signingPackage, n2, kp2);

  final signature = aggregate(
    signingPackage,
    {kp1.identifier: s1, kp2.identifier: s2},
    pkp,
  );
  signature.verify(pkp.verifyingKey, message);
}
