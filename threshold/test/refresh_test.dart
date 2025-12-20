import 'package:threshold/threshold.dart';
import 'package:test/test.dart';

import 'dkg_test.dart' show dealerDKG, Participant;
import 'test_helper.dart';

void main() {
  group('Key Refresh', () {
    test('Test Key Refresh (Full Group)', () {
      final minParticipants = 2;
      final maxParticipants = 3;

      final ids = defaultIdentifiers(maxParticipants);
      final participants = <Participant>[];
      for (var i = 0; i < maxParticipants; i++) {
        final secret = modNRandom();
        final coefficients = generateCoefficients(minParticipants - 1);
        participants.add(Participant(ids[i], SecretKey(secret), coefficients));
      }

      // 1. Initial DKG
      final (initialKeys, initialPkp) = dealerDKG(
        minParticipants,
        maxParticipants,
        participants,
      );

      // Verify initial reconstruction
      final initialShares = <Identifier, SecretShare>{};
      for (final p in initialKeys) {
        initialShares[p.identifier] = p.secretShare;
      }
      final initialReconstructed = reconstruct(minParticipants, initialShares);

      // 2. Refresh Protocol (All participants)
      final r1Secrets = <Identifier, Round1SecretPackage>{};
      final r1Pkgs = <Identifier, Round1Package>{};

      // Everyone generates r1
      for (final p in initialKeys) {
        final (sec, pkg) = dkgRefreshPart1(
          p.identifier,
          maxParticipants,
          minParticipants,
        );
        r1Secrets[p.identifier] = sec;
        r1Pkgs[p.identifier] = pkg;
      }

      // Everyone executes r2 with everyone else
      final r2Secrets = <Identifier, Round2SecretPackage>{};
      final r2Outgoing = <Identifier, Map<Identifier, Round2Package>>{};

      for (final p in initialKeys) {
        final id = p.identifier;
        final others = <Identifier, Round1Package>{};
        for (final other in initialKeys) {
          if (other.identifier == id) continue;
          others[other.identifier] = r1Pkgs[other.identifier]!;
        }

        final (r2s, out) = dkgRefreshPart2(r1Secrets[id]!, others);
        r2Secrets[id] = r2s;
        r2Outgoing[id] = out;
      }

      // Everyone executes r3
      final newKeys = <KeyPackage>[];
      PublicKeyPackage? newPkp;

      for (final p in initialKeys) {
        final id = p.identifier;
        final r2View = <Identifier, Round2Package>{};
        final r1View = <Identifier, Round1Package>{};

        for (final other in initialKeys) {
          if (other.identifier == id) continue;
          final otherId = other.identifier;
          r2View[otherId] = r2Outgoing[otherId]![id]!;
          r1View[otherId] = r1Pkgs[otherId]!;
        }

        final (kp, pk) = dkgRefreshPart3(
          r2Secrets[id]!,
          r1View,
          r2View,
          initialPkp,
          p,
        );
        newKeys.add(kp);
        newPkp = pk;
      }

      // 3. Verification matches initial test...
      expect(
        newPkp!.verifyingKey.E.getEncoded(true),
        equals(initialPkp.verifyingKey.E.getEncoded(true)),
      );

      final newReconstructed = reconstruct(minParticipants, {
        for (var k in newKeys) k.identifier: k.secretShare,
      });
      expect(newReconstructed.scalar, equals(initialReconstructed.scalar));
    });

    test('Test Key Refresh (Subset)', () {
      final minParticipants = 2;
      final maxParticipants = 3;

      final ids = defaultIdentifiers(maxParticipants);
      final participants = <Participant>[];
      for (var i = 0; i < maxParticipants; i++) {
        final secret = modNRandom();
        final coefficients = generateCoefficients(minParticipants - 1);
        participants.add(Participant(ids[i], SecretKey(secret), coefficients));
      }

      final (initialKeys, initialPkp) = dealerDKG(
        minParticipants,
        maxParticipants,
        participants,
      );

      final initialReconstructed = reconstruct(minParticipants, {
        for (var k in initialKeys) k.identifier: k.secretShare,
      });

      // --- SUBSET REFRESH ---
      // We only use the first 2 participants (minParticipants) to refresh.
      // The 3rd participant is excluded.

      final subset = initialKeys.sublist(0, minParticipants);
      final excluded = initialKeys[2];

      // To refresh with a subset, we treat it as a "new DKG" among the subset
      // but modifying the share aggregation logic.
      // HOWEVER, the standard `dkgRefreshPart*` functions generally assume `maxSigners`
      // participation for zero-sum check if not careful.
      // BUT, mathematically, any `t` participants can refresh the secret.
      // The issue is that the `dkgRefreshPart1` asks for `maxSigners`.
      // If we pass the ORIGINAL `maxSigners` (3), it might expect 3 polynomials.
      // If we want to do a subset refresh, we should theoretically treat the current session
      // as having `n=2` participants who are adding zero-polynomials.

      // Let's try passing `maxSigners = 2` (the subset size) to the refresh functions.
      // This tells the logic: "There are 2 people participating in this zero-sum game".
      // They will generating polys for those 2 people.

      final refreshParticipants = subset.length; // 2

      final r1Secrets = <Identifier, Round1SecretPackage>{};
      final r1Pkgs = <Identifier, Round1Package>{};

      for (final p in subset) {
        // IMPORTANT: We say maxSigners = refreshParticipants (2) here
        // so they only generate commitments for the 2 participants.
        final (sec, pkg) = dkgRefreshPart1(
          p.identifier,
          refreshParticipants,
          minParticipants,
        );
        r1Secrets[p.identifier] = sec;
        r1Pkgs[p.identifier] = pkg;
      }

      // Part 2 exchange among subset
      final r2Secrets = <Identifier, Round2SecretPackage>{};
      final r2Outgoing = <Identifier, Map<Identifier, Round2Package>>{};

      for (final p in subset) {
        final id = p.identifier;
        final others = <Identifier, Round1Package>{};
        for (final other in subset) {
          if (other.identifier == id) continue;
          others[other.identifier] = r1Pkgs[other.identifier]!;
        }

        final (r2s, out) = dkgRefreshPart2(r1Secrets[id]!, others);
        r2Secrets[id] = r2s;
        r2Outgoing[id] = out;
      }

      // Part 3 finalization
      final newSubsetKeys = <KeyPackage>[];
      PublicKeyPackage? newPkp;

      for (final p in subset) {
        final id = p.identifier;
        final r2View = <Identifier, Round2Package>{};
        final r1View = <Identifier, Round1Package>{};

        for (final other in subset) {
          if (other.identifier == id) continue;
          final otherId = other.identifier;
          r2View[otherId] = r2Outgoing[otherId]![id]!;
          r1View[otherId] =
              r1Pkgs[otherId]!; // Need coefficients to verify zero-sum?
        }

        // Note: dkgRefreshPart3 might check if `r1View` + self has size `maxSigners`.
        // Since we passed `maxSigners=2` in Part1, `r2Secret.maxSigners` is 2.
        // It should expect 1 peer. We provide 1 peer. This should pass logic checks.

        final (kp, pk) = dkgRefreshPart3(
          r2Secrets[id]!,
          r1View,
          r2View,
          initialPkp,
          p,
        );
        newSubsetKeys.add(kp);
        newPkp = pk;
      }

      // --- VERIFICATION ---

      // 1. Group Public Key must be unchanged
      expect(
        newPkp!.verifyingKey.E.getEncoded(true),
        equals(initialPkp.verifyingKey.E.getEncoded(true)),
      );

      // 2. Subset shares must have changed
      expect(
        newSubsetKeys[0].secretShare,
        isNot(equals(subset[0].secretShare)),
      );
      expect(
        newSubsetKeys[1].secretShare,
        isNot(equals(subset[1].secretShare)),
      );

      // 3. Subset RECONSTRUCTION
      // The 2 new shares should successfully reconstruct the ORIGINAL secret.
      final newReconstructed = reconstruct(minParticipants, {
        for (var k in newSubsetKeys) k.identifier: k.secretShare,
      });
      expect(newReconstructed.scalar, equals(initialReconstructed.scalar));

      // 4. MIXED Reconstruction (FAILURE EXPECTED)
      // If we use 1 new share and 1 old excluded share, it should FAIL to reconstruct the key.
      // This confirms the excluded participant is effectively "out" of this epoch
      // (unless they just keep their old share and we assume compatibility, BUT
      // since the subset added a random zero-polynomial, the global polynomial has changed.
      // P(x)_new = P(x)_old + Q(x)_zero.
      // For participants in subset, P_new(i) = P_old(i) + Q_zero(i).
      // For excluded paticipant k, they hold P_old(k).
      // But P_new(k) would be P_old(k) + Q_zero(k).
      // Since they weren't involved, they don't know Q_zero(k) (and it wasn't given to them).
      // So their share P_old(k) is NOT a valid share on P_new(x).

      final mixedShares = {
        newSubsetKeys[0].identifier: newSubsetKeys[0].secretShare, // New
        excluded.identifier: excluded.secretShare, // Old
      };

      final mixedReconstructed = reconstruct(minParticipants, mixedShares);
      expect(
        mixedReconstructed.scalar,
        isNot(equals(initialReconstructed.scalar)),
      );
    });
  });
}
