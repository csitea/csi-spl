#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_check_env_order (SPL-1947) -- the daily read-only drift check
#          that dev always equals or leads prd. A SYNTHETIC repo (a copy of
#          the real cnf and the iac cnf helpers, two commits), file:// probe
#          fixtures and a stub plan: no network, no tf-runner, no GCP.
#   1. everything equal                              -> rc 0, OK line
#   2. tf: dev pending + prd clean                   -> prd-leads, rc 1
#      CONTROL: dev clean + prd pending              -> dev-leads, rc 0
#   3. served: prd serves a hub input dev does not   -> prd-leads, rc 1
#      CONTROL: dev serves the later commit          -> dev-leads, rc 0
#   4. cnf: prd's hub.image.tag newer than dev's     -> prd-leads, rc 1
#   5. a plan error, or no tf-runner                 -> unknown, rc 2
#   6. the action plans only: no apply, no gcloud, no provision
#   7. the daily tick script: prd leads -> one note (DRY_RUN=0 only); fine
#      or unknown -> no note; it exits the action's code
#   8. the cron installer on a fixture crontab: dry run writes nothing, one
#      tagged daily line, idempotent, check, worktree refused, remove
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0
ACTION_FILE="$PROJ_ROOT/src/bash/run/check-env-order.func.sh"
[[ -f "$ACTION_FILE" ]] || { echo "FAIL: no $ACTION_FILE"; exit 1; }

# --- a synthetic repo: the real cnf, then a hub + wui input commit ---------
REPO="$T/repo"
mkdir -p "$REPO/csi-spl-iac/lib/bash" "$REPO/csi-spl-api/src/go"
cp -r "$APP_ROOT/csi-spl-cnf" "$REPO/"
cp -r "$APP_ROOT/csi-spl-iac/lib/bash/funcs" "$REPO/csi-spl-iac/lib/bash/"
echo a >"$REPO/csi-spl-api/src/go/a.go"
git -C "$REPO" init -q -b master
git -C "$REPO" add -A
old="$(date -u -d '-600 minutes' +%Y-%m-%dT%H:%M:%S%z)"
GIT_AUTHOR_DATE="$old" GIT_COMMITTER_DATE="$old" git -C "$REPO" -c user.name=t -c user.email=t@example.com commit -qm base
C1=$(git -C "$REPO" rev-parse HEAD)
echo b >>"$REPO/csi-spl-api/src/go/a.go"; mkdir -p "$REPO/csi-spl-wui"; echo w >"$REPO/csi-spl-wui/w.ts"; git -C "$REPO" add -A
GIT_AUTHOR_DATE="$old" GIT_COMMITTER_DATE="$old" git -C "$REPO" -c user.name=t -c user.email=t@example.com commit -qm "hub and wui input"
C2=$(git -C "$REPO" rev-parse HEAD)

fixture() { printf '{"commit":"%s"}' "$1" >"$T/$2.json"; echo "file://$T/$2.json"; }
cat >"$T/plan" <<'EOF'
#!/bin/sh
rc=$STUB_DEV_RC; [ "$ENV" = prd ] && rc=$STUB_PRD_RC
case $rc in 0) w=clean ;; 2) w=pending ;; *) w=error ;; esac
echo "TF_PLAN $ENV $STEP $w sha=0123456789abcdef0123456789abcdef01234567"; exit "$rc"
EOF
chmod +x "$T/plan"

