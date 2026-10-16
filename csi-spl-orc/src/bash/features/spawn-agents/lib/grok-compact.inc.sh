#!/usr/bin/env bash
# grok-compact.inc.sh — the grok context cap (SPL-2215, grok token burn 2/6).
#
# Grok Build compacts a session (a summary of the older turns plus the recent
# ones) when its context reaches [session] auto_compact_threshold_percent of
# the model's window; the model default is 80% of 256000 = 204800 tokens
# (~/.grok/models_cache.json, grok 1.0.60). Measured on sat 2026-10-16: a grok
# lane grows ~2.2k tokens a model call and every call re-reads the whole
# context, so the cap decides what a long lane costs
# (csi-spl-doc/doc/md/grok-token-burn/02-context-growth.md).
#
#   grok_compact_cnf CNF          env.box.grok_cli.auto_compact_threshold_percent
#                                 of the cnf file CNF, else empty
#   grok_compact_apply TOML PCT   write `auto_compact_threshold_percent = PCT`
#                                 under [session] in grok's config.toml TOML,
#                                 marked as ours; PCT empty removes OUR line
#                                 (grok's default comes back). A line without
#                                 our marker was set by hand and is kept.
#                                 Idempotent; one status line on stderr.
#                                 Returns 0 (written, current or kept), 2 a
#                                 bad PCT, 7 the file cannot be written.
#
# The GROK_CONFIG overlay cannot carry it: grok allowlists only models,
# features, toolset and shell_environment_policy there
# (~/.grok/docs/user-guide/05-configuration.md), so it goes into config.toml.

GROK_COMPACT_MARK='# spool-harness: cnf env.box.grok_cli (SPL-2215)'

grok_compact_cnf() {  # CNF
  [ -r "$1" ] || return 0
  awk '
    /^[[:space:]]*grok_cli:[[:space:]]*$/ { match($0, /^[[:space:]]*/); ind = RLENGTH; on = 1; next }
    on { match($0, /^[[:space:]]*/); if (RLENGTH <= ind && $0 ~ /[^[:space:]]/ && $0 !~ /^[[:space:]]*#/) exit }
    on && /^[[:space:]]*auto_compact_threshold_percent:/ {
      sub(/^[[:space:]]*auto_compact_threshold_percent:[[:space:]]*/, ""); sub(/[[:space:]]*(#.*)?$/, ""); gsub(/["'\'']/, ""); print; exit }
  ' "$1"
}

grok_compact_apply() {  # TOML PCT
  local toml="$1" pct="${2:-}"
  if [ -n "$pct" ] && ! { [[ "$pct" =~ ^[0-9]+$ ]] && [ "$pct" -ge 1 ] && [ "$pct" -le 100 ]; }; then
    echo "grok-compact: auto_compact_threshold_percent must be 1..100, got '$pct': config left alone" >&2
    return 2
  fi
  mkdir -p "$(dirname "$toml")" 2>/dev/null || true
  python3 - "$toml" "$pct" "$GROK_COMPACT_MARK" <<'EOF_PY'
import os, re, sys
path, pct, mark = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    text = open(path).read()
except FileNotFoundError:
    text = ""
except OSError as e:
    print("grok-compact: cannot read %s: %s" % (path, e), file=sys.stderr); sys.exit(7)
lines = text.splitlines(keepends=True)
key = re.compile(r"^\s*auto_compact_threshold_percent\s*=")
start = end = None
for i, l in enumerate(lines):
    if start is None and re.match(r"^\s*\[session\]\s*(#.*)?$", l):
        start = i
    elif start is not None and end is None and re.match(r"^\s*\[", l):
        end = i
if start is not None and end is None:
    end = len(lines)
mine = hand = None
if start is not None:
    for i in range(start + 1, end):
        if key.match(lines[i]):
            if mark in lines[i]: mine = i
            else: hand = i
want = "auto_compact_threshold_percent = %s  %s\n" % (pct, mark) if pct else ""
if hand is not None:
    print("grok-compact: %s sets auto_compact_threshold_percent by hand (%s): kept"
          % (path, lines[hand].split("=", 1)[1].strip()), file=sys.stderr); sys.exit(0)
if mine is not None and lines[mine] == want:
    print("grok-compact: %s already at %s%%" % (path, pct), file=sys.stderr); sys.exit(0)
if mine is None and not pct:
    sys.exit(0)
if mine is not None:
    lines[mine:mine + 1] = [want] if want else []
elif start is not None:
    lines.insert(start + 1, want)
else:
    if lines and not lines[-1].endswith("\n"): lines[-1] += "\n"
    lines += (["\n"] if lines else []) + ["[session]\n", want]
new = "".join(lines)
try:
    import tomllib
    tomllib.loads(new)
except ImportError:
    pass
except ValueError as e:
    print("grok-compact: %s would not parse (%s): left alone" % (path, e), file=sys.stderr); sys.exit(7)
tmp = "%s.tmp.%d" % (path, os.getpid())
try:
    with open(tmp, "w") as f: f.write(new)
    os.chmod(tmp, os.stat(path).st_mode & 0o7777 if os.path.exists(path) else 0o600)
    os.replace(tmp, path)
except OSError as e:
    print("grok-compact: cannot write %s: %s" % (path, e), file=sys.stderr); sys.exit(7)
print("grok-compact: %s %s" % (path, "auto_compact_threshold_percent = %s%%" % pct if pct
      else "our auto_compact_threshold_percent removed (grok default)"), file=sys.stderr)
EOF_PY
}
