//! The force-push matcher: a port of `_FORCE_PUSH_GUARD_PY` in
//! `csi-spl-orc/src/bash/features/spawn-agents/lib/force-push-guard.inc.sh`.
//! Same walk, same verdict, same reason text; that file's header lists the
//! forms. Each function keeps the Python one's name.

use crate::lexer;
use crate::pytext::{
    base, git_then_push, is_assignment, is_cred_key, is_cred_url, is_digits, is_git_config_key, is_space, is_word,
    partition_eq, strip,
};

const OVERRIDE: &str = "SPL_PREPUSH_OVERRIDE";
const DECLARE: [&str; 5] = ["export", "declare", "typeset", "readonly", "local"];
const FORCE_LONG: [&str; 4] = ["--force", "--force-with-lease", "--force-if-includes", "--mirror"];
const NO_VERIFY: &str = "--no-verify";
const HOOKS: &str = "core.hookspath";
const SHELLS: [&str; 7] = ["bash", "sh", "zsh", "dash", "ksh", "fish", "busybox"];
const WRAP: [&str; 28] = [
    "env", "command", "exec", "nohup", "time", "nice", "ionice", "setsid", "stdbuf", "timeout", "xargs", "builtin",
    "chronic", "unbuffer", "flock", "doas", "sudo", "if", "elif", "while", "until", "then", "do", "else", "!", "watch",
    "parallel", "strace",
];
const GIT_ARG_OPTS: [&str; 6] = [
    "-C",
    "--git-dir",
    "--work-tree",
    "--namespace",
    "--exec-path",
    "--config-env",
];
const PUSH_ARG_OPTS: [&str; 5] = ["-o", "--push-option", "--repo", "--receive-pack", "--exec"];
const MASTER: [&str; 2] = ["master", "refs/heads/master"];
const APPROVAL: &str = "forbidden without the owner's explicit approval";
const NO_AUTH: &str = "a failed push is reported to your spawner, never worked around";
const CRED_FILE: &str = ".git-credentials";
const CRED_FILE_OK: [&str; 15] = [
    "grep", "egrep", "fgrep", "rg", "echo", "printf", "ls", "stat", "test", "[", "[[", "for", "wc", "du", "rm",
];
const ASKPASS: [&str; 2] = ["GIT_ASKPASS", "SSH_ASKPASS"];
const CONFIG_NO_WRITE: [&str; 12] = [
    "--get",
    "--get-all",
    "--get-regexp",
    "--get-urlmatch",
    "--list",
    "-l",
    "--unset",
    "--unset-all",
    "--remove-section",
    "--rename-section",
    "--edit",
    "-e",
];
const CONFIG_NO_WRITE_VERB: [&str; 6] = ["get", "list", "unset", "remove-section", "rename-section", "edit"];
const CONFIG_ARG_OPTS: [&str; 8] = [
    "--file",
    "-f",
    "--blob",
    "--type",
    "--default",
    "--comment",
    "--value",
    "--url",
];

/// A refusal and its reason (the text after "force-push-guard: refused: ").
pub type Refuse = String;
type R = Result<(), Refuse>;

fn arg_opts(b: &str) -> &'static [&'static str] {
    match b {
        "sudo" => &["-u", "-g", "-C", "-D", "-h", "-p", "-r", "-t", "-U", "-T"],
        "env" => &["-u", "--unset", "-C", "--chdir", "-S", "--split-string"],
        "nice" => &["-n", "--adjustment"],
        "ionice" => &["-c", "-n", "-t"],
        "timeout" => &["-s", "--signal", "-k", "--kill-after"],
        "xargs" => &["-I", "-L", "-n", "-P", "-d", "-E", "-a", "-s"],
        "flock" => &["-w", "-E", "-c"],
        "watch" => &["-n", "-d"],
        "stdbuf" => &["-i", "-o", "-e"],
        _ => &[],
    }
}

fn override_refuse() -> Refuse {
    format!("SPL_PREPUSH_OVERRIDE bypasses the pre-push gate; {APPROVAL}")
}

