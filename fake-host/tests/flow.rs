//! A wallet's life with its cosigner, against the very `cosigner.wasm` a release ships.
//!
//! The test plays the wallet, over the cosigner's own gRPC service, and the fake host plays the
//! runtime: DKG, devices, a signature, renewing the delegate, and then the cosigner refreshing the
//! funds by itself, in a background run, against the ASP. Everything the cosigner keeps between
//! those calls it has to seal: every call is a fresh instance.
//!
//! ```console
//! $ make cosigner-wasm                         # result/bin/cosigner.wasm, as a release builds it
//! $ COSIGNER_WASM=result/bin/cosigner.wasm cargo test --manifest-path fake-host/Cargo.toml
//! ```

use std::collections::BTreeMap;
use std::path::PathBuf;
use std::time::{SystemTime, UNIX_EPOCH};

use cosigner::cosigner::{
    Outcome, Task, CATEGORY_DELEGATE_SETTLED, CATEGORY_SETTLE_DUE, WATCH_TASK_ID,
};
use cosigner::session::proto;
use cosigner::wallet_proto as wp;
use fake_host::Host;
use rand::rngs::OsRng;
use sha2::{Digest, Sha256};
use threshold::dkg::{self, Round1Package, Round2Package};
use threshold::identifier::Identifier;
use threshold::keys::{KeyPackage, PublicKeyPackage};
use threshold::random;

/// The component under test: `COSIGNER_WASM`, or what `make cosigner-wasm` leaves in `result/`.
fn wasm() -> PathBuf {
    std::env::var_os("COSIGNER_WASM").map(PathBuf::from).unwrap_or_else(|| {
        PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../result/bin/cosigner.wasm")
    })
}

/// A deployment as a test would make one: the ASP the host answers for, and the margin the
/// cosigner settles that long before a VTXO expires.
const MARGIN_SECS: i64 = 1800;

fn host() -> Host {
    let host = Host::new(&wasm(), &[("AUTO_SETTLE_SAFETY_MARGIN_SECS", "1800")])
        .expect("load the component; build it first with `make cosigner-wasm`");
    host.runtime.asp.lock().unwrap().info = ark_info_json();
    host
}

/// A device token as FCM issues them: long enough for `notify.wit`'s 32-character floor.
const PHONE: &str = "phone-0123456789abcdef0123456789abcdef";
const TABLET: &str = "tablet-0123456789abcdef0123456789abcdef";

