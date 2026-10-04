#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the gcp-* actions harvested from the 2026-09-19 ad-hoc scripts
#          (csi-spl-doc/specs/007-spool-hub-api-infra/adhoc-harvest.md) run as
#          the per-env project service account in a private gcloud config,
#          never print a secret value, and mutate nothing unless told to.
#   1. _gcp_env_sa (trunk's do_gcp_sa_key_file + do_gcp_activate_sa_key)
#      refuses the shared config and a missing key without activating anything
#   2. do_gcp_copy_secret: each side read as ITS OWN project's key; DRY_RUN
#      (default) adds no version; DRY_RUN=0 adds exactly one as the target
#      SA and verifies it; a re-run adds nothing; the value never reaches
#      stdout / stderr; a missing param calls no gcloud
#   3. do_gcp_audit_iam: read-only (no mutating gcloud verb), every call as
#      the env SA in a private config; the dump + analysis land, and a
#      user-held binding is flagged
#   4. do_gcp_backup_env: read-only, secrets saved 0600 and never printed,
#      the backup dir is 0700
#   5. iam-analyze.py owner rules read the SA ids from the cnf; the diff
# With gcloud stubbed; CONTROL: the stub records calls, so an absent call
# means "not made", not "not recorded".
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
RUN="$PROJ_ROOT/src/bash/run"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fails=0
command -v yq >/dev/null || { echo "SKIP: no yq"; exit 0; }

DEV_SA=csi-spl-dev@csi-spl-dev.iam.gserviceaccount.com
REL_SA=csi-rel-prd@csi-rel-prd.iam.gserviceaccount.com
mkdir -p "$T/home/.gcp/.csi" "$T/stub" "$T/sm"
for p in csi-spl-dev csi-rel-prd; do
  printf '{"type":"service_account","client_email":"%s@%s.iam.gserviceaccount.com"}\n' "$p" "$p" >"$T/home/.gcp/.csi/key-$p.json"
done

# stub gcloud: logs "<CLOUDSDK_CONFIG>|<argv>". activate-service-account makes
# the key's client_email the active account OF THAT CONFIG. Secret Manager is
# a dir of files: $T/sm/<project>/<secret>; `versions add` reads stdin.
cat >"$T/stub/gcloud" <<'EOF'
#!/usr/bin/env bash
echo "${CLOUDSDK_CONFIG-<unset>}|$*" >>"$STUB_LOG"
arg() { local a; for a in "${@:2}"; do [[ "$a" == "$1="* ]] && { echo "${a#*=}"; return; }; done; }
proj=$(arg --project "$@"); sec=$(arg --secret "$@")
case "$*" in
  "auth activate-service-account"*)
    jq -r .client_email "$(arg --key-file "$@")" >"$CLOUDSDK_CONFIG/active" ;;
  "auth list"*) cat "$CLOUDSDK_CONFIG/active" 2>/dev/null ;;
  "auth print-access-token"*) echo tok ;;
  "secrets versions access"*) cat "$SM/$proj/$sec" 2>/dev/null || exit 1 ;;
  "secrets versions add "*) mkdir -p "$SM/$proj"; cat >"$SM/$proj/$4" ;;
  "secrets describe "*) [[ -e "$SM/$proj/$3.slot" ]] || exit 1 ;;
  "secrets list"*) [[ "$*" == *json* ]] && echo '[{"name":"projects/p/secrets/s1"}]' || echo s1 ;;
  *get-iam-policy*) echo '{"bindings":[{"role":"roles/owner","members":["user:someone@example.com","serviceAccount:csi-spl-dev@csi-spl-dev.iam.gserviceaccount.com"]}]}' ;;
  "iam service-accounts list"*) echo '[{"email":"csi-spl-hub-dev@csi-spl-dev.iam.gserviceaccount.com"}]' ;;
  *) : ;;
esac
exit 0
EOF
chmod +x "$T/stub/gcloud"

