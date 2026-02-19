extern crate alloc;

use alloc::collections::BTreeMap;
use alloc::vec::Vec;
use k256::Scalar;
use rand::rngs::OsRng;
use threshold::commitment::SigningPackage;
use threshold::identifier::Identifier;
use threshold::keys::{KeyPackage, PublicKeyPackage, VerifyingKey};
use threshold::lagrange::lagrange_coeff_at_zero;
use threshold::nonce::new_nonce;
use threshold::point;
use threshold::scalar::{scalar_from_bytes, scalar_to_bytes};
use threshold::signing::{aggregate, sign};

// --- Dealer DKG simulation (test-only) ---

/// Evaluate a polynomial at a given identifier using Horner's method.
/// coeffs = [a0, a1, ..., a_{t-1}] where a0 is the constant term.
fn evaluate_polynomial(id: &Identifier, coeffs: &[Scalar]) -> Scalar {
    let x = *id.to_scalar();
    let mut val = Scalar::ZERO;
    for i in (0..coeffs.len()).rev() {
        if i != coeffs.len() - 1 {
            val = val * x;
        }
        val = val + coeffs[i];
    }
    val
}

/// Simulate a dealer DKG for testing: generates key packages for `max_signers`
/// participants with a `min_signers` threshold.
fn run_dealer_dkg(
    min_signers: usize,
    max_signers: usize,
) -> (Vec<KeyPackage>, PublicKeyPackage) {
    let mut rng = OsRng;

    // Each participant generates a random polynomial of degree (min_signers - 1)
    let ids: Vec<Identifier> = (1..=max_signers as u16)
        .map(|i| Identifier::from_u16(i).unwrap())
        .collect();

    let mut all_coefficients: Vec<Vec<Scalar>> = Vec::new();

    for _ in 0..max_signers {
        let mut coeffs = Vec::with_capacity(min_signers);
        for _ in 0..min_signers {
            // Generate random non-zero scalar
            let s = loop {
                let nonce = new_nonce(&mut rng, &Scalar::ONE);
                let s = nonce.hiding; // Use nonce scalar as random
                if !bool::from(s.is_zero()) {
                    break s;
                }
            };
            coeffs.push(s);
        }
        all_coefficients.push(coeffs);
    }

    // Compute combined secret shares for each participant:
    // s_i = sum_j f_j(i) for all j
    let mut key_packages = Vec::new();
    let mut verifying_shares = BTreeMap::new();

    // Group public key = sum of all a0 values
    let mut group_secret = Scalar::ZERO;
    for coeffs in &all_coefficients {
        group_secret = group_secret + coeffs[0];
    }
    let group_pk = point::base_mul(&group_secret);
    let verifying_key = VerifyingKey::new(group_pk);

    for id in ids.iter() {
        let mut secret_share = Scalar::ZERO;
        for coeffs in &all_coefficients {
            secret_share = secret_share + evaluate_polynomial(id, coeffs);
        }

        let verifying_share = point::base_mul(&secret_share);
        verifying_shares.insert(id.clone(), verifying_share);

        key_packages.push(KeyPackage {
            identifier: id.clone(),
            secret_share,
            verifying_share,
            verifying_key: verifying_key.clone(),
            min_signers,
        });
    }

    let pubkeys = PublicKeyPackage {
        verifying_shares,
        verifying_key,
    };

    (key_packages, pubkeys)
}

// --- Tests ---

#[test]
fn test_scalar_round_trip() {
    let mut rng = OsRng;
    let nonce = new_nonce(&mut rng, &Scalar::ONE);
    let s = nonce.hiding;

    let bytes = scalar_to_bytes(&s);
    let recovered = scalar_from_bytes(&bytes).unwrap();
    assert_eq!(scalar_to_bytes(&s), scalar_to_bytes(&recovered));
}

