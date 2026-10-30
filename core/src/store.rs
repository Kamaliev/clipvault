use std::path::Path;
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::{SystemTime, UNIX_EPOCH};

use rusqlite::{Connection, OptionalExtension, params};

use crate::crypto::Keys;
use crate::error::{CoreError, Result};
use crate::model::*;
use crate::preview;

type Clock = Box<dyn Fn() -> i64 + Send + Sync>;

const CHECK_PLAINTEXT: &[u8] = b"clipvault key check v1";

#[derive(uniffi::Object)]
pub struct Store {
    conn: Mutex<Connection>,
    keys: Keys,
    ttl_secs: i64,
    max_bytes: u64,
    clock: Clock,
}

fn system_now() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

fn hex(b: &[u8]) -> String {
    b.iter().map(|x| format!("{x:02x}")).collect()
}

fn aad_meta(hash: &[u8]) -> Vec<u8> {
    format!("meta|{}", hex(hash)).into_bytes()
}
fn aad_thumb(hash: &[u8]) -> Vec<u8> {
    format!("thumb|{}", hex(hash)).into_bytes()
}
fn aad_rep(hash: &[u8], idx: usize) -> Vec<u8> {
    format!("rep|{}|{idx}", hex(hash)).into_bytes()
}

// Length-prefixed encoding so no serialization dependency is needed.
fn put_bytes(out: &mut Vec<u8>, b: &[u8]) {
    out.extend_from_slice(&(b.len() as u32).to_le_bytes());
    out.extend_from_slice(b);
}

fn take_bytes<'a>(buf: &mut &'a [u8]) -> Result<&'a [u8]> {
    if buf.len() < 4 {
        return Err(CoreError::Decrypt);
    }
    let n = u32::from_le_bytes(buf[..4].try_into().unwrap()) as usize;
    if buf.len() < 4 + n {
        return Err(CoreError::Decrypt);
    }
    let v = &buf[4..4 + n];
    *buf = &buf[4 + n..];
    Ok(v)
}

fn take_str(buf: &mut &[u8]) -> Result<String> {
    Ok(String::from_utf8_lossy(take_bytes(buf)?).into_owned())
}

struct Meta {
    preview: String,
    search: String,
    source_app: Option<String>,
}

impl Meta {
    fn encode(&self) -> Vec<u8> {
        let mut out = Vec::new();
        put_bytes(&mut out, self.preview.as_bytes());
        put_bytes(&mut out, self.search.as_bytes());
        put_bytes(
            &mut out,
            self.source_app.as_deref().unwrap_or("").as_bytes(),
        );
        out
    }

    fn decode(mut b: &[u8]) -> Result<Self> {
        let preview = take_str(&mut b)?;
        let search = take_str(&mut b)?;
        let app = take_str(&mut b)?;
        Ok(Self {
            preview,
            search,
            source_app: (!app.is_empty()).then_some(app),
        })
    }
}

fn encode_rep(r: &ClipRep) -> Vec<u8> {
    let mut out = Vec::with_capacity(r.data.len() + r.uti.len() + 12);
    out.extend_from_slice(&r.item.to_le_bytes());
    put_bytes(&mut out, r.uti.as_bytes());
    put_bytes(&mut out, &r.data);
    out
}

fn decode_rep(b: &[u8]) -> Result<ClipRep> {
    if b.len() < 4 {
        return Err(CoreError::Decrypt);
    }
    let item = u32::from_le_bytes(b[..4].try_into().unwrap());
    let mut rest = &b[4..];
    let uti = take_str(&mut rest)?;
    let data = take_bytes(&mut rest)?.to_vec();
    Ok(ClipRep { item, uti, data })
}

const SCHEMA_VERSION: i64 = 2;
const LIVE: &str = "(pinned = 1 OR created_at > ?1)";

fn migrate(conn: &Connection) -> Result<()> {
    let version: i64 = conn.query_row("PRAGMA user_version", [], |r| r.get(0))?;
    if version < 2 {
        let has_pinned = conn
            .prepare("SELECT 1 FROM pragma_table_info('entry') WHERE name = 'pinned'")?
            .exists([])?;
        if !has_pinned {
            conn.execute_batch("ALTER TABLE entry ADD COLUMN pinned INTEGER NOT NULL DEFAULT 0;")?;
        }
    }
    conn.execute_batch(&format!("PRAGMA user_version = {SCHEMA_VERSION};"))?;
    Ok(())
}

