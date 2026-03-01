use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;

use serde_json::{json, Value};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::TcpStream;
use tokio::sync::{broadcast, Mutex, oneshot};

/// Electrum TCP JSON-RPC client with notification support.
/// Mirrors `ElectrumTcpServiceImpl` from `server/lib/services/electrum_service_impl.dart`.
pub struct ElectrumClient {
    writer: Arc<Mutex<Option<tokio::io::WriteHalf<TcpStream>>>>,
    pending: Arc<Mutex<HashMap<u64, oneshot::Sender<Value>>>>,
    notification_tx: broadcast::Sender<ElectrumNotification>,
    next_id: AtomicU64,
    domain: String,
    port: u16,
}

#[derive(Debug, Clone)]
pub struct ElectrumNotification {
    pub _method: String,
    pub _params: Vec<Value>,
}

impl ElectrumClient {
    pub fn new(domain: &str, port: u16) -> Self {
        let (notification_tx, _) = broadcast::channel(256);
        Self {
            writer: Arc::new(Mutex::new(None)),
            pending: Arc::new(Mutex::new(HashMap::new())),
            notification_tx,
            next_id: AtomicU64::new(0),
            domain: domain.to_string(),
            port,
        }
    }

    /// Connect to the Electrum server.
    pub async fn connect(&self) -> Result<(), String> {
        let addr = format!("{}:{}", self.domain, self.port);
        tracing::info!("Connecting to Electrum at {addr}...");

        let stream = TcpStream::connect(&addr)
            .await
            .map_err(|e| format!("Failed to connect to Electrum: {e}"))?;

        let (reader, writer) = tokio::io::split(stream);
        *self.writer.lock().await = Some(writer);

        // Spawn reader task
        let pending = self.pending.clone();
        let notification_tx = self.notification_tx.clone();
        tokio::spawn(async move {
            let mut lines = BufReader::new(reader).lines();
            while let Ok(Some(line)) = lines.next_line().await {
                if line.is_empty() {
                    continue;
                }
                match serde_json::from_str::<Value>(&line) {
                    Ok(msg) => {
                        if let Some(id) = msg.get("id").and_then(|v| v.as_u64()) {
                            // Response to a request
                            let mut pending = pending.lock().await;
                            if let Some(sender) = pending.remove(&id) {
                                let _ = sender.send(msg);
                            }
                        } else if let Some(method) = msg.get("method").and_then(|v| v.as_str()) {
                            // Notification
                            if method.ends_with(".subscribe") {
                                let params = msg
                                    .get("params")
                                    .and_then(|v| v.as_array())
                                    .cloned()
                                    .unwrap_or_default();
                                let _ = notification_tx.send(ElectrumNotification {
                                    _method: method.to_string(),
                                    _params: params,
                                });
                            }
                        }
                    }
                    Err(e) => {
                        tracing::warn!("Electrum JSON parse error: {e}");
                    }
                }
            }
            tracing::info!("Electrum reader task ended");
        });

        tracing::info!("Connected to Electrum at {addr}");
        Ok(())
    }

    /// Send a JSON-RPC request and wait for the response.
    pub async fn request(&self, method: &str, params: &[Value]) -> Result<Value, String> {
        let id = self.next_id.fetch_add(1, Ordering::SeqCst);
        let payload = json!({
            "jsonrpc": "2.0",
            "method": method,
            "params": params,
            "id": id,
        });

        let (tx, rx) = oneshot::channel();
        self.pending.lock().await.insert(id, tx);

        let msg = format!("{}\n", payload);
        let mut writer_guard = self.writer.lock().await;
        let writer = writer_guard
            .as_mut()
            .ok_or_else(|| "Not connected to Electrum".to_string())?;
        writer
            .write_all(msg.as_bytes())
            .await
            .map_err(|e| format!("Failed to write to Electrum: {e}"))?;
        drop(writer_guard);

        let response = rx
            .await
            .map_err(|_| "Electrum request cancelled".to_string())?;

        if let Some(error) = response.get("error") {
            if !error.is_null() {
                return Err(format!("Electrum error: {error}"));
            }
        }

        Ok(response.get("result").cloned().unwrap_or(Value::Null))
    }

    /// List unspent outputs for a script hash.
    pub async fn list_unspent(&self, script_hash: &str) -> Result<Vec<ElectrumUtxo>, String> {
        let result = self
            .request("blockchain.scripthash.listunspent", &[json!(script_hash)])
            .await?;

        let utxos: Vec<ElectrumUtxo> = serde_json::from_value(result)
            .map_err(|e| format!("Failed to parse listunspent: {e}"))?;
        Ok(utxos)
    }

    /// Get transaction history for a script hash.
    pub async fn get_history(
        &self,
        script_hash: &str,
    ) -> Result<Vec<ElectrumHistoryItem>, String> {
        let result = self
            .request("blockchain.scripthash.get_history", &[json!(script_hash)])
            .await?;

        let items: Vec<ElectrumHistoryItem> = serde_json::from_value(result)
            .map_err(|e| format!("Failed to parse history: {e}"))?;
        Ok(items)
    }

    /// Get raw transaction hex by hash.
    pub async fn get_transaction(&self, tx_hash: &str) -> Result<String, String> {
        let result = self
            .request("blockchain.transaction.get", &[json!(tx_hash)])
            .await?;

        result
            .as_str()
            .map(|s| s.to_string())
            .ok_or_else(|| "unexpected transaction response".to_string())
    }

    /// Get block header hex at a given height.
    pub async fn get_block_header(&self, height: u32) -> Result<String, String> {
        let result = self
            .request("blockchain.block.header", &[json!(height)])
            .await?;

        result
            .as_str()
            .map(|s| s.to_string())
            .ok_or_else(|| "unexpected header response".to_string())
    }

}

#[derive(Debug, Clone, serde::Deserialize)]
pub struct ElectrumUtxo {
    pub tx_hash: String,
    pub tx_pos: u32,
    pub value: i64,
    #[allow(dead_code)]
    pub height: i64,
}

#[derive(Debug, Clone, serde::Deserialize)]
pub struct ElectrumHistoryItem {
    pub tx_hash: String,
    pub height: i64,
}