/// The whole decision: Ok allows, Err refuses with the reason.
pub fn check_command(cmd: &str) -> R {
    check(cmd, 0)
}

fn check(cmd: &str, depth: usize) -> R {
    if depth > 8 {
        return Err("the command nests too deep to read (fail closed)".into());
    }
    let owned;
    let cmd = if cmd.contains("<<") {
        owned = heredocs(cmd, depth)?;
        owned.as_str()
    } else {
        cmd
    };
    let segs = match split(cmd) {
        Ok(s) => s,
        Err(e) => {
            // Fail closed only where a push can hide.
            if override_raw(cmd) {
                return Err(override_refuse());
            }
            if git_then_push(cmd) {
                return Err(format!(
                    "cannot tokenize a command with git ... push ({e}); fail closed"
                ));
            }
            return Ok(());
        }
    };
    segs.iter().try_for_each(|seg| segment(seg, depth))
}

fn is_redirect(t: &str) -> bool {
    !t.is_empty() && t.chars().all(|c| "<>&".contains(c)) && (t.contains('<') || t.contains('>'))
}

fn is_separator(t: &str) -> bool {
    !t.is_empty() && t.chars().all(|c| ";&|()<>".contains(c))
}

fn split(cmd: &str) -> Result<Vec<Vec<String>>, lexer::LexError> {
    let s = cmd.replace(['`', '\n'], " ; ").replace("$(", " ; ( ");
    let (mut segs, mut cur, mut target) = (Vec::new(), Vec::<String>::new(), false);
    for t in lexer::tokens(&s)? {
        if is_redirect(&t) {
            // A redirect does not end the command; its target is its own segment.
            if cur.last().is_some_and(|l| is_digits(l)) {
                cur.pop();
            }
            target = true;
        } else if is_separator(&t) {
            if !cur.is_empty() {
                segs.push(std::mem::take(&mut cur));
            }
            target = false;
        } else if target {
            segs.push(vec![t]);
            target = false;
        } else {
            cur.push(t);
        }
    }
    if !cur.is_empty() {
        segs.push(cur);
    }
    Ok(segs)
}

/// `(?:^|[\s;&|(`])(?:export\s+|declare\s+-\w+\s+|env\s+)?SPL_PREPUSH_OVERRIDE=`
/// followed by anything but nothing, two quotes, a blank, ; & | or a lone 0.
fn override_raw(cmd: &str) -> bool {
    let needle = "SPL_PREPUSH_OVERRIDE=";
    cmd.match_indices(needle)
        .any(|(p, _)| override_prefix(&cmd[..p]) && override_value(&cmd[p + needle.len()..]))
}

fn boundary(s: &str) -> bool {
    s.chars().next_back().is_none_or(|c| is_space(c) || ";&|(`".contains(c))
}

fn override_prefix(before: &str) -> bool {
    if boundary(before) {
        return true;
    }
    let t = before.trim_end_matches(is_space);
    if t.len() == before.len() {
        return false;
    }
    let word_at_end = |s: &str, w: &str| s.strip_suffix(w).is_some_and(boundary);
    if word_at_end(t, "export") || word_at_end(t, "env") {
        return true;
    }
    let u = t.trim_end_matches(is_word);
    if u.len() == t.len() {
        return false;
    }
    let Some(v) = u.strip_suffix('-') else {
        return false;
    };
    let w = v.trim_end_matches(is_space);
    w.len() < v.len() && word_at_end(w, "declare")
}

fn override_value(after: &str) -> bool {
    let mut cs = after.chars();
    let Some(c0) = cs.next() else {
        return false;
    };
    let c1 = cs.next();
    let quote = |c: char| c == '"' || c == '\'';
    let stop = |c: char| is_space(c) || ";&|".contains(c);
    if quote(c0) && c1.is_some_and(quote) {
        return false;
    }
    if stop(c0) {
        return false;
    }
    !(c0 == '0' && c1.is_none_or(stop))
}