# act <snippet> [VAR=value ...] -> runs the snippet with the iac libs + the
# harvested actions loaded; stdout+stderr to $T/out, calls to $T/calls.log
act() {
  local snip="$1"; shift
  : >"$T/calls.log"
  env -u CLOUDSDK_CONFIG -u ACCOUNT -u GCP_ACCOUNT HOME="$T/home" PATH="$T/stub:$PATH" STUB_LOG="$T/calls.log" SM="$T/sm" \
    PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" ENV=dev SNIPPET="$snip" "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }; quit_on() { :; }; do_require_bin() { :; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/gcp-{copy-secret,audit-iam,backup-env}.func.sh; do source "$f"; done
    eval "$SNIPPET"' >"$T/out" 2>&1
}
calls_as() { grep -vE '\|auth (activate-service-account|list)' "$T/calls.log" | grep -c -- "--account=$1"; }

# --- 1. activation guard -------------------------------------------------------
act '_gcp_env_sa csi-spl-dev'; rc=$?
[[ $rc -ne 0 ]] && ! grep -q 'activate-service-account' "$T/calls.log" && pass "1. CLOUDSDK_CONFIG unset: refused (rc=$rc), nothing activated" || fail "1. unset config: rc=$rc calls=$(cat "$T/calls.log")"
act 'export CLOUDSDK_CONFIG="$HOME/.config/gcloud"; mkdir -p "$CLOUDSDK_CONFIG"; _gcp_env_sa csi-spl-dev'; rc=$?
[[ $rc -ne 0 ]] && ! grep -q 'activate-service-account' "$T/calls.log" && pass "1. the shared ~/.config/gcloud: refused, nothing activated" || fail "1. shared config: rc=$rc"
act 'export CLOUDSDK_CONFIG=$(mktemp -d); _gcp_env_sa csi-nope-dev'; rc=$?
[[ $rc -ne 0 && ! -s "$T/calls.log" ]] && grep -q 'no service-account key' "$T/out" && pass "1. a missing key: refused before gcloud" || fail "1. missing key: rc=$rc $(cat "$T/out")"
act 'export CLOUDSDK_CONFIG=$(mktemp -d); _gcp_env_sa csi-spl-dev'
[[ "$(tail -1 "$T/out")" == "$DEV_SA" ]] && pass "1. CONTROL: a private config activates and prints the env SA" || fail "1. activation printed '$(tail -1 "$T/out")'"

# --- 2. copy secret --------------------------------------------------------------
VAL="val-$RANDOM-$RANDOM"
mkdir -p "$T/sm/csi-rel-prd" "$T/sm/csi-spl-dev"
printf '%s' "$VAL" >"$T/sm/csi-rel-prd/src-sec"; : >"$T/sm/csi-spl-dev/tgt-sec.slot"
CP=(SRC_PROJECT=csi-rel-prd SRC_SECRET=src-sec TGT_SECRET=tgt-sec)
act 'do_gcp_copy_secret' "${CP[@]}"; rc=$?
[[ $rc -eq 0 ]] && grep -q 'DRY_RUN would add' "$T/out" && ! grep -q 'versions add' "$T/calls.log" \
  && pass "2. DRY_RUN (default): would add, no 'versions add' call" || fail "2. dry run: rc=$rc $(tail -2 "$T/out")"
grep 'secrets versions access' "$T/calls.log" | grep -- '--project=csi-rel-prd' | grep -v -- "--account=$REL_SA" >/dev/null \
  && fail "2. a source read ran as someone other than $REL_SA" || pass "2. the source is read as ITS project's SA ($REL_SA)"
grep 'secrets ' "$T/calls.log" | grep -- '--project=csi-spl-dev' | grep -v -- "--account=$DEV_SA" >/dev/null \
  && fail "2. a target call ran as someone other than $DEV_SA" || pass "2. the target is touched as the env SA ($DEV_SA)"
