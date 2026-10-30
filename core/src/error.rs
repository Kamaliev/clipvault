#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum CoreError {
    #[error("invalid key: {0}")]
    InvalidKey(String),
    #[error("stored data was encrypted with a different key")]
    KeyMismatch,
    #[error("decryption failed")]
    Decrypt,
    #[error("database error: {0}")]
    Database(String),
    #[error("io error: {0}")]
    Io(String),
    #[error("entry not found")]
    NotFound,
}

impl From<rusqlite::Error> for CoreError {
    fn from(e: rusqlite::Error) -> Self {
        CoreError::Database(e.to_string())
    }
}

impl From<std::io::Error> for CoreError {
    fn from(e: std::io::Error) -> Self {
        CoreError::Io(e.to_string())
    }
}

pub type Result<T> = std::result::Result<T, CoreError>;
