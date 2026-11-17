#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_hub_cost_invoice_import (SPL-5802, spec 123 section 15.6),
#          on synthetic invoices, with the hub and the cost_lines read stubbed:
#   1. the parser: the service month (three date forms, the file date
#      fallback), the account's last 4 (text, else the pdf/<id>/ dir), the
#      net in 1,234.50 / 1.234,56 / 1 234,56 / 12 forms, the currency (code
#      or symbol); an amount it cannot tell (1,234, 1.234,567), two numbers
#      on one line, and a missing field read "-" with unparsed:<field>,
#      never a guess; several different subtotals give the one that adds
#      up with VAT to the Total, else none; one that does not add up is
#      refused; a VAT number is not a VAT amount
#   2. totals: one TSV row per PDF (sub dirs too), mode 600, no cloud call;
#      no full account id in any output; refusals: COST_INVOICE_DIR unset or
#      not a dir, a TSV inside a git work tree, a dir with no PDF
#   3. import, dry (the default): one GET of the cloud entries, no POST;
#      the plan's actions: create, conflict:cost_entry (a Google Cloud /
#      GCP label in the month), conflict:cost_lines=n/N (some or all of the
#      month's days from the export), skip:not-above-0, skip:duplicate,
#      skip:unparsed; each create row passes do_spl_hub_cost_entries' dry
#      create; the plan sha is printed
#   4. DRY_RUN=0: refused with no or a wrong COST_INVOICE_PLAN_SHA (no POST);
#      with the dry run's sha it POSTs exactly the create rows, net amount,
#      the masked account in the label
#   5. a real PDF through the real pdftotext (when the box has it)
# RED CONTROL: case 3 fails when the conflict checks of _scii_plan are
# dropped (2026-01 and 2026-10 then read create), and case 4 when the sha
# check is dropped (the POSTs then run without it): the plants in the commit.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0
PY="$PROJ_ROOT/src/bash/scripts/invoice-pdf-month-totals.py"
ACCT=0A1B2C-3D4E5F-6A7B8C
ACCT2=0A1B2C-3D4E5F-6A7B9D

# --- 1. the parser ----------------------------------------------------------------
parse() { printf '%b' "$1" >"$T/p.txt"; python3 -I "$PY" "$T/p.txt" "$2"; }
check() {
  local got; got="$(parse "$1" "$2")"
  [[ "$got" == "$3" ]] && pass "1. $4" || fail "1. $4: got '$got' want '$3'"
}
check "Billing account ID: $ACCT\nSummary for Nov 1, 2025 - Nov 30, 2025\nSubtotal in EUR      1,234.50\nTotal in EUR  1,530.78\n" \
  "$T/2025-12-01-1.pdf" $'2025-12-01-1.pdf\t2025-11\t7B8C\t1234.50\tEUR\tok' "month-day-year period, code currency"
check "1 Oct 2026 \xe2\x80\x93 31 Oct 2026\nTotal excluding VAT   1.234,56 \xe2\x82\xac\n" \
  "$T/$ACCT/x.pdf" $'x.pdf\t2026-10\t7B8C\t1234.56\tEUR\tok' "day-month-year period, symbol currency, account from the dir"