#[cfg(unix)]
fn restrict_permissions(path: &Path, mode: u32) {
    use std::os::unix::fs::PermissionsExt;
    let _ = std::fs::set_permissions(path, std::fs::Permissions::from_mode(mode));
}

impl Store {
    pub fn open_with_clock(
        path: &str,
        key: &[u8],
        ttl_secs: u64,
        max_bytes: u64,
        clock: Clock,
    ) -> Result<Self> {
        let keys = Keys::derive(key)?;
        let conn = if path == ":memory:" {
            Connection::open_in_memory()?
        } else {
            let p = Path::new(path);
            if let Some(dir) = p.parent().filter(|d| !d.as_os_str().is_empty()) {
                std::fs::create_dir_all(dir)?;
                restrict_permissions(dir, 0o700);
            }
            let conn = Connection::open(p)?;
            restrict_permissions(p, 0o600);
            conn
        };
        conn.execute_batch(
            "PRAGMA secure_delete = ON;
             PRAGMA journal_mode = DELETE;
             PRAGMA foreign_keys = ON;
             CREATE TABLE IF NOT EXISTS kv (key TEXT PRIMARY KEY, value BLOB NOT NULL);
             CREATE TABLE IF NOT EXISTS entry (
                 id INTEGER PRIMARY KEY AUTOINCREMENT,
                 hash BLOB NOT NULL UNIQUE,
                 kind INTEGER NOT NULL,
                 created_at INTEGER NOT NULL,
                 size INTEGER NOT NULL,
                 meta BLOB NOT NULL,
                 thumb BLOB
             );
             CREATE INDEX IF NOT EXISTS entry_created ON entry(created_at);
             CREATE TABLE IF NOT EXISTS rep (
                 entry_id INTEGER NOT NULL REFERENCES entry(id) ON DELETE CASCADE,
                 idx INTEGER NOT NULL,
                 payload BLOB NOT NULL,
                 PRIMARY KEY (entry_id, idx)
             );
",
        )?;
        migrate(&conn)?;
        let check: Option<Vec<u8>> = conn
            .query_row("SELECT value FROM kv WHERE key = 'check'", [], |r| r.get(0))
            .optional()?;
        match check {
            Some(sealed) => {
                let pt = keys
                    .open(&sealed, b"check")
                    .map_err(|_| CoreError::KeyMismatch)?;
                if pt.as_slice() != CHECK_PLAINTEXT {
                    return Err(CoreError::KeyMismatch);
                }
            }
            None => {
                conn.execute(
                    "INSERT INTO kv (key, value) VALUES ('check', ?1)",
                    params![keys.seal(CHECK_PLAINTEXT, b"check")?],
                )?;
            }
        }
        let store = Self {
            conn: Mutex::new(conn),
            keys,
            ttl_secs: ttl_secs as i64,
            max_bytes,
            clock,
        };
        store.purge_expired()?;
        Ok(store)
    }

    fn conn(&self) -> MutexGuard<'_, Connection> {
        self.conn.lock().unwrap_or_else(|e| e.into_inner())
    }

    fn cutoff(&self) -> i64 {
        (self.clock)() - self.ttl_secs
    }
}

#[uniffi::export]
impl Store {
    /// Opens (or creates) the encrypted store. `key` is the 32-byte master key from the Keychain.
    /// `path` may be `:memory:` for a non-persistent store.
    #[uniffi::constructor]
    pub fn open(path: String, key: Vec<u8>, ttl_secs: u64, max_bytes: u64) -> Result<Arc<Self>> {
        let key = zeroize::Zeroizing::new(key);
        Self::open_with_clock(&path, &key, ttl_secs, max_bytes, Box::new(system_now)).map(Arc::new)
    }

