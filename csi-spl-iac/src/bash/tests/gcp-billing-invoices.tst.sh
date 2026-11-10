#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the billing-account actions (spec 123 section 15, SPL-5220), offline:
#   A. do_gcp_billing_invoices_fetch, on the REAL pin lib (gcp-account-pin):
#      1. every gcloud call carries --account=<the billing SA> and runs under a
#         throwaway CLOUDSDK_CONFIG; ~/.config/gcloud is never made; an
#         inherited ACCOUNT / GCP_ACCOUNT (the owner's) is not used.
#      2. the window: 2026-11-10 x 12 -> invoice months 202511..202610, in the
#         query and in summary.tsv (2 accounts x 12 rows), amounts filled.
#      3. a PDF the browser saved (dated month+1) ticks its month "have".
#      4. no key / a key of another SA / no account readable / a bad day or
#         count -> FATAL rc 1, nothing read (no billing call).
#      5. BigQuery denied -> WARNING, rc 0, the checklist still written.
#      6. ids masked in the log, the token never in the log or argv; the out
#         dir is mode 700.
#   B. do_gcp_billing_sa_create: the dry run (default) prints 2 would-run and
#      the owner steps, NO mutation; CONTROL DRY_RUN=0 makes the 2; everything
#      present -> none; an owner (user) identity and DRY_RUN=2 are refused.
#   C. do_gcp_billing_invoices_browser: refused (node never started) under
#      AGENT_ID / CLAUDECODE / SPOOL_AGENT_ID, under SUDO_USER with those
#      markers dropped (the fleet's `sudo -u <user> bash -c`), under an
#      ancestor process named claude/agy/grok/vibe/qwen (the /proc walk is
#      also run for real, under a bash copy named claude), and without a
#      terminal; playwright-core installed at the PINNED version, once; on a
#      terminal (script(1)) node gets the accounts of the newest fetch run and
#      a fresh mode-700 TMPDIR (the throwaway profile) that is gone after the
#      run, and after a TERM too; download.mjs uses launch(), never a
#      persistent context. The out dir inside a git work tree is refused.
#   D. node --test of src/js/billing-invoices/lib.mjs (the row choice), when
#      node is on the box; else NOT RUN.
# Stubs: gcloud, curl, npm, node on PATH (they log their argv). Nothing
# reaches GCP, npm or a browser.
#------------------------------------------------------------------------------
set -uo pipefail

TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
FETCH="$PROJ_ROOT/src/bash/run/gcp-billing-invoices-fetch.func.sh"
SACR="$PROJ_ROOT/src/bash/run/gcp-billing-sa-create.func.sh"
BROW="$PROJ_ROOT/src/bash/run/gcp-billing-invoices-browser.func.sh"
LIBS="$PROJ_ROOT/lib/bash/funcs/gcp-billing-cnf.func.sh $PROJ_ROOT/lib/bash/funcs/spl-cost-gcp.func.sh $PROJ_ROOT/lib/bash/funcs/gcp-account-pin.func.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fails=0

for f in "$FETCH" "$SACR" "$BROW"; do require_action "$f"; done
bash -n "$FETCH" && bash -n "$SACR" && bash -n "$BROW" && pass "bash -n the three actions" || fail "bash -n"

SA=spl-billing@csi-spl-all.iam.gserviceaccount.com
A1=0A1B2C-3D4E5F-6A7B8C A2=0F0E0D-0C0B0A-090807
stub gcloud '
echo "gcloud $* CFG=${CLOUDSDK_CONFIG:-}" >>"$LOG"
case "$*" in
  "auth list"*) exit 0 ;;
  "auth activate-service-account"*) exit 0 ;;
  "auth print-access-token"*) echo tok-SECRET-1 ;;
  "billing accounts list"*) [[ -n "${STUB_NO_ACCT:-}" ]] && { echo "[]"; exit 0; }
    echo "[{\"name\":\"billingAccounts/$A1\",\"displayName\":\"Main\",\"open\":true},{\"name\":\"billingAccounts/$A2\",\"displayName\":\"Old\",\"open\":true}]" ;;
  "billing projects list --billing-account=$A1"*) printf "csi-spl-dev\tTrue\ncsi-spl-prd\tTrue\n" ;;
  "billing projects list"*) printf "other-proj\tTrue\n" ;;
  "iam service-accounts describe"*) [[ "$STATE" == present ]] && { echo "$SA"; exit 0; }; echo "ERROR: NOT_FOUND: Unknown service account" >&2; exit 1 ;;
  "projects get-iam-policy"*) [[ "$STATE" == present ]] && echo "{\"bindings\":[{\"role\":\"roles/bigquery.jobUser\",\"members\":[\"serviceAccount:$SA\"]}]}" || echo "{}" ;;
