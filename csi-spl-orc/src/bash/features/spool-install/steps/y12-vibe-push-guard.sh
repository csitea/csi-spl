#!/usr/bin/env bash
#------------------------------------------------------------------------------
# spool-install step Y12: the Mistral Vibe push guard (owner order, t1
# 4e373f5d: nobody force-pushes master without the owner's explicit approval).
#
#   spool_install_vibe_push_guard <vibe-home> <dry 0|1>
#
# Copies assets/vibe-push-guard/vibe-push-guard.py and the shared matcher
# spawn-agents/lib/force-push-guard.inc.sh into <vibe-home>/spool-push-guard/,
# and merges ONE [[hooks]] entry into <vibe-home>/hooks.toml:
#     name = "spool-push-guard", type = "pre_tool", match = "*", strict = true
# Why a hook and not [tools.bash] denylist: every m- seat runs vibe
# --auto-approve, and vibe 2.26.0 returns EXECUTE before it reads the denylist
# when tool permissions are bypassed (agent_loop/_loop.py _should_execute_tool:
# "if self.bypass_tool_permissions: return ToolDecision(verdict=EXECUTE ...)"),
# while the pre_tool pipeline runs before that check
# (_run_pre_tool_pipeline, then _should_execute_tool). strict = true makes any
# hook failure a deny (vibe skill doc: "pre_tool | Deny the tool call with the
# failure reason"), so the guard fails closed.
# Every other hooks.toml entry (the spool-mirror / heartbeat ones the launcher
# rewrites) is kept. Copies, not links: a moved checkout cannot switch it off.
# Idempotent: a current install says so and writes nothing. A <vibe-home>
# that does not exist (no vibe for this user) is skipped.
# SPOOL_INSTALL_VIBE_PUSH_GUARD=0 skips the step.
#------------------------------------------------------------------------------
spool_install_vibe_push_guard() {
  local home="$1" dry="${2:-0}" here src_py src_m dir f n changed=0 toml_rc
  if [ "${SPOOL_INSTALL_VIBE_PUSH_GUARD:-1}" = 0 ]; then
    echo "spool-install: vibe push guard: skipped (SPOOL_INSTALL_VIBE_PUSH_GUARD=0)" >&2
    return 0
  fi
  if [ ! -d "$home" ]; then
    echo "spool-install: vibe push guard: skipped (no $home)" >&2
    return 0
  fi
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  src_py="$here/../assets/vibe-push-guard/vibe-push-guard.py"
  src_m="$here/../../spawn-agents/lib/force-push-guard.inc.sh"
  if [ ! -r "$src_py" ] || [ ! -r "$src_m" ]; then
    echo "spool-install: vibe push guard: sources missing" >&2
    return 7
  fi
  dir="$home/spool-push-guard"
  for f in "$src_py" "$src_m"; do
    n="$dir/$(basename "$f")"
    if [ -f "$n" ] && cmp -s "$f" "$n"; then continue; fi
    changed=1
    if [ "$dry" = 1 ]; then echo "would: install $n"; continue; fi
    mkdir -p "$dir" && cp "$f" "$n.tmp" && chmod 755 "$n.tmp" && mv -f "$n.tmp" "$n" || return 7
    echo "spool-install: vibe push guard: $n" >&2
  done
  python3 - "$home/hooks.toml" "$dir/vibe-push-guard.py" "$dry" <<'EOF_PY'
import json, os, re, shlex, sys, time
path, hook, dry = sys.argv[1], sys.argv[2], sys.argv[3] == "1"
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
    if dry:
        print("would: move the unreadable %s aside and write it fresh" % path)
        sys.exit(3)
    os.replace(path, path + ".bad." + time.strftime("%Y%m%dT%H%M%SZ", time.gmtime()))
    text = ""
want = ('[[hooks]]\nname = "spool-push-guard"\ntype = "pre_tool"\nmatch = "*"\nstrict = true\n'
        'timeout = 30.0\ncommand = %s\n' % json.dumps("exec python3 " + shlex.quote(hook)))
blocks = re.split(r"(?m)^(?=\[)", text)
mine = [b for b in blocks if b.startswith("[[hooks]]") and re.search(r'(?m)^name\s*=\s*"spool-push-guard"\s*$', b)]
if len(mine) == 1 and mine[0].rstrip("\n") == want.rstrip("\n"):
    sys.exit(0)
if dry:
    print("would: write the spool-push-guard pre_tool hook into %s" % path)
    sys.exit(3)
keep = [b for b in blocks if b not in mine]
body = "".join(keep).rstrip("\n")
out = (body + "\n\n" if body else "") + want
tmp = path + ".tmp.%d" % os.getpid()
fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w") as f:
    f.write(out)
os.replace(tmp, path)
print("spool-install: vibe push guard: hook entry written to %s" % path, file=sys.stderr)
sys.exit(3)
EOF_PY
  toml_rc=$?
  case "$toml_rc" in 0) ;; 3) changed=1 ;; *) return 7 ;; esac
  [ "$changed" = 0 ] && echo "spool-install: vibe push guard: $home already current" >&2
  return 0
}