    /// Stores a clipboard snapshot. Returns the entry id, or `None` if it was skipped
    /// (empty or larger than `max_bytes`). Re-copying identical content moves it to the top.
    pub fn add(&self, clip: NewClip) -> Result<Option<i64>> {
        let reps: Vec<ClipRep> = clip
            .reps
            .into_iter()
            .filter(|r| !r.data.is_empty())
            .collect();
        let size: u64 = reps.iter().map(|r| r.data.len() as u64).sum();
        if reps.is_empty() || size > self.max_bytes {
            return Ok(None);
        }
        let kind = preview::detect_kind(&reps);
        let search = match kind {
            ClipKind::Image => preview::truncate_chars(
                clip.ocr_text.as_deref().unwrap_or("").trim(),
                preview::SEARCH_CHARS,
            ),
            _ => preview::plain_text(kind, &reps),
        };
        if kind != ClipKind::Image && search.trim().is_empty() {
            return Ok(None);
        }
        let hash = self
            .keys
            .content_hash(reps.iter().map(|r| (r.uti.as_str(), r.data.as_slice())));
        let now = (self.clock)();

        let mut conn = self.conn();
        let tx = conn.transaction()?;
        let existing: Option<i64> = tx
            .query_row(
                "SELECT id FROM entry WHERE hash = ?1",
                params![&hash[..]],
                |r| r.get(0),
            )
            .optional()?;
        if let Some(id) = existing {
            tx.execute(
                "UPDATE entry SET created_at = ?1 WHERE id = ?2",
                params![now, id],
            )?;
            tx.commit()?;
            return Ok(Some(id));
        }
        let meta = Meta {
            preview: preview::make_preview(&search),
            search,
            source_app: clip.source_app,
        };
        let meta_ct = self.keys.seal(&meta.encode(), &aad_meta(&hash))?;
        let thumb_ct = match clip.thumbnail.filter(|t| !t.is_empty()) {
            Some(t) => Some(self.keys.seal(&t, &aad_thumb(&hash))?),
            None => None,
        };
        tx.execute(
            "INSERT INTO entry (hash, kind, created_at, size, meta, thumb) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
            params![&hash[..], kind.to_i64(), now, size as i64, meta_ct, thumb_ct],
        )?;
        let id = tx.last_insert_rowid();
        for (idx, r) in reps.iter().enumerate() {
            let pt = zeroize::Zeroizing::new(encode_rep(r));
            let ct = self.keys.seal(&pt, &aad_rep(&hash, idx))?;
            tx.execute(
                "INSERT INTO rep (entry_id, idx, payload) VALUES (?1, ?2, ?3)",
                params![id, idx as i64, ct],
            )?;
        }
        tx.commit()?;
        Ok(Some(id))
    }

    /// Lists pinned and non-expired entries (pinned first, then newest first),
    /// optionally filtered by a search query.
    pub fn list(&self, query: Option<String>, limit: u32) -> Result<Vec<ClipSummary>> {
        let query = query.unwrap_or_default();
        let conn = self.conn();
        let mut stmt = conn.prepare(&format!(
            "SELECT id, hash, kind, created_at, size, meta, thumb IS NOT NULL, pinned
             FROM entry WHERE {LIVE} ORDER BY pinned DESC, created_at DESC, id DESC"
        ))?;
        let rows = stmt.query_map(params![self.cutoff()], |r| {
            Ok((
                r.get::<_, i64>(0)?,
                r.get::<_, Vec<u8>>(1)?,
                r.get::<_, i64>(2)?,
                r.get::<_, i64>(3)?,
                r.get::<_, i64>(4)?,
                r.get::<_, Vec<u8>>(5)?,
                r.get::<_, bool>(6)?,
                r.get::<_, bool>(7)?,
            ))
        })?;
        let mut out = Vec::new();
        for row in rows {
            let (id, hash, kind, created_at, size, meta_ct, has_thumbnail, pinned) = row?;
            let Ok(pt) = self.keys.open(&meta_ct, &aad_meta(&hash)) else {
                continue;
            };
            let meta = Meta::decode(&pt)?;
            if !query.trim().is_empty()
                && !preview::matches(&query, &meta.search, meta.source_app.as_deref())
            {
                continue;
            }
            out.push(ClipSummary {
                id,
                kind: ClipKind::from_i64(kind),
                preview: meta.preview,
                source_app: meta.source_app,
                created_at,
                size: size as u64,
                has_thumbnail,
                pinned,
            });
            if out.len() >= limit as usize {
                break;
            }
        }
        Ok(out)
    }