#[tokio::test(flavor = "multi_thread")]
async fn a_wallet_from_dkg_to_the_refresh_its_cosigner_runs_by_itself() {
    let host = host();

    // It serves at all.
    let info: wp::GetServerInfoResponse =
        host.unary("GetServerInfo", &wp::GetServerInfoRequest {}).await.unwrap();
    assert_eq!(info.bitcoin_network, "regtest");

    // DKG, enrolling the phone it runs on.
    let wallet = dkg(&host, PHONE).await;
    assert_eq!(host.runtime.devices(), vec![PHONE], "DKG enrols the device it carried");

    // Devices: one more, counted, and forgotten again.
    let _: proto::RegisterDeviceResponse = host
        .unary("RegisterDevice", &proto::RegisterDeviceRequest { token: TABLET.into() })
        .await
        .unwrap();
    assert_eq!(device_count(&host).await, 2);
    let _: proto::ForgetDeviceResponse = host
        .unary("ForgetDevice", &proto::ForgetDeviceRequest { token: TABLET.into() })
        .await
        .unwrap();
    assert_eq!(device_count(&host).await, 1);

    // A signature, which verifies under the group key as BIP-340.
    let message: [u8; 32] = Sha256::digest(b"a wallet's first signature").into();
    let signature = sign(&host, &wallet, &message).await;
    let secp = bitcoin::secp256k1::Secp256k1::verification_only();
    secp.verify_schnorr(
        &bitcoin::secp256k1::schnorr::Signature::from_slice(&signature).unwrap(),
        &bitcoin::secp256k1::Message::from_digest(message),
        &wallet.x_only(),
    )
    .expect("the cosigner's half and the wallet's make a group-key signature");

    // Renewing the delegate over one VTXO whose refresh is already due: it expires within the
    // margin. Renewing arms the cosigner's watch, for the deadline the delegate is valid from.
    let expires_at = now_secs() + MARGIN_SECS - 60;
    let renewed = renew_delegate(&host, &wallet, expires_at).await;
    assert_eq!(renewed.valid_at_secs as i64, expires_at - MARGIN_SECS);
    assert_eq!(renewed.covered, vec![format!("{}:0", vtxo_txid())]);
    let watch = &host.runtime.tasks()[WATCH_TASK_ID];
    assert_eq!(watch.run_at_ms, renewed.valid_at_secs * 1000, "armed for the deadline");
    assert!(watch.interval_ms.is_some(), "and watching after it, until it is done");
    assert_eq!(
        serde_json::from_slice::<Task>(&watch.payload).unwrap(),
        Task::SettleDue { deadline_secs: renewed.valid_at_secs },
    );

    // The background: the runtime finds the watch due and runs it, and the cosigner refreshes the
    // funds itself — registers the sealed delegate's intent, follows the ASP's batch to its end.
    script_a_batch(&host, "intent-1");
    let outcome = run_watch(&host, now_ms()).await;
    assert_eq!(outcome, Outcome::Settled { commitment_txid: commitment_txid() });
    let called = host.runtime.asp.lock().unwrap().called();
    assert_eq!(
        called,
        [
            "GET /v1/info",
            "POST /v1/batch/registerIntent",
            "GET /v1/batch/events",
            "POST /v1/batch/ack",
        ],
        "the delegate's round, as the cosigner ran it"
    );
    assert_eq!(
        host.runtime.wakes(),
        vec![(CATEGORY_DELEGATE_SETTLED.into(), None)],
        "and its owner told, with a label and nothing readable"
    );

    // The next occurrence finds nothing left to settle: the delegate went with its round.
    let later = now_ms() + host.runtime.tasks()[WATCH_TASK_ID].interval_ms.unwrap();
    assert_eq!(run_watch(&host, later).await, Outcome::NothingToSettle);
    assert_eq!(host.runtime.wakes().len(), 1, "nobody woken about nothing");
}

/// An ASP that will not take the intent: the owner is woken to do it, and the watch keeps going.
/// The next run, with the ASP back, refreshes — from the delegate the first run sealed, on a
/// fresh instance.
#[tokio::test(flavor = "multi_thread")]
async fn a_refresh_the_asp_refuses_wakes_the_owner_and_succeeds_on_a_later_run() {
    let host = host();
    let wallet = dkg(&host, PHONE).await;
    let renewed = renew_delegate(&host, &wallet, now_secs() + MARGIN_SECS - 60).await;

    host.runtime.asp.lock().unwrap().refuse_registration = true;
    let outcome = run_watch(&host, now_ms()).await;
    assert_eq!(outcome, Outcome::Woke { deadline_secs: renewed.valid_at_secs });
    assert_eq!(host.runtime.wakes(), vec![(CATEGORY_SETTLE_DUE.into(), None)]);
    assert!(!host.runtime.tasks()[WATCH_TASK_ID].cancelled, "still watching");

    {
        let mut asp = host.runtime.asp.lock().unwrap();
        asp.refuse_registration = false;
        asp.calls.clear();
    }
    script_a_batch(&host, "intent-1");
    let interval = host.runtime.tasks()[WATCH_TASK_ID].interval_ms.unwrap();
    let outcome = run_watch(&host, now_ms() + interval).await;
    assert_eq!(outcome, Outcome::Settled { commitment_txid: commitment_txid() });
    assert_eq!(
        host.runtime.wakes().last().unwrap().0,
        CATEGORY_DELEGATE_SETTLED,
        "this time the refresh itself is what the owner hears about"
    );
}

/// A background run may wake its owner, and nothing more: here, as in the runtime, anything else
/// it asks of the host is refused, so a cosigner that relied on more would fail this.
#[tokio::test(flavor = "multi_thread")]
async fn a_background_run_cannot_arm_or_enrol_anything() {
    let host = host();
    let wallet = dkg(&host, PHONE).await;
    renew_delegate(&host, &wallet, now_secs() + MARGIN_SECS - 60).await;
    let armed = host.runtime.tasks();

    // A run with no ASP to reach: it can only wake, and does.
    script_a_batch(&host, "intent-1");
    host.runtime.asp.lock().unwrap().refuse_registration = true;
    run_watch(&host, now_ms()).await;

    assert_eq!(host.runtime.tasks().keys().collect::<Vec<_>>(), armed.keys().collect::<Vec<_>>());
    assert_eq!(host.runtime.devices(), vec![PHONE]);
    assert!(host.runtime.streams.lock().unwrap().is_empty());
}

