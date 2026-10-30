//! Detection and masking of passwords, tokens and keys in clipboard text.
//!
//! Masking only affects what is shown; stored representations are never changed.

use std::ops::Range;

pub const MASK: &str = "••••••";

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Span {
    pub range: Range<usize>,
    /// Bytes at the start of the span that are a well-known, non-secret prefix (`ghp_`, `sk-ant-`).
    pub prefix: usize,
    /// Show a few edge characters so the user can tell secrets apart.
    pub reveal: bool,
}

/// Finds secrets in `text`; spans are sorted and do not overlap.
pub fn find(text: &str) -> Vec<Span> {
    let mut spans = Vec::new();
    pem_keys(text, &mut spans);
    known_tokens(text, &mut spans);
    auth_headers(text, &mut spans);
    url_passwords(text, &mut spans);
    key_values(text, &mut spans);
    whole_record(text, &mut spans);
    merge(spans)
}

/// Masks the detected secrets. With `whole`, text without detected secrets is masked entirely
/// (used when the user marked a record as secret).
pub fn mask_text(text: &str, whole: bool) -> String {
    let spans = find(text);
    if spans.is_empty() {
        return if whole {
            mask_whole(text)
        } else {
            text.to_string()
        };
    }
    let mut out = String::with_capacity(text.len());
    let mut last = 0;
    for s in &spans {
        out.push_str(&text[last..s.range.start]);
        out.push_str(&mask_span(&text[s.range.clone()], s.prefix, s.reveal));
        last = s.range.end;
    }
    out.push_str(&text[last..]);
    out
}

pub fn mask_whole(text: &str) -> String {
    let t = text.trim();
    if t.is_empty() {
        return text.to_string();
    }
    mask_span(t, 0, true)
}

/// Masks `text` for display. `whole` masks the entire text if no secret is detected in it.
#[uniffi::export]
pub fn mask_secrets(text: String, whole: bool) -> String {
    mask_text(&text, whole)
}

/// Keeps the prefix and at most an eighth of the secret at each edge (no more than 4 chars);
/// the mask has a fixed width so the length is not revealed.
fn mask_span(s: &str, prefix: usize, reveal: bool) -> String {
    let (pre, rest) = s.split_at(prefix);
    let chars: Vec<char> = rest.chars().collect();
    let k = if reveal { (chars.len() / 8).min(4) } else { 0 };
    let head = if prefix > 0 { 0 } else { k };
    let mut out = String::from(pre);
    out.extend(&chars[..head]);
    out.push_str(MASK);
    out.extend(&chars[chars.len() - k..]);
    out
}

fn merge(mut spans: Vec<Span>) -> Vec<Span> {
    spans.retain(|s| !s.range.is_empty());
    spans.sort_by_key(|s| (s.range.start, std::cmp::Reverse(s.range.end)));
    let mut out: Vec<Span> = Vec::with_capacity(spans.len());
    for s in spans {
        match out.last_mut() {
            Some(last) if s.range.start < last.range.end => {
                last.range.end = last.range.end.max(s.range.end);
            }
            _ => out.push(s),
        }
    }
    out
}

fn push(spans: &mut Vec<Span>, range: Range<usize>, prefix: usize, reveal: bool) {
    spans.push(Span {
        range,
        prefix,
        reveal,
    });
}

/// `-----BEGIN … PRIVATE KEY-----` blocks: the body is hidden completely, the armor stays.
fn pem_keys(text: &str, spans: &mut Vec<Span>) {
    const BEGIN: &str = "-----BEGIN ";
    let mut from = 0;
    while let Some(p) = text[from..].find(BEGIN) {
        let label_start = from + p + BEGIN.len();
        let Some(e) = text[label_start..].find("-----") else {
            return;
        };
        let header_end = label_start + e + 5;
        from = header_end;
        if !text[label_start..label_start + e].contains("PRIVATE KEY") {
            continue;
        }
        let body_end = text[header_end..]
            .find("-----END ")
            .map_or(text.len(), |p| header_end + p);
        let body = &text[header_end..body_end];
        let start = header_end + (body.len() - body.trim_start().len());
        let end = header_end + body.trim_end().len();
        if start < end {
            push(spans, start..end, 0, false);
        }
        from = body_end;
    }
}

