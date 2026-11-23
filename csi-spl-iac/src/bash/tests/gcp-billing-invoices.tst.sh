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
#   B. do_gcp_billing_sa_create (read only since SPL-5265: terraform step
#      002-gcp-billing-sa is the one creator): absent -> it names the step's
#      plan command and prints the owner steps, NO mutation; present -> OK, no
#      mutation; DRY_RUN=0 is refused before any gcloud call; an owner (user)
#      identity and DRY_RUN=2 are refused. CONTROL: a copy of the action
#      planted with a create call is caught by the same mutation check.
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
#   E. download.mjs itself on static console pages (fixtures/billing-invoices,
#      a fake playwright-core, SPL-5810): it opens /billing/<id> and follows the
#      overview's own "Invoices" (else "Payment status") link, never
#      /billing/<id>/documents; a not-found page, no such entry, a not-found
#      page behind it or no documents list -> one FATAL line, the id masked to
#      its last 4, rc 2. CONTROL: the old /documents path on the same pages.
#      R7 c-073: a lazily filling list is read once its row count holds
#      (CONTROL: one read saves 1 of 3, rc 0); a list that never stops
#      loading or has more pages, or an entry leading off the console -> FATAL;
#      the direct, checkbox + "Download selected" and menu paths save real
#      %PDF- files; a .zip name or a non-PDF body -> FATAL, nothing left; the
#      payments iframe beats the page's own table; an href-less entry is
#      clicked; a Chrome that fails to start -> one line, rc 2. SPL-6333: the
#      wait budget counts poll waits, not the wall clock: page reads slower
#      than the whole budget still pass (CONTROL: a wall-clock deadline FATALs).
# Stubs: gcloud, curl, npm, node on PATH (they log their argv); E runs the
# real node on a fake playwright-core. Nothing reaches GCP, npm or a browser.
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
[[ -s "$OUT/2026-11-10/projects-$A1.tsv" ]] && grep -qx "https://console.cloud.google.com/billing/$A1 (then Invoices, or Payment status)" "$OUT/2026-11-10/README.md" \
  && ! grep -q "/documents" "$OUT/2026-11-10/README.md" \
  && pass "fetch: projects per account and the README checklist with each account's overview link (never the gone /documents, SPL-5810)" || fail "projects/README"
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
grep -q '^rc=0$' "$T/o" && [[ -z "$(mutations)" ]] && grep -q 'WARN the SA and its jobUser missing: terraform step 002-gcp-billing-sa creates them: cd csi-spl-orc && ENV=prd STEP=002-gcp-billing-sa make do-tf-plan' "$T/o" \
  && grep -q 'nothing was changed' "$T/o" \
  && pass "sa_create: absent -> points to terraform step 002-gcp-billing-sa, no mutation" || fail "sa absent: $(cat "$T/o") / $(mutations)"
grep -q "billing accounts add-iam-policy-binding <BILLING_ACCOUNT_ID> --member=serviceAccount:$P --role=roles/billing.admin --account=<OWNER_LOGIN>" "$T/o" \
  && grep -q "step 002-gcp-billing-sa grants $SA roles/billing.viewer + roles/billing.user on each (owner msg a508c121)" "$T/o" \
  && ! grep -q -- "--member=serviceAccount:$SA --role=roles/billing.viewer" "$T/o" \
  && grep -q 'role=roles/billing.projectManager ' "$T/o" \
  && grep -q "KEY: terraform step 002-gcp-billing-sa makes it and writes $T/home/.gcp/.csi/key-csi-spl-billing.json (mode 0600)" "$T/o" \
  && ! grep -q 'keys create' "$T/o" \
  && ! grep -qE '^gcloud billing accounts add-iam' "$T/log" \
  && pass "sa_create: the owner steps (billing admin for the csi-spl-all SA, projectManager) are printed, never run; viewer + user and the key are named as step 002's" || fail "owner steps: $(cat "$T/o")"
