#!/usr/bin/env bash
# spool-mirror-hooks.inc.sh — the terminal mirror's CLI hooks (specs/036), one
# copy for every launcher: spool-agent.sh, and spool-harness.sh --mirror (what
# every spawn and every restore goes through).
#
#   smh_hooks_json PY            the claude-shaped hooks object (UserPromptSubmit
#                                + Stop), each running `PY hook`; a no-op when PY
#                                is gone (a moved checkout must not print a hook
#                                error on every prompt)
#   smh_agy_merge FILE PY        merge the named hook "spool-mirror" into agy's
#                                ~/.gemini/config/hooks.json; others kept
#   smh_qwen_merge FILE PY       merge the mirror entries into ~/.qwen/settings.json;
#                                an older spool-mirror entry replaced, all else kept
#   smh_vibe_merge FILE PY       merge the [[hooks]] entry "spool-mirror" (post_agent)
#                                and the heartbeat entries "spool-heartbeat-*" (PY's
#                                sibling spool-agent-hook.sh) into mistral vibe's
#                                ~/.vibe/hooks.toml; others kept
#   smh_user_hooked KIND         0 when the user's own settings already carry the
#                                mirror (claude and grok read ~/.claude/settings.json,
#                                qwen its own): a second copy would fire twice
#   smh_install KIND ID PY       write what KIND needs for this session and set
#                                SMH_ARGS (extra CLI args: claude's --settings
#                                <file>) and SMH_WHERE (where the hooks live).
#                                Non-zero when nothing could be written.
#
# Env: SMH_STATE_DIR (default $XDG_STATE_HOME or ~/.local/state, /spool-agent),
#      SPOOL_AGENT_USER_SETTINGS, SPOOL_AGENT_AGY_HOOKS, SPOOL_AGENT_QWEN_SETTINGS,
#      SPOOL_AGENT_VIBE_HOOKS (default $VIBE_HOME or ~/.vibe, /hooks.toml).

smh_hooks_json() {  # PY
  python3 - "$1" <<'EOF_PY'
import json, shlex, sys
p = shlex.quote(sys.argv[1])
cmd = f"[ -r {p} ] && exec python3 {p} hook; exit 0"
h = [{"hooks": [{"type": "command", "command": cmd, "timeout": 10}]}]
print(json.dumps({"hooks": {"UserPromptSubmit": h, "Stop": h}}, indent=2, sort_keys=True))
EOF_PY
}

# agy (antigravity) reads ~/.gemini/config/hooks.json: named hooks, each with
# its event lists (measured, agy 1.2.11). Its payloads carry no text and no
# event name, so the command names the event; spool-mirror.py reads the
# transcript.
smh_agy_merge() {  # FILE PY
  mkdir -p "$(dirname "$1")" && python3 - "$1" "$2" <<'EOF_PY'
import json, os, shlex, sys, time
path, py = sys.argv[1], shlex.quote(sys.argv[2])
try:
    d = json.load(open(path))
    if not isinstance(d, dict):
        raise ValueError
except FileNotFoundError:
    d = {}
except ValueError:
    # Not a hooks file agy can load, so it holds no hook to keep: moved aside
    # (never deleted), and the file is written fresh.
    os.replace(path, path + ".bad." + time.strftime("%Y%m%dT%H%M%SZ", time.gmtime()))
    d = {}
def h(ev):
    return [{"type": "command", "command": f"[ -r {py} ] && exec python3 {py} hook --agy {ev}; echo '{{}}'", "timeout": 10}]
d["spool-mirror"] = {"PreInvocation": h("pre"), "Stop": h("stop")}
tmp = path + ".tmp.%d" % os.getpid()
open(tmp, "w").write(json.dumps(d, indent=2) + "\n")
os.replace(tmp, path)
EOF_PY
}

# qwen (0.24.6) runs claude-shaped UserPromptSubmit / Stop hooks from
# ~/.qwen/settings.json, with claude's payload fields (prompt,
# last_assistant_message).
smh_qwen_merge() {  # FILE PY
  mkdir -p "$(dirname "$1")" && smh_hooks_json "$2" | python3 -c '
import json, os, sys, time
path = sys.argv[1]
new = json.load(sys.stdin)["hooks"]
try:
    d = json.load(open(path))
    if not isinstance(d, dict):
        raise ValueError
except FileNotFoundError:
    d = {}
except ValueError:
    os.replace(path, path + ".bad." + time.strftime("%Y%m%dT%H%M%SZ", time.gmtime()))
    d = {}
hk = d.setdefault("hooks", {})
for ev, entries in new.items():
    hk[ev] = [e for e in hk.get(ev, []) if "spool-mirror.py" not in json.dumps(e)] + entries
tmp = path + ".tmp.%d" % os.getpid()
open(tmp, "w").write(json.dumps(d, indent=2) + "\n")
os.replace(tmp, path)
' "$1"
}