#[test]
fn test_point_round_trip() {
    let mut rng = OsRng;
    let nonce = new_nonce(&mut rng, &Scalar::ONE);
    let p = point::base_mul(&nonce.hiding);

    let compressed = point::serialize_compressed(&p);
    let recovered = point::deserialize_compressed(&compressed).unwrap();
    assert!(point::points_equal(&p, &recovered));
}

#[test]
fn test_identifier_ordering() {
    let id1 = Identifier::from_u16(1).unwrap();
    let id2 = Identifier::from_u16(2).unwrap();
    let id3 = Identifier::from_u16(3).unwrap();

    assert!(id1 < id2);
    assert!(id2 < id3);
    assert!(id1 != id2);
}

#[test]
fn test_identifier_derive() {
    let id = Identifier::derive(b"test-participant").unwrap();
    let bytes = id.serialize();
    let recovered = Identifier::deserialize(&bytes).unwrap();
    assert_eq!(id, recovered);
}

#[test]
fn test_lagrange_reconstruction() {
    // Create a polynomial f(x) = a0 + a1*x with known constant term
    let a0 = Scalar::from(42u64);
    let a1 = Scalar::from(7u64);

    let id1 = Identifier::from_u16(1).unwrap();
    let id2 = Identifier::from_u16(2).unwrap();
    let id3 = Identifier::from_u16(3).unwrap();

    let coeffs = vec![a0, a1];

    // Evaluate at each point
    let y1 = evaluate_polynomial(&id1, &coeffs); // f(1) = 42 + 7 = 49
    let y2 = evaluate_polynomial(&id2, &coeffs); // f(2) = 42 + 14 = 56
    let y3 = evaluate_polynomial(&id3, &coeffs); // f(3) = 42 + 21 = 63

    // Reconstruct f(0) = a0 using Lagrange on any 2 points
    let set12 = vec![id1.clone(), id2.clone()];
    let l1 = lagrange_coeff_at_zero(&id1, &set12);
    let l2 = lagrange_coeff_at_zero(&id2, &set12);
    let reconstructed_12 = l1 * y1 + l2 * y2;
    assert_eq!(scalar_to_bytes(&reconstructed_12), scalar_to_bytes(&a0));

    // Also with a different pair
    let set23 = vec![id2.clone(), id3.clone()];
    let l2b = lagrange_coeff_at_zero(&id2, &set23);
    let l3b = lagrange_coeff_at_zero(&id3, &set23);
    let reconstructed_23 = l2b * y2 + l3b * y3;
    assert_eq!(scalar_to_bytes(&reconstructed_23), scalar_to_bytes(&a0));
}

#[test]
fn test_even_y_normalization() {
    let mut rng = OsRng;
    // Generate a random point
    let nonce = new_nonce(&mut rng, &Scalar::ONE);
    let p = point::base_mul(&nonce.hiding);

    let vk = VerifyingKey::new(p);
    let vk_even = vk.into_even_y();

    // After normalization, Y must be even
    assert!(vk_even.has_even_y());

    // Double normalization is idempotent
    let vk_even2 = vk_even.into_even_y();
    assert!(point::points_equal(&vk_even.point, &vk_even2.point));
}

#[test]
fn test_frost_sign_and_aggregate_2_of_3() {
    let min_signers = 2;
    let max_signers = 3;

    // 1. Dealer DKG
    let (key_packages, pubkeys) = run_dealer_dkg(min_signers, max_signers);

    // 2. Signing setup: participants 1 and 2 sign
    let signers: Vec<&KeyPackage> = key_packages.iter().take(min_signers).collect();
    let message = b"threshold frost end-to-end signature";

    let mut rng = OsRng;
    let mut nonces = BTreeMap::new();
    let mut commitments = BTreeMap::new();

    for kp in &signers {
        let nonce = new_nonce(&mut rng, &kp.secret_share);
        commitments.insert(kp.identifier.clone(), nonce.commitments.clone());
        nonces.insert(kp.identifier.clone(), nonce);
    }

    let signing_package = SigningPackage::new(commitments, message.to_vec());

    // 3. Each signer produces a share
    let mut signature_shares = BTreeMap::new();
    for kp in &signers {
        let nonce = nonces.get(&kp.identifier).unwrap();
        let share = sign(&signing_package, nonce, kp).unwrap();
        signature_shares.insert(kp.identifier.clone(), share);
    }

    // 4. Aggregate
    let signature = aggregate(&signing_package, &signature_shares, &pubkeys).unwrap();

    // 5. Verify
    signature
        .verify(&pubkeys.verifying_key, message)
        .expect("Signature verification failed");
}

