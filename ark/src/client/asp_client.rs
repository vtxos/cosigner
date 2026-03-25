//! gRPC client for communicating with an Ark Service Provider (ASP).

use tonic::transport::Channel;

use crate::client::proto::ark_service_client::ArkServiceClient;
use crate::client::proto;
use crate::client::types::ArkInfo;

/// Client for communicating with an ASP via gRPC.
pub struct AspClient {
    inner: ArkServiceClient<Channel>,
    /// Cached server info, populated after first `get_info()` call.
    pub info: Option<ArkInfo>,
}

impl AspClient {
    /// Connect to an ASP at the given URL (e.g. "http://localhost:7070").
    pub async fn connect(url: &str) -> Result<Self, Box<dyn std::error::Error + Send + Sync>> {
        let channel = Channel::from_shared(url.to_string())?
            .connect()
            .await?;
        Ok(Self {
            inner: ArkServiceClient::new(channel),
            info: None,
        })
    }

    /// Fetch server info from the ASP.
    pub async fn get_info(&mut self) -> Result<ArkInfo, Box<dyn std::error::Error + Send + Sync>> {
        let response = self
            .inner
            .get_info(proto::GetInfoRequest {})
            .await?
            .into_inner();

        let info = ArkInfo {
            signer_pubkey: response.signer_pubkey,
            forfeit_pubkey: response.forfeit_pubkey,
            forfeit_address: response.forfeit_address,
            checkpoint_tapscript: response.checkpoint_tapscript,
            network: response.network,
            session_duration: response.session_duration,
            unilateral_exit_delay: response.unilateral_exit_delay,
            boarding_exit_delay: response.boarding_exit_delay,
            vtxo_min_amount: response.vtxo_min_amount,
            dust: response.dust,
        };

        self.info = Some(info.clone());
        Ok(info)
    }

    /// Register an intent for the next batch round.
    ///
    /// `proof` is a BIP-322 proof, `message` contains the intent details.
    pub async fn register_intent(
        &mut self,
        proof: String,
        message: String,
    ) -> Result<String, Box<dyn std::error::Error + Send + Sync>> {
        let response = self
            .inner
            .register_intent(proto::RegisterIntentRequest {
                intent: Some(proto::Intent { proof, message }),
            })
            .await?
            .into_inner();

        Ok(response.intent_id)
    }

    /// Confirm participation in a batch by revealing the intent ID.
    pub async fn confirm_registration(
        &mut self,
        intent_id: String,
    ) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        self.inner
            .confirm_registration(proto::ConfirmRegistrationRequest { intent_id })
            .await?;
        Ok(())
    }

    /// Submit signed forfeit transactions for a batch.
    pub async fn submit_signed_forfeit_txs(
        &mut self,
        signed_forfeit_txs: Vec<String>,
        signed_commitment_tx: String,
    ) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        self.inner
            .submit_signed_forfeit_txs(proto::SubmitSignedForfeitTxsRequest {
                signed_forfeit_txs,
                signed_commitment_tx,
            })
            .await?;
        Ok(())
    }

    /// Submit a signed Ark transaction (off-chain send).
    pub async fn submit_tx(
        &mut self,
        signed_ark_tx: String,
        checkpoint_txs: Vec<String>,
    ) -> Result<proto::SubmitTxResponse, Box<dyn std::error::Error + Send + Sync>> {
        let response = self
            .inner
            .submit_tx(proto::SubmitTxRequest {
                signed_ark_tx,
                checkpoint_txs,
            })
            .await?
            .into_inner();
        Ok(response)
    }

    /// Finalize an Ark transaction with signed checkpoint transactions.
    pub async fn finalize_tx(
        &mut self,
        ark_txid: String,
        final_checkpoint_txs: Vec<String>,
    ) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        self.inner
            .finalize_tx(proto::FinalizeTxRequest {
                ark_txid,
                final_checkpoint_txs,
            })
            .await?;
        Ok(())
    }

    /// Submit tree nonces for batch co-signing.
    pub async fn submit_tree_nonces(
        &mut self,
        batch_id: &str,
        pubkey: String,
        tree_nonces: std::collections::HashMap<String, String>,
    ) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        self.inner
            .submit_tree_nonces(proto::SubmitTreeNoncesRequest {
                batch_id: batch_id.to_string(),
                pubkey,
                tree_nonces,
            })
            .await?;
        Ok(())
    }

    /// Submit tree signatures for batch co-signing.
    pub async fn submit_tree_signatures(
        &mut self,
        batch_id: &str,
        pubkey: String,
        tree_signatures: std::collections::HashMap<String, String>,
    ) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        self.inner
            .submit_tree_signatures(proto::SubmitTreeSignaturesRequest {
                batch_id: batch_id.to_string(),
                pubkey,
                tree_signatures,
            })
            .await?;
        Ok(())
    }

    /// Open a server-sent event stream for batch events.
    pub async fn get_event_stream(
        &mut self,
        topics: Vec<String>,
    ) -> Result<
        tonic::Streaming<proto::GetEventStreamResponse>,
        Box<dyn std::error::Error + Send + Sync>,
    > {
        let response = self
            .inner
            .get_event_stream(proto::GetEventStreamRequest { topics })
            .await?
            .into_inner();
        Ok(response)
    }

    /// Open a transaction notification stream.
    pub async fn get_transactions_stream(
        &mut self,
    ) -> Result<
        tonic::Streaming<proto::GetTransactionsStreamResponse>,
        Box<dyn std::error::Error + Send + Sync>,
    > {
        let response = self
            .inner
            .get_transactions_stream(proto::GetTransactionsStreamRequest {})
            .await?
            .into_inner();
        Ok(response)
    }
}
