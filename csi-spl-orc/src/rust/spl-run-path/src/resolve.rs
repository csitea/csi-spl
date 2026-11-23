//! The `perl` of run.sh's `do_set_vars`, ported one step at a time:
//!
//! ```perl
//! while (1) { $d = abs_path(dirname($p)) // die "abs_path: $p\n";
//!   last if $d =~ m{/src/bash/run$} || !-l $p || ++$n > 40;
//!   my $t = readlink $p; $p = $t =~ m{^/} ? $t : dirname($p) . "/$t"; }
//! ```
//!
//! `dirname` is File::Basename's (Unix), `abs_path` is Cwd's XS
//! `bsd_realpath`: the last component may be missing, an earlier one may not.
//! Where an exact port would need a corner the tests cannot pin (a newline in
//! a path, a long path, a long link chain), the port answers `Refuse` and
//! run.sh takes the perl itself.

use std::ffi::OsStr;
use std::os::unix::ffi::OsStrExt;

/// ENOENT on Linux: the one lstat error bsd_realpath forgives.
const ENOENT: i32 = 2;
/// Paths at or over this length are refused: bsd_realpath's MAXPATHLEN
/// checks (4096) are then never reached, so they need no port.
pub const MAX_LEN: usize = 1024;
/// Links followed inside one abs_path before the port refuses; under
/// bsd_realpath's own ELOOP limit (MAXSYMLINKS, 20 on Linux).
pub const MAX_LINKS: u32 = 16;
/// The perl's own hop limit (`++$n > 40`).
const MAX_HOPS: u32 = 40;

#[derive(Debug, PartialEq, Eq)]
pub enum Outcome {
    /// The resolved `src/bash/run`-like dir (`$d` when the loop ends).
    Dir(Vec<u8>),
    /// abs_path returned undef: the perl dies.
    Die,
    /// Outside what the port proves equal: let the perl decide.
    Refuse,
}

/// File::Basename::fileparse's split (`m{^(.*/)?(.*)}s`, `./` when no dir).
fn fileparse(p: &[u8]) -> (Vec<u8>, Vec<u8>) {
    match p.iter().rposition(|&c| c == b'/') {
        Some(i) => (p[..=i].to_vec(), p[i + 1..].to_vec()),
        None => (b"./".to_vec(), p.to_vec()),
    }
}

/// `s{(.)/*\z}{$1}s`: drop trailing slashes, keep at least one byte.
fn strip_trailing_sep(d: &mut Vec<u8>) {
    while d.len() > 1 && d.last() == Some(&b'/') {
        d.pop();
    }
}

/// File::Basename::dirname, Unix flavour.
pub fn dirname(p: &[u8]) -> Vec<u8> {
    let (mut dir, base) = fileparse(p);
    strip_trailing_sep(&mut dir);
    if base.is_empty() {
        let (d2, _) = fileparse(&dir);
        dir = d2;
        strip_trailing_sep(&mut dir);
    }
    dir
}

/// Drop the last component of `resolved` (which ends in '/'), keep the '/'.
fn pop_component(resolved: &mut Vec<u8>) {
    if resolved.len() > 1 {
        resolved.pop();
        let q = resolved.iter().rposition(|&c| c == b'/').map_or(0, |i| i + 1);
        resolved.truncate(q);
    }
}

fn os(p: &[u8]) -> &OsStr {
    OsStr::from_bytes(p)
}

/// Cwd::abs_path (bsd_realpath). `None` is undef; `Err(())` is a refusal.
pub fn abs_path(path: &[u8], cwd: &[u8]) -> Result<Option<Vec<u8>>, ()> {
    let (mut resolved, mut remaining) = if path.first() == Some(&b'/') {
        if path.len() == 1 {
            return Ok(Some(b"/".to_vec()));
        }
        (b"/".to_vec(), path[1..].to_vec())
    } else {
        (cwd.to_vec(), path.to_vec())
    };
    let mut links = 0u32;
    while !remaining.is_empty() {
        if resolved.len() >= MAX_LEN || remaining.len() >= MAX_LEN {
            return Err(());
        }
        let slash = remaining.iter().position(|&c| c == b'/');
        let token: Vec<u8> = match slash {
            Some(i) => {
                let t = remaining[..i].to_vec();
                remaining.drain(..=i);
                t
            }
            None => std::mem::take(&mut remaining),
        };
        if resolved.last() != Some(&b'/') {
            resolved.push(b'/');
        }
        if token.is_empty() || token == b"." {
            continue;
        }
        if token == b".." {
            pop_component(&mut resolved);
            continue;
        }
        resolved.extend_from_slice(&token);
        let meta = match std::fs::symlink_metadata(os(&resolved)) {
            Ok(m) => m,
            Err(e) if e.raw_os_error() == Some(ENOENT) && slash.is_none() => return Ok(Some(resolved)),
            Err(_) => return Ok(None),
        };
        if !meta.file_type().is_symlink() {
            continue;
        }
        links += 1;
        if links > MAX_LINKS {
            return Err(());
        }
        let target = std::fs::read_link(os(&resolved)).map_err(|_| ())?;
        let mut link = target.as_os_str().as_bytes().to_vec();
        if link.is_empty() {
            return Err(());
        }
        if link[0] == b'/' {
            resolved.truncate(1);
        } else {
            pop_component(&mut resolved);
        }
        if slash.is_some() {
            if link.last() != Some(&b'/') {
                link.push(b'/');
            }
            link.extend_from_slice(&remaining);
        }
        remaining = link;
    }
    if resolved.len() > 1 && resolved.last() == Some(&b'/') {
        resolved.pop();
    }
    Ok(Some(resolved))
}

