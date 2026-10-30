use std::sync::atomic::{AtomicI64, Ordering};
use std::sync::Arc;

use clipvault_core::{delete_store_files, ClipKind, ClipRep, CoreError, NewClip, Store};

const KEY: [u8; 32] = [7u8; 32];
const DAY: u64 = 24 * 3600;

struct Env {
    _dir: tempfile::TempDir,
    path: String,
    now: Arc<AtomicI64>,
}

impl Env {
    fn new() -> Self {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("sub/history.db").to_str().unwrap().to_string();
        Self { _dir: dir, path, now: Arc::new(AtomicI64::new(1_000_000)) }
    }

    fn open_with(&self, key: &[u8], max: u64) -> Result<Store, CoreError> {
        let now = self.now.clone();
        Store::open_with_clock(&self.path, key, DAY, max, Box::new(move || now.load(Ordering::SeqCst)))
    }

    fn open(&self) -> Store {
        self.open_with(&KEY, 1024).unwrap()
    }

    fn advance(&self, secs: i64) {
        self.now.fetch_add(secs, Ordering::SeqCst);
    }
}

fn text(s: &str) -> NewClip {
    NewClip {
        reps: vec![ClipRep { item: 0, uti: "public.utf8-plain-text".into(), data: s.as_bytes().to_vec() }],
        source_app: Some("Notes".into()),
        thumbnail: None,
    }
}

#[test]
fn add_list_get_roundtrip() {
    let env = Env::new();
    let s = env.open();
    let clip = NewClip {
        reps: vec![
            ClipRep { item: 0, uti: "public.rtf".into(), data: br"{\rtf1 Hi \b there}".to_vec() },
            ClipRep { item: 0, uti: "public.utf8-plain-text".into(), data: b"Hi there".to_vec() },
        ],
        source_app: Some("TextEdit".into()),
        thumbnail: None,
    };
    let id = s.add(clip.clone()).unwrap().unwrap();
    env.advance(1);
    let id2 = s.add(text("second")).unwrap().unwrap();

    let list = s.list(None, 10).unwrap();
    assert_eq!(list.iter().map(|e| e.id).collect::<Vec<_>>(), vec![id2, id]);
    assert_eq!(list[1].kind, ClipKind::Rtf);
    assert_eq!(list[1].preview, "Hi there");
    assert_eq!(list[1].source_app.as_deref(), Some("TextEdit"));
    assert_eq!(s.get(id).unwrap(), clip.reps);
}

#[test]
fn content_is_encrypted_on_disk() {
    let env = Env::new();
    let s = env.open();
    s.add(text("TOP-SECRET-MARKER")).unwrap();
    drop(s);
    let raw = std::fs::read(&env.path).unwrap();
    assert!(!raw.windows(17).any(|w| w == b"TOP-SECRET-MARKER"));
    assert!(!raw.windows(5).any(|w| w == b"Notes"));
}

#[test]
fn dedup_moves_to_top() {
    let env = Env::new();
    let s = env.open();
    let a = s.add(text("a")).unwrap().unwrap();
    env.advance(1);
    s.add(text("b")).unwrap();
    env.advance(1);
    assert_eq!(s.add(text("a")).unwrap(), Some(a));
    let list = s.list(None, 10).unwrap();
    assert_eq!(list.len(), 2);
    assert_eq!(list[0].id, a);
}

#[test]
fn skips_empty_and_oversized() {
    let env = Env::new();
    let s = env.open();
    assert_eq!(s.add(text("   ")).unwrap(), None);
    assert_eq!(s.add(NewClip { reps: vec![], source_app: None, thumbnail: None }).unwrap(), None);
    assert_eq!(s.add(text(&"x".repeat(2000))).unwrap(), None);
    assert_eq!(s.count().unwrap(), 0);
}

#[test]
fn entries_expire_after_ttl() {
    let env = Env::new();
    let s = env.open();
    let old = s.add(text("old")).unwrap().unwrap();
    env.advance(DAY as i64 - 10);
    s.add(text("new")).unwrap();
    env.advance(20);
    // hidden before purge runs
    assert_eq!(s.list(None, 10).unwrap().len(), 1);
    assert!(matches!(s.get(old), Err(CoreError::NotFound)));
    assert_eq!(s.purge_expired().unwrap(), 1);
    assert_eq!(s.count().unwrap(), 1);
}

