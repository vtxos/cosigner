use std::collections::HashMap;
use std::path::Path;

/// Sled-based key-value persistence store.
/// Replaces Dart's Hive with five named trees (equivalent to Hive boxes).
pub struct PersistenceStore {
    db: sled::Db,
}

impl PersistenceStore {
    /// Open or create the store at the given path.
    pub fn open(path: &Path) -> Result<Self, sled::Error> {
        let db = sled::open(path)?;
        Ok(Self { db })
    }

    /// Get a named tree (equivalent to a Hive box).
    pub fn tree(&self, name: &str) -> Result<TypedTree, sled::Error> {
        let tree = self.db.open_tree(name)?;
        Ok(TypedTree { tree })
    }

}

/// A typed wrapper around a sled::Tree for string key-value storage.
#[derive(Clone)]
pub struct TypedTree {
    tree: sled::Tree,
}

impl TypedTree {
    /// Get a value by key.
    pub fn get(&self, key: &str) -> Result<Option<String>, sled::Error> {
        self.tree
            .get(key.as_bytes())
            .map(|opt| opt.map(|v| String::from_utf8_lossy(&v).to_string()))
    }

    /// Put a key-value pair.
    pub fn put(&self, key: &str, value: &str) -> Result<(), sled::Error> {
        self.tree.insert(key.as_bytes(), value.as_bytes())?;
        Ok(())
    }

    /// Delete a key.
    pub fn delete(&self, key: &str) -> Result<(), sled::Error> {
        self.tree.remove(key.as_bytes())?;
        Ok(())
    }

    /// Get all key-value pairs.
    pub fn all(&self) -> Result<HashMap<String, String>, sled::Error> {
        let mut result = HashMap::new();
        for item in self.tree.iter() {
            let (k, v) = item?;
            let key = String::from_utf8_lossy(&k).to_string();
            let value = String::from_utf8_lossy(&v).to_string();
            result.insert(key, value);
        }
        Ok(result)
    }

}