grep -q '<unset>|' "$T/calls.log" && fail "2. a gcloud call ran under the shared config" || pass "2. every call ran in a private gcloud config"
act 'do_gcp_copy_secret' "${CP[@]}" DRY_RUN=0; rc=$?
n_add=$(grep -c 'secrets versions add tgt-sec' "$T/calls.log")
[[ $rc -eq 0 && $n_add -eq 1 && "$(cat "$T/sm/csi-spl-dev/tgt-sec")" == "$VAL" ]] && grep -q 'verified by sha256' "$T/out" \
  && grep 'versions add' "$T/calls.log" | grep -- "--account=$DEV_SA" >/dev/null \
  && pass "2. DRY_RUN=0: one version added as $DEV_SA, verified by sha256" || fail "2. real run: rc=$rc adds=$n_add $(tail -2 "$T/out")"
grep -rqF -- "$VAL" "$T/out" "$T/calls.log" && fail "2. the secret VALUE reached the output or argv" || pass "2. the value is in neither the output nor any argv"
act 'do_gcp_copy_secret' "${CP[@]}" DRY_RUN=0
! grep -q 'versions add' "$T/calls.log" && grep -q 'already holds' "$T/out" && pass "2. re-run: target already holds it, nothing added" || fail "2. re-run added again"
act 'do_gcp_copy_secret' SRC_PROJECT=csi-rel-prd SRC_SECRET=src-sec; rc=$?
[[ $rc -ne 0 && ! -s "$T/calls.log" ]] && pass "2. TGT_SECRET unset: fails fast, no gcloud call" || fail "2. missing TGT_SECRET: rc=$rc"
rm "$T/sm/csi-spl-dev/tgt-sec.slot"
act 'do_gcp_copy_secret' "${CP[@]}" TGT_SECRET=other DRY_RUN=0; rc=$?
[[ $rc -ne 0 ]] && ! grep -q 'versions add' "$T/calls.log" && pass "2. a target slot that does not exist: refused, nothing added (terraform owns slots)" || fail "2. missing slot: rc=$rc"

MUT='(add-iam-policy-binding|remove-iam-policy-binding|set-iam-policy| create | delete | update |versions add|versions destroy|storage rm|record-sets (create|delete|update|import))'
# --- 3. IAM audit ------------------------------------------------------------------
act 'do_gcp_audit_iam' IAM_AUDIT_DIR="$T/iam" IAM_TAG=t1; rc=$?
[[ $rc -eq 0 && -s "$T/iam/dev-t1.json" && -s "$T/iam/dev-t1.md" ]] && pass "3. the dump and the analysis land ($T/iam/dev-t1.{json,md})" || fail "3. audit: rc=$rc $(tail -3 "$T/out")"
n=$(grep -vE '\|auth ' "$T/calls.log" | wc -l); na=$(calls_as "$DEV_SA")
[[ $n -ge 8 && $n -eq $na ]] && pass "3. all $n audit calls pinned --account=$DEV_SA" || fail "3. $na of $n calls as $DEV_SA"
grep -qE "$MUT" "$T/calls.log" && fail "3. a mutating gcloud verb: $(grep -E "$MUT" "$T/calls.log" | sed -n 1p)" || pass "3. no mutating gcloud verb"
grep -q 'USER-HELD' "$T/iam/dev-t1.md" && grep -q 'gcp-003 (IaC SA)' "$T/iam/dev-t1.md" && pass "3. a user-held binding is flagged; the IaC SA owner binding is owned by gcp-003" \
  || fail "3. analysis: $(head -8 "$T/iam/dev-t1.md")"

