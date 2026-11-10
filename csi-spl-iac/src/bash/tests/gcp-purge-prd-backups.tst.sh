#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_gcp_purge_prd_backups, the one-off clean-up of the prd db
#          backups (SPL-5187). gcloud is a function stub that records its argv
#          and serves a fake versioned listing per bucket from a JSON file; the
#          cnf, project, account and key resolvers are stubbed, so nothing
#          reaches GCP. Bucket and object names are synthetic. "now" is pinned
#          to 2026-11-10T12:00:00Z (SPL_PURGE_NOW).
#   1. bash -n, the action exists
#   2. non-prd refused (dev, unset), DRY_RUN=2 refused: no gcloud call
#   3. dry run (default): no rm; would-delete lines, the report lines, soft
#      delete and versioning stated; every gcloud call carries the right
#      --account (045 = env SA, 046 = the 046 project's SA)
#   4. DRY_RUN=0: rm gets exactly the expected generations: 045 everything
#      before today 00:00 UTC (00:00:00 stays, 23:59:59 yesterday goes); 046
#      under prd/db/ only, exactly 30 days old goes, 30 days minus 1 s stays
#      even with its retention expired, retention not expired stays,
#      prd/files/ untouched; after-report counts
#   5. a bucket with no backup created today is aborted: no rm in it, the
#      other bucket still runs, rc 1
#   6. a generation still there after the rm is a FATAL
#   7. RED controls: each guard (# guard:<name> in the action) removed by sed
#      turns its assertion above red: dry-run, no-today, 30-days, prd-only
#------------------------------------------------------------------------------
set -uo pipefail

TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
RUN="$PROJ_ROOT/src/bash/run"
F="$RUN/gcp-purge-prd-backups.func.sh"
SDK="$PROJ_ROOT/lib/bash/funcs/gcp-temp-sdk-config.func.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fails=0

require_action "$F"
bash -n "$F" && pass "bash -n $(basename "$F")" || fail "bash -n $(basename "$F")"

NOW=$(date -u -d 2026-11-10T12:00:00Z +%s)
DB=gs://test-prd-db-backups OFF=gs://test-bkp-prd
ENV_SA=env-sa@example.com BKP_SA=bkp-sa@example.com