// --- The wallet's side ---------------------------------------------------------------------------

/// What a wallet holds after DKG: its key package and the group's.
struct Wallet {
    key: KeyPackage,
    group: PublicKeyPackage,
}

impl Wallet {
    fn identifier(&self) -> Vec<u8> {
        self.key.identifier.serialize().to_vec()
    }

    fn x_only(&self) -> bitcoin::secp256k1::XOnlyPublicKey {
        let compressed = self.group.verifying_key.serialize();
        bitcoin::secp256k1::XOnlyPublicKey::from_slice(&compressed[1..]).unwrap()
    }
}

/// DKG, as the app runs it: the wallet's round one, the cosigner's, the wallet's round two, and
/// the cosigner's share of the key for the wallet to finish with.
async fn dkg(host: &Host, device_token: &str) -> Wallet {
    let mut rng = OsRng;
    let (secret, slope) = (random::mod_n_random(&mut rng), random::mod_n_random(&mut rng));
    let (round1_secret, round1) = dkg::dkg_part1(2, 2, &secret, &[slope], &mut rng).unwrap();
    let me = hex::encode(round1_secret.identifier.serialize());
    let identifier = round1_secret.identifier.serialize().to_vec();

    let mut call = host.call("Dkg").await.unwrap();
    call.send(&proto::DkgClientMsg {
        session_id: "dkg".into(),
        seq: 1,
        body: Some(proto::dkg_client_msg::Body::Open(proto::DkgOpen {
            identifier: identifier.clone(),
            round1_package: round1.to_json(),
            device_token: device_token.into(),
        })),
    });
    let Some(proto::dkg_server_msg::Body::Round1(theirs)) =
        call.next::<proto::DkgServerMsg>().await.unwrap().body
    else {
        panic!("expected the cosigner's round one");
    };
    let peers: BTreeMap<Identifier, Round1Package> = theirs
        .round1_packages
        .iter()
        .filter(|(id, _)| **id != me)
        .map(|(id, package)| (id.parse().unwrap(), Round1Package::from_json(package).unwrap()))
        .collect();
    let (round2_secret, shares) = dkg::dkg_part2(&round1_secret, &peers, &[]).unwrap();
    call.send(&proto::DkgClientMsg {
        session_id: "dkg".into(),
        seq: 2,
        body: Some(proto::dkg_client_msg::Body::Round2(proto::DkgRound2 {
            identifier,
            round2_packages_for_others: shares
                .iter()
                .map(|(id, package)| (hex::encode(id.serialize()), package.to_json()))
                .collect(),
        })),
    });
    let Some(proto::dkg_server_msg::Body::Complete(complete)) =
        call.next::<proto::DkgServerMsg>().await.unwrap().body
    else {
        panic!("expected the ceremony to complete");
    };
    assert_eq!(call.finish().await.unwrap().0, "0");
    assert!(complete.device_enrolled);

    let for_me: BTreeMap<Identifier, Round2Package> = complete
        .round2_packages_for_me
        .iter()
        .map(|(id, package)| (id.parse().unwrap(), Round2Package::from_json(package).unwrap()))
        .collect();
    let (key, group) =
        dkg::dkg_part3(&round1_secret, &round2_secret, &peers, &for_me, &[]).unwrap();
    let wallet = Wallet { key: key.into_even_y(), group: group.into_even_y() };
    assert_eq!(
        complete.group_key,
        hex::encode(wallet.group.verifying_key.serialize()),
        "both sides finish with the same group key"
    );
    wallet
}