run "$T/o" do_gcp_billing_sa_create STUB_PIN="$P" STATE=present
grep -q '^rc=0$' "$T/o" && [[ -z "$(mutations)" ]] && grep -q "OK $SA exists with jobUser on csi-spl-all (terraform step 002-gcp-billing-sa)" "$T/o" \
  && pass "sa_create: present -> OK, no mutation" || fail "sa present: $(cat "$T/o") / $(mutations)"
run "$T/o" do_gcp_billing_sa_create STUB_PIN="$P" DRY_RUN=0
grep -q '^rc=1$' "$T/o" && grep -q 'DRY_RUN=0 refused: this action creates nothing.*terraform step 002-gcp-billing-sa' "$T/o" && [[ ! -s "$T/log" ]] \
  && pass "sa_create: DRY_RUN=0 -> refused before any gcloud call (the step is the one creator)" || fail "sa DRY_RUN=0: $(cat "$T/o") / $(cat "$T/log")"
# CONTROL: the same check sees a create the action would make
sed 's/gcloud iam service-accounts describe/gcloud iam service-accounts create/' "$SACR" >"$T/sacr-planted.sh"
run "$T/o" do_gcp_billing_sa_create STUB_PIN="$P" SACR="$T/sacr-planted.sh"
[[ -n "$(mutations)" ]] && pass "sa_create CONTROL: a planted create call is caught by the mutation check" || fail "sa control: the planted create was not seen ($(cat "$T/log"))"
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