# mistral vibe (2.26.0) runs [[hooks]] from ~/.vibe/hooks.toml. It has no
# prompt hook: post_agent fires once per turn, after the answer, with
# session_id and transcript_path on stdin, and spool-mirror.py --vibe reads
# both halves of the turn from the session (specs/110 3.4). A hook must print
# nothing or a JSON object, so the no-op branch prints nothing.
# The heartbeat (specs/093 5.2): the claude hook script, one entry per vibe
# hook point (pre_tool, post_tool, post_agent as claude's PreToolUse,
# PostToolUse, Stop), so the watchdog reads <id>/heartbeat.json for an m- lane
# too. vibe passes its own env to a hook, SPOOL_AGENT_ID included.
smh_vibe_merge() {  # FILE PY
  mkdir -p "$(dirname "$1")" && python3 - "$1" "$2" "$(dirname "$2")/spool-agent-hook.sh" <<'EOF_PY'
import json, os, re, shlex, sys, time
path, py, hk = sys.argv[1], shlex.quote(sys.argv[2]), shlex.quote(sys.argv[3])
try:
    text = open(path).read()
except FileNotFoundError:
    text = ""
try:
    import tomllib
    tomllib.loads(text)
except ImportError:
    pass
except ValueError:
    # Not a hooks file vibe can load, so it holds no hook to keep: moved
    # aside (never deleted), and the file is written fresh.
    os.replace(path, path + ".bad." + time.strftime("%Y%m%dT%H%M%SZ", time.gmtime()))
    text = ""
# Drop our older blocks: a [[hooks]] table up to the next header.
blocks = re.split(r"(?m)^(?=\[)", text)
keep = [b for b in blocks if not (b.startswith("[[hooks]]") and re.search(r'(?m)^name\s*=\s*"spool-(mirror|heartbeat-[a-z-]+)"\s*$', b))]
text = "".join(keep).rstrip("\n")
def entry(name, typ, cmd, timeout):
    return '[[hooks]]\nname = "%s"\ntype = "%s"\ncommand = %s\ntimeout = %s\n' % (name, typ, json.dumps(cmd), timeout)
ents = [entry("spool-mirror", "post_agent", f"[ -r {py} ] && exec python3 {py} hook --vibe; exit 0", "10.0")]
for typ, ev in (("pre_tool", "PreToolUse"), ("post_tool", "PostToolUse"), ("post_agent", "Stop")):
    ents.append(entry("spool-heartbeat-" + typ.replace("_", "-"), typ,
                      f"[ -r {hk} ] && SPOOL_HARNESS=vibe exec bash {hk} {ev}; exit 0", "5.0"))
text = (text + "\n\n" if text else "") + "\n".join(ents)
tmp = path + ".tmp.%d" % os.getpid()
fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w") as f:
    f.write(text)
os.replace(tmp, path)
EOF_PY
}

smh_qwen_settings() { printf '%s' "${SPOOL_AGENT_QWEN_SETTINGS:-$HOME/.qwen/settings.json}"; }
smh_vibe_hooks()    { printf '%s' "${SPOOL_AGENT_VIBE_HOOKS:-${VIBE_HOME:-$HOME/.vibe}/hooks.toml}"; }
smh_agy_hooks()     { printf '%s' "${SPOOL_AGENT_AGY_HOOKS:-$HOME/.gemini/config/hooks.json}"; }

smh_user_hooked() {  # KIND
  case "$1" in
    claude|grok) grep -q 'spool-mirror\.py' "${SPOOL_AGENT_USER_SETTINGS:-$HOME/.claude/settings.json}" 2>/dev/null ;;
    qwen) grep -q 'spool-mirror\.py' "$(smh_qwen_settings)" 2>/dev/null ;;
    *) return 1 ;;
  esac
}

smh_install() {  # KIND ID PY
  local kind="$1" id="$2" py="$3" dir f
  SMH_ARGS=(); SMH_WHERE=""
  dir="${SMH_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/spool-agent}"
  case "$kind" in
    claude)
      if smh_user_hooked claude; then SMH_WHERE="~/.claude/settings.json"; return 0; fi
      # One file per agent: two launches from two checkouts never race on it.
      f="$dir/mirror-hooks-$id.json"
      mkdir -p "$dir" && smh_hooks_json "$py" >"$f.tmp.$$" && mv -f "$f.tmp.$$" "$f" || { rm -f "$f.tmp.$$"; return 1; }
      SMH_ARGS=(--settings "$f"); SMH_WHERE="$f" ;;
    grok)
      if smh_user_hooked grok; then SMH_WHERE="~/.claude/settings.json"; return 0; fi
      f="$HOME/.grok/hooks/spool-mirror.json"
      mkdir -p "${f%/*}" && smh_hooks_json "$py" >"$f.tmp.$$" && mv -f "$f.tmp.$$" "$f" || { rm -f "$f.tmp.$$"; return 1; }
      SMH_WHERE="$f" ;;
    agy)  f="$(smh_agy_hooks)"; smh_agy_merge "$f" "$py" || return 1; SMH_WHERE="$f" ;;
    qwen) f="$(smh_qwen_settings)"; smh_qwen_merge "$f" "$py" || return 1; SMH_WHERE="$f" ;;
    mistral) f="$(smh_vibe_hooks)"; smh_vibe_merge "$f" "$py" || return 1; SMH_WHERE="$f" ;;
    *) return 1 ;;
  esac
}
