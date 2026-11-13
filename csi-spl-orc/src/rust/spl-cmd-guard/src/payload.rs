//! The hook payload extractor: the inline Python of
//! `force-push-guard-hook.sh`, the same answer for every harness shape.

use crate::json::{self, JsonError, Value};

const SHELL: [&str; 6] = [
    "bash",
    "run_terminal_command",
    "run_shell_command",
    "shell",
    "shelltool",
    "run_command",
];
const CMD_KEYS: [&str; 4] = ["command", "CommandLine", "commandLine", "cmd"];

/// What the payload asks.
#[derive(Debug, PartialEq, Eq)]
pub enum Call {
    /// Not a shell call: not ours.
    NotShell,
    /// A shell call and its command, as bash hands it to the matcher.
    Cmd(String),
    /// Unreadable (the Python exits non-zero): the hook refuses.
    Unreadable,
}

/// The tool name, as `str(a or b or c or d)`: the first truthy candidate;
/// a non-string one can never name a shell tool.
fn tool_name(d: &Value, call: &Value) -> String {
    let cands = [
        d.get("tool_name"),
        d.get("toolName"),
        call.get("name"),
        call.get("toolName"),
    ];
    match cands.into_iter().flatten().find(|v| v.truthy()) {
        Some(Value::Str { s, .. }) => s.clone(),
        Some(_) => String::from("\u{0}not-a-string"),
        None => String::new(),
    }
}

/// The first of tool_input, toolInput, toolCall.args/arguments/input that
/// is (or, as a string, parses to or wraps into) an object.
fn tool_args(d: &Value, call: &Value) -> Result<Option<Value>, JsonError> {
    let srcs = [
        (d, "tool_input"),
        (d, "toolInput"),
        (call, "args"),
        (call, "arguments"),
        (call, "input"),
    ];
    for (src, k) in srcs {
        let v = match src.get(k) {
            Some(Value::Str { s, lone }) => match json::parse(s) {
                Ok(v) => v,
                Err(JsonError::Recursion) => return Err(JsonError::Recursion),
                Err(JsonError::Decode) => Value::Obj(vec![(
                    "command".into(),
                    Value::Str {
                        s: s.clone(),
                        lone: *lone,
                    },
                )]),
            },
            Some(v) => v.clone(),
            None => continue,
        };
        if matches!(v, Value::Obj(_)) {
            return Ok(Some(v));
        }
    }
    Ok(None)
}

/// bash `$(...)` on the printed command: NUL bytes dropped, trailing
/// newlines stripped.
fn as_bash_reads_it(cmd: &str) -> String {
    cmd.replace('\0', "").trim_end_matches('\n').to_string()
}

/// Read one hook payload.
pub fn extract(payload: &str) -> Call {
    let Ok(d) = json::parse(payload) else {
        return Call::Unreadable;
    };
    if !matches!(d, Value::Obj(_)) {
        return Call::Unreadable;
    }
    let empty = Value::Obj(Vec::new());
    let call = match d.get("toolCall") {
        Some(v @ Value::Obj(_)) => v,
        _ => &empty,
    };
    let name = tool_name(&d, call);
    let Ok(args) = tool_args(&d, call) else {
        return Call::Unreadable;
    };
    let cmd = args.as_ref().and_then(|a| {
        CMD_KEYS.iter().find_map(|k| match a.get(k) {
            Some(Value::Str { s, lone }) => Some((s.clone(), *lone)),
            _ => None,
        })
    });
    match cmd {
        // Python cannot print a lone surrogate: it exits 1.
        Some((_, true)) => Call::Unreadable,
        Some((s, false)) => Call::Cmd(as_bash_reads_it(&s)),
        None if SHELL.contains(&name.to_lowercase().as_str()) => Call::Unreadable,
        None => Call::NotShell,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cmd(s: &str) -> Call {
        Call::Cmd(s.into())
    }

    #[test]
    fn harness_shapes() {
        assert_eq!(
            extract(r#"{"tool_name":"Bash","tool_input":{"command":"git status"}}"#),
            cmd("git status")
        );
        assert_eq!(extract(r#"{"toolName":"x","toolInput":{"command":"ls"}}"#), cmd("ls"));
        assert_eq!(
            extract(r#"{"toolCall":{"name":"run_command","args":{"CommandLine":"ls"}}}"#),
            cmd("ls")
        );
        assert_eq!(extract(r#"{"toolCall":{"args":"{\"cmd\":\"ls\"}"}}"#), cmd("ls"));
        assert_eq!(extract(r#"{"tool_input":"git push"}"#), cmd("git push"));
    }

    #[test]
    fn not_ours_and_unreadable() {
        assert_eq!(
            extract(r#"{"tool_name":"Read","tool_input":{"file_path":"x"}}"#),
            Call::NotShell
        );
        assert_eq!(extract(r#"{"tool_name":"Bash","tool_input":{}}"#), Call::Unreadable);
        assert_eq!(extract("[1]"), Call::Unreadable);
        assert_eq!(extract(""), Call::Unreadable);
        assert_eq!(extract(r#"{"tool_input":{"command":"\ud800"}}"#), Call::Unreadable);
    }

    #[test]
    fn string_args_that_parse_to_a_non_object_fall_through() {
        assert_eq!(
            extract(r#"{"tool_input":"\"x\"","toolInput":{"command":"y"}}"#),
            cmd("y")
        );
        assert_eq!(extract(r#"{"tool_name":"bash","tool_input":"5"}"#), Call::Unreadable);
    }

    #[test]
    fn bash_reads_the_output() {
        assert_eq!(extract(r#"{"tool_input":{"command":"a\u0000b\n\n"}}"#), cmd("ab"));
    }
}
