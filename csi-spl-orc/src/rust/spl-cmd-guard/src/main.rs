//! spl-cmd-guard: the force-push guard of `force-push-guard-hook.sh` as one
//! native process (SPL-5392, the Rust pilot of
//! `csi-spl-doc/specs/011-spool-project-refactor/rust-candidates-analysis.md`
//! section 6.1). It replaces the hook's two Python cold starts: the payload
//! extractor and the force-push matcher. The kill-target and heredoc-collision
//! guards stay in Python (Phase 0).
//!
//!   spl-cmd-guard hook          the hook payload JSON on stdin
//!       rc 0  stdout NONE (not a shell call) or CMD:<command> (no forbidden push)
//!       rc 2  stdout <reason>: a forbidden push form
//!       rc 3  the payload cannot be read (the hook refuses: fail closed)
//!   spl-cmd-guard check <command>
//!       rc 0 allow; rc 2 and "force-push-guard: refused: <reason>" on stderr
//!   spl-cmd-guard batch         NUL-separated commands on stdin, one verdict
//!       line each: "0", or "2<TAB><reason>" (the differential test's form)
//!   spl-cmd-guard --version | --self-test
//!   any other call: rc 64
#![forbid(unsafe_code)]

mod guard;
mod json;
mod lexer;
mod payload;
mod pytext;

use std::io::{Read, Write};
use std::process::ExitCode;

const PREFIX: &str = "force-push-guard: refused: ";

fn hook() -> u8 {
    let mut raw = Vec::new();
    if std::io::stdin().read_to_end(&mut raw).is_err() {
        return 3;
    }
    let Ok(text) = String::from_utf8(raw) else {
        return 3;
    };
    let (out, rc) = match payload::extract(&text) {
        payload::Call::Unreadable => return 3,
        payload::Call::NotShell => ("NONE".to_string(), 0),
        payload::Call::Cmd(cmd) => match guard::check_command(&cmd) {
            Ok(()) => (format!("CMD:{cmd}"), 0),
            Err(why) => (why, 2),
        },
    };
    let mut so = std::io::stdout().lock();
    if so.write_all(out.as_bytes()).and_then(|_| so.flush()).is_err() {
        return 3;
    }
    rc
}

fn check(cmd: &str) -> u8 {
    match guard::check_command(cmd) {
        Ok(()) => 0,
        Err(why) => {
            eprintln!("{PREFIX}{why}");
            2
        }
    }
}

fn batch() -> u8 {
    let mut raw = Vec::new();
    if std::io::stdin().read_to_end(&mut raw).is_err() {
        return 3;
    }
    let text = String::from_utf8_lossy(&raw);
    let mut so = std::io::BufWriter::new(std::io::stdout().lock());
    for cmd in text.split_terminator('\0') {
        let line = match guard::check_command(cmd) {
            Ok(()) => "0".to_string(),
            Err(why) => format!("2\t{}", why.replace('\n', "\\n")),
        };
        if writeln!(so, "{line}").is_err() {
            return 3;
        }
    }
    if so.flush().is_err() { 3 } else { 0 }
}

/// A few fixed verdicts: an installer runs this before it swaps a binary in.
fn self_test() -> u8 {
    let cases = [
        ("git push origin HEAD:master", true),
        ("git status", true),
        ("git push --force origin HEAD:master", false),
        ("sudo -u x bash -c 'git push origin +HEAD:master'", false),
        ("SPL_PREPUSH_OVERRIDE=1 git push", false),
    ];
    let bad: Vec<_> = cases
        .iter()
        .filter(|(c, ok)| guard::check_command(c).is_ok() != *ok)
        .collect();
    let hook_ok =
        payload::extract(r#"{"tool_name":"Bash","tool_input":{"command":"ls"}}"#) == payload::Call::Cmd("ls".into());
    if bad.is_empty() && hook_ok {
        println!("spl-cmd-guard self-test: ok ({} cases)", cases.len() + 1);
        return 0;
    }
    eprintln!("spl-cmd-guard self-test: FAILED {bad:?} hook_ok={hook_ok}");
    1
}

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args_os()
        .skip(1)
        .map(|a| a.to_string_lossy().into_owned())
        .collect();
    let rc = match args.iter().map(String::as_str).collect::<Vec<_>>().as_slice() {
        ["hook"] => hook(),
        ["check", cmd] => check(cmd),
        ["batch"] => batch(),
        ["--self-test"] => self_test(),
        ["--version"] => {
            let commit = option_env!("SPL_CMD_GUARD_COMMIT").unwrap_or("unknown");
            println!("spl-cmd-guard {} ({commit})", env!("CARGO_PKG_VERSION"));
            0
        }
        _ => {
            eprintln!(
                "usage: spl-cmd-guard hook < payload.json | check \"<command>\" | batch < cmds | --version | --self-test"
            );
            64
        }
    };
    ExitCode::from(rc)
}
