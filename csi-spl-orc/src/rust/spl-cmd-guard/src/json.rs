//! A JSON reader with Python `json.loads` semantics, as far as the hook's
//! payload extractor can tell them apart: NaN / Infinity accepted, control
//! characters in strings refused, the last of duplicate keys wins, a lone
//! surrogate kept (and flagged: Python cannot print it), a leading BOM refused.

/// Python's recursion limit is 1000 frames; the C scanner fails near it.
const MAX_DEPTH: usize = 990;

#[derive(Debug, Clone, PartialEq)]
pub enum Value {
    Null,
    Bool(bool),
    /// A number; only its truthiness matters here.
    Num {
        zero: bool,
    },
    /// A string; `lone` when it holds an unpaired surrogate (U+FFFD here).
    Str {
        s: String,
        lone: bool,
    },
    Arr(Vec<Value>),
    Obj(Vec<(String, Value)>),
}

#[derive(Debug, PartialEq, Eq)]
pub enum JsonError {
    /// json.JSONDecodeError, a ValueError.
    Decode,
    /// RecursionError: not a ValueError, so nothing catches it.
    Recursion,
}

impl Value {
    /// Python truthiness.
    pub fn truthy(&self) -> bool {
        match self {
            Value::Null => false,
            Value::Bool(b) => *b,
            Value::Num { zero } => !zero,
            Value::Str { s, .. } => !s.is_empty(),
            Value::Arr(a) => !a.is_empty(),
            Value::Obj(o) => !o.is_empty(),
        }
    }

    /// `dict.get(key)`: the last pair with that key.
    pub fn get(&self, key: &str) -> Option<&Value> {
        match self {
            Value::Obj(o) => o.iter().rev().find(|(k, _)| k == key).map(|(_, v)| v),
            _ => None,
        }
    }
}

/// `json.loads(s)`.
pub fn parse(s: &str) -> Result<Value, JsonError> {
    let mut p = Parser {
        c: s.chars().collect(),
        i: 0,
        depth: 0,
    };
    if p.c.first() == Some(&'\u{feff}') {
        return Err(JsonError::Decode);
    }
    p.ws();
    let v = p.value()?;
    p.ws();
    if p.i != p.c.len() {
        return Err(JsonError::Decode);
    }
    Ok(v)
}

struct Parser {
    c: Vec<char>,
    i: usize,
    depth: usize,
}

impl Parser {
    fn peek(&self) -> Option<char> {
        self.c.get(self.i).copied()
    }

    fn ws(&mut self) {
        while matches!(self.peek(), Some(' ' | '\t' | '\n' | '\r')) {
            self.i += 1;
        }
    }

    fn lit(&mut self, w: &str) -> bool {
        let n = w.chars().count();
        if self.c.len() >= self.i + n && self.c[self.i..self.i + n].iter().copied().eq(w.chars()) {
            self.i += n;
            return true;
        }
        false
    }

    fn value(&mut self) -> Result<Value, JsonError> {
        match self.peek() {
            Some('"') => self.string().map(|(s, lone)| Value::Str { s, lone }),
            Some('{') => self.nested(Self::object),
            Some('[') => self.nested(Self::array),
            Some('n') if self.lit("null") => Ok(Value::Null),
            Some('t') if self.lit("true") => Ok(Value::Bool(true)),
            Some('f') if self.lit("false") => Ok(Value::Bool(false)),
            Some('N') if self.lit("NaN") => Ok(Value::Num { zero: false }),
            Some('I') if self.lit("Infinity") => Ok(Value::Num { zero: false }),
            Some('-') if self.lit("-Infinity") => Ok(Value::Num { zero: false }),
            Some('-' | '0'..='9') => self.number(),
            _ => Err(JsonError::Decode),
        }
    }

    fn nested(&mut self, f: fn(&mut Self) -> Result<Value, JsonError>) -> Result<Value, JsonError> {
        self.depth += 1;
        if self.depth > MAX_DEPTH {
            return Err(JsonError::Recursion);
        }
        self.i += 1;
        let v = f(self);
        self.depth -= 1;
        v
    }

    fn object(&mut self) -> Result<Value, JsonError> {
        let mut o = Vec::new();
        self.ws();
        if self.peek() == Some('}') {
            self.i += 1;
            return Ok(Value::Obj(o));
        }
        loop {
            if self.peek() != Some('"') {
                return Err(JsonError::Decode);
            }
            let (k, _) = self.string()?;
            self.ws();
            if self.peek() != Some(':') {
                return Err(JsonError::Decode);
            }
            self.i += 1;
            self.ws();
            o.push((k, self.value()?));
            self.ws();
            match self.peek() {
                Some(',') => self.i += 1,
                Some('}') => {
                    self.i += 1;
                    return Ok(Value::Obj(o));
                }
                _ => return Err(JsonError::Decode),
            }
            self.ws();
        }
    }

    fn array(&mut self) -> Result<Value, JsonError> {
        let mut a = Vec::new();
        self.ws();
        if self.peek() == Some(']') {
            self.i += 1;
            return Ok(Value::Arr(a));
        }
        loop {
            self.ws();
            a.push(self.value()?);
            self.ws();
            match self.peek() {
                Some(',') => self.i += 1,
                Some(']') => {
                    self.i += 1;
                    return Ok(Value::Arr(a));
                }
                _ => return Err(JsonError::Decode),
            }
        }
    }

