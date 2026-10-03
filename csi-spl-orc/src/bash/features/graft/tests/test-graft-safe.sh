#!/usr/bin/env bash
# The wrapper is the enforcement. Every assertion here is a way source leaves
# this box if the wrapper stops doing its job, so each one names the leak.
#
# A stub stands in for graft: the point is what the wrapper does to the
# environment and the argv, not what graft does with them.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
SAFE="$SCRIPTS/graft-safe.sh"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
# Outside any git repo: inside one the wrapper adds --dir <out-of-tree index>
# (test-graft-index-dir.sh), and these assertions are about argv passing through.
cd "$TMP" || exit 1
cat > "$TMP/stub" <<'STUB'
#!/usr/bin/env bash
echo "ARGV:$*"
echo "DNT:${DO_NOT_TRACK-unset} NOPROXY:${NO_PROXY-unset} HTTPS:${https_proxy-unset} KEY:${GRAFT_API_KEY-unset}"
STUB
chmod 755 "$TMP/stub"
run() { GRAFT_SAFE_BIN="$TMP/stub" bash "$SAFE" "$@" 2>&1; }

out=$(GRAFT_SAFE_BIN="$TMP/stub" GRAFT_API_KEY=sk-secret https_proxy=http://p:3128 \
      bash "$SAFE" grep foo 2>&1); rc=$?
is "$rc" 0 "an ordinary command passes through"
has "$out" "ARGV:grep foo"  "argv reaches graft unchanged"
has "$out" "DNT:1"          "telemetry off: DO_NOT_TRACK forced"
has "$out" "NOPROXY:*"      "no route out: NO_PROXY=*"
has "$out" "HTTPS:unset"    "an inherited proxy is cleared, not passed through"
has "$out" "KEY:unset"      "the API key is cleared so a --deep slip fails loudly"

# init is the one that writes .mcp.json (npx -y from the public registry) and a
# repo .claude/settings.json -- and it does it even with the opt-out flags, so
# the flags must not buy their way past the refusal.
for a in "init" "init --no-mcp --no-hooks --no-statusline --agents claude" "init --dry-run"; do
  # shellcheck disable=SC2086
  out=$(run $a); rc=$?
  is "$rc" 78 "refused: graft $a"
  has "$out" "refused" "and says so: graft $a"
  hasnt "$out" "ARGV:" "graft was never reached: graft $a"
done

out=$(run upgrade); is "$?" 78 "refused: upgrade installs from the public npm registry"
has "$out" "refused" "and says why upgrade is refused"
out=$(run search x --deep); is "$?" 78 "refused: --deep sends source to a model API"
out=$(run search x --deep=2); is "$?" 78 "refused: --deep= with a value"
out=$(run --deep-research x); is "$?" 78 "refused: anything spelling 'deep' is treated as --deep"

# Passing through what should pass through matters as much as refusing: a
# wrapper that blocks real work gets removed from PATH within the week.
# `version` only probes npm for a newer release; with no route out it reports
# "latest: unreachable" rather than reaching anything, so it stays allowed --
# refusing it would cost the one command that reports what is installed.
for a in "ask needle" "build" "skeleton f.sh" "check" "version" "--help" "deepen-nothing"; do
  # shellcheck disable=SC2086
  run $a >/dev/null 2>&1
  is "$?" 0 "allowed: graft $a"
done

# A refusal must never look like "no results". 78 is EX_CONFIG, distinct from
# graft's own exit codes and from 0/1.
out=$(run init); is "$?" 78 "refusal exit is 78, not 0 and not 1"

# No binary is a loud failure, not a silent no-op.
out=$(GRAFT_SAFE_BIN=/nonexistent/graft bash "$SAFE" grep x 2>&1); is "$?" 78 "missing binary refuses"
has "$out" "no graft binary" "and says the binary is missing"

# The wrapper installs AS `graft`, so a search that accepted a plain `graft`
# would find itself. Exec'ing yourself hangs rather than errors, which is the
# one failure nobody debugs quickly -- so it is refused explicitly.
out=$(GRAFT_SAFE_BIN="$SAFE" bash "$SAFE" ask x 2>&1); is "$?" 78 "refuses to exec itself"
has "$out" "exec forever" "and names the loop"

# With nothing set at all it must still refuse rather than pick a plain graft
# off PATH -- on this box that plain graft IS this wrapper.
#
# HERMETIC, every candidate pointed at an empty dir. The wrapper does not search
# PATH: it checks $HOME/.local/bin, $GRAFT_REAL_HOME/.local/bin, the system dir
# (/usr/local/bin unless GRAFT_SAFE_SYSTEM_DIR). Clearing
# only HOME and GRAFT_REAL_HOME passed on a box with no system graft.real and
# FAILED on one that had /usr/local/bin/graft.real (got 0, want 78, 2026-09-17).
mkdir -p "$TMP/emptybin" "$TMP/sysbin"
cp "$TMP/stub" "$TMP/sysbin/graft.real"
bare() {  # DIR ARGS — the wrapper with every candidate but DIR's empty
  local dir="$1"; shift
  env -u GRAFT_SAFE_BIN HOME="$TMP/nohome" GRAFT_REAL_HOME= \
      GRAFT_SAFE_SYSTEM_DIR="$dir" PATH="$TMP/emptybin:/usr/bin:/bin" bash "$SAFE" "$@" 2>&1
}
out=$(bare "$TMP/sysbin" ask x); rc=$?
is "$rc" 0 "control: a graft.real in the system dir IS found (the seam steers the search)"
has "$out" "ARGV:ask x" "control: ... and it is the one that runs"
out=$(bare "$TMP/emptybin" ask x)
is "$?" 78 "with no graft.real anywhere it refuses rather than guessing"

# The escape hatch exists and is explicit.
out=$(GRAFT_SAFE_BIN="$TMP/stub" GRAFT_SAFE_ALLOW_PROXY=1 https_proxy=http://p:3128 \
      bash "$SAFE" grep x 2>&1)
has "$out" "HTTPS:http://p:3128" "GRAFT_SAFE_ALLOW_PROXY=1 keeps the proxy, explicitly"

finish