    /// Returns decrypted representations of an entry for restoring to the pasteboard.
    pub fn get(&self, id: i64) -> Result<Vec<ClipRep>> {
        let conn = self.conn();
        let hash: Vec<u8> = conn
            .query_row(
                &format!("SELECT hash FROM entry WHERE id = ?2 AND {LIVE}"),
                params![self.cutoff(), id],
                |r| r.get(0),
            )
            .optional()?
            .ok_or(CoreError::NotFound)?;
        let mut stmt =
            conn.prepare("SELECT idx, payload FROM rep WHERE entry_id = ?1 ORDER BY idx")?;
        let rows = stmt.query_map(params![id], |r| {
            Ok((r.get::<_, i64>(0)?, r.get::<_, Vec<u8>>(1)?))
        })?;
        let mut reps = Vec::new();
        for row in rows {
            let (idx, ct) = row?;
            let pt = self.keys.open(&ct, &aad_rep(&hash, idx as usize))?;
            reps.push(decode_rep(&pt)?);
        }
        Ok(reps)
    }

    pub fn thumbnail(&self, id: i64) -> Result<Option<Vec<u8>>> {
        let conn = self.conn();
        let row: Option<(Vec<u8>, Option<Vec<u8>>)> = conn
            .query_row(
                "SELECT hash, thumb FROM entry WHERE id = ?1",
                params![id],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .optional()?;
        match row {
            Some((hash, Some(ct))) => Ok(Some(self.keys.open(&ct, &aad_thumb(&hash))?.to_vec())),
            Some((_, None)) => Ok(None),
            None => Err(CoreError::NotFound),
        }
    }

    /// Moves an entry to the top (used after pasting it).
    pub fn touch(&self, id: i64) -> Result<()> {
        let n = self.conn().execute(
            "UPDATE entry SET created_at = ?1 WHERE id = ?2",
            params![(self.clock)(), id],
        )?;
        if n == 0 {
            Err(CoreError::NotFound)
        } else {
            Ok(())
        }
    }

    /// Pins or unpins an entry. Unpinning restarts its 24-hour lifetime so it does not
    /// disappear immediately.
    pub fn set_pinned(&self, id: i64, pinned: bool) -> Result<()> {
        let n = if pinned {
            self.conn()
                .execute("UPDATE entry SET pinned = 1 WHERE id = ?1", params![id])?
        } else {
            self.conn().execute(
                "UPDATE entry SET pinned = 0, created_at = MAX(created_at, ?1) WHERE id = ?2",
                params![(self.clock)(), id],
            )?
        };
        if n == 0 {
            Err(CoreError::NotFound)
        } else {
            Ok(())
        }
    }

    pub fn delete(&self, id: i64) -> Result<()> {
        self.conn()
            .execute("DELETE FROM entry WHERE id = ?1", params![id])?;
        Ok(())
    }

    /// Deletes all entries, or only unpinned ones when `keep_pinned` is set.
    pub fn clear(&self, keep_pinned: bool) -> Result<()> {
        let conn = self.conn();
        if keep_pinned {
            conn.execute("DELETE FROM entry WHERE pinned = 0", [])?;
        } else {
            conn.execute("DELETE FROM entry", [])?;
        }
        conn.execute_batch("VACUUM")?;
        Ok(())
    }

    /// Removes unpinned entries older than the TTL. Returns the number of removed entries.
    pub fn purge_expired(&self) -> Result<u32> {
        let n = self.conn().execute(
            "DELETE FROM entry WHERE pinned = 0 AND created_at <= ?1",
            params![self.cutoff()],
        )?;
        Ok(n as u32)
    }

    pub fn count(&self) -> Result<u32> {
        let n: i64 = self.conn().query_row(
            &format!("SELECT COUNT(*) FROM entry WHERE {LIVE}"),
            params![self.cutoff()],
            |r| r.get(0),
        )?;
        Ok(n as u32)
    }
}

/// Deletes the database files (used when the Keychain key was lost/reset).
#[uniffi::export]
pub fn delete_store_files(path: String) -> Result<()> {
    for suffix in ["", "-journal", "-wal", "-shm"] {
        match std::fs::remove_file(format!("{path}{suffix}")) {
            Ok(()) => {}
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
            Err(e) => return Err(e.into()),
        }
    }
    Ok(())
}