#[test]
fn test_frost_sign_and_aggregate_3_of_5() {
    let min_signers = 3;
    let max_signers = 5;

    let (key_packages, pubkeys) = run_dealer_dkg(min_signers, max_signers);

    let message = b"3-of-5 threshold test";

    // Pick participants 2, 3, 5 (non-contiguous)
    let signers: Vec<&KeyPackage> = vec![&key_packages[1], &key_packages[2], &key_packages[4]];

    let mut rng = OsRng;
    let mut nonces = BTreeMap::new();
    let mut commitments = BTreeMap::new();

    for kp in &signers {
        let nonce = new_nonce(&mut rng, &kp.secret_share);
        commitments.insert(kp.identifier.clone(), nonce.commitments.clone());
        nonces.insert(kp.identifier.clone(), nonce);
    }

    let signing_package = SigningPackage::new(commitments, message.to_vec());

    let mut signature_shares = BTreeMap::new();
    for kp in &signers {
        let nonce = nonces.get(&kp.identifier).unwrap();
        let share = sign(&signing_package, nonce, kp).unwrap();
        signature_shares.insert(kp.identifier.clone(), share);
    }

    let signature = aggregate(&signing_package, &signature_shares, &pubkeys).unwrap();

    signature
        .verify(&pubkeys.verifying_key, message)
        .expect("3-of-5 signature verification failed");
}

#[test]
fn test_frost_different_signer_subsets_produce_valid_signatures() {
    let min_signers = 2;
    let max_signers = 3;

    let (key_packages, pubkeys) = run_dealer_dkg(min_signers, max_signers);
    let message = b"different subsets";

    // Sign with participants {1,2} and then {2,3} and then {1,3}
    let subsets: Vec<Vec<usize>> = vec![vec![0, 1], vec![1, 2], vec![0, 2]];

    for subset in &subsets {
        let signers: Vec<&KeyPackage> =
            subset.iter().map(|&i| &key_packages[i]).collect();

        let mut rng = OsRng;
        let mut nonces = BTreeMap::new();
        let mut commitments = BTreeMap::new();

        for kp in &signers {
            let nonce = new_nonce(&mut rng, &kp.secret_share);
            commitments.insert(kp.identifier.clone(), nonce.commitments.clone());
            nonces.insert(kp.identifier.clone(), nonce);
        }

        let signing_package =
            SigningPackage::new(commitments, message.to_vec());

        let mut signature_shares = BTreeMap::new();
        for kp in &signers {
            let nonce = nonces.get(&kp.identifier).unwrap();
            let share = sign(&signing_package, nonce, kp).unwrap();
            signature_shares.insert(kp.identifier.clone(), share);
        }

        let signature =
            aggregate(&signing_package, &signature_shares, &pubkeys).unwrap();
        signature
            .verify(&pubkeys.verifying_key, message)
            .expect("Subset signature verification failed");
    }
}