/// Every `(?<!<)<<(-?)\s*(["']?)([A-Za-z_][A-Za-z0-9_]*)\2` of a line, as
/// (dash, delimiter).
fn heredoc_marks(line: &str) -> Vec<(bool, String)> {
    let c: Vec<char> = line.chars().collect();
    let (mut out, mut p) = (Vec::new(), 0);
    while p + 1 < c.len() {
        match heredoc_at(&c, p) {
            Some((dash, word, end)) => {
                out.push((dash, word));
                p = end;
            }
            None => p += 1,
        }
    }
    out
}

fn heredoc_at(c: &[char], p: usize) -> Option<(bool, String, usize)> {
    if c[p] != '<' || c.get(p + 1) != Some(&'<') || (p > 0 && c[p - 1] == '<') {
        return None;
    }
    let mut i = p + 2;
    let dash = c.get(i) == Some(&'-');
    if dash {
        i += 1;
    }
    while c.get(i).is_some_and(|&ch| is_space(ch)) {
        i += 1;
    }
    let q = c.get(i).copied().filter(|&ch| ch == '"' || ch == '\'');
    if q.is_some() {
        i += 1;
    }
    let start = i;
    if !c.get(i).is_some_and(|ch| ch.is_ascii_alphabetic() || *ch == '_') {
        return None;
    }
    while c.get(i).is_some_and(|ch| ch.is_ascii_alphanumeric() || *ch == '_') {
        i += 1;
    }
    let word: String = c[start..i].iter().collect();
    if let Some(q) = q {
        if c.get(i) != Some(&q) {
            return None;
        }
        i += 1;
    }
    Some((dash, word, i))
}

/// A line whose words name a shell or eval reads its heredoc bodies.
fn line_runs_body(line: &str) -> bool {
    line.split(|c: char| is_space(c) || ";&|()`".contains(c)).any(|w| {
        let b = base(w.trim_matches(['"', '\'']));
        b == "eval" || SHELLS.contains(&b)
    })
}

/// Cut heredoc bodies out of cmd: a body is data, unless a shell or eval on
/// the same line reads it (bash <<EOF, cat <<EOF | sh): then it is checked.
fn heredocs(cmd: &str, depth: usize) -> Result<String, Refuse> {
    let lines: Vec<&str> = cmd.split('\n').collect();
    let (mut out, mut i) = (Vec::new(), 0);
    while i < lines.len() {
        let line = lines[i];
        out.push(line);
        i += 1;
        for (dash, word) in heredoc_marks(line) {
            let mut body = Vec::new();
            while i < lines.len() {
                let cur = lines[i];
                i += 1;
                if (if dash { cur.trim_start_matches('\t') } else { cur }) == word {
                    break;
                }
                body.push(cur);
            }
            if line_runs_body(line) {
                check(&body.join("\n"), depth + 1)?;
            }
        }
    }
    Ok(out.join("\n"))
}

/// Refuse the override assigned anything but empty or 0.
fn override_tok(tok: &str) -> R {
    let (name, eq, val) = partition_eq(tok);
    if eq && name == OVERRIDE && !val.is_empty() && val != "0" {
        return Err(override_refuse());
    }
    Ok(())
}

fn skip_wrapper(b: &str, toks: &[String], mut i: usize, depth: usize) -> Result<usize, Refuse> {
    let opts = arg_opts(b);
    while i < toks.len() && toks[i].starts_with('-') && toks[i] != "-" {
        let t = toks[i].as_str();
        if (t == "-S" || t == "--split-string") && b == "env" && i + 1 < toks.len() {
            check(&toks[i + 1], depth + 1)?;
        }
        if t == "-c" && b == "flock" && i + 1 < toks.len() {
            check(&toks[i + 1], depth + 1)?;
        }
        i += if opts.contains(&t) { 2 } else { 1 };
    }
    if (b == "timeout" || b == "flock") && i < toks.len() {
        i += 1; // the duration / the lock file
    }
    Ok(i)
}

/// `^-[A-Za-z]*c[A-Za-z]*$`: a shell's -c, alone or among short flags.
fn is_dash_c(a: &str) -> bool {
    a.strip_prefix('-')
        .is_some_and(|f| f.contains('c') && f.chars().all(|c| c.is_ascii_alphabetic()))
}