# fixture <file> <bucket> then lines "name gen timeCreated retentionExpiration|- [noncurrent]"
fixture() {
  local f="$1" b="$2"; shift 2
  printf '%s\n' "$@" | jq -R -s --arg b "$b" '[split("\n")[] | select(. != "") | split(" ") |
    {url: ($b + "/" + .[0] + "#" + .[1]), type: "cloud_object",
     metadata: ({name: .[0], generation: .[1], timeCreated: .[2]}
       + (if .[3] != "-" then {retentionExpirationTime: .[3]} else {} end)
       + (if (.[4] // "") == "noncurrent" then {timeDeleted: "2026-10-03T00:00:00+00:00"} else {} end))}]' >"$f"
}
fixture "$T/db.full" "$DB" \
  "prd/c-old.sql.gz 11 2026-10-20T03:00:00.123000+00:00 -" \
  "prd/a-yday.sql.gz 12 2026-11-09T23:59:59.000000+00:00 -" \
  "prd/b-today.sql.gz 13 2026-11-10T00:00:00.000000+00:00 -"
fixture "$T/off.full" "$OFF" \
  "prd/db/d30.sql.gz 21 2026-10-11T12:00:00.000000+00:00 2026-11-10T12:00:00.000000+00:00" \
  "prd/db/d29r.sql.gz 22 2026-10-11T12:00:01.000000+00:00 2026-11-10T12:00:01.000000+00:00" \
  "prd/db/d29x.sql.gz 23 2026-10-11T12:00:01.000000+00:00 2026-11-01T00:00:00.000000+00:00" \
  "prd/db/dret.sql.gz 24 2026-10-01T00:00:00.000000+00:00 2026-11-20T00:00:00.000000+00:00" \
  "prd/db/dnon.sql.gz 25 2026-10-02T00:00:00.000000+00:00 2026-11-01T00:00:00.000000+00:00 noncurrent" \
  "prd/db/today.sql.gz 26 2026-11-10T03:00:00.000000+00:00 2026-12-10T03:00:00.000000+00:00" \
  "prd/files/t/x/f1 27 2026-09-29T00:00:00.000000+00:00 2026-10-29T00:00:00.000000+00:00"

# the listing the gcloud stub serves: the fixture minus what rm removed
echo 'map(select(.url as $u | ($r | split("\n")) | any(. == $u) | not))' >"$T/unremoved.jq"

# run_case [VAR=value ...] - the action ($FA, default $F) in a subshell; output
# in $T/o, rc in $rc, gcloud argv lines in $T/calls, rm'd urls in $T/removed.
#   stub knobs: NOTODAY=db|off (drop that bucket's today object)
#               RM=keep (rm deletes nothing)
run_case() {
  : >"$T/calls"; : >"$T/removed"
  jq 'map(select(.metadata.name != "prd/b-today.sql.gz"))' "$T/db.full" >"$T/db.notoday"
  jq 'map(select(.metadata.name != "prd/db/today.sql.gz"))' "$T/off.full" >"$T/off.notoday"
  env -u DRY_RUN F="${FA:-$F}" SDK="$SDK" TD="$T" ENV=prd SPL_PURGE_NOW="$NOW" "$@" bash -c '
    do_log(){ echo "$*"; }
    do_require_bin(){ :; }
    do_gcp_spl_proj_id(){ PROJ_ID="test-${ENV}"; }
    do_gcp_pin_account(){ GCP_ACCOUNT='"$ENV_SA"'; }
    do_gcp_sa_key_file(){ [[ "$PROJ_ID" == test-bkp ]] && echo /nonexistent/key-test-bkp.json; }
    do_gcp_activate_sa_key(){ echo '"$BKP_SA"'; }
    do_spl_merged_cnf(){ printf "env:\n  steps:\n    045-gcs-db-backups:\n      backups_bucket_name: test-prd-db-backups\n    046-gcs-offsite-backups:\n      offsite_bucket_name: test-bkp-prd\n      tf_key_project: test-bkp\n" >"$3"; }
    gcloud(){
      echo "gcloud $*" >>"$TD/calls"
      local a which
      case "$*" in *test-bkp-prd*) which=off ;; *) which=db ;; esac
      case "$1 $2" in
        "storage buckets")
          if [[ $which == off ]]; then
            echo "{\"versioning_enabled\":true,\"soft_delete_policy\":{\"retentionDurationSeconds\":\"2592000\"},\"retention_policy\":{\"retentionPeriod\":\"2592000\"}}"
          else
            echo "{\"versioning_enabled\":false,\"soft_delete_policy\":{\"retentionDurationSeconds\":\"604800\"}}"
          fi ;;
        "storage ls")
          local src="$TD/$which.full"; [[ "${NOTODAY:-}" == "$which" ]] && src="$TD/$which.notoday"
          jq --rawfile r "$TD/removed" -f "$TD/unremoved.jq" "$src" ;;
        "storage rm")
          [[ "${RM:-}" == keep ]] && return 0
          for a in "$@"; do [[ "$a" == gs://* ]] && echo "$a" >>"$TD/removed"; done; return 0 ;;
      esac
    }
    source "$SDK"
    source "$F"
    do_gcp_purge_prd_backups
    echo "rc=$?"' >"$T/o" 2>&1
  rc=$(sed -n 's/^rc=//p' "$T/o" | tail -1)
}
removed_is() { # <url>... -> 0 when $T/removed holds exactly these
  diff <(sort "$T/removed") <(printf '%s\n' "$@" | sort) >/dev/null
}
WANT=("$DB/prd/c-old.sql.gz#11" "$DB/prd/a-yday.sql.gz#12"
  "$OFF/prd/db/d30.sql.gz#21" "$OFF/prd/db/dnon.sql.gz#25")

# --- the assertions, as functions, so the red controls in 7. reuse them -----------
chk_prd_only() { # 0 when ENV=dev and an unset ENV are refused before any gcloud call
  run_case ENV=dev
  [[ "$rc" == 1 && ! -s "$T/calls" ]] && grep -q "ENV must be prd" "$T/o" || return 1
  run_case ENV=
  [[ "$rc" == 1 && ! -s "$T/calls" ]]
}
chk_dry_run() { # 0 when the default run deletes nothing and reports the plan
  run_case
  [[ "$rc" == 0 ]] && ! grep -q 'storage rm' "$T/calls" && [[ ! -s "$T/removed" ]] &&
    [[ "$(grep -c 'DRY_RUN would delete ' "$T/o")" == 4 ]] &&
    grep -qF "REPORT $DB DRY_RUN: before=3 to_remove=2 after=1 left_by_lock=1 out_of_scope_untouched=0" "$T/o" &&
    grep -qF "REPORT $OFF DRY_RUN: before=6 to_remove=2 after=4 left_by_lock=4 out_of_scope_untouched=1" "$T/o"
}
chk_boundary() { # 0 when DRY_RUN=0 removes exactly WANT (the day and 30-day edges)
  run_case DRY_RUN=0
  [[ "$rc" == 0 ]] && removed_is "${WANT[@]}"
}
chk_no_today() { # 0 when a bucket without today's backup is aborted and the other still runs
  run_case DRY_RUN=0 NOTODAY=db
  [[ "$rc" == 1 ]] && ! grep -q "$DB/" "$T/removed" && grep -q "ABORT $DB" "$T/o" &&
    removed_is "$OFF/prd/db/d30.sql.gz#21" "$OFF/prd/db/dnon.sql.gz#25" || return 1
  run_case DRY_RUN=0 NOTODAY=off
  [[ "$rc" == 1 ]] && ! grep -q "$OFF/" "$T/removed" && grep -q "ABORT $OFF" "$T/o"
}

# --- 2. refusals ----------------------------------------------------------------------
chk_prd_only && pass "ENV=dev and an unset ENV are refused before any gcloud call" || fail "non-prd: rc=$rc $(cat "$T/o") / $(cat "$T/calls")"
run_case DRY_RUN=2
[[ "$rc" == 1 && ! -s "$T/calls" ]] && grep -q 'DRY_RUN must be 0 or 1' "$T/o" \
  && pass "DRY_RUN=2 is refused before any gcloud call" || fail "DRY_RUN=2: rc=$rc $(cat "$T/o")"

# --- 3. dry run -----------------------------------------------------------------------
chk_dry_run && pass "dry run (default) deletes nothing and reports before / to_remove / after / left_by_lock per bucket" \
  || fail "dry run: rc=$rc $(cat "$T/o") / $(cat "$T/calls")"
grep -q "$DB soft delete: ON, 7 day(s). A deleted object is NOT gone" "$T/o" &&
  grep -q "$OFF soft delete: ON, 30 day(s)" "$T/o" &&
  grep -q "$OFF object versioning: ON" "$T/o" && grep -q "$DB object versioning: OFF" "$T/o" \
  && pass "soft delete and versioning are read and stated plainly for both buckets" || fail "settings lines: $(cat "$T/o")"
if [[ -s "$T/calls" ]] && ! grep -v -- "--account=" "$T/calls" >/dev/null &&
  ! grep "test-bkp-prd" "$T/calls" | grep -v -- "--account=$BKP_SA" >/dev/null &&
  ! grep "test-prd-db-backups" "$T/calls" | grep -v -- "--account=$ENV_SA" >/dev/null; then
  pass "every gcloud call is pinned: 045 as the env SA, 046 as its own project's SA"
else
  fail "account pinning: $(cat "$T/calls")"
fi
! grep -q -- '--project\|buckets update\|retention\|lifecycle' "$T/calls" \
  && pass "no bucket setting is written (describe and ls only)" || fail "a setting call: $(cat "$T/calls")"

# --- 4. DRY_RUN=0 ---------------------------------------------------------------------
chk_boundary && pass "DRY_RUN=0 removes before-today in 045 (00:00:00 stays) and >= 30 days with expired retention under prd/db/ in 046 (30 d - 1 s, retention-held and prd/files/ stay)" \
  || fail "DRY_RUN=0 removed: $(cat "$T/removed") / $(cat "$T/o")"
grep -qF "REPORT $DB DELETED: before=3 removed=2 after=1 left_by_lock=1" "$T/o" &&
  grep -qF "REPORT $OFF DELETED: before=6 removed=2 after=4 left_by_lock=4 out_of_scope_untouched=1" "$T/o" \
  && pass "the after-report re-lists: removed, after and left_by_lock per bucket" || fail "after report: $(cat "$T/o")"

# --- 5. no today -> abort -------------------------------------------------------------
chk_no_today && pass "a bucket with no backup created today is aborted (no rm in it, rc 1); the other bucket still runs" \
  || fail "no-today: rc=$rc removed=$(cat "$T/removed") $(cat "$T/o")"

# --- 6. leftovers ---------------------------------------------------------------------
run_case DRY_RUN=0 RM=keep
[[ "$rc" == 1 ]] && grep -q "FATAL $DB: 2 generation(s) meant to go are still there" "$T/o" \
  && pass "a generation still there after the rm is a FATAL" || fail "leftover: rc=$rc $(cat "$T/o")"

# --- 7. red controls: each guard removed turns its assertion red ----------------------
mutant() { # <guard> <sed expr> -> path of a copy of the action with the guard broken
  local m="$T/mut-$1.sh"
  sed "$2" "$F" >"$m"
  grep -q "# guard:$1" "$F" && ! cmp -s "$F" "$m" || { echo "FAIL: mutant $1 changed nothing" >&2; return 1; }
  echo "$m"
}
red() { # <guard> <sed expr> <chk fn>
  local m
  m=$(mutant "$1" "$2") || { fail "RED control $1: no mutant"; return; }
  if FA="$m" "$3"; then fail "RED control $1: the assertion stayed green with the guard removed"
  else pass "RED control: guard $1 removed -> $3 goes red"; fi
}
FA=
red dry-run  '/# guard:dry-run/s/\[\[ "\$dry_run" == 1 \]\]/false/' chk_dry_run
red no-today '/# guard:no-today/s/((n_today == 0))/false/' chk_no_today
red 30-days  '/# guard:30-days/s/SPL_PURGE_OFFSITE_MIN_AGE_DAYS \* 86400/0/' chk_boundary
red prd-only '/# guard:prd-only/d' chk_prd_only

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
