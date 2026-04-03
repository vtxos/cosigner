use std::collections::HashMap;

use super::traits::{KvStore, PersistenceError};

/// HTTP-based key-value persistence store for enclave deployments.
///
/// Delegates storage to the enclave's KV endpoints. The enclave exposes
/// a simple REST API for (key, value) operations. Keys are namespaced
/// by tree: `{base_url}/{tree}/{key}`.
///
/// Expected enclave API:
///   GET    /{tree}/{key}       -> 200 + body (value) | 404
///   PUT    /{tree}/{key}       -> 200  (body = value)
///   DELETE /{tree}/{key}       -> 200
///   GET    /{tree}             -> 200 + JSON object { "key": "value", ... }
///   DELETE /{tree}             -> 200  (clears all keys in tree)
pub struct EnclaveStore {
    client: reqwest::Client,
    base_url: String,
}

impl EnclaveStore {
    pub fn new(base_url: String) -> Self {
        let client = reqwest::Client::new();
        Self { client, base_url: base_url.trim_end_matches('/').to_string() }
    }

    fn url(&self, tree: &str, key: &str) -> String {
        format!("{}/{tree}/{key}", self.base_url)
    }

    fn tree_url(&self, tree: &str) -> String {
        format!("{}/{tree}", self.base_url)
    }

    /// Run an async block synchronously using block_in_place.
    fn block_on<F: std::future::Future<Output = T>, T>(f: F) -> T {
        let rt = tokio::runtime::Handle::current();
        tokio::task::block_in_place(|| rt.block_on(f))
    }
}

impl KvStore for EnclaveStore {
    fn get(&self, tree: &str, key: &str) -> Result<Option<String>, PersistenceError> {
        Self::block_on(async {
            let resp = self.client
                .get(&self.url(tree, key))
                .send()
                .await
                .map_err(|e| PersistenceError::Backend(format!("enclave get: {e}")))?;

            if resp.status() == reqwest::StatusCode::NOT_FOUND {
                return Ok(None);
            }
            if !resp.status().is_success() {
                return Err(PersistenceError::Backend(
                    format!("enclave get: status {}", resp.status()),
                ));
            }
            let body = resp.text().await
                .map_err(|e| PersistenceError::Backend(format!("enclave get body: {e}")))?;
            Ok(Some(body))
        })
    }

    fn put(&self, tree: &str, key: &str, value: &str) -> Result<(), PersistenceError> {
        Self::block_on(async {
            let resp = self.client
                .put(&self.url(tree, key))
                .body(value.to_string())
                .send()
                .await
                .map_err(|e| PersistenceError::Backend(format!("enclave put: {e}")))?;

            if !resp.status().is_success() {
                return Err(PersistenceError::Backend(
                    format!("enclave put: status {}", resp.status()),
                ));
            }
            Ok(())
        })
    }

    fn delete(&self, tree: &str, key: &str) -> Result<(), PersistenceError> {
        Self::block_on(async {
            let resp = self.client
                .delete(&self.url(tree, key))
                .send()
                .await
                .map_err(|e| PersistenceError::Backend(format!("enclave delete: {e}")))?;

            if !resp.status().is_success() {
                return Err(PersistenceError::Backend(
                    format!("enclave delete: status {}", resp.status()),
                ));
            }
            Ok(())
        })
    }

    fn get_all(&self, tree: &str) -> Result<HashMap<String, String>, PersistenceError> {
        Self::block_on(async {
            let resp = self.client
                .get(&self.tree_url(tree))
                .send()
                .await
                .map_err(|e| PersistenceError::Backend(format!("enclave get_all: {e}")))?;

            if !resp.status().is_success() {
                return Err(PersistenceError::Backend(
                    format!("enclave get_all: status {}", resp.status()),
                ));
            }
            let map: HashMap<String, String> = resp.json().await
                .map_err(|e| PersistenceError::Backend(format!("enclave get_all parse: {e}")))?;
            Ok(map)
        })
    }

    fn clear(&self, tree: &str) -> Result<(), PersistenceError> {
        Self::block_on(async {
            let resp = self.client
                .delete(&self.tree_url(tree))
                .send()
                .await
                .map_err(|e| PersistenceError::Backend(format!("enclave clear: {e}")))?;

            if !resp.status().is_success() {
                return Err(PersistenceError::Backend(
                    format!("enclave clear: status {}", resp.status()),
                ));
            }
            Ok(())
        })
    }
}