# --- E. download.mjs on static console pages (SPL-5810) -------------------------------
# A fake playwright-core serves the fixture pages by the last path segment of
# the URL (the account id = the overview); an unknown path gets the console's
# not-found page, as Google answered /billing/<id>/documents (owner msg 917d252a).
FIX="$TEST_DIR/fixtures/billing-invoices"
DL="$PROJ_ROOT/src/js/billing-invoices/download.mjs"
mkdir -p "$T/fakepw/node_modules/playwright-core"
echo '{"name":"playwright-core","main":"index.js"}' >"$T/fakepw/node_modules/playwright-core/package.json"
cat >"$T/fakepw/node_modules/playwright-core/index.js" <<'JS'
const fs = require('node:fs');
const E = process.env;
const log = (l) => fs.appendFileSync(E.FAKE_LOG, `${l}\n`);
const map = Object.fromEntries((E.FAKE_MAP || '').split(',').filter(Boolean).map((kv) => kv.split('=')));
const file = (f) => fs.readFileSync(`${E.FAKE_FIX}/${f}`, 'utf8');
const serve = (url) => {
  const seg = new URL(url).pathname.split('/').filter(Boolean).pop();
  const key = /^[0-9A-F]{6}-[0-9A-F]{6}-[0-9A-F]{6}$/.test(seg) ? 'overview' : seg;
  return [key, file(map[key] || 'not-found.html')];
};
const rows = (html) => [...html.matchAll(/<tr\b[^>]*>([\s\S]*?)<\/tr>/gi)].map((m) => m[1].replace(/<[^>]*>/g, ' ').replace(/\s+/g, ' ').trim());
if (E.FAKE_LAUNCH_FAIL) exports.chromium = { launch: async () => { throw new Error('Failed to launch: /bin/false --user-data-dir=/tmp/x\n  at stack'); } };
else exports.chromium = { launch: async () => ({ newContext: async () => ({ newPage: async () => page() }), close: async () => {} }) };
function page() {
  let url = 'about:blank', html = '', key = '', reads = 0, fire = null;
  const download = () => { const n = E.FAKE_DL_NAME || 'invoice.pdf'; log(`download ${n}`);
    fire({ suggestedFilename: () => n, saveAs: async (f) => fs.writeFileSync(f, E.FAKE_DL_BODY || '%PDF-1.4 fake') }); };
  const ctl = (on, act) => ({ first: () => ({ count: async () => (on ? 1 : 0), click: async () => act && act() }) });
  // a row: its controls per FAKE_DL (direct | checkbox | menu); the zip/html name and body come from FAKE_DL_*
  const row = () => ({ locator: (sel) => {
    if (/ownload/.test(sel)) return ctl(E.FAKE_DL === 'direct', download);
    if (/checkbox/.test(sel)) return ctl(E.FAKE_DL === 'checkbox', () => log('tick'));
    return ctl(E.FAKE_DL === 'menu', () => log('menu'));
  } });
  const frameOf = (furl, fhtml) => ({ url: () => furl, content: async () => fhtml(),
    getByRole: (role) => ctl(true, () => { log(`click ${role}`); if (role !== 'link') download(); }),
    locator: (sel) => {
      const h = fhtml();
      if (/progressbar/.test(sel)) return { count: async () => (/role="progressbar"/.test(h) ? 1 : 0) };
      if (/next page/.test(sel)) return { count: async () => (/aria-label="Next page"(?![^>]*disabled)/.test(h) ? 1 : 0) };
      return { count: async () => { reads += 1; const r = rows(h); return reads <= Number(E.FAKE_LAZY || 0) ? Math.min(r.length, 2) : r.length; },
        allInnerTexts: async () => { const r = rows(h); return reads <= Number(E.FAKE_LAZY || 0) ? r.slice(0, 2) : r; },
        nth: () => row() };
    } });
  const p = {
    goto: async (u) => { url = u; [key, html] = serve(u); log(`goto ${u}`); },
    // FAKE_SLOW_MS: each page read takes that long, a loaded runner (SPL-6333)
    url: () => url, content: async () => { if (E.FAKE_SLOW_MS) await new Promise((r) => setTimeout(r, Number(E.FAKE_SLOW_MS))); return html; },
    waitForTimeout: async () => {},
    waitForEvent: () => new Promise((res) => { fire = res; }),
    getByRole: (role, o) => ctl(true, async () => { log(`click ${role} ${o.name}`); await p.goto(`${url}/invoices`); }),
  };
  const main = frameOf('', () => html);
  main.url = () => url;
  const pay = frameOf('https://payments.google.com/frame', () => (key && key !== 'overview' ? file(E.FAKE_IFRAME) : ''));
  p.frames = () => (E.FAKE_IFRAME ? [main, pay] : [main]);
  return p;
}
JS
# dl <out> <FAKE_MAP> [VAR=value ...] - download.mjs (or DLMJS, a copy) on the
# fixtures, DRY unless BILLING_DRY=0 is passed; rc on the last line. The fake
# waits take no time, so a poll is 200/10 + 1 = 21 reads, however loaded the box.
dl() {
  local out="$1" m="$2"; shift 2
  : >"$T/fake.log"; rm -rf "$T/dlpdf"
  env -i PATH="$PATH" HOME="$T/home" FAKE_FIX="$FIX" FAKE_LOG="$T/fake.log" FAKE_MAP="$m" \
    BILLING_ACCOUNTS="$A1" BILLING_TODAY=2026-11-10 BILLING_MONTHS=12 BILLING_PDF_DIR="$T/dlpdf" \
    BILLING_PW_DIR="$T/fakepw" BILLING_CHROME=/bin/false BILLING_DRY=1 BILLING_PAGE_WAIT_MS=200 BILLING_POLL_MS=10 "$@" \
    node "${DLMJS:-$DL}" >"$out" 2>&1
  echo "rc=$?" >>"$out"
}
if command -v node >/dev/null 2>&1 && [[ "$(command -v node)" != "$T/bin/node" ]]; then
  dl "$T/e" overview=overview.html,invoices=invoices.html
  [[ "$(grep -c "^INFO DRY XXXXXX-XXXXXX-XX7B8C would save .* (Invoices)$" "$T/e")" -eq 3 ]] \
    && grep -q 'would save 2026-11-01-5123456789.pdf' "$T/e" && grep -q 'would save 2025-12-01-5100000002.pdf' "$T/e" \
    && ! grep -q '5100000001\|5123456790' "$T/e" && grep -q '^rc=0$' "$T/e" \
    && pass "download: overview -> its own 'Invoices' entry -> the 12-month rows (3 invoices, no payment, nothing older), rc 0" \
    || fail "download good: $(cat "$T/e")"
  [[ "$(sed -n 1p "$T/fake.log")" == "goto https://console.cloud.google.com/billing/$A1" ]] \
    && [[ "$(sed -n 2p "$T/fake.log")" == "goto https://console.cloud.google.com/billing/$A1/invoices?organizationId=0&x=1" ]] \
    && ! grep -q '/documents' "$T/fake.log" \
    && pass "download: opens /billing/<id>, then the href the console's nav gives; never /documents" || fail "download gotos: $(cat "$T/fake.log")"
  dl "$T/e" overview=overview-invoiced.html,payment-status=invoices.html
  grep -q '^rc=0$' "$T/e" && [[ "$(grep -c '(Payment status)$' "$T/e")" -eq 3 ]] \
    && pass "download: an invoiced account (no 'Invoices') -> 'Payment status' (its aria-label), rc 0" || fail "download invoiced: $(cat "$T/e")"
  # each failure: one FATAL line for the account, the id masked to its last 4, exit 2
  for c in "overview=not-found.html|URL not found\" for the billing account overview" \
           "overview=overview-no-nav.html|no \"Invoices\" or \"Payment status\" entry in the Billing navigation" \
           "overview=overview.html|URL not found\" behind the \"Invoices\" entry" \
           "overview=overview.html,invoices=invoices-empty.html|no documents list on the \"Invoices\" page"; do
    dl "$T/e" "${c%%|*}"
    [[ "$(grep -c "^FATAL XXXXXX-XXXXXX-XX7B8C: " "$T/e")" -eq 1 ]] && grep -qF "${c#*|}" "$T/e" \
      && grep -q '^FATAL 1 of 1 account(s) failed' "$T/e" && grep -q '^rc=2$' "$T/e" \
      && ! grep -qF "$A1" "$T/e" && ! grep -q 'would save\|^OK ' "$T/e" \
      && pass "download: ${c%%|*} -> one FATAL line (${c#*|}), id masked, rc 2" || fail "download ${c%%|*}: $(cat "$T/e")"
  done
  # CONTROL: the old deep link (/billing/<id>/documents) on the same good pages fails loudly
  mkdir -p "$T/ctl" && cp "$(dirname "$DL")/lib.mjs" "$T/ctl/"
  sed "s#\`\${CONSOLE}/billing/\${id}\`#\`\${CONSOLE}/billing/\${id}/documents\`#" "$DL" >"$T/ctl/download.mjs"
  DLMJS="$T/ctl/download.mjs" dl "$T/e" overview=overview.html,invoices=invoices.html
  grep -q '^rc=2$' "$T/e" && grep -q 'URL not found' "$T/e" && grep -q '/documents$' "$T/fake.log" \
    && pass "download CONTROL: the old /billing/<id>/documents path on the same pages -> FATAL, rc 2" || fail "download control: $(cat "$T/e" "$T/fake.log")"
  # R7 c-073 W1: a list that fills in lazily (2 reads of 1 row, then all) is read only once stable
  dl "$T/e" overview=overview.html,invoices=invoices.html FAKE_LAZY=2
  [[ "$(grep -c 'would save' "$T/e")" -eq 3 ]] && grep -q '^rc=0$' "$T/e" \
    && pass "download: a lazily filling list -> all 3 rows, once the row count holds (W1)" || fail "download lazy: $(cat "$T/e")"
  # CONTROL: the same lazy list with the stability wait cut to one read -> fewer rows (c-073's plant)
  mkdir -p "$T/ctl1" && cp "$(dirname "$DL")/lib.mjs" "$T/ctl1/"
  sed 's/^const STABLE_READS = 3;/const STABLE_READS = 1;/' "$DL" >"$T/ctl1/download.mjs"
  DLMJS="$T/ctl1/download.mjs" dl "$T/e" overview=overview.html,invoices=invoices.html FAKE_LAZY=2
  [[ "$(grep -c 'would save' "$T/e")" -eq 1 ]] && grep -q '^rc=0$' "$T/e" \
    && pass "download CONTROL: one read of the lazy list saves 1 of 3 and exits 0 (the W1 defect)" || fail "download lazy control: $(cat "$T/e")"
  # R7 c-073 N6: a list that holds still for the 3 stability reads, then grows, is caught by the recount after the saves
  for lazy in 3 5; do
    dl "$T/e" overview=overview.html,invoices=invoices.html FAKE_LAZY=$lazy
    [[ "$(grep -c '^FATAL XXXXXX-XXXXXX-XX7B8C: ' "$T/e")" -eq 1 ]] && grep -qF 'changed from 2 to 6 rows after it was read' "$T/e" && grep -q '^rc=2$' "$T/e" \
      && pass "download: a list partial for $lazy reads, then whole -> the recount FATALs, rc 2 (N6)" || fail "download lazy $lazy: $(cat "$T/e")"
  done
  # CONTROL: the same list without the recount saves 1 of 3 and exits 0 (the N6 defect)
  mkdir -p "$T/ctl6" && cp "$(dirname "$DL")/lib.mjs" "$T/ctl6/"
  sed '/^  await recheckRows(/d' "$DL" >"$T/ctl6/download.mjs"
  DLMJS="$T/ctl6/download.mjs" dl "$T/e" overview=overview.html,invoices=invoices.html FAKE_LAZY=3
  [[ "$(grep -c 'would save' "$T/e")" -eq 1 ]] && grep -q '^rc=0$' "$T/e" \
    && pass "download CONTROL: without the recount a list partial for 3 reads saves 1 of 3, rc 0 (N6)" || fail "download N6 control: $(cat "$T/e")"
  for c in "overview=overview.html,invoices=invoices-loading.html|never stopped loading" \
           "overview=overview.html,invoices=invoices-paged.html|has more pages" \
           "overview=overview-offsite.html,invoices=invoices.html|leads off the console (elsewhere.example.com)"; do
    dl "$T/e" "${c%%|*}"
    [[ "$(grep -c '^FATAL XXXXXX-XXXXXX-XX7B8C: ' "$T/e")" -eq 1 ]] && grep -qF "${c#*|}" "$T/e" && grep -q '^rc=2$' "$T/e" \
      && pass "download: ${c%%|*} -> one FATAL line (${c#*|}), rc 2" || fail "download ${c%%|*}: $(cat "$T/e")"
  done
  # W2: the download half, for real (BILLING_DRY=0): each control path saves 3 PDFs
  for mode in direct checkbox menu; do
    dl "$T/e" overview=overview.html,invoices=invoices.html BILLING_DRY=0 FAKE_DL="$mode"
    n=$(find "$T/dlpdf/$A1" -name '*.pdf' 2>/dev/null | wc -l)
    [[ "$n" -eq 3 && "$(grep -c '^OK XXXXXX-XXXXXX-XX7B8C saved ' "$T/e")" -eq 3 ]] && grep -q '^rc=0$' "$T/e" \
      && [[ "$(head -c 5 "$T/dlpdf/$A1/2026-11-01-5123456789.pdf")" == '%PDF-' ]] \
      && case $mode in checkbox) [[ "$(grep -c '^tick$' "$T/fake.log")" -eq 6 ]] && grep -q '^click button$' "$T/fake.log" ;;
           menu) grep -q '^menu$' "$T/fake.log" && grep -q '^click menuitem$' "$T/fake.log" ;; *) true ;; esac \
      && pass "download: the $mode control path saves 3 PDFs (%PDF-), rc 0" || fail "download $mode: $(cat "$T/e" "$T/fake.log")"
  done
  for c in "FAKE_DL_NAME=invoices.zip|no PDF (a .zip file)" "FAKE_DL_BODY=<html>error</html>|is no PDF (removed)"; do
    dl "$T/e" overview=overview.html,invoices=invoices.html BILLING_DRY=0 FAKE_DL=direct "${c%%|*}"
    [[ -z "$(find "$T/dlpdf" -name '*.pdf' 2>/dev/null)" ]] && grep -qF "${c#*|}" "$T/e" && grep -q '^rc=2$' "$T/e" \
      && pass "download: ${c%%=*} -> FATAL (${c#*|}), no .pdf left, rc 2 (W3)" || fail "download ${c%%|*}: $(cat "$T/e"; find "$T/dlpdf")"
  done
  dl "$T/e" overview=overview.html,invoices=invoices-decoy.html BILLING_DRY=0 FAKE_DL=direct FAKE_IFRAME=invoices.html
  [[ -e "$T/dlpdf/$A1/2026-11-01-5123456789.pdf" && -z "$(find "$T/dlpdf" -name '*59999999*')" ]] && grep -q '^rc=0$' "$T/e" \
    && pass "download: the payments.google.com iframe's list wins over the page's own table" || fail "download iframe: $(cat "$T/e"; find "$T/dlpdf")"
  # SPL-6333: a page read slower than the whole wait budget (a loaded runner) still gets
  # its 3 stable reads: the budget counts the poll's waits, never the wall clock
  dl "$T/e" overview=overview.html,invoices=invoices.html FAKE_SLOW_MS=250
  [[ "$(grep -c 'would save' "$T/e")" -eq 3 ]] && grep -q '^rc=0$' "$T/e" \
    && pass "download: page reads slower than the wait budget -> all 3 rows, rc 0 (SPL-6333)" || fail "download slow: $(cat "$T/e")"
  # CONTROL: the same slow reads against a wall-clock deadline -> the CI flake's FATAL
  mkdir -p "$T/ctlw" && cp "$(dirname "$DL")/lib.mjs" "$T/ctlw/"
  sed -e 's/^  for (let waited = 0; ; waited += POLL_MS) {/  const T0 = Date.now(); for (let waited = 0; ; waited += POLL_MS) {/' \
    -e 's/^    if (waited >= PAGE_WAIT_MS) return null;/    if (Date.now() - T0 >= PAGE_WAIT_MS) return null;/' "$DL" >"$T/ctlw/download.mjs"
  DLMJS="$T/ctlw/download.mjs" dl "$T/e" overview=overview.html,invoices=invoices.html FAKE_SLOW_MS=250
  [[ "$(grep -c 'T0' "$T/ctlw/download.mjs")" -eq 2 ]] && grep -qF 'no documents list on the "Invoices" page, or it never stopped loading' "$T/e" && grep -q '^rc=2$' "$T/e" \
    && pass "download CONTROL: a wall-clock deadline on the same slow reads -> FATAL no documents list, rc 2 (the SPL-6333 flake)" || fail "download slow control: $(cat "$T/e")"
  dl "$T/e" overview=overview-nohref.html,invoices=invoices.html
  grep -q '^click link Invoices$' "$T/fake.log" && [[ "$(grep -c 'would save' "$T/e")" -eq 3 ]] && grep -q '^rc=0$' "$T/e" \
    && pass "download: an 'Invoices' entry with no href is clicked by its name" || fail "download nohref: $(cat "$T/e" "$T/fake.log")"
  dl "$T/e" overview=overview.html FAKE_LAUNCH_FAIL=1
  grep -q '^FATAL cannot start Chrome (BILLING_CHROME): Failed to launch' "$T/e" && grep -q '^rc=2$' "$T/e" \
    && [[ "$(grep -vc '^rc=' "$T/e")" -eq 1 ]] && ! grep -q '/tmp/x\|at stack' "$T/e" \
    && pass "download: Chrome fails to start -> one FATAL line, no stack, no profile path, rc 2 (N2)" || fail "download launch: $(cat "$T/e")"
else
  echo "NOT RUN: download.mjs on the fixture pages (no node on this box)"
fi

[[ $fails -eq 0 ]] && echo "ALL PASSED" || { echo "$fails FAILED"; exit 1; }
