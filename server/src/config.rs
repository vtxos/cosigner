use std::env;
use std::fs;

/// Server configuration loaded from environment variables.
/// Mirrors the Dart `ServerConfig` from `server/lib/config.dart`.
#[derive(Debug, Clone)]
pub struct ServerConfig {
    pub bitcoin_rpc_url: String,
    pub bitcoin_rpc_user: String,
    pub bitcoin_rpc_password: String,
    pub electrum_url: String,
    pub electrum_port: u16,
    pub data_dir: String,
    /// ASP (Ark Service Provider) gRPC URL, e.g. "http://localhost:7070".
    /// When empty, Ark RPCs return UNAVAILABLE.
    pub asp_url: String,
    /// Bitcoin network name (e.g. "regtest", "signet", "testnet", "mainnet").
    /// Used for logging; the authoritative network comes from the ASP's GetArkInfo.
    pub bitcoin_network: String,
    /// Persistence backend: "sled" (local) or "enclave" (HTTP KV store).
    pub persistence_backend: String,
    /// Enclave KV store base URL (only used when persistence_backend = "enclave").
    pub enclave_store_url: String,
}

impl ServerConfig {
    /// Load configuration from environment variables.
    /// Supports Docker secrets via `_FILE` suffix pattern.
    pub fn from_environment() -> Self {
        Self {
            bitcoin_rpc_url: env::var("BITCOIN_RPC_URL")
                .unwrap_or_else(|_| "http://127.0.0.1:18443".to_string()),
            bitcoin_rpc_user: load_secret("BITCOIN_RPC_USER"),
            bitcoin_rpc_password: load_secret("BITCOIN_RPC_PASSWORD"),
            electrum_url: env::var("ELECTRUM_URL").unwrap_or_else(|_| "127.0.0.1".to_string()),
            electrum_port: env::var("ELECTRUM_PORT")
                .ok()
                .and_then(|s| s.parse().ok())
                .unwrap_or(50001),
            data_dir: env::var("DATA_DIR").unwrap_or_else(|_| {
                let home = env::var("HOME").unwrap_or_else(|_| "/tmp".to_string());
                format!("{}/.mpc_wallet/server", home)
            }),
            asp_url: env::var("ASP_URL").unwrap_or_default(),
            bitcoin_network: env::var("BITCOIN_NETWORK")
                .unwrap_or_else(|_| "regtest".to_string()),
            persistence_backend: env::var("PERSISTENCE_BACKEND")
                .unwrap_or_else(|_| "sled".to_string()),
            enclave_store_url: env::var("ENCLAVE_STORE_URL").unwrap_or_default(),
        }
    }
}

/// Load a secret from environment variable or Docker secrets file.
fn load_secret(env_name: &str) -> String {
    // Check _FILE variant first (Docker secrets)
    let file_env = format!("{}_FILE", env_name);
    if let Ok(path) = env::var(&file_env) {
        if !path.is_empty() {
            if let Ok(contents) = fs::read_to_string(&path) {
                return contents.trim().to_string();
            }
        }
    }
    env::var(env_name).unwrap_or_default()
}
