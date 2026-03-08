//! Ark protocol client — ASP communication, address derivation, VTXO management.
//!
//! This module is only available with the `client` feature enabled.

pub mod address;
pub mod asp_client;
pub mod batch;
pub mod send;
pub mod types;

/// Re-export generated protobuf types for the arkd ArkService.
pub mod proto {
    tonic::include_proto!("ark.v1");
}

// Re-exports for convenience.
pub use address::{ark_address, boarding_address, parse_network};
pub use asp_client::AspClient;
pub use types::{ArkInfo, StoredVtxo, VtxoStatus};