fn is_token_char(c: char) -> bool {
    c.is_ascii_alphanumeric() || matches!(c, '_' | '-' | '.')
}

/// Maximal runs of characters accepted by `pred`, as byte ranges.
fn runs(text: &str, pred: impl Fn(char) -> bool) -> Vec<Range<usize>> {
    let mut out = Vec::new();
    let mut start = None;
    for (i, c) in text.char_indices() {
        match (pred(c), start) {
            (true, None) => start = Some(i),
            (false, Some(s)) => {
                out.push(s..i);
                start = None;
            }
            _ => {}
        }
    }
    if let Some(s) = start {
        out.push(s..text.len());
    }
    out
}

/// Prefix and minimal length of the random part for well-known token formats.
const PREFIXED: &[(&str, usize)] = &[
    ("github_pat_", 30),
    ("ghp_", 30),
    ("gho_", 30),
    ("ghu_", 30),
    ("ghs_", 30),
    ("ghr_", 30),
    ("glpat-", 20),
    ("sk-ant-", 30),
    ("sk-proj-", 30),
    ("sk-", 20),
    ("sk_live_", 16),
    ("sk_test_", 16),
    ("rk_live_", 16),
    ("rk_test_", 16),
    ("xoxb-", 10),
    ("xoxp-", 10),
    ("xoxa-", 10),
    ("xoxr-", 10),
    ("xoxs-", 10),
    ("xapp-", 10),
    ("AIza", 30),
    ("npm_", 30),
    ("pypi-", 30),
    ("hf_", 30),
    ("dop_v1_", 30),
    ("shpat_", 20),
    ("SG.", 30),
];

/// Returns the length of the non-secret prefix if `t` is a token of a well-known format.
fn known_token(t: &str) -> Option<usize> {
    for &(prefix, min) in PREFIXED {
        if let Some(rest) = t.strip_prefix(prefix) {
            return (rest.len() >= min && rest.bytes().any(|b| b.is_ascii_digit()))
                .then_some(prefix.len());
        }
    }
    for prefix in ["AKIA", "ASIA"] {
        if let Some(rest) = t.strip_prefix(prefix)
            && rest.len() == 16
            && rest
                .bytes()
                .all(|b| b.is_ascii_uppercase() || b.is_ascii_digit())
        {
            return Some(prefix.len());
        }
    }
    let parts: Vec<&str> = t.split('.').collect();
    if t.starts_with("eyJ")
        && parts.len() == 3
        && parts.iter().all(|p| {
            p.len() >= 10
                && p.bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
        })
    {
        return Some(0);
    }
    None
}

fn known_tokens(text: &str, spans: &mut Vec<Span>) {
    for r in runs(text, is_token_char) {
        let t = text[r.clone()].trim_end_matches('.');
        if let Some(prefix) = known_token(t) {
            push(spans, r.start..r.start + t.len(), prefix, true);
        }
    }
}

fn is_quote(c: char) -> bool {
    matches!(c, '"' | '\'' | '`')
}

/// Credentials after `Bearer` / `Basic` (e.g. in an `Authorization:` header or a curl command).
fn auth_headers(text: &str, spans: &mut Vec<Span>) {
    let lower = text.to_ascii_lowercase();
    for scheme in ["bearer ", "basic "] {
        let mut from = 0;
        while let Some(p) = lower[from..].find(scheme) {
            let at = from + p;
            from = at + scheme.len();
            if text[..at]
                .chars()
                .next_back()
                .is_some_and(|c| c.is_alphanumeric())
            {
                continue;
            }
            let rest = &text[from..];
            let start = from + (rest.len() - rest.trim_start_matches([' ', '\t']).len());
            let end = text[start..]
                .find(|c: char| c.is_whitespace() || is_quote(c) || matches!(c, ',' | ';'))
                .map_or(text.len(), |e| start + e);
            let cred = &text[start..end];
            // Credentials are base64/token-like; this skips prose like "basic understanding".
            if cred.len() >= 8
                && cred.bytes().any(|b| b.is_ascii_digit())
                && cred
                    .bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b"+/=_-.~".contains(&b))
            {
                push(spans, start..end, 0, true);
            }
        }
    }
}