fn segment(toks: &[String], depth: usize) -> R {
    let (mut i, mut hooks) = (0, false);
    while i < toks.len() {
        let t = toks[i].as_str();
        let b = base(t);
        if is_assignment(t) {
            override_tok(t)?;
            auth_env(t)?;
            hooks = hooks || hooks_env(t);
            i += 1;
        } else if DECLARE.contains(&b) {
            return toks[i + 1..]
                .iter()
                .try_for_each(|a| override_tok(a).and_then(|_| auth_env(a)));
        } else if WRAP.contains(&b) {
            i = skip_wrapper(b, toks, i + 1, depth)?;
        } else if SHELLS.contains(&b) {
            return shell_c(&toks[i + 1..], depth);
        } else if ["eval", "ssh", "tmux", "screen"].contains(&b) {
            return check(&toks[i + 1..].join(" "), depth + 1);
        } else if b == "su" || b == "runuser" {
            return su_c(&toks[i + 1..], depth);
        } else {
            if b == "git" {
                return git(&toks[i + 1..], depth, hooks);
            }
            if !cred_file_ok(b, &toks[i + 1..]) {
                return cred_file(&toks[i..]);
            }
            return Ok(());
        }
    }
    Ok(())
}

fn shell_c(rest: &[String], depth: usize) -> R {
    for (j, a) in rest.iter().enumerate() {
        if is_dash_c(a) && j + 1 < rest.len() {
            return check(&rest[j + 1], depth + 1);
        }
    }
    Ok(())
}

fn su_c(rest: &[String], depth: usize) -> R {
    for (j, a) in rest.iter().enumerate() {
        if (a == "-c" || a == "--command") && j + 1 < rest.len() {
            check(&rest[j + 1], depth + 1)?;
        } else if let Some(c) = a.strip_prefix("--command=") {
            check(c, depth + 1)?;
        }
    }
    Ok(())
}

/// Refuse an askpass program or a credential helper set in the environment.
fn auth_env(tok: &str) -> R {
    let (name, _, val) = partition_eq(tok);
    let low = val.to_lowercase();
    if ASKPASS.contains(&name) && !val.is_empty() {
        return Err(format!("{name} improvises git auth; {NO_AUTH}"));
    }
    if is_git_config_key(name) && is_cred_key(strip(&low)) {
        return Err(format!("{name}={val} improvises git auth; {NO_AUTH}"));
    }
    if name == "GIT_CONFIG_PARAMETERS" && (low.contains("credential.") || low.contains("core.askpass")) {
        return Err(format!("GIT_CONFIG_PARAMETERS sets a git credential; {NO_AUTH}"));
    }
    Ok(())
}

/// A search or a check of the file; find only while it runs nothing.
fn cred_file_ok(b: &str, args: &[String]) -> bool {
    if b == "find" {
        return !args.iter().any(|a| a.starts_with("-exec") || a.starts_with("-ok"));
    }
    CRED_FILE_OK.contains(&b)
}

/// Refuse a .git-credentials file as an argument or a redirect target.
fn cred_file(toks: &[String]) -> R {
    if toks.iter().any(|t| base(t) == CRED_FILE && !t.chars().any(is_space)) {
        return Err(format!("{CRED_FILE} holds clear-text tokens; {NO_AUTH}"));
    }
    Ok(())
}

/// Refuse an http(s) url that carries a user or a token.
fn cred_url(args: &[String]) -> R {
    if args.iter().any(|a| is_cred_url(a)) {
        return Err(format!(
            "a url with embedded credentials improvises git auth; {NO_AUTH}"
        ));
    }
    Ok(())
}