# --- 4. backup ---------------------------------------------------------------------
BK="bk-$RANDOM-$RANDOM"; printf '%s' "$BK" >"$T/sm/csi-spl-dev/s1"
act 'do_gcp_backup_env' BACKUP_ROOT="$T/bk"; rc=$?
d=$(find "$T/bk/dev" -mindepth 1 -maxdepth 1 -type d | sed -n 1p)
[[ $rc -eq 0 && -n "$d" && "$(stat -c %a "$d")" == 700 ]] && pass "4. backup ran into a 0700 dir" || fail "4. backup: rc=$rc dir='$d' $(tail -3 "$T/out")"
[[ -f "$d/secrets/s1" && "$(stat -c %a "$d/secrets/s1")" == 600 && "$(cat "$d/secrets/s1")" == "$BK" ]] && pass "4. the secret is saved 0600" || fail "4. secret file: $(ls -l "$d/secrets" 2>&1)"
grep -qF -- "$BK" "$T/out" "$d/backup.log" && fail "4. the secret VALUE was printed or logged" || pass "4. the value is neither printed nor logged"
grep -qE "$MUT" "$T/calls.log" && fail "4. a mutating gcloud verb: $(grep -E "$MUT" "$T/calls.log" | sed -n 1p)" || pass "4. no mutating gcloud verb"
n=$(grep -vE '\|auth (activate-service-account|list)' "$T/calls.log" | wc -l); na=$(calls_as "$DEV_SA")
[[ $n -ge 5 && $n -eq $na ]] && pass "4. all $n backup calls pinned --account=$DEV_SA" || fail "4. $na of $n calls as $DEV_SA"
grep -q "gs://$(yq -r .env.gcp.state_bucket "$APP_ROOT/csi-spl-cnf/csi-spl/dev.env.yaml")/" "$T/calls.log" \
  && pass "4. the state bucket name comes from the cnf" || fail "4. no copy of the cnf state bucket"
# rdb 0014 (017 FR-SEC-013): FORCE RLS binds the hub login; a plain pg_dump
# fails ("query would be affected by row-level security policy", measured on
# pg16 2026-09-19) and plain counts read 0. The SQL leg is not reached offline.
bs="$(declare -f _gcp_backup_sql 2>/dev/null || sed -n '/^_gcp_backup_sql()/,/^}/p' "$PROJ_ROOT/src/bash/run/gcp-backup-env.func.sh")"
grep -q "PGOPTIONS='-c app.rls_scope=operator'" <<<"$bs" && grep -q 'export .*PGOPTIONS' <<<"$bs" \
  && grep -q 'pg_dump .*--enable-row-security' <<<"$bs" && pass "4. backup SQL: operator RLS scope + pg_dump --enable-row-security" \
  || fail "4. backup SQL leg would fail under rdb 0014 RLS"

# --- 5. analyzer ---------------------------------------------------------------------
cat >"$T/cnf.json" <<'EOF'
{"env":{"gcp":{"gcp_project":"x-y-dev"},"hub":{"runtime_sa_account_id":"hubsa","secret_env":{"SPOOL_HUB_DB_DSN":"dsn"}},
 "steps":{"020-gcp-relay-bucket":{"relay_sa_account_id":"relsa"}}}}
EOF
mk() { printf '{"project":"x-y-dev","as":"a","tag":"%s","taken_utc":"z","policies":{"project":{"bindings":[%s]}}}' "$1" "$2"; }
mk b '{"role":"roles/cloudsql.client","members":["serviceAccount:hubsa@x-y-dev.iam.gserviceaccount.com","user:u@example.com"]}' >"$T/b.json"
mk a '{"role":"roles/cloudsql.client","members":["serviceAccount:hubsa@x-y-dev.iam.gserviceaccount.com"]}' >"$T/a.json"
out=$(python3 "$PROJ_ROOT/src/bash/scripts/iam-analyze.py" "$T/cnf.json" "$T/b.json" "$T/a.json")
grep -q 'hubsa@x-y-dev.iam.gserviceaccount.com` | 030 hub runtime' <<<"$out" && pass "5. the hub runtime SA id comes from the cnf (030 owns cloudsql.client)" || fail "5. owner rule: $out"
grep -q 'user:u@example.com` | yes | - |' <<<"$out" && pass "5. the diff shows the removed user binding" || fail "5. diff: $out"
grep -q 'bucket:relay | roles/storage.objectUser | `serviceAccount:relsa@' <<<"$out" && pass "5. a grant 020 expects but the policy lacks is listed" || fail "5. expected: $out"

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
