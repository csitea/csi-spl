#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the standalone stack (root docker-compose.yml) hands its three
#          secrets over as Docker secret files, never as env vars (owner
#          security scan, revised list, action 1; SPL-2158, epic SPL-2151).
#          Doc: csi-spl-doc/doc/md/security-baselines.md section 8.
#   1. no service env holds one of the secrets as a plain value: the
#      Postgres superuser password, the S3 secret key, the SMTP password
#      (by its env name or by its ${SPOOL_...} source)
#   2. every *_FILE env var names /run/secrets/<s>, the service mounts <s>,
#      and the file declares <s> with a file under ${SPOOL_SECRETS_DIR}
#   3. the default dir holds each file (the public local defaults) and the
#      real dir ./secrets is git-ignored
#   4. secret-env.sh (in front of an image that reads only the plain var):
#      the file wins, an unreadable file stops it naming only the variable
#   CONTROLS: a planted file with POSTGRES_PASSWORD from env, a _FILE whose
#   secret is not mounted, and one whose secret is not declared fail 1 and 2
# Hermetic: yq + jq over the files and sh over the shim, no docker. The live
# proof is `docker compose up` (wf 50).
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0

command -v yq >/dev/null || { fail "yq is not installed"; exit 1; }
command -v jq >/dev/null || { fail "jq is not installed"; exit 1; }
COMPOSE="$APP_ROOT/docker-compose.yml"
SHIM="$APP_ROOT/csi-spl-api/src/docker/secret-env.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