/// `scheme://user:password@host`: only the password is hidden.
fn url_passwords(text: &str, spans: &mut Vec<Span>) {
    let mut from = 0;
    while let Some(p) = text[from..].find("://") {
        let start = from + p + 3;
        from = start;
        let end = text[start..]
            .find(|c: char| {
                c.is_whitespace() || is_quote(c) || matches!(c, '/' | '?' | '#' | '<' | '>')
            })
            .map_or(text.len(), |e| start + e);
        let authority = &text[start..end];
        if let Some(at) = authority.rfind('@')
            && let Some(colon) = authority[..at].find(':')
            && colon + 1 < at
        {
            push(spans, start + colon + 1..start + at, 0, true);
        }
    }
}

/// Key names whose value is secret (compared per word: `db_password`, `apiKey`, `X-Auth-Token`).
const SECRET_WORDS: &[&str] = &[
    "password",
    "passwd",
    "pwd",
    "pass",
    "passphrase",
    "passcode",
    "secret",
    "token",
    "credential",
    "credentials",
    "authorization",
    "пароль",
    "токен",
    "секрет",
];
/// Words that turn a secret-looking key into metadata (`token_url`, `password_min_length`).
const NON_SECRET_WORDS: &[&str] = &[
    "count",
    "limit",
    "len",
    "length",
    "size",
    "type",
    "url",
    "uri",
    "endpoint",
    "file",
    "path",
    "name",
    "id",
    "expiry",
    "expires",
    "expiration",
    "ttl",
    "max",
    "min",
    "num",
    "index",
    "kind",
    "header",
    "field",
    "timeout",
    "policy",
    "enabled",
    "required",
    "hint",
    "reset",
    "prompt",
    "label",
    "placeholder",
    "format",
    "pattern",
    "regex",
    "validator",
    "strength",
    "manager",
    "rotation",
    "store",
    "provider",
    "usage",
    "budget",
];
const KEY_QUALIFIERS: &[&str] = &[
    "api",
    "access",
    "private",
    "secret",
    "client",
    "auth",
    "signing",
    "encryption",
    "master",
    "license",
];

/// Splits `db_password`, `apiKey`, `X-API-KEY` into lowercase words.
fn words(ident: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut cur = String::new();
    let mut prev_lower = false;
    for c in ident.chars() {
        if !c.is_alphanumeric() {
            if !cur.is_empty() {
                out.push(std::mem::take(&mut cur));
            }
            prev_lower = false;
            continue;
        }
        if c.is_uppercase() && prev_lower && !cur.is_empty() {
            out.push(std::mem::take(&mut cur));
        }
        prev_lower = c.is_lowercase() || c.is_ascii_digit();
        cur.extend(c.to_lowercase());
    }
    if !cur.is_empty() {
        out.push(cur);
    }
    out
}

fn is_secret_key(ident: &str) -> bool {
    let w = words(ident);
    if w.iter().any(|x| NON_SECRET_WORDS.contains(&x.as_str())) {
        return false;
    }
    let joined = w.concat();
    w.iter().any(|x| SECRET_WORDS.contains(&x.as_str()))
        || w.windows(2)
            .any(|p| p[1] == "key" && KEY_QUALIFIERS.contains(&p[0].as_str()))
        || matches!(
            joined.as_str(),
            "apikey" | "privatekey" | "accesskey" | "secretkey" | "authkey"
        )
}

