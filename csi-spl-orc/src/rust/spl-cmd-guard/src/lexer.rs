//! A port of CPython's `shlex.shlex(s, posix=True, punctuation_chars=";&|()<>")`
//! with `whitespace_split = True` and `commenters = ""`, the exact tokenizer
//! `force-push-guard.inc.sh` runs. Same tokens, same two errors.

const PUNCT: &str = ";&|()<>";
const QUOTES: &str = "'\"";
const ESCAPE: char = '\\';
const ESCAPED_QUOTES: &str = "\"";

#[derive(Debug, PartialEq, Eq)]
pub enum LexError {
    NoClosingQuotation,
    NoEscapedCharacter,
}

impl std::fmt::Display for LexError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(match self {
            LexError::NoClosingQuotation => "No closing quotation",
            LexError::NoEscapedCharacter => "No escaped character",
        })
    }
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum State {
    Space,
    Word,
    Punct,
    Quote(char),
    Escape(char),
}

fn is_ws(c: char) -> bool {
    matches!(c, ' ' | '\t' | '\r' | '\n')
}

fn is_punct(c: char) -> bool {
    PUNCT.contains(c)
}

struct Lexer {
    chars: Vec<char>,
    pos: usize,
    pushback: Option<char>,
    state: State,
}

/// Every token of `s`, as `list(shlex.shlex(...))` returns them.
pub fn tokens(s: &str) -> Result<Vec<String>, LexError> {
    let mut lx = Lexer {
        chars: s.chars().collect(),
        pos: 0,
        pushback: None,
        state: State::Space,
    };
    let mut out = Vec::new();
    while let Some(t) = lx.read_token()? {
        out.push(t);
    }
    Ok(out)
}

impl Lexer {
    fn next_char(&mut self) -> Option<char> {
        if let Some(c) = self.pushback.take() {
            return Some(c);
        }
        let c = self.chars.get(self.pos).copied();
        self.pos += 1;
        c
    }

    /// One token; None at the end (an unquoted empty result).
    fn read_token(&mut self) -> Result<Option<String>, LexError> {
        let mut tok = String::new();
        let mut quoted = false;
        let mut escaped_state = State::Word;
        loop {
            let next = self.next_char();
            let done = match self.state {
                State::Space => self.on_space(next, &mut tok, &mut escaped_state),
                State::Quote(q) => self.on_quote(q, next, &mut tok, &mut quoted, &mut escaped_state)?,
                State::Escape(e) => self.on_escape(e, next, &mut tok, escaped_state)?,
                State::Word | State::Punct => self.on_word(next, &mut tok, quoted, &mut escaped_state),
            };
            if done {
                break;
            }
        }
        if !quoted && tok.is_empty() {
            return Ok(None);
        }
        Ok(Some(tok))
    }

    fn on_space(&mut self, next: Option<char>, tok: &mut String, esc: &mut State) -> bool {
        let Some(c) = next else {
            return true;
        };
        if is_ws(c) {
            return !tok.is_empty();
        }
        if c == ESCAPE {
            *esc = State::Word;
            self.state = State::Escape(c);
        } else if is_punct(c) {
            tok.push(c);
            self.state = State::Punct;
        } else if QUOTES.contains(c) {
            self.state = State::Quote(c);
        } else {
            // a wordchar, or any other char under whitespace_split: a word
            tok.push(c);
            self.state = State::Word;
        }
        false
    }

    fn on_quote(
        &mut self,
        q: char,
        next: Option<char>,
        tok: &mut String,
        quoted: &mut bool,
        esc: &mut State,
    ) -> Result<bool, LexError> {
        *quoted = true;
        let Some(c) = next else {
            return Err(LexError::NoClosingQuotation);
        };
        if c == q {
            self.state = State::Word;
        } else if c == ESCAPE && ESCAPED_QUOTES.contains(q) {
            *esc = State::Quote(q);
            self.state = State::Escape(c);
        } else {
            tok.push(c);
        }
        Ok(false)
    }

    fn on_escape(&mut self, e: char, next: Option<char>, tok: &mut String, esc: State) -> Result<bool, LexError> {
        let Some(c) = next else {
            return Err(LexError::NoEscapedCharacter);
        };
        if let State::Quote(q) = esc
            && c != e
            && c != q
        {
            tok.push(e);
        }
        tok.push(c);
        self.state = esc;
        Ok(false)
    }

    fn on_word(&mut self, next: Option<char>, tok: &mut String, quoted: bool, esc: &mut State) -> bool {
        let Some(c) = next else {
            self.state = State::Space;
            return true;
        };
        if is_ws(c) {
            self.state = State::Space;
            return !tok.is_empty() || quoted;
        }
        if self.state == State::Punct {
            if is_punct(c) {
                tok.push(c);
                return false;
            }
            self.pushback = Some(c);
            self.state = State::Space;
            return true;
        }
        if QUOTES.contains(c) {
            self.state = State::Quote(c);
        } else if c == ESCAPE {
            *esc = State::Word;
            self.state = State::Escape(c);
        } else if !is_punct(c) {
            tok.push(c);
        } else {
            self.pushback = Some(c);
            self.state = State::Space;
            return !tok.is_empty() || quoted;
        }
        false
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn t(s: &str) -> Vec<String> {
        tokens(s).unwrap()
    }

    #[test]
    fn words_and_punct() {
        assert_eq!(t("a && b;c|d"), ["a", "&&", "b", ";", "c", "|", "d"]);
        assert_eq!(t("echo 2>/dev/null"), ["echo", "2", ">", "/dev/null"]);
        assert_eq!(t("x;;&y"), ["x", ";;&", "y"]);
    }

    #[test]
    fn quotes_and_escapes() {
        assert_eq!(t(r#"a "b c" 'd e'"#), ["a", "b c", "d e"]);
        assert_eq!(t(r#""a\"b\x""#), [r#"a"b\x"#]);
        assert_eq!(t(r"a\ b"), ["a b"]);
        assert_eq!(t(r#""""#), [""]);
        assert_eq!(t("a\"b\"c"), ["abc"]);
    }

    #[test]
    fn errors() {
        assert_eq!(tokens("\"x"), Err(LexError::NoClosingQuotation));
        assert_eq!(tokens("x\\"), Err(LexError::NoEscapedCharacter));
    }
}