#[test]
fn test_signature_serialization_64_bytes() {
    let (key_packages, pubkeys) = run_dealer_dkg(2, 3);
    let message = b"serialization test";

    let signers: Vec<&KeyPackage> = key_packages.iter().take(2).collect();

    let mut rng = OsRng;
    let mut nonces = BTreeMap::new();
    let mut commitments = BTreeMap::new();

    for kp in &signers {
        let nonce = new_nonce(&mut rng, &kp.secret_share);
        commitments.insert(kp.identifier.clone(), nonce.commitments.clone());
        nonces.insert(kp.identifier.clone(), nonce);
    }

    let signing_package = SigningPackage::new(commitments, message.to_vec());

    let mut signature_shares = BTreeMap::new();
    for kp in &signers {
        let nonce = nonces.get(&kp.identifier).unwrap();
        let share = sign(&signing_package, nonce, kp).unwrap();
        signature_shares.insert(kp.identifier.clone(), share);
    }

    let signature = aggregate(&signing_package, &signature_shares, &pubkeys).unwrap();
    let serialized = signature.serialize();

    // BIP-340: 64 bytes = R_x(32) || z(32)
    assert_eq!(serialized.len(), 64);

    // R should have even Y after serialization
    let sig_even = signature.into_even_y();
    assert!(sig_even.has_even_y());
}

#[test]
fn test_key_package_json_round_trip() {
    let (key_packages, _) = run_dealer_dkg(2, 3);
    let kp = &key_packages[0];

    let json = kp.to_json();
    let recovered = KeyPackage::from_json(&json).unwrap();

    assert_eq!(kp.identifier, recovered.identifier);
    assert_eq!(
        scalar_to_bytes(&kp.secret_share),
        scalar_to_bytes(&recovered.secret_share)
    );
    assert!(point::points_equal(
        &kp.verifying_share,
        &recovered.verifying_share
    ));
    assert!(point::points_equal(
        &kp.verifying_key.point,
        &recovered.verifying_key.point
    ));
    assert_eq!(kp.min_signers, recovered.min_signers);
}

#[test]
fn test_taproot_tweaked_signing() {
    let (key_packages, pubkeys) = run_dealer_dkg(2, 3);
    let merkle_root = [0u8; 32]; // Empty merkle root

    // Tweak key packages and public key package
    let tweaked_kps: Vec<KeyPackage> = key_packages
        .iter()
        .map(|kp| kp.tweak(Some(&merkle_root)))
        .collect();
    let tweaked_pubkeys = pubkeys.tweak(Some(&merkle_root));

    let message = b"taproot tweaked signature";
    let signers: Vec<&KeyPackage> = tweaked_kps.iter().take(2).collect();

    let mut rng = OsRng;
    let mut nonces = BTreeMap::new();
    let mut commitments = BTreeMap::new();

    for kp in &signers {
        let nonce = new_nonce(&mut rng, &kp.secret_share);
        commitments.insert(kp.identifier.clone(), nonce.commitments.clone());
        nonces.insert(kp.identifier.clone(), nonce);
    }

    let signing_package = SigningPackage::new(commitments, message.to_vec());

    let mut signature_shares = BTreeMap::new();
    for kp in &signers {
        let nonce = nonces.get(&kp.identifier).unwrap();
        let share = sign(&signing_package, nonce, kp).unwrap();
        signature_shares.insert(kp.identifier.clone(), share);
    }

    let signature =
        aggregate(&signing_package, &signature_shares, &tweaked_pubkeys).unwrap();
    signature
        .verify(&tweaked_pubkeys.verifying_key, message)
        .expect("Taproot tweaked signature verification failed");
}

#[test]
fn test_insufficient_signers_rejected() {
    let (key_packages, _) = run_dealer_dkg(2, 3);

    // Only 1 signer for a 2-of-3 scheme
    let kp = &key_packages[0];
    let message = b"insufficient signers";

    let mut rng = OsRng;
    let nonce = new_nonce(&mut rng, &kp.secret_share);
    let mut commitments = BTreeMap::new();
    commitments.insert(kp.identifier.clone(), nonce.commitments.clone());

    let signing_package = SigningPackage::new(commitments, message.to_vec());

    let result = sign(&signing_package, &nonce, kp);
    assert!(result.is_err(), "Should reject insufficient signers");
}
