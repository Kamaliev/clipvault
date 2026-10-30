use crate::model::*;

pub const PREVIEW_CHARS: usize = 300;
pub const SEARCH_CHARS: usize = 16 * 1024;

pub fn detect_kind(reps: &[ClipRep]) -> ClipKind {
    let has = |u: &str| reps.iter().any(|r| r.uti == u);
    if has(UTI_FILE_URL) {
        ClipKind::Files
    } else if has(UTI_RTF) {
        ClipKind::Rtf
    } else if has(UTI_HTML) {
        ClipKind::Html
    } else if has(UTI_TEXT) {
        ClipKind::Text
    } else if reps.iter().any(|r| IMAGE_UTIS.contains(&r.uti.as_str())) {
        ClipKind::Image
    } else {
        ClipKind::Text
    }
}

/// Full plain text used for both preview and search.
pub fn plain_text(kind: ClipKind, reps: &[ClipRep]) -> String {
    let find = |u: &str| reps.iter().find(|r| r.uti == u).map(|r| String::from_utf8_lossy(&r.data));
    let text = match kind {
        ClipKind::Files => reps
            .iter()
            .filter(|r| r.uti == UTI_FILE_URL)
            .map(|r| file_url_to_path(&String::from_utf8_lossy(&r.data)))
            .collect::<Vec<_>>()
            .join("\n"),
        ClipKind::Image => String::new(),
        _ => {
            if let Some(t) = find(UTI_TEXT) {
                t.into_owned()
            } else if let Some(r) = find(UTI_RTF) {
                rtf_to_text(&r)
            } else if let Some(h) = find(UTI_HTML) {
                html_to_text(&h)
            } else {
                String::new()
            }
        }
    };
    truncate_chars(&text, SEARCH_CHARS)
}

pub fn make_preview(text: &str) -> String {
    let collapsed = text.split_whitespace().collect::<Vec<_>>().join(" ");
    truncate_chars(&collapsed, PREVIEW_CHARS)
}

pub fn matches(query: &str, haystack: &str, source_app: Option<&str>) -> bool {
    let hay = haystack.to_lowercase();
    let app = source_app.unwrap_or("").to_lowercase();
    query
        .to_lowercase()
        .split_whitespace()
        .all(|w| hay.contains(w) || app.contains(w))
}

fn truncate_chars(s: &str, n: usize) -> String {
    match s.char_indices().nth(n) {
        Some((i, _)) => s[..i].to_string(),
        None => s.to_string(),
    }
}

pub fn file_url_to_path(url: &str) -> String {
    let p = url.trim().trim_end_matches('\0');
    let p = p.strip_prefix("file://localhost").or_else(|| p.strip_prefix("file://")).unwrap_or(p);
    percent_decode(p)
}