check "2026-02-01 - 2026-02-28\nSubtotal:  1 234,56 USD\n" "$T/$ACCT/y.pdf" $'y.pdf\t2026-02\t7B8C\t1234.56\tUSD\tok' "ISO period, spaced thousands"
check "Subtotal in EUR   12\n" "$T/$ACCT/2026-01-05-9.pdf" $'2026-01-05-9.pdf\t2025-12\t7B8C\t12.00\tEUR\tok' "file date fallback is the month before"
check "Subtotal in EUR   1,234\n" "$T/$ACCT/2026-01-05-9.pdf" $'2026-01-05-9.pdf\t2025-12\t7B8C\t-\tEUR\tunparsed:net' "1,234 is not guessed"
check "Subtotal in EUR   1.234,567\n" "$T/$ACCT/2026-01-05-9.pdf" $'2026-01-05-9.pdf\t2025-12\t7B8C\t-\tEUR\tunparsed:net' "1.234,567 is not guessed"
check "Subtotal   12.00\nSubtotal   52.80\nSubtotal in EUR   64.80\n" "$T/$ACCT/2026-01-05-9.pdf" $'2026-01-05-9.pdf\t2025-12\t7B8C\t-\tEUR\tunparsed:net' "several subtotals, no VAT and Total: no net"
check "Total excl. VAT   70.00\nSubtotal in EUR   64.80\n" "$T/$ACCT/2026-01-05-9.pdf" $'2026-01-05-9.pdf\t2025-12\t7B8C\t-\tEUR\tunparsed:net' "excl. VAT and Subtotal differ: no net"
check "Subtotal   12.00\nSubtotal   52.80\nSubtotal in EUR   64.80\nVAT (25.5%) 16.52\nTotal in EUR   81.32\n" "$T/$ACCT/2026-01-05-9.pdf" $'2026-01-05-9.pdf\t2025-12\t7B8C\t64.80\tEUR\tok' "several subtotals: the one that adds up with VAT to the Total"
check "Subtotal in EUR   64.80\nVAT 24 % 15.55\nTotal in EUR   81.00\n" "$T/$ACCT/2026-01-05-9.pdf" $'2026-01-05-9.pdf\t2025-12\t7B8C\t-\tEUR\tunparsed:net' "one subtotal that does not add up is refused"
check "Subtotal in EUR   64.80\nVAT number 12345678\nTotal in EUR   64.80\n" "$T/$ACCT/2026-01-05-9.pdf" $'2026-01-05-9.pdf\t2025-12\t7B8C\t64.80\tEUR\tok' "a VAT number is not a VAT amount"
check "Subtotal   1   64.80\n" "$T/$ACCT/2026-01-05-9.pdf" $'2026-01-05-9.pdf\t2025-12\t7B8C\t-\t-\tunparsed:net,currency' "two numbers on a line never merge"
check "nothing here\n" "$T/z.pdf" $'z.pdf\t-\t-\t-\t-\tunparsed:month,account,net,currency' "nothing found, nothing guessed"

# --- fixtures: synthetic invoices, text beside each PDF for the stub pdftotext ---
mkdir -p "$T/bin" "$T/inv/$ACCT" "$T/inv/$ACCT2"
cat >"$T/bin/pdftotext" <<'EOF'
#!/usr/bin/env bash
# stub: the text beside the PDF; the last two args are in and out
in="${@: -2:1}"; out="${@: -1}"; cp "$in.txt" "$out"
EOF
chmod +x "$T/bin/pdftotext"
inv() { : >"$T/inv/$1"; printf '%b' "$2" >"$T/inv/$1.txt"; }
inv "$ACCT/2026-02-01-11.pdf" "Summary for Jan 1, 2026 - Jan 31, 2026\nSubtotal in EUR   64.80\n"
inv "$ACCT/2026-03-01-12.pdf" "Summary for Feb 1, 2026 - Feb 28, 2026\nSubtotal in EUR   70.10\n"
inv "$ACCT/2026-03-02-13.pdf" "Summary for Feb 1, 2026 - Feb 28, 2026\nSubtotal in EUR   70.10\n"
inv "$ACCT/2026-04-01-14.pdf" "Summary for Mar 1, 2026 - Mar 31, 2026\nSubtotal in EUR   0.00\n"
inv "$ACCT/2026-10-01-15.pdf" "Summary for Sep 1, 2026 - Sep 30, 2026\nSubtotal in EUR   80.00\n"
inv "$ACCT/2026-11-01-16.pdf" "Summary for Oct 1, 2026 - Oct 31, 2026\nSubtotal in EUR   90.00\n"
inv "$ACCT2/2025-12-01-17.pdf" "Summary for Nov 1, 2025 - Nov 30, 2025\nSubtotal in USD   5.25\n"
inv "$ACCT2/2026-01-01-18.pdf" "garbled\n"

