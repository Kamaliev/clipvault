mod crypto;
mod error;
mod model;
mod preview;
mod store;

pub use error::CoreError;
pub use model::{ClipKind, ClipRep, ClipSummary, NewClip};
pub use store::{Store, delete_store_files};

uniffi::setup_scaffolding!();