# check_file <path>: one "BAD <what>" or "OK <what>" line per check
check_file() {
  # yq's stderr stays out of the JSON: on the hosted runner (yq 4.54) jq read
  # non-JSON in front of it for this compose file only (SPL-2158).
  local json
  json=$(yq -o json '.' "$1" 2>"$T/yq.err") || { echo "BAD -: does not parse: $(cat "$T/yq.err")"; return; }
  jq -r '
    def envmap: if type == "array" then map(split("=") | {key: .[0], value: (.[1:] | join("="))}) | from_entries else (. // {}) end;
    ["POSTGRES_PASSWORD", "AWS_SECRET_ACCESS_KEY", "SPOOL_SUPERUSER_PASSWORD", "SPOOL_S3_SECRET_KEY", "SPOOL_HUB_MAIL_SMTP_PASSWORD"] as $plain
    | ["SPOOL_DB_SUPERUSER_PASSWORD", "SPOOL_S3_SECRET_KEY", "SPOOL_MAIL_SMTP_PASSWORD"] as $src
    | (.secrets // {}) as $decl
    | (.services // {}) | to_entries[] | .key as $k | .value as $v
    | ($v.environment | envmap) as $e
    | ($v.secrets // [] | map(if type == "string" then . else .source end)) as $mounted
    | ($e | to_entries[]
        | if (.key | IN($plain[])) then "BAD \($k): \(.key) is a plain env var"
          elif ((.value | tostring) as $val | any($src[]; . as $s | $val | contains("${" + $s))) then "BAD \($k): \(.key) is read from a secret env var"
          elif (.key | endswith("_FILE")) then
            ((.value | tostring | capture("^/run/secrets/(?<s>[a-z0-9_]+)$").s) // null) as $s
            | if $s == null then "BAD \($k): \(.key) is not /run/secrets/<name>"
              elif ($mounted | index($s)) == null then "BAD \($k): \(.key) names secret \($s), which it does not mount"
              elif ($decl[$s].file // "") == "" then "BAD \($k): secret \($s) is not declared with a file"
              else "OK \($k) reads \(.key) from secret \($s)" end
          else empty end)
  ' <<<"$json"
}

# --- 1 + 2. the standalone compose file -----------------------------------------------
[[ -f "$COMPOSE" ]] || { fail "no $COMPOSE"; exit 1; }
n_ok=0
while read -r verdict rest; do
  if [[ "$verdict" == OK ]]; then pass "$rest"; n_ok=$((n_ok + 1)); else fail "$rest"; fi
done < <(check_file "$COMPOSE")
[[ $n_ok -eq 5 ]] && pass "five *_FILE reads: pg, s3, hub-init and the hub's two" || fail "want 5 *_FILE reads, got $n_ok"

# --- 3. where the files come from ------------------------------------------------------
want="db_superuser_password s3_secret_key mail_smtp_password"
for f in $(yq -r '.secrets[].file' "$COMPOSE"); do
  base="${f##*/}"
  [[ " $want " == *" $base "* ]] || { fail "unexpected secret file $f"; continue; }
  [[ "$f" == '${SPOOL_SECRETS_DIR:-./csi-spl-api/src/docker/local-secrets}/'"$base" ]] &&
    pass "secret $base: \${SPOOL_SECRETS_DIR}, default the local-secrets dir" || fail "secret $base: file is $f"
  [[ -f "$APP_ROOT/csi-spl-api/src/docker/local-secrets/$base" ]] &&
    pass "local default $base is committed" || fail "no local default $base"
done
grep -qx 'spool-local-superuser' "$APP_ROOT/csi-spl-api/src/docker/local-secrets/db_superuser_password" &&
  pass "the local superuser default is the public one hub-init refuses off localhost" || fail "the local superuser default changed"
git -C "$APP_ROOT" check-ignore -q secrets/db_superuser_password &&
  pass "./secrets (the real secret files) is git-ignored" || fail "./secrets is not git-ignored"
for s in s3 hub-init hub; do
  grep -q '^/bin/sh /opt/spool/secret-env.sh [A-Z0-9_ ]* -- ' <<<"$(yq -r ".services[\"$s\"].entrypoint | join(\" \")" "$COMPOSE")" &&
    grep -qx './csi-spl-api/src/docker/secret-env.sh:/opt/spool/secret-env.sh:ro' <<<"$(yq -r ".services[\"$s\"].volumes[]" "$COMPOSE")" &&
    pass "$s runs its entrypoint through secret-env.sh" || fail "$s does not run through secret-env.sh"
done

# --- 4. the shim ---------------------------------------------------------------------------
printf 'from-file\n' >"$T/sec"
out=$(env -i PATH=/usr/bin:/bin X=from-env X_FILE="$T/sec" sh "$SHIM" X -- sh -c 'printf %s "$X"' 2>&1)
[[ "$out" == from-file ]] && pass "secret-env.sh: the file wins over the env var" || fail "secret-env.sh file: $out"
out=$(env -i PATH=/usr/bin:/bin X=from-env sh "$SHIM" X -- sh -c 'printf %s "$X"' 2>&1)
[[ "$out" == from-env ]] && pass "secret-env.sh: no _FILE keeps the env var" || fail "secret-env.sh env: $out"
out=$(env -i PATH=/usr/bin:/bin X_FILE="$T/absent" sh "$SHIM" X -- true 2>&1); rc=$?
[[ $rc -ne 0 && "$out" == *"FATAL X_FILE"* && "$out" != *"$T"* ]] &&
  pass "secret-env.sh: an unreadable file stops it, naming the variable, not the path" || fail "secret-env.sh unreadable: rc $rc $out"
env -i PATH=/usr/bin:/bin sh "$SHIM" X true >/dev/null 2>&1 && fail "secret-env.sh ran with no --" || pass "secret-env.sh: no -- is a usage error"

# --- CONTROLS ----------------------------------------------------------------------------
cat >"$T/bad.yml" <<'YML'
services:
  pg:
    environment:
      POSTGRES_PASSWORD: x
  hub:
    environment:
      SPOOL_X: ${SPOOL_S3_SECRET_KEY:-y}
      SPOOL_A_FILE: /run/secrets/a
      SPOOL_B_FILE: /run/secrets/b
    secrets: [b]
YML
bad=$(check_file "$T/bad.yml")
for want_bad in "pg: POSTGRES_PASSWORD is a plain env var" "hub: SPOOL_X is read from a secret env var" \
  "hub: SPOOL_A_FILE names secret a, which it does not mount" "hub: secret b is not declared with a file"; do
  grep -qxF "BAD $want_bad" <<<"$bad" && pass "CONTROL: $want_bad" || fail "CONTROL missed: $want_bad ($bad)"
done

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
exit 1
