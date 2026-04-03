use std::collections::HashMap;
use std::fmt;

/// Errors from the persistence layer.
#[derive(Debug)]
pub enum PersistenceError {
    Backend(String),
}

impl fmt::Display for PersistenceError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            PersistenceError::Backend(msg) => write!(f, "persistence error: {msg}"),
        }
    }
}

impl std::error::Error for PersistenceError {}

/// Abstract key-value persistence with named trees (namespaces).
///
/// Each "tree" is a logical namespace (e.g. "policies", "vtxo_store").
/// For Sled, these map to named trees. For S3, they map to key prefixes.
pub trait KvStore: Send + Sync + 'static {
    /// Get a value by key from a named tree.
    fn get(&self, tree: &str, key: &str) -> Result<Option<String>, PersistenceError>;

    /// Put a key-value pair into a named tree.
    fn put(&self, tree: &str, key: &str, value: &str) -> Result<(), PersistenceError>;

    /// Delete a key from a named tree.
    fn delete(&self, tree: &str, key: &str) -> Result<(), PersistenceError>;

    /// Get all key-value pairs in a named tree.
    /// Use sparingly — prefer targeted gets where possible.
    fn get_all(&self, tree: &str) -> Result<HashMap<String, String>, PersistenceError>;

    /// Delete all keys in a named tree.
    fn clear(&self, tree: &str) -> Result<(), PersistenceError>;
}