/// Refuse git config writing a credential helper or an askpass program.
fn config(args: &[String]) -> R {
    let (mut pos, mut i) = (Vec::new(), 0);
    while i < args.len() {
        let a = args[i].as_str();
        if CONFIG_NO_WRITE.contains(&a) {
            return Ok(());
        }
        if a.starts_with('-') {
            i += if CONFIG_ARG_OPTS.contains(&a) { 2 } else { 1 };
            continue;
        }
        pos.push(a);
        i += 1;
    }
    if pos.first() == Some(&"set") {
        pos.remove(0);
    } else if pos.first().is_some_and(|p| CONFIG_NO_WRITE_VERB.contains(p)) {
        return Ok(());
    }
    if pos.len() >= 2 && !pos[1].is_empty() && is_cred_key(&pos[0].to_lowercase()) {
        return Err(format!("git config {} improvises git auth; {NO_AUTH}", pos[0]));
    }
    Ok(())
}

/// GIT_CONFIG_KEY_<n>=core.hooksPath or GIT_CONFIG_PARAMETERS naming it.
fn hooks_env(tok: &str) -> bool {
    let (name, _, val) = partition_eq(tok);
    if is_git_config_key(name) {
        return strip(val).to_lowercase() == HOOKS;
    }
    name == "GIT_CONFIG_PARAMETERS" && val.to_lowercase().contains(HOOKS)
}

fn starts_hooks(kv: &str) -> bool {
    kv.to_lowercase().starts_with(&format!("{HOOKS}="))
}

fn git(args: &[String], depth: usize, mut hooks: bool) -> R {
    let mut i = 0;
    while i < args.len() {
        let a = args[i].as_str();
        if a == "-c" && i + 1 < args.len() {
            gitcfg(&args[i + 1], depth)?;
            hooks = hooks || starts_hooks(&args[i + 1]);
            i += 2;
        } else if a.starts_with("--config-env") {
            let kv = match a.split_once('=') {
                Some((_, kv)) => kv,
                None => args.get(i + 1).map_or("", String::as_str),
            };
            hooks = hooks || starts_hooks(kv);
            i += if a.contains('=') { 1 } else { 2 };
        } else if GIT_ARG_OPTS.contains(&a) {
            i += 2;
        } else if a.starts_with('-') {
            i += 1;
        } else {
            break;
        }
    }
    git_verb(args, i, hooks)
}

fn git_verb(args: &[String], i: usize, hooks: bool) -> R {
    let verb = args.get(i).map(String::as_str);
    match verb {
        Some("push") => {
            if hooks {
                return Err(format!(
                    "git core.hooksPath on a push skips the pre-push hook; {APPROVAL}"
                ));
            }
            push(&args[i + 1..])?;
            cred_url(&args[i + 1..])
        }
        Some("config") => config(&args[i + 1..]),
        Some(v @ ("credential" | "credential-store" | "credential-cache")) => {
            Err(format!("git {v} handles stored tokens; {NO_AUTH}"))
        }
        Some("remote") if matches!(args.get(i + 1).map(String::as_str), Some("set-url" | "add")) => {
            cred_url(&args[i + 2..])
        }
        _ => Ok(()),
    }
}

/// `^remote\..+\.<what>$`
fn remote_key(k: &str, what: &str) -> bool {
    k.strip_prefix("remote.")
        .and_then(|r| r.strip_suffix(what))
        .and_then(|r| r.strip_suffix('.'))
        .is_some_and(|mid| !mid.is_empty() && !mid.contains('\n'))
}

fn gitcfg(kv: &str, depth: usize) -> R {
    let (k, _, v) = partition_eq(kv);
    let k = k.to_lowercase();
    if !v.is_empty() && is_cred_key(&k) {
        return Err(format!("git -c {k} improvises git auth; {NO_AUTH}"));
    }
    if remote_key(&k, "push") && v.starts_with('+') {
        return Err(format!("git -c {k}=+... is a forced push refspec; {APPROVAL}"));
    }
    if remote_key(&k, "mirror") {
        return Err(format!("git -c {k} turns push into --mirror; {APPROVAL}"));
    }
    if k.starts_with("alias.") {
        let c = match v.strip_prefix('!') {
            Some(rest) => rest.to_string(),
            None => format!("git {v}"),
        };
        return check(&c, depth + 1);
    }
    Ok(())
}

