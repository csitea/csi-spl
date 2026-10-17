#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: every docker compose service runs as an explicit non-root user
#          (owner security scan, revised list, action 2: "Add explicit
#          non-root user/group to every compose service"; SPL-2154, epic
#          SPL-2151). Doc: csi-spl-doc/doc/md/security-baselines.md section 5.
#   1. every tracked compose file (git ls-files '*compose*.y*ml') parses, and
#      each of its services sets `user:` to a uid (or name) that is not root:
#      not 0, not root, and a ${VAR:-default} whose default is not 0
#   2. a service that truly must start as root is a row of the allow-list
#      .compose-root-allow.tsv (<file> TAB <service> TAB <reason>) with its
#      reason; a row naming no such service, or with no reason, fails (an
#      allow-list never outlives what it allows)
#   CONTROLS: a planted compose file with a `user: "0:0"` service, one with no
#   user and one with ${X:-0} each fail the same check
# Hermetic: yq + jq over the files, no docker, no network.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0

command -v yq >/dev/null || { fail "yq is not installed"; exit 1; }
command -v jq >/dev/null || { fail "jq is not installed"; exit 1; }
ALLOW="$APP_ROOT/.compose-root-allow.tsv"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

# _root_uid <user value> -> 0 when the value starts the process as root
_root_uid() {
  local u="$1"
  # the uid part: a ${...} up to its brace (it holds a ':' itself), else up
  # to the first ':'
  if [[ "$u" == '${'* ]]; then u="${u%%\}*}}"; else u="${u%%:*}"; fi
  # ${VAR:-default} / ${VAR-default}: the default is what an unset VAR runs as
  [[ "$u" =~ ^\$\{[A-Za-z_][A-Za-z0-9_]*:?-([^}]*)\}$ ]] && u="${BASH_REMATCH[1]}"
  [[ "$u" == 0 || "$u" == root ]]
}

# _allowed <file> <service> -> 0 when the allow-list has a row with a reason
_allowed() {
  awk -F'\t' -v f="$1" -v s="$2" '$1 == f && $2 == s && $3 ~ /[^ ]/ { ok = 1 } END { exit !ok }' "$ALLOW"
}

# check_file <path> <label>: prints one "BAD <label> <svc>: <why>" per
# offending service, "OK <label> <svc> user=<u>" otherwise
check_file() {
  local json svc u
  json=$(yq -o json '.' "$1" 2>&1) || { echo "BAD $2 -: does not parse: $json"; return; }
  while IFS=$'\t' read -r svc u; do
    [[ -n "$svc" ]] || continue
    if _allowed "$2" "$svc"; then echo "OK $2 $svc allow-listed (user=${u:-image default})"; continue; fi
    if [[ -z "$u" ]]; then echo "BAD $2 $svc: no user: (runs as the image default)"; continue; fi
    if _root_uid "$u"; then echo "BAD $2 $svc: user '$u' is root"; continue; fi
    echo "OK $2 $svc user=$u"
  done < <(jq -r '(.services // {}) | to_entries[] | [.key, (.value.user // "" | tostring)] | @tsv' <<<"$json")
}

# --- 1. every tracked compose file -------------------------------------------------
mapfile -t files < <(git -C "$APP_ROOT" ls-files | grep -E '(^|/)[^/]*compose[^/]*\.ya?ml$')
[[ "${#files[@]}" -gt 0 ]] && pass "${#files[@]} compose files tracked" || fail "no compose file found under $APP_ROOT"
[[ -f "$ALLOW" ]] || { fail "no allow-list $ALLOW"; exit 1; }
n_svc=0 n_bad=0
for f in "${files[@]}"; do
  while read -r verdict rest; do
    n_svc=$((n_svc + 1))
    if [[ "$verdict" == OK ]]; then pass "$rest"; else fail "$rest"; n_bad=$((n_bad + 1)); fi
  done < <(check_file "$APP_ROOT/$f" "$f")
done
echo "INFO: $n_svc services in ${#files[@]} files, $n_bad running as root or with no explicit user"

# --- 2. the allow-list: each row names a real service and a reason -----------------
while IFS=$'\t' read -r f s r; do
  [[ -z "$f" || "$f" == \#* ]] && continue
  [[ -n "${r// /}" ]] && pass "allow $f $s has a reason" || fail "allow $f $s: no reason"
  if [[ -f "$APP_ROOT/$f" ]] && yq -e ".services[\"$s\"]" "$APP_ROOT/$f" >/dev/null 2>&1; then
    pass "allow $f $s names a service that exists"
  else
    fail "allow $f $s: no such service (a stale row)"
  fi
done <"$ALLOW"

# --- CONTROLS: the same check fails a root, a missing and a defaulted-0 user --------
cat >"$T/compose-plant.yaml" <<'EOF'
services:
  as-root:
    image: alpine
    user: "0:0"
  no-user:
    image: alpine
  var-root:
    image: alpine
    user: "${PLANT_UID:-0}:${PLANT_GID:-0}"
  fine:
    image: alpine
    user: "${PLANT_UID:-10001}:10001"
EOF
out=$(check_file "$T/compose-plant.yaml" plant)
for s in as-root no-user var-root; do
  grep -q "^BAD plant $s:" <<<"$out" && pass "control: $s fails the check" || fail "control: $s passed: $out"
done
grep -q "^OK plant fine " <<<"$out" && pass "control: a non-root \${VAR:-10001} passes" || fail "control: fine failed: $out"

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
exit 1