run() {
  : >"$T/calls"
  env PROJ_PATH="$PROJ_ROOT" PATH="$T/bin:$PATH" CALLS="$T/calls" EMPTY='{"entries":[]}' COST_INVOICE_DIR="$T/inv" COST_INVOICE_TSV="$T/out.tsv" "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    do_require_bin() { :; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    do_spl_cloud_cnf() { SPL_CNF=/dev/null SPL_PROJECT=csi-spl-dev; }
    spl_hub_operator_url() { SPL_HUB_URL=https://hub.invalid; }
    do_gcp_pin_account() { echo pin >>"$CALLS"; GCP_ACCOUNT=sa@example.iam.gserviceaccount.com; }
    do_gcp_require_live_account() { :; }
    _scii_gcp_days() { echo days >>"$CALLS"; printf "%b" "${STUB_DAYS:-}"; }
    spl_hub_operator_call() {
      echo "hub $1 $2 ${3:-}" >>"$CALLS"
      if [[ $1 == GET ]]; then SPL_HUB_OP_STATUS=200 SPL_HUB_OP_BODY="${STUB_BODY:-$EMPTY}"
      else SPL_HUB_OP_STATUS=201 SPL_HUB_OP_BODY="{\"id\":\"0a1b2c3d-1111-4222-8333-444455556666\",\"period\":\"x\",\"type\":\"cloud\",\"label\":\"l\"}"; fi
    }
    do_spl_hub_cost_invoice_import' >"$T/o" 2>&1
}
no_id() { ! grep -qE '[0-9A-F]{6}-[0-9A-F]{6}-[0-9A-F]{6}' "$T/o" "$T/calls"; }

# --- 2. totals --------------------------------------------------------------------
run COST_INVOICE_CMD=totals; rc=$?
[[ $rc -eq 0 && ! -s "$T/calls" && "$(wc -l <"$T/out.tsv")" -eq 8 && "$(stat -c %a "$T/out.tsv")" == 600 ]] \
  && grep -qxF $'2026-01-01-18.pdf\t2025-12\t7B9D\t-\t-\tunparsed:net,currency' "$T/out.tsv" \
  && grep -qxF $'2026-02-01-11.pdf\t2026-01\t7B8C\t64.80\tEUR\tok' "$T/out.tsv" && grep -q '^OK 8 invoice PDF(s) read' "$T/o" \
  && ! grep -q '64.80' "$T/o" && no_id && pass "2. totals: 8 rows, mode 600, no call, no figure or account id printed" \
  || fail "2. totals: rc=$rc $(cat "$T/o" "$T/calls" "$T/out.tsv" 2>/dev/null)"
run COST_INVOICE_CMD=totals COST_INVOICE_DIR=; rc=$?
[[ $rc -ne 0 ]] && grep -q 'FATAL COST_INVOICE_DIR must be set' "$T/o" && pass "2. COST_INVOICE_DIR unset is refused" || fail "2. unset: rc=$rc $(cat "$T/o")"
run COST_INVOICE_CMD=totals COST_INVOICE_DIR="$T/inv/$ACCT/2026-02-01-11.pdf"; rc=$?
[[ $rc -ne 0 ]] && grep -q 'not a readable dir' "$T/o" && no_id && pass "2. a file as the dir is refused, the id masked" || fail "2. not a dir: rc=$rc $(cat "$T/o")"
mkdir -p "$T/repo" "$T/empty" && git -C "$T/repo" init -q
run COST_INVOICE_CMD=totals COST_INVOICE_TSV="$T/repo/m.tsv"; rc=$?
[[ $rc -ne 0 && ! -e "$T/repo/m.tsv" ]] && grep -q 'inside a git work tree' "$T/o" && pass "2. a TSV in a git work tree is refused" || fail "2. git: rc=$rc $(cat "$T/o")"
run COST_INVOICE_CMD=totals COST_INVOICE_DIR="$T/empty"; rc=$?
[[ $rc -ne 0 ]] && grep -q 'no \*.pdf under' "$T/o" && pass "2. a dir with no PDF is refused" || fail "2. empty: rc=$rc $(cat "$T/o")"

# --- 3. import, dry -----------------------------------------------------------------
HELD='{"entries":[{"period":"2026-01","label":"Google Cloud","type":"cloud"},{"period":"2026-02","label":"Hetzner","type":"cloud"}]}'
DAYS='2026-09\t30\n2026-10\t26\n'
run ENV=dev STUB_BODY="$HELD" STUB_DAYS="$DAYS"; rc=$?
want=(
  "2025-11 7B9D 5.25 USD create"
  "2025-12 7B9D - - skip:unparsed:net,currency"
  "2026-01 7B8C 64.80 EUR conflict:cost_entry"
  "2026-02 7B8C 70.10 EUR create"
  "2026-02 7B8C 70.10 EUR skip:duplicate"
  "2026-03 7B8C 0.00 EUR skip:not-above-0"
  "2026-09 7B8C 80.00 EUR conflict:cost_lines=30/30"
  "2026-10 7B8C 90.00 EUR conflict:cost_lines=26/31"
)
ok=1; for w in "${want[@]}"; do grep -qE "^  $(sed 's/ /  */g; s/\./\\./g' <<<"$w") *$" "$T/o" || { ok=0; fail "3. plan row missing: $w"; }; done
[[ $rc -eq 0 && $ok -eq 1 ]] && grep -qx 'hub GET /v1/operator/cost-entries?type=cloud ' "$T/calls" && ! grep -q 'hub POST' "$T/calls" \
  && [[ "$(grep -c 'OK DRY_RUN would POST /v1/operator/cost-entries' "$T/o")" -eq 2 ]] && grep -q 'create row(s), sha256 [0-9a-f]\{64\}' "$T/o" \
  && no_id && pass "3. dry plan: create, both conflicts, the skips; 2 dry creates, no POST, no account id" \
  || fail "3. dry: rc=$rc $(cat "$T/o" "$T/calls")"
SHA="$(grep -o 'sha256 [0-9a-f]\{64\}' "$T/o" | cut -d' ' -f2)"
run ENV=dev STUB_BODY='{"entries":"x"}' STUB_DAYS="$DAYS"; rc=$?
[[ $rc -ne 0 ]] && grep -q 'not a list of cost entries' "$T/o" && pass "3. a malformed hub answer is refused" || fail "3. malformed: rc=$rc $(cat "$T/o")"
run STUB_DAYS="$DAYS"; rc=$?
[[ $rc -ne 0 && ! -s "$T/calls" ]] && grep -q 'ENV must be dev or prd' "$T/o" && pass "3. import without ENV is refused before any call" || fail "3. no ENV: rc=$rc $(cat "$T/o")"

# --- 4. DRY_RUN=0 -------------------------------------------------------------------
for s in "" 0000; do
  run ENV=dev STUB_BODY="$HELD" STUB_DAYS="$DAYS" DRY_RUN=0 COST_INVOICE_PLAN_SHA="$s"; rc=$?
  [[ $rc -ne 0 ]] && ! grep -q 'hub POST' "$T/calls" && grep -q 'needs COST_INVOICE_PLAN_SHA' "$T/o" \
    && pass "4. DRY_RUN=0 with sha '$s' is refused, no POST" || fail "4. sha '$s': rc=$rc $(cat "$T/o" "$T/calls")"
done
run ENV=dev STUB_BODY="$HELD" STUB_DAYS="$DAYS" DRY_RUN=0 COST_INVOICE_PLAN_SHA="$SHA"; rc=$?
B1='{"type":"cloud","label":"Google Cloud (billing account ending 7B9D)","amount":5.25,"currency":"USD","period":"2025-11","note":"invoice PDF import, SPL-5802"}'
B2='{"type":"cloud","label":"Google Cloud (billing account ending 7B8C)","amount":70.1,"currency":"EUR","period":"2026-02","note":"invoice PDF import, SPL-5802"}'
[[ $rc -eq 0 && "$(grep -c 'hub POST' "$T/calls")" -eq 2 ]] && grep -qxF "hub POST /v1/operator/cost-entries $B1" "$T/calls" \
  && grep -qxF "hub POST /v1/operator/cost-entries $B2" "$T/calls" && grep -q 'OK 2 create row(s) created' "$T/o" \
  && pass "4. DRY_RUN=0 with the plan's sha POSTs exactly the 2 create rows" || fail "4. write: rc=$rc $(cat "$T/o" "$T/calls")"

# --- 5. a real PDF through the real pdftotext ------------------------------------------
if command -v pdftotext >/dev/null; then
  mkdir -p "$T/real/$ACCT"
  python3 -I - "$T/real/$ACCT/2026-02-01-21.pdf" <<'EOF'
import sys
lines = ["Invoice", "Summary for Jan 1, 2026 - Jan 31, 2026", "Subtotal in EUR    64.80", "Total in EUR    80.35"]
ops = "BT /F1 11 Tf 72 720 Td 14 TL " + " ".join("(%s) '" % l for l in lines) + " ET"
objs = ["<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>",
        "<< /Length %d >>\nstream\n%s\nendstream" % (len(ops), ops), "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"]
out, offs = b"%PDF-1.4\n", []
for i, o in enumerate(objs, 1):
    offs.append(len(out)); out += ("%d 0 obj\n%s\nendobj\n" % (i, o)).encode()
x = len(out)
out += ("xref\n0 %d\n0000000000 65535 f \n" % (len(objs) + 1)).encode() + b"".join(b"%010d 00000 n \n" % o for o in offs)
out += ("trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n" % (len(objs) + 1, x)).encode()
open(sys.argv[1], "wb").write(out)
EOF
  env PROJ_PATH="$PROJ_ROOT" COST_INVOICE_DIR="$T/real" COST_INVOICE_TSV="$T/real.tsv" COST_INVOICE_CMD=totals bash -c '
    do_log() { echo "$*"; }; do_require_bin() { :; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    do_spl_hub_cost_invoice_import' >"$T/o" 2>&1; rc=$?
  [[ $rc -eq 0 ]] && grep -qxF $'2026-02-01-21.pdf\t2026-01\t7B8C\t64.80\tEUR\tok' "$T/real.tsv" \
    && pass "5. a real PDF through pdftotext parses in full" || fail "5. real pdf: rc=$rc $(cat "$T/o" "$T/real.tsv" 2>/dev/null)"
else
  echo "INFO 5. pdftotext is not on this box: the real-PDF case did not run (cases 1-4 cover the parser and the action)"
fi

(( fails == 0 )) && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
