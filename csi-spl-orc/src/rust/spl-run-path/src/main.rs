//! spl-run-path: the path step of run.sh's `do_set_vars` as one native exec
//! (SPL-5985; spec 027 `rust-run-path.md`). It replaces the `perl` that
//! follows `$0`'s links, the four `$(cd ... && pwd)` and `$(hostname -s)`.
//!
//!   spl-run-path -- <$0>
//!       rc 0  stdout, one `KEY=value` per line, in this order:
//!             SPL_RUN_PATH_VERSION, unit_run_dir, RUN_UNIT, PROJ_PATH,
//!             APP_PATH, ORG_PATH, BASE_PATH, HOST_NAME
//!       rc 2  abs_path is undef (the perl dies): nothing printed
//!       rc 3  outside what the port proves equal: nothing printed
//!   spl-run-path --version
//!   any other call: rc 64
//!
//! On any rc but 0, or a first line that is not run.sh's version, run.sh
//! takes today's Bash path for the step.
#![forbid(unsafe_code)]

mod resolve;

use std::ffi::OsString;
use std::io::Write;
use std::os::unix::ffi::{OsStrExt, OsStringExt};
use std::process::ExitCode;

const VERSION: &str = env!("CARGO_PKG_VERSION");

/// `hostname -s`: the kernel's node name cut at its first dot.
fn host_short() -> Option<Vec<u8>> {
    let raw = std::fs::read("/proc/sys/kernel/hostname").ok()?;
    let line = raw.strip_suffix(b"\n").unwrap_or(&raw);
    let short = line.split(|&c| c == b'.').next().unwrap_or(line);
    (!short.is_empty() && !short.contains(&b'\n')).then(|| short.to_vec())
}

/// The bash `cd <dir>` would fail on a dir it cannot enter (it then sets
/// the value empty): only a dir chdir(2) accepts is answered here.
fn enterable(d: &[u8]) -> bool {
    std::env::set_current_dir(std::ffi::OsStr::from_bytes(d)).is_ok()
}

fn paths(arg0: &[u8]) -> Result<Vec<(&'static str, Vec<u8>)>, u8> {
    let cwd = std::env::current_dir().map_err(|_| 3u8)?.into_os_string().into_vec();
    let d = match resolve::run_dir(arg0, &cwd) {
        resolve::Outcome::Dir(d) => d,
        resolve::Outcome::Die => return Err(2),
        resolve::Outcome::Refuse => return Err(3),
    };
    let base = d.rsplit(|&c| c == b'/').next().unwrap_or(&d);
    let mut unit = base.to_vec();
    unit.extend_from_slice(b".sh");
    let mut out = vec![("unit_run_dir", d.clone()), ("RUN_UNIT", unit)];
    for (k, ups) in [("PROJ_PATH", 3), ("APP_PATH", 4), ("ORG_PATH", 5), ("BASE_PATH", 6)] {
        let p = resolve::parent(&d, ups);
        if !enterable(&p) {
            return Err(3);
        }
        out.push((k, p));
    }
    out.push(("HOST_NAME", host_short().ok_or(3u8)?));
    Ok(out)
}

fn emit(vals: &[(&str, Vec<u8>)]) -> u8 {
    let mut buf = format!("SPL_RUN_PATH_VERSION={VERSION}\n").into_bytes();
    for (k, v) in vals {
        buf.extend_from_slice(k.as_bytes());
        buf.push(b'=');
        buf.extend_from_slice(v);
        buf.push(b'\n');
    }
    let mut so = std::io::stdout().lock();
    if so.write_all(&buf).and_then(|_| so.flush()).is_err() {
        return 3;
    }
    0
}

fn main() -> ExitCode {
    let args: Vec<OsString> = std::env::args_os().skip(1).collect();
    let rc = match args.as_slice() {
        [v] if v == "--version" => {
            println!("spl-run-path {VERSION}");
            0
        }
        [dd, arg0] if dd == "--" => match paths(arg0.as_bytes()) {
            Ok(vals) => emit(&vals),
            Err(rc) => rc,
        },
        _ => {
            eprintln!("usage: spl-run-path -- <$0> | --version");
            64
        }
    };
    ExitCode::from(rc)
}