fn is_symlink(p: &[u8]) -> bool {
    std::fs::symlink_metadata(os(p)).is_ok_and(|m| m.file_type().is_symlink())
}

/// The whole loop: `$0` in, `$d` out. `cwd` is the process's own: a
/// relative `$p` is read through it by both abs_path and `-l`.
pub fn run_dir(arg0: &[u8], cwd: &[u8]) -> Outcome {
    if arg0.contains(&b'\n') || cwd.contains(&b'\n') || arg0.len() >= MAX_LEN {
        return Outcome::Refuse;
    }
    let mut p = arg0.to_vec();
    let mut hops = 0u32;
    loop {
        let d = match abs_path(&dirname(&p), cwd) {
            Ok(Some(d)) => d,
            Ok(None) => return Outcome::Die,
            Err(()) => return Outcome::Refuse,
        };
        if d.contains(&b'\n') {
            return Outcome::Refuse;
        }
        if d.ends_with(b"/src/bash/run") || !is_symlink(&p) {
            return Outcome::Dir(d);
        }
        hops += 1;
        if hops > MAX_HOPS {
            return Outcome::Dir(d);
        }
        let Ok(t) = std::fs::read_link(os(&p)) else {
            return Outcome::Refuse;
        };
        let t = t.as_os_str().as_bytes();
        if t.contains(&b'\n') {
            return Outcome::Refuse;
        }
        p = if t.first() == Some(&b'/') {
            t.to_vec()
        } else {
            let mut q = dirname(&p);
            q.push(b'/');
            q.extend_from_slice(t);
            q
        };
        if p.len() >= MAX_LEN {
            return Outcome::Refuse;
        }
    }
}

/// `$(cd "<d>/<ups>" && pwd)` for an abs_path-resolved `d`: `d` holds no
/// link, so bash's logical `..` is the lexical parent, and `/` stays `/`.
pub fn parent(d: &[u8], ups: usize) -> Vec<u8> {
    let mut p = d.to_vec();
    for _ in 0..ups {
        match p.iter().rposition(|&c| c == b'/') {
            Some(0) | None => p = b"/".to_vec(),
            Some(i) => p.truncate(i),
        }
    }
    p
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn dirname_matches_file_basename() {
        // perl -MFile::Basename -e 'print dirname($_),"|" for (...)'
        let cases: [(&str, &str); 9] = [
            ("run", "."),
            ("./run", "."),
            ("/run", "/"),
            ("a//b", "a"),
            ("a/b/", "a"),
            ("//", "/"),
            ("", "."),
            ("a/b//", "a"),
            ("/x/src/bash/run/run.sh", "/x/src/bash/run"),
        ];
        for (p, want) in cases {
            assert_eq!(dirname(p.as_bytes()), want.as_bytes(), "dirname({p:?})");
        }
    }

    #[test]
    fn parent_stops_at_root() {
        assert_eq!(parent(b"/a/b/c/d", 3), b"/a");
        assert_eq!(parent(b"/a/b", 3), b"/");
        assert_eq!(parent(b"/", 1), b"/");
    }

    fn tmp(tag: &str) -> std::path::PathBuf {
        let d = std::env::temp_dir().join(format!("spl-run-path-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(&d).unwrap();
        std::fs::canonicalize(&d).unwrap()
    }

    #[test]
    fn abs_path_forgives_only_a_missing_last_component() {
        let t = tmp("abs");
        let tb = t.as_os_str().as_bytes();
        let mut miss = tb.to_vec();
        miss.extend_from_slice(b"/nope");
        assert_eq!(abs_path(&miss, b"/").unwrap(), Some(miss.clone()));
        let mut deeper = miss.clone();
        deeper.extend_from_slice(b"/x");
        assert_eq!(abs_path(&deeper, b"/").unwrap(), None);
        assert_eq!(abs_path(b".", tb).unwrap(), Some(tb.to_vec()));
        std::fs::remove_dir_all(&t).unwrap();
    }

    #[test]
    fn module_layout_resolves_to_its_run_dir() {
        let t = tmp("mod");
        let m = t.join("csi-x/csi-x-orc");
        std::fs::create_dir_all(m.join("src/bash/run")).unwrap();
        std::fs::write(m.join("src/bash/run/run.sh"), "").unwrap();
        std::os::unix::fs::symlink("src/bash/run/run.sh", m.join("run")).unwrap();
        let mut want = m.as_os_str().as_bytes().to_vec();
        want.extend_from_slice(b"/src/bash/run");
        // Absolute $0 only: `-l $p` reads the process cwd, which a unit test
        // does not own (run-path-bin.tst.sh covers the relative spellings).
        let run = m.join("run");
        assert_eq!(run_dir(run.as_os_str().as_bytes(), b"/"), Outcome::Dir(want.clone()));
        let xrun = t.join("xrun");
        std::os::unix::fs::symlink(&run, &xrun).unwrap();
        assert_eq!(run_dir(xrun.as_os_str().as_bytes(), b"/"), Outcome::Dir(want));
        std::fs::remove_dir_all(&t).unwrap();
    }

    #[test]
    fn a_newline_is_refused() {
        assert_eq!(run_dir(b"a\nb/run", b"/"), Outcome::Refuse);
    }
}