fn push_long(a: &str, delete: &mut bool) -> Result<usize, Refuse> {
    let name = a.split('=').next().unwrap_or(a);
    let long = name.chars().count() >= 5;
    if long && NO_VERIFY.starts_with(name) {
        return Err(format!("git push {name} skips the pre-push hook; {APPROVAL}"));
    }
    if FORCE_LONG.contains(&name) || (long && FORCE_LONG.iter().any(|f| f.starts_with(name))) {
        return Err(format!("git push {name} rewrites remote history; {APPROVAL}"));
    }
    if name == "--delete" {
        *delete = true;
    }
    Ok(if PUSH_ARG_OPTS.contains(&name) && !a.contains('=') {
        2
    } else {
        1
    })
}

fn push_short(flags: &str, delete: &mut bool) -> Result<usize, Refuse> {
    let n = flags.chars().count();
    for (j, c) in flags.chars().enumerate() {
        if c == 'f' {
            return Err(format!("git push -f is a force push; {APPROVAL}"));
        }
        if c == 'd' {
            *delete = true;
        }
        if c == 'o' {
            return Ok(if j == n - 1 { 2 } else { 1 }); // -o takes the next word
        }
    }
    Ok(1)
}

fn push(args: &[String]) -> R {
    let (mut pos, mut delete, mut i) = (Vec::<&str>::new(), false, 0);
    while i < args.len() {
        let a = args[i].as_str();
        if a == "--" {
            pos.extend(args[i + 1..].iter().map(String::as_str));
            break;
        }
        if a.starts_with("--") {
            i += push_long(a, &mut delete)?;
        } else if a.starts_with('-') && a.chars().count() > 1 {
            i += push_short(&a[1..], &mut delete)?;
        } else {
            pos.push(a);
            i += 1;
        }
    }
    for r in pos {
        if r.starts_with('+') {
            return Err(format!("git push {r} is a forced refspec (+); {APPROVAL}"));
        }
        if r.strip_prefix(':').is_some_and(|m| MASTER.contains(&m)) {
            return Err(format!("git push {r} deletes master; {APPROVAL}"));
        }
        if delete && MASTER.contains(&r.rsplit(':').next().unwrap_or(r)) {
            return Err(format!("git push --delete {r} deletes master; {APPROVAL}"));
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn refused(c: &str) -> bool {
        check_command(c).is_err()
    }

    #[test]
    fn forms() {
        assert!(refused("git push --force origin HEAD:master"));
        assert!(refused("sudo -u x bash -c \"git push -f\""));
        assert!(refused("git push origin +HEAD:master"));
        assert!(refused("SPL_PREPUSH_OVERRIDE=1 git push"));
        assert!(!refused("git push origin HEAD:master"));
        assert!(!refused("git push -n origin HEAD:master"));
        assert!(!refused("grep -n \"SPL_PREPUSH_OVERRIDE=1\" x.log"));
    }

    #[test]
    fn override_raw_forms() {
        assert!(!override_raw("x \"SPL_PREPUSH_OVERRIDE=1"));
        assert!(override_raw("x SPL_PREPUSH_OVERRIDE=1 \""));
        assert!(override_raw("declare -x SPL_PREPUSH_OVERRIDE=1 \""));
        assert!(!override_raw("aSPL_PREPUSH_OVERRIDE=1"));
        assert!(!override_raw("SPL_PREPUSH_OVERRIDE=0 \""));
        assert!(override_raw("SPL_PREPUSH_OVERRIDE=01"));
        assert!(!override_raw("SPL_PREPUSH_OVERRIDE=\"\""));
    }

    #[test]
    fn heredoc_scan() {
        assert_eq!(
            heredoc_marks("cat <<-'EOF' x <<B"),
            vec![(true, "EOF".into()), (false, "B".into())]
        );
        assert!(heredoc_marks("cat <<<x").is_empty());
        assert!(heredoc_marks("cat <<'EOF").is_empty());
    }

    #[test]
    fn nesting_fails_closed() {
        let deep = (0..10).fold(String::from("true"), |c, _| format!("eval {c}"));
        assert!(refused(&deep));
    }
}