/// One signature: the cosigner commits first, the wallet answers with its commitment and share.
async fn sign(host: &Host, wallet: &Wallet, message: &[u8; 32]) -> Vec<u8> {
    let mut call = host.call("Sign").await.unwrap();
    call.send(&proto::SignClientMsg {
        session_id: "sign".into(),
        seq: 1,
        body: Some(proto::sign_client_msg::Body::Open(proto::SignOpen {
            message_to_sign: message.to_vec(),
            script_path_spend: true,
            identifier: wallet.identifier(),
            ..Default::default()
        })),
    });
    let Some(proto::sign_server_msg::Body::Commitments(theirs)) =
        call.next::<proto::SignServerMsg>().await.unwrap().body
    else {
        panic!("expected the cosigner's commitments");
    };
    let commitments: Vec<cosigner::types::Commitment> = theirs
        .commitments
        .into_iter()
        .map(|(identifier_hex, c)| cosigner::types::Commitment {
            identifier_hex,
            hiding: c.hiding,
            binding: c.binding,
        })
        .collect();
    let half = wallet_answers(&wallet.key, &[message.to_vec()], &commitments).remove(0);
    call.send(&proto::SignClientMsg {
        session_id: "sign".into(),
        seq: 2,
        body: Some(proto::sign_client_msg::Body::Share(proto::SignShare {
            signature_share: half.share,
            hiding_commitment: half.hiding,
            binding_commitment: half.binding,
        })),
    });
    let Some(proto::sign_server_msg::Body::Complete(complete)) =
        call.next::<proto::SignServerMsg>().await.unwrap().body
    else {
        panic!("expected the signature");
    };
    assert_eq!(call.finish().await.unwrap().0, "0");
    [&complete.r_point[1..], &complete.z_scalar[..]].concat()
}

const VTXO: &str = "ab";
const COMMITMENT: &str = "cd";

/// Renew the delegate over one VTXO expiring at [expires_at], answering its round as the wallet.
async fn renew_delegate(host: &Host, wallet: &Wallet, expires_at: i64) -> proto::DelegateRenewed {
    let mut call = host.call("Renew").await.unwrap();
    call.send(&proto::RenewClientMsg {
        session_id: "renew".into(),
        seq: 1,
        body: Some(proto::renew_client_msg::Body::Open(proto::RenewOpen {
            ark_info: Some(wp::ArkInfo::from(&ark_info())),
            vtxos: vec![proto::VtxoInput {
                txid: vtxo_txid(),
                vout: 0,
                amount_sats: 100_000,
                exit_delay: 512,
                expires_at,
            }],
            delegate_only: true,
            identifier: wallet.identifier(),
            ..Default::default()
        })),
    });
    let Some(proto::renew_server_msg::Body::Sighashes(sighashes)) =
        call.next::<proto::RenewServerMsg>().await.unwrap().body
    else {
        panic!("expected the delegate's sighashes");
    };
    let commitments: Vec<cosigner::types::Commitment> = sighashes
        .cosigner_commitments
        .into_iter()
        .map(|c| cosigner::types::Commitment {
            identifier_hex: sighashes.cosigner_identifier.clone(),
            hiding: c.hiding,
            binding: c.binding,
        })
        .collect();
    let rounds = wallet_answers(&wallet.key, &sighashes.messages_to_sign, &commitments)
        .into_iter()
        .map(|h| proto::WalletRound { hiding: h.hiding, binding: h.binding, share: h.share })
        .collect();
    call.send(&proto::RenewClientMsg {
        session_id: "renew".into(),
        seq: 2,
        body: Some(proto::renew_client_msg::Body::Signed(proto::RenewSigned { rounds })),
    });
    let Some(proto::renew_server_msg::Body::DelegateRenewed(renewed)) =
        call.next::<proto::RenewServerMsg>().await.unwrap().body
    else {
        panic!("expected the renewed delegate");
    };
    assert_eq!(call.finish().await.unwrap().0, "0");
    renewed
}

