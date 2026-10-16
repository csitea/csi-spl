#!/usr/bin/env bash
#------------------------------------------------------------------------------
# spool-install step Y15: the Mistral Vibe output cap (SPL-2217).
#
#   spool_install_vibe_output_cap <vibe-home> <dry 0|1>
#
# Copies assets/vibe-output-cap/vibe-output-cap.py into
# <vibe-home>/spool-output-cap/ and merges ONE [[hooks]] entry into
# <vibe-home>/hooks.toml:
#     name = "spool-output-cap", type = "post_tool", match = "*bash"
# Why: vibe resends the whole context on every completion, so a long bash
# result (a test log) is paid for again on every later turn of the lane.
# The hook keeps the return code, the head and the tail of a result longer
# than VIBE_OUTPUT_CAP_CHARS (4000) and writes the whole output to a log file
# the model can grep. Measured: csi-spl-doc/doc/md/vibe-output-cap.md.
# Not strict: a failing hook leaves the result as it was (fail open).
# Every other hooks.toml entry is kept. Idempotent: a current install says so
# and writes nothing. A <vibe-home> that does not exist is skipped.
# SPOOL_INSTALL_VIBE_OUTPUT_CAP=0 skips the step.
#------------------------------------------------------------------------------
spool_install_vibe_output_cap() {
  local home="$1" dry="${2:-0}" here src dir n changed=0 toml_rc
  if [ "${SPOOL_INSTALL_VIBE_OUTPUT_CAP:-1}" = 0 ]; then
    echo "spool-install: vibe output cap: skipped (SPOOL_INSTALL_VIBE_OUTPUT_CAP=0)" >&2
    return 0
  fi
  if [ ! -d "$home" ]; then
    echo "spool-install: vibe output cap: skipped (no $home)" >&2
    return 0
  fi
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  src="$here/../assets/vibe-output-cap/vibe-output-cap.py"
  [ -r "$src" ] || { echo "spool-install: vibe output cap: $src missing" >&2; return 7; }
  dir="$home/spool-output-cap"
  n="$dir/vibe-output-cap.py"
  if ! { [ -f "$n" ] && cmp -s "$src" "$n"; }; then
    changed=1
    if [ "$dry" = 1 ]; then
      echo "would: install $n"
    else
      mkdir -p "$dir" && cp "$src" "$n.tmp" && chmod 755 "$n.tmp" && mv -f "$n.tmp" "$n" || return 7
      echo "spool-install: vibe output cap: $n" >&2
    fi
  fi
  python3 - "$home/hooks.toml" "$n" "$dry" <<'EOF_PY'
import json, os, re, shlex, sys
path, hook, dry = sys.argv[1], sys.argv[2], sys.argv[3] == "1"
try:
    text = open(path).read()
except FileNotFoundError:
    text = ""
want = ('[[hooks]]\nname = "spool-output-cap"\ntype = "post_tool"\nmatch = "*bash"\n'
        'timeout = 10.0\ncommand = %s\n' % json.dumps("exec python3 " + shlex.quote(hook)))
blocks = re.split(r"(?m)^(?=\[)", text)
mine = [b for b in blocks if b.startswith("[[hooks]]") and re.search(r'(?m)^name\s*=\s*"spool-output-cap"\s*$', b)]
if len(mine) == 1 and mine[0].rstrip("\n") == want.rstrip("\n"):
    sys.exit(0)
if dry:
    print("would: write the spool-output-cap post_tool hook into %s" % path)
    sys.exit(3)
body = "".join(b for b in blocks if b not in mine).rstrip("\n")
tmp = path + ".tmp.%d" % os.getpid()
fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w") as f:
    f.write((body + "\n\n" if body else "") + want)
os.replace(tmp, path)
print("spool-install: vibe output cap: hook entry written to %s" % path, file=sys.stderr)
sys.exit(3)
EOF_PY
  toml_rc=$?
  case "$toml_rc" in 0) ;; 3) changed=1 ;; *) return 7 ;; esac
  [ "$changed" = 0 ] && echo "spool-install: vibe output cap: $home already current" >&2
  return 0
}