esac
exit 0'
stub curl '
hdr=$(cat); printf "%s\n" "$hdr" >>"$LOG.stdin"; echo "curl $*" >>"$LOG"
for a in "$@"; do [[ "$a" == @* ]] && cp "${a#@}" "$LOG.body"; done
[[ -n "${BQ_DENY:-}" ]] && { printf "{\"error\":{\"message\":\"Access Denied: billing export\"}}\n403"; exit 0; }
printf "{\"jobComplete\":true,\"rows\":[{\"f\":[{\"v\":\"$A1\"},{\"v\":\"202610\"},{\"v\":\"EUR\"},{\"v\":\"1254.5\"}]},{\"f\":[{\"v\":\"$A1\"},{\"v\":\"202609\"},{\"v\":\"EUR\"},{\"v\":\"980\"}]}]}\n200"'
stub npm 'echo "npm $*" >>"$LOG"; for ((i = 1; i <= $#; i++)); do [[ "${!i}" == --prefix ]] && { j=$((i + 1)); d="${!j}"; }; done
mkdir -p "$d/node_modules/playwright-core"; echo "{\"version\":\"${STUB_PW_VER:-1.65.0}\"}" >"$d/node_modules/playwright-core/package.json"'
stub node 'echo "node $* ACCOUNTS=$BILLING_ACCOUNTS TODAY=$BILLING_TODAY MONTHS=$BILLING_MONTHS PDF=$BILLING_PDF_DIR DRY=$BILLING_DRY" >>"$LOG"
echo "TMPDIR=$TMPDIR MODE=$(stat -c %a "$TMPDIR")" >>"$LOG"; mkdir -p "$TMPDIR/playwright_chromiumdev_profile-x"; echo cookie >"$TMPDIR/playwright_chromiumdev_profile-x/Cookies"
[[ -n "${STUB_NODE_TERM:-}" ]] && { kill -TERM "$PPID"; sleep 1; }; exit 0'

key() { mkdir -p "$T/home/.gcp/.csi"; printf '{"type":"service_account","client_email":"%s"}\n' "$1" >"$T/home/.gcp/.csi/key-csi-spl-billing.json"; }

# run <out> <function> [VAR=value ...] - the action in a fresh shell, HOME=$T/home
run() {
  local out="$1" fn="$2"; shift 2
  : >"$T/log"; : >"$T/log.stdin"; rm -f "$T/log.body"
  env -u ACCOUNT -u GCP_ACCOUNT -u CLOUDSDK_CONFIG -u DRY_RUN -u AGENT_ID -u SPOOL_AGENT_ID -u CLAUDECODE -u SUDO_USER \
    -u BILLING_SA_KEY_FILE -u BILLING_OUT_DIR -u BILLING_ACCOUNT_IDS \
    PATH="$T/bin:$PATH" HOME="$T/home" LOG="$T/log" STATE=absent SA="$SA" A1="$A1" A2="$A2" APP_PATH="$APP_ROOT" \
    BILLING_TODAY=2026-11-10 LIBS="$LIBS" FETCH="$FETCH" SACR="$SACR" BROW="$BROW" FN="$fn" "$@" bash -c '
    do_log(){ echo "$*"; }
    do_resolve_oap(){ case "$1" in ORG) export ORG=csi ;; APP) export APP=spl ;; esac; }
    for l in $LIBS; do source "$l"; done
    source "$FETCH"; source "$SACR"; source "$BROW"
    [[ -n "${STUB_PIN:-}" ]] && do_gcp_pin_account(){ GCP_ACCOUNT="$STUB_PIN"; export GCP_ACCOUNT; }
    [[ -n "${STUB_ANCESTORS:-}" ]] && _gbb_ancestor_comms(){ tr " " "\n" <<<"$STUB_ANCESTORS"; }
    $FN; echo "rc=$?"' >"$out" 2>&1
}
calls() { grep -E '^gcloud (billing|iam|projects|services)|^curl ' "$T/log"; }
OUT="$T/home/.local/share/csi-spl/billing-invoices"