    fn digits(&mut self) -> usize {
        let start = self.i;
        while matches!(self.peek(), Some('0'..='9')) {
            self.i += 1;
        }
        self.i - start
    }

    /// `-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][-+]?[0-9]+)?`
    fn number(&mut self) -> Result<Value, JsonError> {
        let start = self.i;
        if self.peek() == Some('-') {
            self.i += 1;
        }
        match self.peek() {
            Some('0') => self.i += 1,
            Some('1'..='9') => {
                self.digits();
            }
            _ => return Err(JsonError::Decode),
        }
        let int_end = self.i;
        let mut float = false;
        if self.peek() == Some('.') && matches!(self.c.get(self.i + 1), Some('0'..='9')) {
            self.i += 1;
            self.digits();
            float = true;
        }
        if matches!(self.peek(), Some('e' | 'E')) {
            let save = self.i;
            self.i += 1;
            if matches!(self.peek(), Some('+' | '-')) {
                self.i += 1;
            }
            if self.digits() == 0 {
                self.i = save;
            } else {
                float = true;
            }
        }
        let text: String = self.c[start..self.i].iter().collect();
        let zero = if float {
            text.parse::<f64>().map(|f| f == 0.0).unwrap_or(false)
        } else {
            self.c[start..int_end].iter().all(|&c| c == '0' || c == '-')
        };
        Ok(Value::Num { zero })
    }

    fn hex4(&mut self) -> Result<u32, JsonError> {
        let h: String = self
            .c
            .get(self.i..self.i + 4)
            .ok_or(JsonError::Decode)?
            .iter()
            .collect();
        if !h.chars().all(|c| c.is_ascii_hexdigit()) {
            return Err(JsonError::Decode);
        }
        self.i += 4;
        u32::from_str_radix(&h, 16).map_err(|_| JsonError::Decode)
    }

    /// A `\uXXXX` escape (the `\u` already read), pairing surrogates as
    /// Python does; a lone one becomes U+FFFD and sets `lone`.
    fn unicode(&mut self, out: &mut String, lone: &mut bool) -> Result<(), JsonError> {
        let u = self.hex4()?;
        if (0xd800..0xdc00).contains(&u) && self.c.get(self.i) == Some(&'\\') && self.c.get(self.i + 1) == Some(&'u') {
            let save = self.i;
            self.i += 2;
            match self.hex4() {
                Ok(l) if (0xdc00..0xe000).contains(&l) => {
                    let cp = 0x10000 + ((u - 0xd800) << 10) + (l - 0xdc00);
                    out.push(char::from_u32(cp).ok_or(JsonError::Decode)?);
                    return Ok(());
                }
                _ => self.i = save,
            }
        }
        match char::from_u32(u) {
            Some(ch) => out.push(ch),
            None => {
                out.push('\u{fffd}');
                *lone = true;
            }
        }
        Ok(())
    }

    fn string(&mut self) -> Result<(String, bool), JsonError> {
        self.i += 1;
        let (mut out, mut lone) = (String::new(), false);
        loop {
            let c = self.peek().ok_or(JsonError::Decode)?;
            self.i += 1;
            match c {
                '"' => return Ok((out, lone)),
                '\\' => {
                    let e = self.peek().ok_or(JsonError::Decode)?;
                    self.i += 1;
                    match e {
                        '"' | '\\' | '/' => out.push(e),
                        'b' => out.push('\u{8}'),
                        'f' => out.push('\u{c}'),
                        'n' => out.push('\n'),
                        'r' => out.push('\r'),
                        't' => out.push('\t'),
                        'u' => self.unicode(&mut out, &mut lone)?,
                        _ => return Err(JsonError::Decode),
                    }
                }
                c if (c as u32) < 0x20 => return Err(JsonError::Decode),
                c => out.push(c),
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn python_forms() {
        assert!(parse("NaN").is_ok());
        assert!(parse(" [1, -Infinity] ").is_ok());
        assert_eq!(parse("01"), Err(JsonError::Decode));
        assert_eq!(parse("\u{feff}{}"), Err(JsonError::Decode));
        assert_eq!(parse("\"a\u{1}\""), Err(JsonError::Decode));
        assert_eq!(parse("[1,]"), Err(JsonError::Decode));
        assert_eq!(parse("1."), Err(JsonError::Decode));
    }

    #[test]
    fn dup_keys_and_truth() {
        let v = parse(r#"{"a": 1, "a": 0.0}"#).unwrap();
        assert!(!v.get("a").unwrap().truthy());
        assert!(parse("1e-400").map(|v| !v.truthy()).unwrap());
        assert!(parse("-0").map(|v| !v.truthy()).unwrap());
    }

    #[test]
    fn surrogates() {
        assert_eq!(
            parse(r#""😀""#).unwrap(),
            Value::Str {
                s: "😀".into(),
                lone: false
            }
        );
        assert!(matches!(parse(r#""\ud83d""#).unwrap(), Value::Str { lone: true, .. }));
        assert_eq!(parse(r#""\u00""#), Err(JsonError::Decode));
    }

    #[test]
    fn deep() {
        let s = "[".repeat(2000) + &"]".repeat(2000);
        assert_eq!(parse(&s), Err(JsonError::Recursion));
    }
}
