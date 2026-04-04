mod auth;
mod bitcoin;
mod config;
mod crypto_ops;
mod persistence;
mod policy;
mod wallet_service;
mod wasm_manager;

use std::sync::Arc;

use clap::Parser;
use tonic::transport::Server;

// Client-facing wallet API
pub mod wallet_proto {
    tonic::include_proto!("mpc_wallet");
}

#[derive(Parser)]
#[command(
    name = "server",
    about = "MPC Wallet Server with per-user WASM crypto isolation"
)]
struct Args {
    /// Path to the cosigner WASM component.
    /// Falls back to COSIGNER_WASM_PATH env var, then the local build path.
    #[arg(long)]
    wasm: Option<String>,

    /// gRPC listen port
    #[arg(long, default_value = "50051")]
    port: u16,
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    use std::io::IsTerminal as _;
    tracing_subscriber::fmt()
        .with_timer(tracing_subscriber::fmt::time::uptime())
        .with_target(false)
        .with_ansi(std::io::stderr().is_terminal())
        .compact()
        .init();

    let args = Args::parse();

    // Load config from environment
    let cfg = config::ServerConfig::from_environment();
    tracing::info!(
        "Config: bitcoin_rpc={}, electrum={}:{}, network={}",
        cfg.bitcoin_rpc_url,
        cfg.electrum_url,
        cfg.electrum_port,
        cfg.bitcoin_network
    );

    // Initialize persistence backend
    let (persistence, secret_store): (Arc<dyn persistence::KvStore>, Arc<dyn persistence::SecretStore>) =
        match cfg.persistence_backend.as_str() {
            #[cfg(feature = "enclave-backend")]
            "enclave" => {
                tracing::info!("Persistence: enclave supervisor at {}", cfg.supervisor_url);
                let store = Arc::new(persistence::EnclaveStore::new(
                    cfg.supervisor_url.clone(),
                    cfg.enclave_mgmt_token.clone(),
                ));
                (store.clone(), store)
            }
            #[cfg(feature = "sled-backend")]
            _ => {
                let data_dir = std::path::Path::new(&cfg.data_dir);
                std::fs::create_dir_all(data_dir)?;
                tracing::info!("Persistence: Sled at {}", cfg.data_dir);
                let store = Arc::new(persistence::SledStore::open(data_dir)?);
                (store.clone(), store)
            }
            #[cfg(not(feature = "sled-backend"))]
            other => {
                panic!("Unknown persistence backend: {other}");
            }
        };

    // Load WASM component: CLI --wasm > COSIGNER_WASM_PATH env > default
    let wasm_source = args.wasm.unwrap_or(cfg.cosigner_wasm_path.clone());
    let wasm_path = if wasm_source.starts_with("http://") || wasm_source.starts_with("https://") {
        tracing::info!("Downloading WASM component from: {}", wasm_source);
        let wasm_dir = std::path::Path::new(&cfg.data_dir).join("wasm");
        std::fs::create_dir_all(&wasm_dir)?;
        let local_path = wasm_dir.join("cosigner.wasm");
        let bytes = reqwest::get(&wasm_source)
            .await?
            .error_for_status()
            .map_err(|e| format!("Failed to download WASM: {e}"))?
            .bytes()
            .await?;
        std::fs::write(&local_path, &bytes)?;
        tracing::info!("Downloaded {} bytes to {}", bytes.len(), local_path.display());
        local_path.to_string_lossy().into_owned()
    } else {
        wasm_source
    };
    tracing::info!("Loading WASM component from: {}", wasm_path);
    let manager = wasm_manager::WasmManager::new(&wasm_path)?;

    // Initialize Bitcoin services
    let bitcoin_rpc = Arc::new(bitcoin::BitcoinRpcClient::new(
        &cfg.bitcoin_rpc_url,
        &cfg.bitcoin_rpc_user,
        &cfg.bitcoin_rpc_password,
    ));

    let electrum_client =
        bitcoin::ElectrumClient::new(&cfg.electrum_url, cfg.electrum_port);
    let bitcoin_history = Arc::new(tokio::sync::Mutex::new(
        bitcoin::BitcoinHistoryService::new(electrum_client),
    ));

    // Initialize Electrum connection in background
    let bh = bitcoin_history.clone();
    tokio::spawn(async move {
        let service = bh.lock().await;
        if let Err(e) = service.init().await {
            tracing::error!("Failed to initialize Electrum: {e}");
        }
    });

    // Create auth verifier
    let auth_verifier = Arc::new(auth::AuthVerifier::new());

    // Connect to ASP (Ark Service Provider) if configured
    let asp_client = if !cfg.asp_url.is_empty() {
        tracing::info!("Connecting to ASP at {}", cfg.asp_url);
        match ark::client::AspClient::connect(&cfg.asp_url).await {
            Ok(client) => {
                tracing::info!("Connected to ASP");
                Some(client)
            }
            Err(e) => {
                tracing::warn!("Failed to connect to ASP: {e} (Ark RPCs will be unavailable)");
                None
            }
        }
    } else {
        tracing::info!("ASP_URL not set, Ark RPCs disabled");
        None
    };

    // Create wallet service
    let service = std::sync::Arc::new(wallet_service::WalletService::new(
        manager,
        auth_verifier,
        persistence,
        secret_store,
        bitcoin_rpc,
        bitcoin_history,
        asp_client,
    ));

    // Load persisted Ark state and validate ASP key
    service.load_ark_state().await;

    // Spawn background VTXO stream sync if ASP is configured
    if service.asp_client.is_some() {
        let svc = service.clone();
        tokio::spawn(async move {
            svc.run_vtxo_stream().await;
        });
    }

    let addr = format!("0.0.0.0:{}", args.port).parse()?;
    tracing::info!("MPC Wallet Server listening on {}", addr);

    Server::builder()
        .add_service(
            wallet_proto::mpc_wallet_server::MpcWalletServer::from_arc(service),
        )
        .serve(addr)
        .await?;

    Ok(())
}