# --- A. fetch -------------------------------------------------------------------
key "$SA"
run "$T/o" do_gcp_billing_invoices_fetch ACCOUNT=owner@example.com GCP_ACCOUNT=owner@example.com
grep -q '^rc=0$' "$T/o" && pass "fetch: rc 0 (an inherited ACCOUNT / GCP_ACCOUNT set)" || fail "fetch rc: $(cat "$T/o")"
n_g=$(grep -cE '^gcloud (billing|auth print)' "$T/log")
[[ "$n_g" -eq 4 ]] && [[ -z "$(grep -E '^gcloud (billing|auth print)' "$T/log" | grep -v -- "--account=$SA ")" ]] \
  && pass "fetch: all $n_g account/project/token calls carry --account=$SA, never the inherited owner" \
  || fail "fetch --account: $(grep '^gcloud' "$T/log")"
cfgs=$(grep '^gcloud' "$T/log" | sed 's/.* CFG=//' | sort -u)
[[ "$(wc -l <<<"$cfgs")" -eq 1 && -n "$cfgs" && "$cfgs" != "$T/home/.config/gcloud" ]] && [[ ! -e "$T/home/.config/gcloud" ]] \
  && grep -q '^gcloud auth activate-service-account --key-file=' "$T/log" \
  && pass "fetch: the key is activated in ONE throwaway CLOUDSDK_CONFIG; ~/.config/gcloud is never made" \
  || fail "fetch config: [$cfgs] $(ls -a "$T/home/.config" 2>&1)"
S="$OUT/2026-11-10/summary.tsv"
[[ "$(tail -n +2 "$S" | wc -l)" -eq 24 ]] && [[ "$(awk -F'\t' -v a="$A1" 'NR > 1 && $1 == a { print $3 }' "$S" | paste -sd' ')" == "202511 202512 202601 202602 202603 202604 202605 202606 202607 202608 202609 202610" ]] \
  && grep -qP "^$A1\tMain\t202610\tEUR\t1254.5\ttodo$" "$S" && grep -qP "^$A2\tOld\t202610\t-\t-\ttodo$" "$S" \
  && pass "fetch: 2026-11-10 x 12 -> 202511..202610 per account (24 rows), the export amount filled, '-' where none" \
  || fail "summary: $(cat "$S" 2>&1)"
jq -e '[.queryParameters[].parameterValue.value] == ["202511", "202610"] and (.query | test("gcp_billing_export_v1_\\*"))' "$T/log.body" >/dev/null 2>&1 \
  && grep -q '^curl .*/projects/csi-spl-all/queries$' "$T/log" \
  && pass "fetch: one query over the export, invoice.month 202511..202610, its job in csi-spl-all" || fail "query: $(cat "$T/log.body" 2>&1)"
[[ -s "$OUT/2026-11-10/projects-$A1.tsv" ]] && grep -q "console.cloud.google.com/billing/$A1/documents" "$OUT/2026-11-10/README.md" \
  && pass "fetch: projects per account and the README checklist with each account's documents link" || fail "projects/README"
! grep -qF "$A1" "$T/o" && ! grep -qF "$A2" "$T/o" && grep -q 'XXXXXX-XXXXXX-6A7B8C' "$T/o" \
  && pass "fetch: billing account ids are logged masked only" || fail "ids leaked: $(grep -E "$A1|$A2" "$T/o")"
! grep -q 'tok-SECRET' "$T/o" "$T/log" && grep -q 'Bearer tok-SECRET-1' "$T/log.stdin" \
  && pass "fetch: the token reaches curl on stdin only" || fail "token in argv/log"
[[ "$(stat -c %a "$OUT")" == 700 && "$(stat -c %a "$OUT/2026-11-10")" == 700 ]] \
  && pass "fetch: the out dir is mode 700" || fail "out mode: $(stat -c %a "$OUT" "$OUT/2026-11-10")"