fn percent_decode(s: &str) -> String {
    let b = s.as_bytes();
    let mut out = Vec::with_capacity(b.len());
    let mut i = 0;
    while i < b.len() {
        if b[i] == b'%' && i + 2 < b.len()
            && let Some(v) = std::str::from_utf8(&b[i + 1..i + 3]).ok().and_then(|h| u8::from_str_radix(h, 16).ok()) {
                out.push(v);
                i += 3;
                continue;
            }
        out.push(b[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

/// Minimal RTF → plain text: drops control words, groups like fonttbl/colortbl and `\*` destinations.
pub fn rtf_to_text(rtf: &str) -> String {
    const SKIP_DEST: &[&str] = &[
        "fonttbl", "colortbl", "stylesheet", "info", "pict", "expandedcolortbl", "listtable",
        "listoverridetable", "header", "footer", "generator",
    ];
    let mut out = String::new();
    let chars: Vec<char> = rtf.chars().collect();
    let mut i = 0;
    // stack of "skip" flags per group
    let mut stack: Vec<bool> = vec![false];
    let mut uc_skip = 0usize;
    while i < chars.len() {
        let skipping = *stack.last().unwrap_or(&false);
        match chars[i] {
            '{' => {
                stack.push(skipping);
                i += 1;
            }
            '}' => {
                if stack.len() > 1 {
                    stack.pop();
                }
                i += 1;
            }
            '\\' => {
                i += 1;
                if i >= chars.len() {
                    break;
                }
                let c = chars[i];
                if c.is_ascii_alphabetic() {
                    let start = i;
                    while i < chars.len() && chars[i].is_ascii_alphabetic() {
                        i += 1;
                    }
                    let word: String = chars[start..i].iter().collect();
                    let nstart = i;
                    if i < chars.len() && chars[i] == '-' {
                        i += 1;
                    }
                    while i < chars.len() && chars[i].is_ascii_digit() {
                        i += 1;
                    }
                    let num: Option<i32> = chars[nstart..i].iter().collect::<String>().parse().ok();
                    if i < chars.len() && chars[i] == ' ' {
                        i += 1;
                    }
                    if SKIP_DEST.contains(&word.as_str()) {
                        if let Some(top) = stack.last_mut() {
                            *top = true;
                        }
                        continue;
                    }
                    if skipping {
                        continue;
                    }
                    match word.as_str() {
                        "par" | "line" | "row" => out.push('\n'),
                        "tab" | "cell" => out.push('\t'),
                        "uc" => uc_skip = num.unwrap_or(1).max(0) as usize,
                        "u" => {
                            if let Some(n) = num {
                                let cp = if n < 0 { n + 65536 } else { n } as u32;
                                if let Some(ch) = char::from_u32(cp) {
                                    out.push(ch);
                                }
                                let mut k = 0;
                                while k < uc_skip.max(1) && i < chars.len() {
                                    if chars[i] == '\\' && i + 1 < chars.len() && chars[i + 1] == '\'' {
                                        i += 4;
                                    } else {
                                        i += 1;
                                    }
                                    k += 1;
                                }
                            }
                        }
                        _ => {}
                    }
                } else if c == '\'' {
                    let hex: String = chars.get(i + 1..i + 3).map(|s| s.iter().collect()).unwrap_or_default();
                    i += 3;
                    if !skipping
                        && let Ok(v) = u8::from_str_radix(&hex, 16) {
                            out.push(cp1252(v));
                        }
                } else if c == '*' {
                    if let Some(top) = stack.last_mut() {
                        *top = true;
                    }
                    i += 1;
                } else {
                    if !skipping {
                        match c {
                            '\n' | '\r' => out.push('\n'),
                            '~' => out.push(' '),
                            '{' | '}' | '\\' => out.push(c),
                            _ => {}
                        }
                    }
                    i += 1;
                }
            }
            '\r' | '\n' => i += 1,
            c => {
                if !skipping {
                    out.push(c);
                }
                i += 1;
            }
        }
    }
    out.trim().to_string()
}

fn cp1252(b: u8) -> char {
    const HI: [char; 32] = [
        '€', '\u{81}', '‚', 'ƒ', '„', '…', '†', '‡', 'ˆ', '‰', 'Š', '‹', 'Œ', '\u{8d}', 'Ž', '\u{8f}',
        '\u{90}', '‘', '’', '“', '”', '•', '–', '—', '˜', '™', 'š', '›', 'œ', '\u{9d}', 'ž', 'Ÿ',
    ];
    if (0x80..0xa0).contains(&b) {
        HI[(b - 0x80) as usize]
    } else {
        b as char
    }
}

/// Minimal HTML → plain text: strips tags, script/style bodies, decodes common entities.
pub fn html_to_text(html: &str) -> String {
    let mut out = String::new();
    let lower = html.to_ascii_lowercase();
    let mut i = 0;
    let bytes = html.as_bytes();
    while i < html.len() {
        if bytes[i] == b'<' {
            let end = match html[i..].find('>') {
                Some(e) => i + e + 1,
                None => break,
            };
            let tag = lower[i + 1..end - 1].trim_start_matches('/');
            let name: String = tag.chars().take_while(|c| c.is_ascii_alphanumeric()).collect();
            if !lower[i + 1..].starts_with('/') && (name == "script" || name == "style") {
                let close = format!("</{name}");
                i = lower[end..].find(&close).map(|p| end + p).unwrap_or(html.len());
                continue;
            }
            if matches!(name.as_str(), "br" | "p" | "div" | "li" | "tr" | "h1" | "h2" | "h3" | "h4" | "h5" | "h6") {
                out.push('\n');
            }
            i = end;
        } else if bytes[i] == b'&' {
            let rest = &html[i..];
            let semi = rest.find(';').filter(|&p| p <= 10);
            if let Some(p) = semi
                && let Some(ch) = decode_entity(&rest[1..p]) {
                    out.push(ch);
                    i += p + 1;
                    continue;
                }
            out.push('&');
            i += 1;
        } else {
            let ch = html[i..].chars().next().unwrap();
            out.push(ch);
            i += ch.len_utf8();
        }
    }
    out.trim().to_string()
}

fn decode_entity(e: &str) -> Option<char> {
    Some(match e {
        "amp" => '&',
        "lt" => '<',
        "gt" => '>',
        "quot" => '"',
        "apos" => '\'',
        "nbsp" => ' ',
        _ => {
            let n = e.strip_prefix('#')?;
            let v = match n.strip_prefix(['x', 'X']) {
                Some(h) => u32::from_str_radix(h, 16).ok()?,
                None => n.parse().ok()?,
            };
            char::from_u32(v)?
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rep(uti: &str, data: &[u8]) -> ClipRep {
        ClipRep { item: 0, uti: uti.into(), data: data.to_vec() }
    }

    #[test]
    fn kind_priority() {
        assert_eq!(detect_kind(&[rep(UTI_TEXT, b"a"), rep("public.png", b"x")]), ClipKind::Text);
        assert_eq!(detect_kind(&[rep("public.tiff", b"x")]), ClipKind::Image);
        assert_eq!(detect_kind(&[rep(UTI_HTML, b"a"), rep(UTI_TEXT, b"a")]), ClipKind::Html);
        assert_eq!(detect_kind(&[rep(UTI_FILE_URL, b"file:///a"), rep(UTI_TEXT, b"a")]), ClipKind::Files);
    }

    #[test]
    fn rtf_strips_formatting() {
        let rtf = r"{\rtf1\ansi{\fonttbl\f0\fswiss Helvetica;}{\colortbl;\red255\green0\blue0;}{\*\expandedcolortbl;;}\f0\b Hello\b0  World\par caf\'e9 \u1055?\u1088?}";
        assert_eq!(rtf_to_text(rtf), "Hello World\ncafé Пр");
    }

    #[test]
    fn html_strips_tags_and_entities() {
        let h = "<html><head><style>p{color:red}</style></head><body><p>Tom &amp; Jerry</p>x&lt;y&#33;<script>alert(1)</script></body></html>";
        assert_eq!(html_to_text(h), "Tom & Jerry\nx<y!");
    }

    #[test]
    fn file_urls_decoded() {
        let reps = [rep(UTI_FILE_URL, b"file:///Users/me/My%20File.txt"), rep(UTI_FILE_URL, b"file:///tmp/%D0%AF")];
        assert_eq!(plain_text(ClipKind::Files, &reps), "/Users/me/My File.txt\n/tmp/Я");
    }

    #[test]
    fn preview_collapses_and_truncates() {
        assert_eq!(make_preview("  a\n\n b\tc "), "a b c");
        assert_eq!(make_preview(&"я".repeat(1000)).chars().count(), PREVIEW_CHARS);
    }

    #[test]
    fn search_all_words_case_insensitive() {
        assert!(matches("HELLO wor", "Hello World", None));
        assert!(matches("привет safari", "Привет мир", Some("Safari")));
        assert!(!matches("hello xyz", "Hello World", None));
        assert!(matches("", "anything", None));
    }
}