/// The wallet's half of a signing round over [messages]: a fresh nonce for each, and a share over
/// both parties' commitments.
fn wallet_answers(
    key: &KeyPackage,
    messages: &[Vec<u8>],
    theirs: &[cosigner::types::Commitment],
) -> Vec<cosigner::sign::WalletHalf> {
    use threshold::commitment::SigningPackage;
    use threshold::nonce::{self, SigningCommitments};
    use threshold::point;
    use threshold::scalar::scalar_to_bytes;
    use threshold::signing;

    let mut rng = OsRng;
    messages
        .iter()
        .zip(theirs)
        .map(|(message, theirs)| {
            let ours = nonce::new_nonce(&mut rng, &key.secret_share);
            let id: [u8; 32] = hex::decode(&theirs.identifier_hex).unwrap().try_into().unwrap();
            let mut commitments = BTreeMap::new();
            commitments.insert(
                Identifier::deserialize(&id).unwrap(),
                SigningCommitments {
                    hiding: point::deserialize_compressed(&theirs.hiding.clone().try_into().unwrap())
                        .unwrap(),
                    binding: point::deserialize_compressed(
                        &theirs.binding.clone().try_into().unwrap(),
                    )
                    .unwrap(),
                },
            );
            commitments.insert(key.identifier.clone(), ours.commitments.clone());
            let package = SigningPackage::new(commitments, message.clone());
            let share = signing::sign(&package, &ours, key).expect("the wallet's share");
            cosigner::sign::WalletHalf {
                hiding: point::serialize_compressed(&ours.commitments.hiding).to_vec(),
                binding: point::serialize_compressed(&ours.commitments.binding).to_vec(),
                share: scalar_to_bytes(&share.s).to_vec(),
            }
        })
        .collect()
}

async fn device_count(host: &Host) -> u32 {
    let count: proto::DeviceCountResponse =
        host.unary("DeviceCount", &proto::DeviceCountRequest {}).await.unwrap();
    count.devices
}

// --- The runtime's side ----------------------------------------------------------------------------

/// Run what is due by [now_ms]: the watch, and only the watch. What it concluded.
async fn run_watch(host: &Host, now_ms: u64) -> Outcome {
    let ran = host.run_due(now_ms).await.unwrap();
    assert_eq!(ran.len(), 1, "the watch, and nothing else, was due: {ran:?}");
    assert_eq!(ran[0].0, WATCH_TASK_ID);
    let bytes = ran[0].1.clone().expect("the watch's run succeeded");
    serde_json::from_slice(&bytes).unwrap()
}

/// The ASP's next batch, with [intent_id] in it: started, then finalized — a batch with no tree
/// for the delegate to sign, which is the shortest a round can be.
fn script_a_batch(host: &Host, intent_id: &str) {
    let hash = hex::encode(Sha256::digest(intent_id.as_bytes()));
    host.runtime.asp.lock().unwrap().events = vec![
        serde_json::json!({ "result": { "batchStarted": {
            "id": "batch-1", "intentIdHashes": [hash], "batchExpiry": "512" } } }),
        serde_json::json!({ "result": { "batchFinalized": {
            "id": "batch-1", "commitmentTxid": commitment_txid() } } }),
    ];
}

fn vtxo_txid() -> String {
    VTXO.repeat(32)
}

fn commitment_txid() -> String {
    COMMITMENT.repeat(32)
}

/// Regtest-shaped ASP parameters: real keys and a real address, which the delegate parses.
fn ark_info() -> ark::client::types::ArkInfo {
    ark::client::types::ArkInfo {
        signer_pubkey: "79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798".into(),
        forfeit_pubkey: "0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798".into(),
        forfeit_address: "bcrt1qq5rjlmqartxjyh6vnmjrhrqnc58q2hqr5asln0".into(),
        checkpoint_tapscript: String::new(),
        network: "regtest".into(),
        session_duration: 0,
        unilateral_exit_delay: 512,
        boarding_exit_delay: 144,
        vtxo_min_amount: 0,
        dust: 330,
    }
}

/// The same, as the ASP's REST gateway serves it.
fn ark_info_json() -> serde_json::Value {
    let info = ark_info();
    serde_json::json!({
        "signerPubkey": info.signer_pubkey,
        "forfeitPubkey": info.forfeit_pubkey,
        "forfeitAddress": info.forfeit_address,
        "checkpointTapscript": info.checkpoint_tapscript,
        "network": info.network,
        "sessionDuration": info.session_duration.to_string(),
        "unilateralExitDelay": info.unilateral_exit_delay.to_string(),
        "boardingExitDelay": info.boarding_exit_delay.to_string(),
        "vtxoMinAmount": info.vtxo_min_amount.to_string(),
        "dust": info.dust.to_string(),
    })
}

fn now_secs() -> i64 {
    SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_secs() as i64
}

fn now_ms() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_millis() as u64
}