#[test]
fn search_filters() {
    let env = Env::new();
    let s = env.open();
    s.add(text("Hello world")).unwrap();
    s.add(text("Привет мир")).unwrap();
    let r = s.list(Some("ПРИВЕТ".into()), 10).unwrap();
    assert_eq!(r.len(), 1);
    assert_eq!(r[0].preview, "Привет мир");
    assert_eq!(s.list(Some("notes".into()), 10).unwrap().len(), 2);
    assert_eq!(s.list(Some("nothing".into()), 10).unwrap().len(), 0);
    assert_eq!(s.list(None, 1).unwrap().len(), 1);
}

#[test]
fn image_thumbnail_delete_clear_touch() {
    let env = Env::new();
    let s = env.open();
    let img = s
        .add(NewClip {
            reps: vec![ClipRep { item: 0, uti: "public.png".into(), data: vec![1, 2, 3] }],
            source_app: None,
            thumbnail: Some(vec![9, 9]),
        })
        .unwrap()
        .unwrap();
    env.advance(1);
    let t = s.add(text("t")).unwrap().unwrap();
    let list = s.list(None, 10).unwrap();
    assert_eq!(list[1].kind, ClipKind::Image);
    assert!(list[1].has_thumbnail);
    assert_eq!(s.thumbnail(img).unwrap(), Some(vec![9, 9]));
    assert_eq!(s.thumbnail(t).unwrap(), None);

    env.advance(1);
    s.touch(img).unwrap();
    assert_eq!(s.list(None, 10).unwrap()[0].id, img);
    s.delete(img).unwrap();
    assert_eq!(s.count().unwrap(), 1);
    s.clear().unwrap();
    assert_eq!(s.count().unwrap(), 0);
}

#[test]
fn wrong_key_is_detected_and_store_can_be_reset() {
    let env = Env::new();
    env.open().add(text("x")).unwrap();
    assert!(matches!(env.open_with(&[8u8; 32], 1024), Err(CoreError::KeyMismatch)));
    assert!(matches!(env.open_with(&[1u8; 3], 1024), Err(CoreError::InvalidKey(_))));
    delete_store_files(env.path.clone()).unwrap();
    let s = env.open_with(&[8u8; 32], 1024).unwrap();
    assert_eq!(s.count().unwrap(), 0);
    // persistence with the right key
    s.add(text("persist")).unwrap();
    drop(s);
    assert_eq!(env.open_with(&[8u8; 32], 1024).unwrap().count().unwrap(), 1);
}

#[test]
fn multiple_file_items_roundtrip() {
    let env = Env::new();
    let s = env.open();
    let reps = vec![
        ClipRep { item: 0, uti: "public.file-url".into(), data: b"file:///a/b%20c.txt".to_vec() },
        ClipRep { item: 1, uti: "public.file-url".into(), data: b"file:///d.png".to_vec() },
    ];
    let id = s.add(NewClip { reps: reps.clone(), source_app: Some("Finder".into()), thumbnail: None }).unwrap().unwrap();
    let e = &s.list(None, 10).unwrap()[0];
    assert_eq!(e.kind, ClipKind::Files);
    assert_eq!(e.preview, "/a/b c.txt /d.png");
    assert_eq!(s.get(id).unwrap(), reps);
}

#[test]
fn in_memory_store_and_private_file_permissions() {
    use std::os::unix::fs::PermissionsExt;
    let s = Store::open_with_clock(":memory:", &KEY, DAY, 1024, Box::new(|| 5)).unwrap();
    s.add(text("m")).unwrap();
    assert_eq!(s.count().unwrap(), 1);

    let env = Env::new();
    drop(env.open());
    let mode = std::fs::metadata(&env.path).unwrap().permissions().mode() & 0o777;
    assert_eq!(mode, 0o600);
}
