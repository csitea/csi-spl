#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: characterization of do_gcp_project_delete (refactor round 25, row
#          02): pin what the action does past its identity step today, so a
#          later round can split it (it is in bash-cleancode's LONG list).
#          gcp-key-path-no-eval.tst.sh stops it at a refused identity; this
#          test drives it to the end with gcloud / gsutil stubbed.
#   1. The first `projects describe` fails: rc 1, FATAL names it, no gsutil
#      and no `projects delete` call.
#   2. State already DELETE_REQUESTED: rc 0, WARN, no gsutil, no delete.
#   3. FORCE=true, ACTIVE, two buckets under 1024 B: each logged as
#      `<name>: <n> B`, exactly one `projects delete <proj> --account=<SA>
#      --quiet`, the verify describe reads DELETE_REQUESTED and logs the three
#      INFO lines, rc 0. No buckets: `(no buckets found)`.
#   4. FORCE unset: the wrong project id on stdin cancels (rc 1, no delete);
#      the right one deletes.
#   5. `projects delete` fails: rc 1, FATAL names the project, no verify
#      describe.
#   6. The verify describe reads ACTIVE: WARN "unexpected state after
#      deletion: ACTIVE", rc 0.
#   7. Every gcloud call but `config set project` carries --account=<SA>; all
#      ran under one private CLOUDSDK_CONFIG that is gone afterwards; no
#      $HOME/.config/gcloud.
# The KB / MB / GB lines need bc and are not asserted: every size is < 1024.
# The action's absolute /opt/google-cloud-sdk/bin is pointed at the stubs in a
# copy of the action (the gcp-s3-download-all-mkdir.tst.sh recipe); the test
# refuses to run a copy that still names /opt/google-cloud-sdk. Nothing
# reaches GCP.
#------------------------------------------------------------------------------
set -uo pipefail

TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
RUN="$PROJ_ROOT/src/bash/run"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export T
export HELPER="$PROJ_ROOT/lib/bash/funcs/gcp-temp-sdk-config.func.sh"

fails=0
ACTION="$RUN/gcp-project-delete.func.sh"
require_action "$ACTION"
SA=sa@example.com
PROJ=csi-spl-dev

# gcloud: argv to STUB_LOG, CLOUDSDK_CONFIG to $T/csc.log; the lifecycle
# describe answers STATE_BEFORE on its first call, STATE_AFTER after
stub gcloud 'echo "gcloud|$*" >>"$STUB_LOG"; echo "${CLOUDSDK_CONFIG:-<unset>}" >>"$T/csc.log"
case "$*" in
  "projects describe "*"table("*)
    [[ "${DESCRIBE_RC:-0}" != 0 ]] && { echo "ERROR: describe denied"; exit "$DESCRIBE_RC"; }
    echo "PROJECT_ID  NAME  LIFECYCLE_STATE"; echo "csi-spl-dev  csi-spl-dev  ACTIVE" ;;
  "projects describe "*"value(lifecycleState)"*)
    n=$(cat "$T/describes" 2>/dev/null || echo 0); echo $((n + 1)) >"$T/describes"
    [[ $n == 0 ]] && echo "$STATE_BEFORE" || echo "$STATE_AFTER" ;;
  "projects delete "*) exit "${DELETE_RC:-0}" ;;
esac
exit 0'
# gsutil: `ls -p` prints $T/buckets; `du -s <url>` the size listed for it in $T/sizes
stub gsutil 'echo "gsutil|$*" >>"$STUB_LOG"
case "$1 $2" in
  "ls -p") cat "$T/buckets" ;;
  "du -s") awk -v u="$3" '"'"'$1 == u { print $2 "  " u }'"'"' "$T/sizes" ;;
esac
exit 0'
mkdir -p "$T/home" "$T/tmp"

sed "s|/opt/google-cloud-sdk/bin|$T/bin|g" "$ACTION" >"$T/action.sh"
if grep -q '/opt/google-cloud-sdk' "$T/action.sh"; then
  fail "the action copy still names /opt/google-cloud-sdk: refusing to run it"
  echo "FAIL: $fails assertion(s)"; exit 1