/// Values that are references, types or flags rather than secrets.
fn is_placeholder(v: &str, quoted: bool) -> bool {
    let lower = v.to_lowercase();
    if v.is_empty()
        || v.starts_with(['$', '<', '{', '%', '[', '('])
        || v.chars()
            .all(|c| c == '*' || c == 'x' || c == 'X' || c == '•')
        || matches!(
            lower.as_str(),
            "null"
                | "none"
                | "nil"
                | "true"
                | "false"
                | "undefined"
                | "yes"
                | "no"
                | "on"
                | "off"
                | "required"
                | "optional"
                | "string"
                | "str"
                | "&str"
                | "bool"
                | "boolean"
                | "int"
                | "number"
                | "any"
                | "secret"
                | "password"
                | "token"
                | "redacted"
                | "changeme"
                // `Authorization: Bearer …` is handled by `auth_headers`.
                | "bearer"
                | "basic"
                | "digest"
                // Code: `token = await getToken()`, `password = input(...)`.
                | "await"
                | "new"
                | "yield"
                | "self"
                | "this"
                | "input"
                | "getpass"
        )
    {
        return true;
    }
    // Unquoted code expressions: calls, generics, `config.password`, `os.environ`.
    !quoted
        && (v.contains(['(', '<'])
            || (v.contains('.')
                && v.split('.').all(|p| {
                    !p.is_empty() && p.chars().all(|c| c.is_ascii_alphabetic() || c == '_')
                })))
}

/// `password=…`, `"token": "…"`, `API_KEY: …`, `?access_token=…&`.
fn key_values(text: &str, spans: &mut Vec<Span>) {
    let ident = |c: char| c.is_alphanumeric() || matches!(c, '_' | '-' | '.');
    let mut offset = 0;
    for line in text.split_inclusive('\n') {
        let base = offset;
        offset += line.len();
        for r in runs(line, ident) {
            if !is_secret_key(&line[r.clone()]) {
                continue;
            }
            let mut rest = &line[r.end..];
            rest = rest.strip_prefix(['"', '\'']).unwrap_or(rest);
            rest = rest.trim_start_matches([' ', '\t']);
            let Some(after) = [":=", "=>", "=", ":"]
                .iter()
                .find_map(|sep| rest.strip_prefix(sep))
            else {
                continue;
            };
            let value = after.trim_start_matches([' ', '\t']);
            let start = base + line.len() - value.len();
            let (vs, ve, quoted) = match value.chars().next() {
                Some(q) if is_quote(q) => {
                    let inner = &value[1..];
                    let len = inner.find(q).unwrap_or(inner.trim_end().len());
                    (start + 1, start + 1 + len, true)
                }
                _ => {
                    let len = value
                        .find(|c: char| {
                            c.is_whitespace() || matches!(c, ',' | ';' | '&' | ')' | '}' | ']')
                        })
                        .unwrap_or(value.len());
                    let v = value[..len].trim_end_matches(['"', '\'']);
                    (start, start + v.len(), false)
                }
            };
            if !is_placeholder(&text[vs..ve], quoted) {
                push(spans, vs..ve, 0, true);
            }
        }
    }
}

fn is_uuid(t: &str) -> bool {
    let parts: Vec<&str> = t.split('-').collect();
    parts.len() == 5
        && parts.iter().map(|p| p.len()).eq([8, 4, 4, 4, 12])
        && parts
            .iter()
            .all(|p| p.bytes().all(|b| b.is_ascii_hexdigit()))
}

/// `bob@example.com`, also with a port (`git@host:22`).
fn is_email(t: &str) -> bool {
    let Some((user, domain)) = t.split_once('@') else {
        return false;
    };
    !user.is_empty()
        && domain.contains('.')
        && !domain.starts_with('.')
        && domain
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b".-:".contains(&b))
}

/// `report.pdf`, `My_File2.txt`.
fn is_file_name(t: &str) -> bool {
    t.rsplit_once('.').is_some_and(|(name, ext)| {
        !name.is_empty()
            && (1..=5).contains(&ext.len())
            && ext.bytes().all(|b| b.is_ascii_alphabetic())
            && name
                .chars()
                .all(|c| c.is_alphanumeric() || matches!(c, '_' | '-' | '.' | ' '))
    })
}

#[derive(Default)]
struct Shape {
    lower: usize,
    upper: usize,
    digit: usize,
    /// Non-alphanumeric characters other than the separators `-_.`.
    symbol: usize,
    /// Adjacent pairs that switch between lowercase, uppercase and digits (`aK9x` → 3).
    switches: usize,
}

fn shape(t: &str) -> Shape {
    let mut s = Shape::default();
    let mut prev = None;
    for c in t.chars() {
        let class = if c.is_ascii_digit() {
            s.digit += 1;
            Some(0)
        } else if c.is_lowercase() {
            s.lower += 1;
            Some(1)
        } else if c.is_uppercase() {
            s.upper += 1;
            Some(2)
        } else {
            if !matches!(c, '-' | '_' | '.') {
                s.symbol += 1;
            }
            None
        };
        if let (Some(a), Some(b)) = (prev, class)
            && a != b
        {
            s.switches += 1;
        }
        prev = class;
    }
    s
}