mkdir -p "$OUT/pdf/$A1" && : >"$OUT/pdf/$A1/2026-11-01-5123456789.pdf"
run "$T/o" do_gcp_billing_invoices_fetch
grep -qP "^$A1\tMain\t202610\tEUR\t1254.5\thave$" "$S" && grep -qP "^$A1\tMain\t202609\tEUR\t980\ttodo$" "$S" \
  && pass "fetch: a PDF dated 2026-11-01 ticks invoice month 202610 'have', 202609 stays 'todo'" || fail "have: $(grep "$A1" "$S")"

run "$T/o" do_gcp_billing_invoices_fetch BQ_DENY=1
grep -q '^rc=0$' "$T/o" && grep -q 'WARNING amounts NOT read .*Access Denied' "$T/o" && grep -qP "^$A1\tMain\t202610\t-\t-\t" "$S" \
  && pass "fetch: BigQuery denied -> WARNING, rc 0, the checklist still written" || fail "bq deny: $(cat "$T/o")"

run "$T/o" do_gcp_billing_invoices_fetch STUB_NO_ACCT=1
grep -q '^rc=1$' "$T/o" && grep -q 'holds no role on any billing account' "$T/o" && [[ -s "$OUT/2026-11-10/accounts.tsv" ]] \
  && pass "fetch: no readable account -> FATAL rc 1, the last good accounts.tsv is kept" || fail "no acct: $(cat "$T/o")"

key other@csi-spl-all.iam.gserviceaccount.com
run "$T/o" do_gcp_billing_invoices_fetch
grep -q '^rc=1$' "$T/o" && grep -q 'is not the billing SA' "$T/o" && [[ -z "$(calls)" ]] \
  && pass "fetch: a key of another SA -> refused, nothing read" || fail "other key: $(cat "$T/o") / $(calls)"
rm -f "$T/home/.gcp/.csi/key-csi-spl-billing.json"
run "$T/o" do_gcp_billing_invoices_fetch ACCOUNT=owner@example.com
grep -q '^rc=1$' "$T/o" && grep -q 'no billing SA key' "$T/o" && [[ ! -s "$T/log" ]] \
  && pass "fetch: no key -> FATAL rc 1, no gcloud call (the owner account is never a fallback)" || fail "no key: $(cat "$T/o") / $(cat "$T/log")"
key "$SA"
for bad in "BILLING_MONTHS=0" "BILLING_MONTHS=37" "BILLING_TODAY=10.11.2026"; do
  run "$T/o" do_gcp_billing_invoices_fetch "$bad"
  grep -q '^rc=1$' "$T/o" && [[ ! -s "$T/log" ]] && pass "fetch: $bad -> refused before any call" || fail "$bad: $(cat "$T/o")"
done

# --- B. sa create -------------------------------------------------------------------
P=csi-spl-all@csi-spl-all.iam.gserviceaccount.com
mutations() { grep -E '^gcloud (iam service-accounts create|.*add-iam-policy-binding)' "$T/log"; }
run "$T/o" do_gcp_billing_sa_create STUB_PIN="$P"
grep -q '^rc=0$' "$T/o" && [[ "$(grep -c 'DRY_RUN would run' "$T/o")" -eq 2 ]] && [[ -z "$(mutations)" ]] \
  && pass "sa_create: the default dry run prints 2 would-run (create, jobUser), no mutation" || fail "sa dry: $(cat "$T/o") / $(mutations)"
grep -q "billing accounts add-iam-policy-binding <BILLING_ACCOUNT_ID> --member=serviceAccount:$SA --role=roles/billing.viewer --account=<OWNER_LOGIN>" "$T/o" \
  && grep -q 'role=roles/billing.user ' "$T/o" && grep -q 'role=roles/billing.projectManager ' "$T/o" \
  && grep -q "keys create \"\$HOME/.gcp/.csi/key-csi-spl-billing.json\" --iam-account=$SA" "$T/o" \
  && ! grep -qE '^gcloud billing accounts add-iam' "$T/log" \
  && pass "sa_create: the owner steps (viewer, user, projectManager, the key) are printed, never run" || fail "owner steps: $(cat "$T/o")"