fi
pass "the action copy calls only the stubs (no /opt/google-cloud-sdk left)"

# drive <stdin> [VAR=value ...] - runs the copy with every helper stubbed;
# prints the rc. Argv log $T/calls.log, do_log lines $T/log.log, stdout and
# stderr $T/out.log, the CLOUDSDK_CONFIG of each gcloud call in $T/csc.log.
drive() {
  local input="$1"; shift
  : >"$T/calls.log"; : >"$T/log.log"; : >"$T/csc.log"; rm -f "$T/describes"
  ( cd "$T" && printf '%s\n' "$input" | env -u GCP_PROJECT -u CLOUDSDK_CONFIG -u FORCE -u GCP_SA_KEY_FILE \
      -u DESCRIBE_RC -u DELETE_RC HOME="$T/home" TMPDIR="$T/tmp" PATH="$T/bin:$PATH" \
      STUB_LOG="$T/calls.log" ORG=csi APP=spl ENV=dev STATE_BEFORE=ACTIVE STATE_AFTER=DELETE_REQUESTED "$@" \
    bash -c 'do_log() { echo "$*" >>"$T/log.log"; }; do_require_var() { :; }; do_gcp_log_identity() { :; }
      do_gcp_account() { echo sa@example.com; }
      source "$HELPER" || exit 1; source "$T/action.sh"; do_gcp_project_delete' >"$T/out.log" 2>&1 )
  echo $?
}
deletes() { grep -c '^gcloud|projects delete ' "$T/calls.log"; }
verifies() { grep -c '^gcloud|projects describe .*value(lifecycleState)' "$T/calls.log"; }
logged() { grep -qxF -- "$1" "$T/log.log"; }

printf 'gs://b1/\ngs://b2/\n' >"$T/buckets"
printf 'gs://b1/ 12\ngs://b2/ 1023\n' >"$T/sizes"

# --- 1. the first describe fails --------------------------------------------
rc=$(drive "" FORCE=true DESCRIBE_RC=1)
[[ "$rc" != 0 ]] && pass "1. rc $rc (non-zero)" || fail "1. rc 0"
logged "FATAL failed to describe project: ERROR: describe denied" \
  && pass "1. FATAL names the failed describe" || fail "1. no FATAL: $(tail -2 "$T/log.log")"
! grep -q '^gsutil|' "$T/calls.log" && pass "1. no gsutil call" || fail "1. gsutil ran"
[[ $(deletes) == 0 ]] && pass "1. no projects delete" || fail "1. projects delete ran"

# --- 2. already DELETE_REQUESTED --------------------------------------------
rc=$(drive "" FORCE=true STATE_BEFORE=DELETE_REQUESTED)
[[ "$rc" == 0 ]] && pass "2. rc 0" || fail "2. rc $rc"
logged "WARN project $PROJ is already in DELETE_REQUESTED state" \
  && pass "2. WARN already DELETE_REQUESTED" || fail "2. no WARN: $(tail -2 "$T/log.log")"
! grep -q '^gsutil|' "$T/calls.log" && pass "2. no gsutil call" || fail "2. gsutil ran"
[[ $(deletes) == 0 ]] && pass "2. no projects delete" || fail "2. projects delete ran"

# --- 3. FORCE=true, ACTIVE, two small buckets --------------------------------
rc=$(drive "" FORCE=true)
[[ "$rc" == 0 ]] && pass "3. rc 0" || fail "3. rc $rc: $(tail -3 "$T/log.log")"
logged "INFO   b1: 12 B" && logged "INFO   b2: 1023 B" \
  && pass "3. both buckets logged as <name>: <n> B" || fail "3. bucket lines: $(grep ' B$' "$T/log.log")"
[[ $(deletes) == 1 ]] && grep -qxF "gcloud|projects delete $PROJ --account=$SA --quiet" "$T/calls.log" \
  && pass "3. exactly one 'projects delete $PROJ --account=$SA --quiet'" \
  || fail "3. delete calls: $(grep '^gcloud|projects delete' "$T/calls.log")"
[[ $(verifies) == 2 ]] && pass "3. a verify describe ran after the delete" || fail "3. lifecycle describes: $(verifies)"
logged "INFO project $PROJ is now in DELETE_REQUESTED state" \
  && logged "INFO the project will be permanently deleted after 30 days" \
  && logged "INFO to undelete: gcloud projects undelete $PROJ" \
  && pass "3. the three INFO lines after the delete" || fail "3. INFO lines missing: $(tail -3 "$T/log.log")"
: >"$T/buckets"
rc=$(drive "" FORCE=true)
[[ "$rc" == 0 ]] && logged "INFO   (no buckets found)" \
  && pass "3. no buckets: '(no buckets found)', rc 0" || fail "3. empty ls: rc $rc"
printf 'gs://b1/\ngs://b2/\n' >"$T/buckets"

# --- 4. FORCE unset: the typed project id ------------------------------------
rc=$(drive "csi-spl-prd")
[[ "$rc" != 0 ]] && pass "4. wrong id: rc $rc (non-zero)" || fail "4. wrong id: rc 0"
grep -q 'cancelled' "$T/log.log" && pass "4. wrong id: cancelled" || fail "4. wrong id: no 'cancelled'"
[[ $(deletes) == 0 ]] && pass "4. wrong id: no projects delete" || fail "4. wrong id: projects delete ran"
rc=$(drive "$PROJ")
[[ "$rc" == 0 && $(deletes) == 1 ]] && pass "4. right id: the delete runs, rc 0" \
  || fail "4. right id: rc $rc, deletes $(deletes)"

# --- 5. projects delete fails ------------------------------------------------
rc=$(drive "" FORCE=true DELETE_RC=1)
[[ "$rc" != 0 ]] && pass "5. rc $rc (non-zero)" || fail "5. rc 0"
logged "FATAL failed to delete project $PROJ" && pass "5. FATAL names the project" \
  || fail "5. no FATAL: $(tail -2 "$T/log.log")"
[[ $(verifies) == 1 ]] && pass "5. no verify describe after the failed delete" \
  || fail "5. lifecycle describes: $(verifies)"

# --- 6. still ACTIVE after the delete ----------------------------------------
rc=$(drive "" FORCE=true STATE_AFTER=ACTIVE)
[[ "$rc" == 0 ]] && pass "6. rc 0" || fail "6. rc $rc"
logged "WARN unexpected state after deletion: ACTIVE" && pass "6. WARN unexpected state ACTIVE" \
  || fail "6. no WARN: $(tail -2 "$T/log.log")"

# --- 7. identity and private config, on a full FORCE=true run ----------------
rc=$(drive "" FORCE=true)
n=$(grep -c '^gcloud|' "$T/calls.log")
bad=$(grep '^gcloud|' "$T/calls.log" | grep -v '^gcloud|config set project ' | grep -vF -- "--account=$SA")
[[ "$rc" == 0 && "$n" -ge 5 && -z "$bad" ]] && pass "7. $n gcloud calls: each but 'config set project' carries --account=$SA" \
  || fail "7. rc $rc, $n calls, without --account: $bad"
grep -qxF "gcloud|config set project $PROJ" "$T/calls.log" \
  && pass "7. 'config set project $PROJ' ran, without --account" || fail "7. no plain 'config set project $PROJ'"
dirs=$(sort -u "$T/csc.log")
[[ $(wc -l <"$T/csc.log") == "$n" && $(printf '%s\n' "$dirs" | wc -l) == 1 && "$dirs" == "$T/tmp/"* ]] \
  && pass "7. every gcloud call ran under one private CLOUDSDK_CONFIG" || fail "7. CLOUDSDK_CONFIG seen: $dirs"
[[ -n "$dirs" && ! -e "$dirs" ]] && pass "7. the private config dir is gone afterwards" || fail "7. $dirs still exists"
[[ ! -e "$T/home/.config/gcloud" ]] && pass "7. \$HOME/.config/gcloud never created" || fail "7. \$HOME/.config/gcloud exists"

[[ $fails -eq 0 ]] && pass "all $(basename "$0") assertions" || { echo "FAIL: $fails assertion(s)"; exit 1; }
