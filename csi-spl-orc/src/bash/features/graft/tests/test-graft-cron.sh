#!/usr/bin/env bash
# test-graft-cron.sh -- the scheduled re-index (spec 069 C3, C4) runs from
# csi-spl alone: graft-cron.sh -> graft-index-update.sh -> graft-common.inc.sh.
# A sandbox HOME carries a stub graft; no real graft runs, nothing outside $T
# is written.
#
#   resolve   args > GRAFT_REGISTRY > $GRAFT_VAR_ROOT/repos.list, comments and
#             blanks dropped; a missing list is named
#   log/lock  under $GRAFT_VAR_ROOT by default; GRAFT_CRON_LOG / _LOCK win
#   tick      the stub launcher is wrapped by graft-safe.sh, each repo is built
#             with --dir <out-of-tree index>, the log carries START/END rv=0
#   skip      an unchanged-repo stamp is not trusted without a lib (rebuilds),
#             and a held lock makes the tick SKIP, not pile up
#   hygiene   no script or asset names the engine, a home or /var/tmp
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

C="$SCRIPTS/graft-cron.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
T="$(cd "$T" && pwd -P)"
mkdir -p "$T/var" "$T/home/.local/bin" "$T/src/repo-a" "$T/src/repo-b" "$T/src/plain"
git -C "$T/src/repo-a" init -q; git -C "$T/src/repo-b" init -q
printf '# the box repo list\n%s\n\n  %s   # trailing comment\n%s\n' "$T/src/repo-a" "$T/src/repo-b" "$T/src/plain" > "$T/var/repos.list"
printf '%s\n' "$T/src/repo-b" > "$T/envlist"
cat > "$T/home/.local/bin/graft" <<STUB
#!/usr/bin/env bash
echo "ARGV:\$*" >> "$T/argv"
[ "\${1:-}" = --dir ] && mkdir -p "\$2/.graph" && echo '{"n":1}' > "\$2/.graph/wiring.json"
exit 0
STUB
chmod 755 "$T/home/.local/bin/graft"

cron() {  # [ENV=V ...] -- ARGS
  local kv=()
  while [ $# -gt 0 ] && [ "$1" != -- ]; do kv+=("$1"); shift; done; shift
  env -u GRAFT_REGISTRY -u GRAFT_REGISTRY_SRC -u GRAFT_INDEX_ROOT -u GRAFT_CRON_LOG -u GRAFT_CRON_LOCK \
    HOME="$T/home" PATH=/usr/bin:/bin GRAFT_VAR_ROOT="$T/var" GRAFT_LANGS=" " ${kv[@]+"${kv[@]}"} bash "$C" "$@" 2>&1
}

echo "== resolve"
out="$(cron -- --resolve-only)"
has "$out" "repo-list source=box file=$T/var/repos.list" "box: \$GRAFT_VAR_ROOT/repos.list is the source"
is "$(printf '%s\n' "$out" | sed -n 's/^repo //p' | tr '\n' ' ')" "$T/src/repo-a $T/src/repo-b $T/src/plain " "box: exactly its repos, comments and blanks dropped"
out="$(cron GRAFT_REGISTRY="$T/envlist" -- --resolve-only)"
has "$out" "repo-list source=env file=$T/envlist" "env: GRAFT_REGISTRY wins over the box list"
out="$(cron -- --resolve-only "$T/src/repo-a")"
has "$out" "repo-list source=args" "args win over both"
out="$(cron GRAFT_VAR_ROOT="$T/none" -- --resolve-only)"
has "$out" "repo-list MISSING $T/none/repos.list" "control: a missing list is named, not guessed"
out="$(cron -- --bogus)"; is "$?" 2 "an unknown flag is refused"

echo "== log/lock"
out="$(cron -- --resolve-only)"
has "$out" "log $T/var/graft-cron.log" "log: under GRAFT_VAR_ROOT by default"
has "$out" "lock $T/var/graft-cron.lock" "lock: under GRAFT_VAR_ROOT by default"
out="$(cron GRAFT_CRON_LOG="$T/l.log" GRAFT_CRON_LOCK="$T/l.lock" -- --resolve-only)"
has "$out" "log $T/l.log" "GRAFT_CRON_LOG overrides"
has "$out" "lock $T/l.lock" "GRAFT_CRON_LOCK overrides"

echo "== tick"
cron -- >/dev/null; rc=$?
is "$rc" 0 "a tick over the box list exits 0"
LOG="$(cat "$T/var/graft-cron.log" 2>/dev/null)"
has "$LOG" "repo-list source=box file=$T/var/repos.list" "tick: the log names the source"
has "$LOG" "WARN  skipping '$T/src/plain' - not a git repo" "tick: a non-repo is skipped and named"
has "$LOG" "END rv=0" "tick: END rv=0 in the log"
SA="${T#/}/src/repo-a"; SA="${SA//\//__}"; SB="${T#/}/src/repo-b"; SB="${SB//\//__}"
ARGV="$(cat "$T/argv" 2>/dev/null)"
has "$ARGV" "ARGV:--dir $T/var/index/$SA build ." "repo-a is built into its out-of-tree index"
has "$ARGV" "ARGV:--dir $T/var/index/$SB build ." "repo-b is built into its out-of-tree index"
[ -e "$T/src/repo-a/graft" ] && bad "a graft/ was written into the repo" || ok "nothing is written into a repo"
bash "$SCRIPTS/graft-wrap.sh" --check "$T/home/.local/bin/graft"; is "$?" 0 "the tick left graft on PATH as the csi-spl wrapper stub"
has "$(cat "$T/home/.local/bin/graft")" "exec bash '$SCRIPTS/graft-safe.sh'" "... naming this checkout's graft-safe.sh"

echo "== skip"
exec 8>"$T/var/graft-cron.lock"; flock -n 8
cron -- >/dev/null; rc=$?
is "$rc" 0 "a tick under a held lock exits 0"
has "$(tail -1 "$T/var/graft-cron.log")" "SKIP" "... and logs SKIP instead of piling up"
exec 8>&-

echo "== hygiene"
is "$(grep -rnE '/opt/|/var/tmp|/home/' "$SCRIPTS" | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#')" "" "no script line names /opt, /var/tmp or a home"
is "$(grep -rnIE 'ysg-box|BOX_VAR_ROOT|BOX_ENGINE_ROOT|box-env\.inc|\.box-root' "$SCRIPTS" "$ASSETS" | head -3)" "" "no script or asset reaches into the engine"

finish
