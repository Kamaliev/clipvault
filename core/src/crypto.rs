use chacha20poly1305::aead::{Aead, KeyInit, Payload};
use chacha20poly1305::{XChaCha20Poly1305, XNonce};
use hkdf::Hkdf;
use sha2::Sha256;
use zeroize::Zeroizing;

use crate::error::{CoreError, Result};

pub const KEY_LEN: usize = 32;
pub const NONCE_LEN: usize = 24;

/// Keys derived from the master key stored in the macOS Keychain.
pub struct Keys {
    cipher: XChaCha20Poly1305,
    hash_key: Zeroizing<[u8; 32]>,
}

impl Keys {
    pub fn derive(master: &[u8]) -> Result<Self> {
        if master.len() != KEY_LEN {
            return Err(CoreError::InvalidKey(format!(
                "expected {KEY_LEN} bytes, got {}",
                master.len()
            )));
        }
        let hk = Hkdf::<Sha256>::new(Some(b"pb-window/v1"), master);
        let mut enc = Zeroizing::new([0u8; 32]);
        let mut hash_key = Zeroizing::new([0u8; 32]);
        hk.expand(b"encryption", enc.as_mut())
            .map_err(|e| CoreError::InvalidKey(e.to_string()))?;
        hk.expand(b"dedup-hash", hash_key.as_mut())
            .map_err(|e| CoreError::InvalidKey(e.to_string()))?;
        let cipher = XChaCha20Poly1305::new_from_slice(enc.as_ref())
            .map_err(|e| CoreError::InvalidKey(e.to_string()))?;
        Ok(Self { cipher, hash_key })
    }

    /// Returns `nonce || ciphertext`.
    pub fn seal(&self, plaintext: &[u8], aad: &[u8]) -> Result<Vec<u8>> {
        let mut nonce = [0u8; NONCE_LEN];
        getrandom::fill(&mut nonce).map_err(|e| CoreError::Io(e.to_string()))?;
        let ct = self
            .cipher
            .encrypt(&XNonce::from(nonce), Payload { msg: plaintext, aad })
            .map_err(|_| CoreError::Decrypt)?;
        let mut out = Vec::with_capacity(NONCE_LEN + ct.len());
        out.extend_from_slice(&nonce);
        out.extend_from_slice(&ct);
        Ok(out)
    }

    pub fn open(&self, sealed: &[u8], aad: &[u8]) -> Result<Zeroizing<Vec<u8>>> {
        if sealed.len() < NONCE_LEN {
            return Err(CoreError::Decrypt);
        }
        let (nonce, ct) = sealed.split_at(NONCE_LEN);
        let nonce: [u8; NONCE_LEN] = nonce.try_into().map_err(|_| CoreError::Decrypt)?;
        self.cipher
            .decrypt(&XNonce::from(nonce), Payload { msg: ct, aad })
            .map(Zeroizing::new)
            .map_err(|_| CoreError::Decrypt)
    }

    /// Keyed content hash used for deduplication; doesn't leak content without the key.
    pub fn content_hash<'a>(&self, parts: impl IntoIterator<Item = (&'a str, &'a [u8])>) -> [u8; 32] {
        let mut h = blake3::Hasher::new_keyed(&self.hash_key);
        for (uti, data) in parts {
            h.update(&(uti.len() as u64).to_le_bytes());
            h.update(uti.as_bytes());
            h.update(&(data.len() as u64).to_le_bytes());
            h.update(data);
        }
        *h.finalize().as_bytes()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn keys(b: u8) -> Keys {
        Keys::derive(&[b; 32]).unwrap()
    }

    #[test]
    fn roundtrip_and_unique_nonces() {
        let k = keys(1);
        let a = k.seal(b"hello", b"aad").unwrap();
        let b = k.seal(b"hello", b"aad").unwrap();
        assert_ne!(a, b);
        assert_eq!(&**k.open(&a, b"aad").unwrap(), b"hello");
    }

    #[test]
    fn rejects_wrong_aad_wrong_key_and_tampering() {
        let k = keys(1);
        let mut s = k.seal(b"secret", b"aad").unwrap();
        assert!(k.open(&s, b"other").is_err());
        assert!(keys(2).open(&s, b"aad").is_err());
        let last = s.len() - 1;
        s[last] ^= 1;
        assert!(k.open(&s, b"aad").is_err());
        assert!(k.open(&[0u8; 5], b"aad").is_err());
    }

    #[test]
    fn invalid_key_length() {
        assert!(matches!(Keys::derive(&[0u8; 16]), Err(CoreError::InvalidKey(_))));
    }

    #[test]
    fn hash_is_keyed_and_unambiguous() {
        let k = keys(1);
        let h1 = k.content_hash([("a", b"bc".as_slice())]);
        assert_eq!(h1, k.content_hash([("a", b"bc".as_slice())]));
        assert_ne!(h1, k.content_hash([("ab", b"c".as_slice())]));
        assert_ne!(h1, keys(2).content_hash([("a", b"bc".as_slice())]));
    }
}