run "$T/o" do_gcp_billing_sa_create STUB_PIN="$P" DRY_RUN=0
grep -q '^rc=0$' "$T/o" && [[ "$(mutations | wc -l)" -eq 2 ]] && [[ -z "$(mutations | grep -v -- "--account=$P")" ]] \
  && pass "sa_create CONTROL: DRY_RUN=0 makes the 2 mutations, as the csi-spl-all SA" || fail "sa run: $(mutations) / $(cat "$T/o")"
run "$T/o" do_gcp_billing_sa_create STUB_PIN="$P" DRY_RUN=0 STATE=present
grep -q '^rc=0$' "$T/o" && [[ -z "$(mutations)" ]] && pass "sa_create: everything present -> no mutation (idempotent)" || fail "sa idem: $(mutations)"
run "$T/o" do_gcp_billing_sa_create STUB_PIN=owner@example.com
grep -q '^rc=1$' "$T/o" && grep -q 'is no service account' "$T/o" && [[ -z "$(calls)" ]] \
  && pass "sa_create: an owner (user) identity -> refused before any call" || fail "sa owner: $(cat "$T/o")"
run "$T/o" do_gcp_billing_sa_create STUB_PIN="$P" DRY_RUN=2
grep -q 'DRY_RUN must be 0 or 1' "$T/o" && [[ ! -s "$T/log" ]] && pass "sa_create: DRY_RUN=2 -> refused" || fail "sa DRY_RUN=2"

# --- C. browser -------------------------------------------------------------------
for v in AGENT_ID=c-000 CLAUDECODE=1 SPOOL_AGENT_ID=c-000; do
  run "$T/o" do_gcp_billing_invoices_browser "$v" DISPLAY=:99 STUB_ANCESTORS="bash script"
  grep -q '^rc=1$' "$T/o" && grep -q 'an agent never runs this' "$T/o" && ! grep -q '^node' "$T/log" \
    && pass "browser: $v -> refused, node never started" || fail "browser $v: $(cat "$T/o")"
done
# the fleet's `sudo -u <user> bash -c`: the env markers are gone, SUDO_USER is set
run "$T/o" do_gcp_billing_invoices_browser SUDO_USER=agentuser DISPLAY=:99 STUB_ANCESTORS="bash sudo bash"
grep -q '^rc=1$' "$T/o" && grep -q 'under sudo' "$T/o" && ! grep -q '^node' "$T/log" \
  && pass "browser: under sudo (markers dropped, SUDO_USER set) -> refused, node never started" || fail "browser sudo: $(cat "$T/o")"
for a in claude agy grok vibe qwen; do
  run "$T/o" do_gcp_billing_invoices_browser DISPLAY=:99 STUB_ANCESTORS="bash $a tmux:"
  grep -q '^rc=1$' "$T/o" && grep -q "($a is an ancestor process)" "$T/o" && ! grep -q '^node' "$T/log" \
    || { fail "browser ancestor $a: $(cat "$T/o")"; continue; }
  [[ $a == qwen ]] && pass "browser: an ancestor named claude/agy/grok/vibe/qwen (markers dropped) -> refused, node never started"
done
# the real /proc walk, under a bash copy named claude (two commands: no exec)
mkdir -p "$T/agent"; cp "$(command -v bash)" "$T/agent/claude"
"$T/agent/claude" -c "bash -c 'source $BROW; _gbb_ancestor_comms' >$T/anc; true"
[[ "$(sed -n 1p "$T/anc")" == claude ]] && pass "browser: the /proc ancestor walk sees a real ancestor named claude" || fail "ancestor walk: $(tr '\n' ' ' <"$T/anc")"
run "$T/o" do_gcp_billing_invoices_browser DISPLAY=:99 STUB_ANCESTORS="bash script"
grep -q '^rc=1$' "$T/o" && grep -q 'no terminal' "$T/o" && ! grep -q '^node' "$T/log" \
  && pass "browser: no terminal -> refused" || fail "browser no tty: $(cat "$T/o")"