fn entropy(t: &str) -> f64 {
    let mut counts = std::collections::HashMap::new();
    for c in t.chars() {
        *counts.entry(c).or_insert(0usize) += 1;
    }
    let n = t.chars().count() as f64;
    counts
        .values()
        .map(|&k| {
            let p = k as f64 / n;
            -p * p.log2()
        })
        .sum()
}

/// A typed password: 8–64 chars mixing at least three of lower/upper/digit/symbol, with a symbol
/// or frequent case/digit switches, so identifiers like `getUser2` or `base64Encode` are not hit.
fn looks_like_password(t: &str) -> bool {
    let n = t.len();
    if !t.is_ascii() || !(8..=64).contains(&n) || t.contains('/') || is_email(t) || is_file_name(t)
    {
        return false;
    }
    let s = shape(t);
    let classes = [s.lower, s.upper, s.digit, s.symbol]
        .iter()
        .filter(|&&k| k > 0)
        .count();
    // Without a symbol, `ProjectX2024Final` (4 switches in 17 chars) is a name, `xK8mQ2pL9nR4` is not.
    classes >= 3
        && s.lower + s.upper >= 2
        && (s.symbol > 0 || (s.switches >= 4 && s.switches * 3 >= n))
}

/// A generated token: long, base64/hex-like, high entropy and frequent case/digit switches.
fn looks_like_token(t: &str) -> bool {
    let n = t.chars().count();
    if !(20..=512).contains(&n)
        || !t
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"+/=_-.~".contains(&b))
        || t.starts_with(['/', '~', '.'])
        || is_uuid(t)
        || (n <= 40 && t.bytes().all(|b| b.is_ascii_hexdigit()))
    {
        return false;
    }
    let s = shape(t);
    s.digit > 0 && s.lower + s.upper > 0 && s.switches * 5 >= n && entropy(t) >= 3.5
}

