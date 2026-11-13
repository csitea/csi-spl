//! The few Python `str` semantics the guard depends on, so a verdict reads
//! the same text the same way `force-push-guard.inc.sh` does.

/// Python `str.isspace()` / `re` `\s` on a `str`: Unicode White_Space plus
/// the four information separators U+001C..U+001F, which Python counts.
pub fn is_space(c: char) -> bool {
    c.is_whitespace() || ('\u{1c}'..='\u{1f}').contains(&c)
}

/// Python `re` `\w` on a `str` (Unicode): letters, digits and underscore.
pub fn is_word(c: char) -> bool {
    c == '_' || c.is_alphanumeric()
}

/// Python `str.isdigit()` on a whole token (non-empty, every char a digit).
pub fn is_digits(s: &str) -> bool {
    !s.is_empty()
        && s.chars()
            .all(|c| c.is_ascii_digit() || (!c.is_ascii() && c.is_numeric()))
}

/// Python `str.strip()` with no argument.
pub fn strip(s: &str) -> &str {
    s.trim_matches(is_space)
}

/// Python `str.rsplit("/", 1)[-1]`: the text after the last slash.
pub fn base(s: &str) -> &str {
    s.rsplit('/').next().unwrap_or(s)
}

/// Python `str.partition("=")`: (name, found, value).
pub fn partition_eq(s: &str) -> (&str, bool, &str) {
    match s.split_once('=') {
        Some((a, b)) => (a, true, b),
        None => (s, false, ""),
    }
}

/// `^[A-Za-z_][A-Za-z0-9_]*=`: a shell variable assignment word.
pub fn is_assignment(t: &str) -> bool {
    let Some((name, _)) = t.split_once('=') else {
        return false;
    };
    let mut cs = name.chars();
    match cs.next() {
        Some(c) if c.is_ascii_alphabetic() || c == '_' => {}
        _ => return false,
    }
    cs.all(|c| c.is_ascii_alphanumeric() || c == '_')
}

/// `^GIT_CONFIG_KEY_[0-9]+$`.
pub fn is_git_config_key(name: &str) -> bool {
    name.strip_prefix("GIT_CONFIG_KEY_")
        .is_some_and(|d| !d.is_empty() && d.chars().all(|c| c.is_ascii_digit()))
}

/// `^(credential\.(.*\.)?helper|core\.askpass)$` on lower-cased text.
pub fn is_cred_key(s: &str) -> bool {
    if s == "core.askpass" {
        return true;
    }
    let Some(rest) = s.strip_prefix("credential.") else {
        return false;
    };
    let Some(mid) = rest.strip_suffix("helper") else {
        return false;
    };
    !mid.contains('\n') && (mid.is_empty() || mid.ends_with('.'))
}

/// `^https?://[^/@]+@` with `re.I`.
pub fn is_cred_url(s: &str) -> bool {
    let b = s.as_bytes();
    let rest = if b.len() >= 8 && b[..8].eq_ignore_ascii_case(b"https://") {
        &s[8..]
    } else if b.len() >= 7 && b[..7].eq_ignore_ascii_case(b"http://") {
        &s[7..]
    } else {
        return false;
    };
    match rest.find(['/', '@']) {
        Some(i) => i > 0 && rest[i..].starts_with('@'),
        None => false,
    }
}

/// Python `re.search(r"\bgit\b.*\bpush\b", s, re.S)`.
pub fn git_then_push(s: &str) -> bool {
    let chars: Vec<char> = s.chars().collect();
    match find_word(&chars, &['g', 'i', 't'], 0) {
        Some(i) => find_word(&chars, &['p', 'u', 's', 'h'], i + 3).is_some(),
        None => false,
    }
}

fn find_word(chars: &[char], w: &[char], from: usize) -> Option<usize> {
    let n = w.len();
    (from..=chars.len().saturating_sub(n)).find(|&i| {
        chars.len() >= n
            && chars[i..i + n] == *w
            && (i == 0 || !is_word(chars[i - 1]))
            && (i + n == chars.len() || !is_word(chars[i + n]))
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cred_key() {
        assert!(is_cred_key("credential.helper"));
        assert!(is_cred_key("credential.https://x.example.com.helper"));
        assert!(is_cred_key("core.askpass"));
        assert!(!is_cred_key("credential.xhelper"));
        assert!(!is_cred_key("credential.helpers"));
    }

    #[test]
    fn cred_url() {
        assert!(is_cred_url("https://u:p@h/x"));
        assert!(is_cred_url("HTTP://u@h"));
        assert!(!is_cred_url("https://h/u@x"));
        assert!(!is_cred_url("https://@h"));
    }

    #[test]
    fn git_push_words() {
        assert!(git_then_push("git -C x push"));
        assert!(!git_then_push("gitx push"));
        assert!(!git_then_push("push git"));
        assert!(git_then_push("git\npush"));
    }
}
