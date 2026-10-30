mod crypto;
mod error;
mod model;
mod preview;
mod secrets;
mod store;

pub use error::CoreError;
pub use model::{ClipKind, ClipRep, ClipSummary, NewClip};
pub use secrets::mask_secrets;
pub use store::{Store, delete_store_files};

uniffi::setup_scaffolding!();