mkdir -p "$T/repo/.git"
run "$T/o" do_gcp_billing_invoices_fetch BILLING_OUT_DIR="$T/repo/sub/out"
grep -q '^rc=1$' "$T/o" && grep -q 'out dir (BILLING_OUT_DIR) is inside a git work tree' "$T/o" && [[ -z "$(calls)" ]] && [[ ! -e "$T/repo/sub" ]] \
  && pass "fetch: an out dir inside a git work tree is refused before any call" || fail "out in git: $(cat "$T/o")"
rm -rf "$T/pw"
run "$T/o" "_gbb_playwright $T/pw"; run "$T/o2" "_gbb_playwright $T/pw"
[[ "$(grep -c '^npm install' "$T/log")" -eq 0 ]] && grep -q '^rc=0$' "$T/o2" \
  && jq -e '.version == "1.65.0"' "$T/pw/node_modules/playwright-core/package.json" >/dev/null \
  && pass "browser: playwright-core installed at the pinned 1.65.0, and not again once there" || fail "pw: $(cat "$T/o" "$T/o2")"
rm -rf "$T/pw"; run "$T/o" "_gbb_playwright $T/pw"
grep -qE '^npm install --prefix .*/pw .*playwright-core@1\.65\.0$' "$T/log" && pass "browser: the npm install names playwright-core@1.65.0 exactly" || fail "npm: $(cat "$T/log")"
# script(1) gives the run a terminal; the runner file carries run() and its vars
tty_run() {
  { echo '#!/bin/bash'; declare -p T APP_ROOT LIBS FETCH SACR BROW SA A1 A2; declare -f run
    echo "run \"\$T/o\" do_gcp_billing_invoices_browser DISPLAY=:99 BILLING_CHROME=bash STUB_ANCESTORS='bash script' $*"; } >"$T/tty.sh"
  script -qec "bash $T/tty.sh" /dev/null </dev/null >/dev/null 2>&1
  tmpd=$(sed -n 's/^TMPDIR=\([^ ]*\) .*/\1/p' "$T/log")
}
tty_run
grep -q '^rc=0$' "$T/o" && grep -q "^node .*/src/js/billing-invoices/download.mjs ACCOUNTS=$A1,$A2 TODAY=2026-11-10 MONTHS=12 PDF=$OUT/pdf DRY=0$" "$T/log" \
  && pass "browser: on a terminal, node gets the newest fetch run's accounts" \
  || fail "browser tty: $(cat "$T/o") / $(cat "$T/log")"
[[ -n "$tmpd" && "$tmpd" != "$T/home"* ]] && grep -q "^TMPDIR=$tmpd MODE=700$" "$T/log" && [[ ! -e "$tmpd" ]] \
  && ! grep -qi 'profile' "$T/o" \
  && pass "browser: Chrome's profile lives in a fresh mode-700 TMPDIR, removed after the run; no profile path logged" \
  || fail "throwaway: [$tmpd] $(ls -la "$tmpd" 2>&1) / $(cat "$T/o")"
tty_run STUB_NODE_TERM=1
grep -q '^rc=143$' "$T/o" && [[ -n "$tmpd" && ! -e "$tmpd" ]] \
  && pass "browser: on a TERM the throwaway profile is removed too (rc 143)" || fail "throwaway TERM: [$tmpd] $(cat "$T/o")"
code=$(grep -vE '^\s*//' "$PROJ_ROOT/src/js/billing-invoices/download.mjs")
grep -q 'chromium.launch(' <<<"$code" && ! grep -q 'launchPersistentContext\|userDataDir\|BILLING_CHROME_PROFILE' <<<"$code" \
  && pass "browser: download.mjs uses chromium.launch() + newContext(), never a persistent profile" || fail "download.mjs persistent"

# --- D. node --test of the row choice -------------------------------------------------
if command -v node >/dev/null 2>&1 && [[ "$(command -v node)" != "$T/bin/node" ]]; then
  node --test "$PROJ_ROOT/src/js/billing-invoices/lib.test.mjs" >"$T/n" 2>&1 \
    && pass "node --test lib.test.mjs ($(grep -c '^ok ' "$T/n") ok)" || fail "node --test: $(tail -20 "$T/n")"
else
  echo "NOT RUN: node --test lib.test.mjs (no node on this box)"
fi

[[ $fails -eq 0 ]] && echo "ALL PASSED" || { echo "$fails FAILED"; exit 1; }