/// A record that is nothing but one password or token.
fn whole_record(text: &str, spans: &mut Vec<Span>) {
    let t = text.trim();
    if t.is_empty() || t.contains(char::is_whitespace) || t.contains("://") {
        return;
    }
    // `name=value` is left to `key_values`, which knows which names are secret.
    if let Some((name, _)) = t.split_once('=')
        && name.len() >= 2
        && name.chars().all(|c| c.is_alphabetic() || c == '_')
    {
        return;
    }
    if looks_like_password(t) || looks_like_token(t) {
        let start = text.len() - text.trim_start().len();
        push(spans, start..start + t.len(), 0, true);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn m(t: &str) -> String {
        mask_text(t, false)
    }

    fn untouched(t: &str) {
        assert_eq!(m(t), t, "unexpectedly masked: {t}");
    }

    #[test]
    fn known_tokens_keep_prefix_and_tail() {
        let gh = "ghp_aB3dE5fG7hI9jK1lM3nO5pQ7rS9tU1vW3xY5";
        assert_eq!(m(gh), "ghp_••••••3xY5");
        assert_eq!(
            m(&format!("export GITHUB_TOKEN={gh}\necho ok")),
            "export GITHUB_TOKEN=ghp_••••••3xY5\necho ok"
        );
        assert_eq!(m("key AKIAIOSFODNN7EXAMPLE."), "key AKIA••••••LE.");
        let ant = "sk-ant-api03-Zx9Yw8Vu7Ts6Rq5Po4Nm3Lk2Ji1Hg0Fe";
        assert!(m(ant).starts_with("sk-ant-••••••"));
        let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U";
        assert_eq!(m(&format!("jwt {jwt}")), "jwt eyJh••••••sR8U");
    }

    #[test]
    fn pem_body_is_hidden() {
        let pem = "-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEA\nAAAABG5vbmU=\n-----END OPENSSH PRIVATE KEY-----\n";
        assert_eq!(
            m(pem),
            "-----BEGIN OPENSSH PRIVATE KEY-----\n••••••\n-----END OPENSSH PRIVATE KEY-----\n"
        );
        untouched("-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----");
    }

    #[test]
    fn key_value_pairs() {
        assert_eq!(m("DB_PASSWORD=hunter2"), "DB_PASSWORD=••••••");
        assert_eq!(
            m(r#"{"user": "bob", "password": "correct horse battery staple"}"#),
            r#"{"user": "bob", "password": "cor••••••ple"}"#
        );
        assert_eq!(m("apiKey: 'abcdef0123456789'"), "apiKey: 'ab••••••89'");
        assert_eq!(
            m("https://x.io/cb?access_token=abc123def456&state=1"),
            "https://x.io/cb?access_token=a••••••6&state=1"
        );
        assert_eq!(m("Пароль: qwerty12"), "Пароль: q••••••2");
        assert_eq!(
            m("client_secret = s3cr3t-value"),
            "client_secret = s••••••e"
        );
    }

    #[test]
    fn key_value_ignores_code_and_metadata() {
        untouched("max_tokens = 4096");
        untouched("token_url = https://auth.example.com/token");
        untouched("password: String,");
        untouched("let token = lexer.next();");
        untouched("password = os.environ");
        untouched("PASSWORD=$DB_PASSWORD");
        untouched("password: ********");
        untouched("passwordless: true");
        untouched("Forgot your password?");
    }

    #[test]
    fn urls_and_auth_headers() {
        assert_eq!(
            m("postgres://admin:Sup3rS3cret@db.local:5432/app"),
            "postgres://admin:S••••••t@db.local:5432/app"
        );
        assert_eq!(
            m("curl -H 'Authorization: Bearer abcdefgh12345678'"),
            "curl -H 'Authorization: Bearer ab••••••78'"
        );
        untouched("https://github.com/Kamaliev/clipvault");
        untouched("mailto:bob@example.com");
    }

    #[test]
    fn whole_record_passwords_and_tokens() {
        assert_eq!(m("P@ssw0rd!"), "P••••••!");
        assert_eq!(m("  xK8mQ2pL9nR4  "), "  x••••••4  ");
        assert_eq!(m("Tr0ub4dor&3"), "T••••••3");
        assert_eq!(m("Zm9vYmFyYmF6cXV4MTIzNDU2Nzg5MA"), "Zm9••••••5MA");
    }

    #[test]
    fn ordinary_text_is_untouched() {
        for t in [
            "hello world",
            "getUser2",
            "base64Encode",
            "HTTP2Server",
            "feature-123-fix",
            "My_File2.txt",
            "bob@example.com",
            "2026-10-30T23:26:39+05:00",
            "9877385a1b2c3d4e5f60718293a4b5c6d7e8f901",
            "550e8400-e29b-41d4-a716-446655440000",
            "/Users/me/Projects/clipvault/core/src/secrets.rs",
            "#ff00aa",
            "test_user_2026_report_v3",
            "Привет, как дела?",
            "fn main() { println!(\"hi\"); }",
            "com.kamaliev.clipvault.toggle",
            "const token = await getToken();",
            "ProjectX2024Final",
            "git@github.com:22",
            "НДС20%Итого",
            "Release_v2.3.1-rc4",
            "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl me@host",
            "https://www.google.com/search?q=rust&sourceid=chrome&ie=UTF-8",
        ] {
            untouched(t);
        }
    }

    #[test]
    fn short_secrets_are_hidden_completely() {
        assert_eq!(m("pin=1234"), "pin=1234");
        assert_eq!(m("password=1234"), "password=••••••");
    }

    #[test]
    fn whole_mask_for_marked_records() {
        assert_eq!(mask_text("just some words here", true), "ju••••••re");
        assert_eq!(mask_text("abc", true), "••••••");
        assert_eq!(mask_text("abc", false), "abc");
    }

    #[test]
    fn words_split() {
        assert_eq!(words("X-API-KEY"), ["x", "api", "key"]);
        assert_eq!(words("dbPassword"), ["db", "password"]);
        assert_eq!(
            words("AWS_SECRET_ACCESS_KEY"),
            ["aws", "secret", "access", "key"]
        );
    }
}