# check <label> <want rc> <want grep> [env...]
check() {
  local label="$1" want="$2" re="$3"; shift 3
  out=$(env PROJ_PATH="$PROJ_ROOT" APP_PATH="$REPO" SPL_STATE_DIR="$T/state" \
        ENV_ORDER_STEPS=030-x ENV_ORDER_PLAN_CMD="$T/plan" STUB_DEV_RC=0 STUB_PRD_RC=0 \
        LAG_HUB_URL="$(fixture "$C2" dh)" LAG_WUI_URL="$(fixture "$C2" dw)" \
        ENV_ORDER_PRD_HUB_URL="$(fixture "$C2" ph)" ENV_ORDER_PRD_WUI_URL="$(fixture "$C2" pw)" "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*" >&2; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    do_check_env_order' 2>"$T/err"); rc=$?
  if [[ $rc -eq $want ]] && grep -qE "$re" <<<"$out"; then pass "$label (rc $rc)"
  else fail "$label: rc=$rc want $want, out='$out' err='$(tail -2 "$T/err")'"; fi
}

check "dev and prd equal everywhere" 0 'ENV_ORDER OK'
grep -qE '^tf +030-x +clean +clean +equal' <<<"$out" && pass "the tf row is a table row" || fail "no tf row: $out"
grep -qE '^cnf +hub.image.tag .* equal' <<<"$out" && pass "the real cnf tags are equal" || fail "cnf row: $out"

check "tf: dev pending, prd clean -> prd leads" 1 '^tf +030-x +pending +clean +prd-leads' STUB_DEV_RC=2
grep -q '^ENV_ORDER FAIL: prd leads dev in 1 row' <<<"$out" && pass "the FAIL line counts the rows" || fail "no FAIL line: $out"
check "CONTROL tf: dev clean, prd pending -> dev leads" 0 '^tf +030-x +clean +pending +dev-leads' STUB_PRD_RC=2
check "tf: both pending -> both-behind, not a lead" 0 'both-behind' STUB_DEV_RC=2 STUB_PRD_RC=2

check "hub: prd serves a hub input dev does not" 1 '^hub +served +[0-9a-f]{8} +[0-9a-f]{8} +prd-leads' LAG_HUB_URL="$(fixture "$C1" dh1)"
check "CONTROL hub: dev serves the later commit" 0 '^hub +served .* dev-leads' ENV_ORDER_PRD_HUB_URL="$(fixture "$C1" ph1)"
echo f >>"$REPO/csi-spl-api/src/go/a.go"; git -C "$REPO" add -A
git -C "$REPO" -c user.name=t -c user.email=t@example.com commit -qm "fresh hub input"
C3=$(git -C "$REPO" rev-parse HEAD)
check "hub: prd ahead by a FRESH commit -> in-flight, not a lead" 0 '^hub +served .* in-flight' ENV_ORDER_PRD_HUB_URL="$(fixture "$C3" ph3)"
check "CONTROL hub: the same with no grace -> prd leads" 1 '^hub +served .* prd-leads' ENV_ORDER_PRD_HUB_URL="$(fixture "$C3" ph4)" ENV_ORDER_GRACE_MINUTES=0
check "wui: prd ahead of dev" 1 '^wui +served .* prd-leads' LAG_WUI_URL="$(fixture "$C1" dw1)"
git -C "$REPO" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m "docs only"
check "hub: dev behind by no hub input -> equal" 0 '^hub +served .* equal +no hub input' LAG_HUB_URL="$(fixture "$C3" dh2)" ENV_ORDER_PRD_HUB_URL="$(fixture "$(git -C "$REPO" rev-parse HEAD)" ph2)"

yq -i '.env.hub.image.tag = "9999.0.0"' "$REPO/csi-spl-cnf/csi-spl/prd.env.yaml"
check "cnf: prd's hub image tag newer than dev's" 1 '^cnf +hub.image.tag .* 9999.0.0 +prd-leads'
git -C "$REPO" checkout -q -- csi-spl-cnf/csi-spl/prd.env.yaml

check "tf: a plan error is unknown" 2 '^tf +030-x +error +clean +unknown' STUB_DEV_RC=1
grep -q '^ENV_ORDER UNKNOWN' <<<"$out" && pass "an unknown row is named" || fail "no UNKNOWN line: $out"
mkdir -p "$T/nodocker"; printf '#!/bin/sh\nexit 1\n' >"$T/nodocker/docker"; chmod +x "$T/nodocker/docker"
check "no tf-runner -> one unknown tf row" 2 'tf-runner con-csi-csi-spl-tf-runner is not running' ENV_ORDER_PLAN_CMD= PATH="$T/nodocker:$PATH"
check "ENV_ORDER_TF=0 skips the tf rows" 0 'ENV_ORDER OK' ENV_ORDER_TF=0 STUB_DEV_RC=2

code=$(grep -vE '^[[:space:]]*#' "$ACTION_FILE")
grep -qE 'gcloud|do_provision|do_tf_apply|terraform .*apply|make do-provision' <<<"$code" \
  && fail "the drift check calls a mutating command" || pass "the drift check only plans and reads"

# --- 7. the daily tick script -------------------------------------------------
SCRIPT="$PROJ_ROOT/src/bash/scripts/check-env-order.sh"
cat >"$T/run" <<'EOF'
#!/bin/sh
printf 'INFO START noise\nkind item dev prd verdict note\ntf   030-x pending clean prd-leads\nENV_ORDER FAIL: prd leads dev in 1 row(s)\n'
exit "$STUB_RC"
EOF
printf '#!/bin/sh\necho "$@" >>"$SENT"\n' >"$T/send"; chmod +x "$T/run" "$T/send"
# tick <n> [env...]: one tick, notes to $T/sent.<n>
tick() { local n="$1"; shift; env ENV_ORDER_RUN="$T/run" ENV_ORDER_SEND="$T/send" ENV_ORDER_FROM=c-001 SENT="$T/sent.$n" "$@" bash "$SCRIPT" 2>&1; }
out="$(tick a STUB_RC=1 DRY_RUN=0)"; rc=$?
[[ $rc -eq 1 ]] && grep -q -- '--to orchestrator --kind note --task env-order' "$T/sent.a" 2>/dev/null \
  && pass "7. prd leads -> one note to the orchestrator, exit 1" || fail "7. note (rc=$rc): $out / $(cat "$T/sent.a" 2>&1)"
grep -q '    tf   030-x pending clean prd-leads' "$T/sent.a" && ! grep -q 'INFO START' "$T/sent.a" \
  && pass "7. the note carries the table rows, not the log noise" || fail "7. body: $(cat "$T/sent.a")"
out="$(tick b STUB_RC=1)"; rc=$?
[[ $rc -eq 1 && ! -e "$T/sent.b" && "$out" == *'PLAN DRY_RUN'* ]] && pass "7. DRY_RUN (default) sends nothing" || fail "7. dry (rc=$rc): $out"
for c in 0 2; do
  out="$(tick "c$c" STUB_RC=$c DRY_RUN=0)"; rc=$?
  [[ $rc -eq $c && ! -e "$T/sent.c$c" ]] && pass "7. exit $c -> no note, same exit" || fail "7. rc $c: got $rc, sent=$(cat "$T/sent.c$c" 2>&1)"
done

# --- 8. the cron installer ----------------------------------------------------
SH="$T/shared"; mkdir -p "$SH/csi-spl-orc/src/bash/scripts"
printf '#!/bin/sh\n' >"$SH/csi-spl-orc/src/bash/scripts/check-env-order.sh"; chmod +x "$SH/csi-spl-orc/src/bash/scripts/check-env-order.sh"
mkdir -p "$T/cbin"
printf '#!/usr/bin/env bash\nif [ "${1:-}" = -l ]; then cat "$FAKE_CRONTAB" 2>/dev/null; exit 0; fi\ncp "$1" "$FAKE_CRONTAB"\n' >"$T/cbin/crontab"
chmod +x "$T/cbin/crontab"
printf '%s\n' '# keep me' '*/5 * * * * /x/box-stats-cron.sh >> /l/cron.out 2>&1 # csi-spl:box-stats' >"$T/crontab"
cp "$T/crontab" "$T/crontab.orig"
inst() {
  env PROJ_PATH="$PROJ_ROOT" APP_PATH="$PROJ_ROOT" PATH="$T/cbin:$PATH" FAKE_CRONTAB="$T/crontab" SPL_ORG_APP=csi-spl \
    DESK_CRON_SRC="$SH" ENV_ORDER_CRON_LOG_DIR="$T/log" "$@" bash -c '
    set -uo pipefail
    do_log() { printf "%s\n" "$*"; }
    do_require_bin() { return 0; }
    source "'"$PROJ_ROOT"'/src/bash/run/check-env-order-install-cron.func.sh"
    do_check_env_order_install_cron' 2>&1
}
want="23 5 * * * DRY_RUN=0 $SH/csi-spl-orc/src/bash/scripts/check-env-order.sh >> $T/log/cron.out 2>&1 # csi-spl:env-order"
out="$(inst)"; rc=$?
[[ $rc -eq 0 && "$out" == *'DRY_RUN nothing was touched'* && "$out" == *"+$want"* ]] && cmp -s "$T/crontab" "$T/crontab.orig" \
  && pass "8. the dry run prints the daily line and writes nothing" || fail "8. dry (rc=$rc): $out"
out="$(inst ENV_ORDER_CRON_ACTION=check)"; rc=$?
[[ $rc -eq 1 && "$out" == *'NOT installed'* ]] && pass "8. CONTROL: check fails while it is not installed" || fail "8. check before (rc=$rc): $out"
out="$(inst DRY_RUN=0)"; rc=$?
[[ $rc -eq 0 && "$(grep -F -x -c "$want" "$T/crontab")" -eq 1 && -d "$T/log" ]] \
  && pass "8. DRY_RUN=0 adds ONE tagged daily line and the log dir" || fail "8. install (rc=$rc): $out / $(cat "$T/crontab")"
cp "$T/crontab" "$T/crontab.once"; inst DRY_RUN=0 >/dev/null
cmp -s "$T/crontab" "$T/crontab.once" && pass "8. a second install changes no byte" || fail "8. reinstall: $(cat "$T/crontab")"
out="$(inst ENV_ORDER_CRON_ACTION=check)"; rc=$?
[[ $rc -eq 0 ]] && pass "8. check passes once installed" || fail "8. check (rc=$rc): $out"
out="$(inst ENV_ORDER_CRON_AT=25:00)"; rc=$?
[[ $rc -eq 1 && "$out" == *'must be HH:MM'* ]] && pass "8. a bad ENV_ORDER_CRON_AT is refused" || fail "8. at (rc=$rc): $out"
out="$(inst DESK_CRON_SRC=/opt/x-wt/c-1)"; rc=$?
[[ $rc -eq 1 ]] && pass "8. an agent worktree is refused" || fail "8. worktree (rc=$rc): $out"
inst DRY_RUN=0 ENV_ORDER_CRON_ACTION=remove >/dev/null
cmp -s "$T/crontab" "$T/crontab.orig" && pass "8. remove restores the crontab byte for byte" || fail "8. remove: $(cat "$T/crontab")"

[[ $fails -eq 0 ]] && echo "PASS: all check-env-order assertions" || { echo "FAILED: $fails"; exit 1; }
