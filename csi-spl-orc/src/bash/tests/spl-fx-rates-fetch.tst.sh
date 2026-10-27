#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_fx_rates_fetch (SPL-2108) reads the ECB and Fed H.10 rates
#          from the cnf URLs and posts them to the hub as units per USD. The
#          downloads and the hub are stubbed (fixtures of each bank's format).
#   1. ECB: EUR-based rates turned USD-based through the same day's EUR/USD,
#      EUR itself 1 / EUR-USD; only the cnf's European currencies; a weekend
#      has no row, so the latest day read on a Sunday is the Friday
#   2. Fed: CRLF lines, an ND holiday skipped, the USD-per-unit series (AUD)
#      inverted, a European currency (EUR, GBP) left to the ECB
#   3. DRY_RUN=1 (default) reads both and posts nothing; DRY_RUN=0 posts every
#      row, in chunks, as {rows: [{day, quote, rate, source}]}
#   4. one bank failing: the other's rows still post, the run is non-zero
#   5. CONTROL: ENV, FX_DAYS, a missing URL or EUR missing from the list are
#      refused before any download; the real cnf passes the checks
#   6. FX_FROM (SPL-3791): a range back to 2024-07-01 reads the banks' history
#      URLs (the ECB full file, the Fed range with from/to filled), keeps every
#      day >= FX_FROM and posts it in chunks; FX_FROM with FX_DAYS, a bad, a
#      future or a pre-1999 day is refused before any download
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
APP_ROOT=$(cd "$PROJ_ROOT/.." && pwd)
FUNC="$PROJ_ROOT/src/bash/run/spl-fx-rates-fetch.func.sh"
REAL_CNF="$APP_ROOT/csi-spl-cnf/csi-spl/all.env.yaml"
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

# Fri 2026-10-09 and Mon 2026-10-12: no weekend cube, as the ECB publishes.
cat >"$T/ecb.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?><gesmes:Envelope xmlns:gesmes="http://www.gesmes.org/xml/2002-08-01" xmlns="http://www.ecb.int/vocabulary/2002-08-01/eurofxref"><Cube><Cube time="2026-10-12"><Cube currency="USD" rate="1.25"/><Cube currency="JPY" rate="180"/><Cube currency="GBP" rate="0.875"/></Cube><Cube time="2026-10-09"><Cube currency="USD" rate="1.125"/><Cube currency="JPY" rate="177"/><Cube currency="GBP" rate="0.9"/><Cube currency="SEK" rate="11.25"/></Cube></Cube></gesmes:Envelope>
EOF
printf '%s\r\n' \
  '"Series Description","Australian Dollar","Euro-Area Euro","Japanese Yen","United Kingdom Pound"' \
  '"Unit:","Currency","Currency","Currency","Currency"' \
  '"Multiplier:","1","1","1","1"' \
  '"Currency:","AUD","EUR","JPY","GBP"' \
  '"Unique Identifier: ","H10/H10/RXI$US_N.B.AL","H10/H10/RXI$US_N.B.EU","H10/H10/RXI_N.B.JA","H10/H10/RXI$US_N.B.UK"' \
  '"Time Period","RXI$US_N.B.AL","RXI$US_N.B.EU","RXI_N.B.JA","RXI$US_N.B.UK"' \
  '2026-10-08,0.5000,1.1000,158.00,1.3000' \
  '2026-10-09,ND,ND,ND,ND' \
  '2026-10-12,0.6250,1.1200,159.50,1.3100' >"$T/fed.csv"

# History: the ECB full file and the Fed range carry 2024-06-28 (before
# FX_FROM, dropped) and 2024-07-01.
cat >"$T/ecb-hist.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?><gesmes:Envelope xmlns:gesmes="http://www.gesmes.org/xml/2002-08-01" xmlns="http://www.ecb.int/vocabulary/2002-08-01/eurofxref"><Cube><Cube time="2026-10-12"><Cube currency="USD" rate="1.25"/><Cube currency="GBP" rate="0.875"/></Cube><Cube time="2024-07-01"><Cube currency="USD" rate="1.0"/><Cube currency="GBP" rate="0.85"/></Cube><Cube time="2024-06-28"><Cube currency="USD" rate="1.0"/><Cube currency="GBP" rate="0.84"/></Cube></Cube></gesmes:Envelope>
EOF
printf '%s\r\n' \
  '"Series Description","Australian Dollar","Japanese Yen"' \
  '"Currency:","AUD","JPY"' \
  '"Unique Identifier: ","H10/H10/RXI$US_N.B.AL","H10/H10/RXI_N.B.JA"' \
  '2024-06-28,0.5000,160.00' \
  '2024-07-01,0.5000,161.00' \
  '2026-10-12,0.6250,159.50' >"$T/fed-hist.csv"

FED_RANGE='https://fed.example/range.csv?from={from}&to={to}'
cnf() { # <file> [ecb_url] [fed_url] [currencies] [ecb_hist_url] [fed_range_url]
  printf 'env:\n  fx:\n    days: 30\n    ecb_url: "%s"\n    fed_url: "%s"\n    ecb_currencies: [%s]\n    ecb_hist_url: "%s"\n    fed_range_url: "%s"\n' \
    "${2-https://ecb.example/rates.xml}" "${3-https://fed.example/h10.csv}" "${4-EUR, GBP, SEK}" \
    "${5-https://ecb.example/hist.xml}" "${6-$FED_RANGE}" >"$1"
}
cnf "$T/cnf.yaml"

# runa <cnf> [VAR=val ...]: the action, downloads served from the fixtures
# (FAIL_BANK=ecb|fed fails one), the hub recorded in $T/posts.
runa() {
  local f="$1"; shift
  : >"$T/posts"; : >"$T/gets"
  env -u DRY_RUN -u FX_DAYS -u FX_FROM FUNC="$FUNC" T="$T" CNF="$f" "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*" >&2; }
    source "${FUNC%/src/bash/run/*}/lib/bash/funcs/spl-cloud-cnf.func.sh"
    do_require_bin() { return 0; }
    do_spl_cloud_cnf() { SPL_CNF="$CNF"; }
    source "$FUNC"
    date() { if [[ "$*" == *days* ]]; then echo 2026-10-01; else command date "$@"; fi; }
    spl_fx_get() {
      echo "$1" >>"$T/gets"
      case "$1" in
        *ecb.example/hist*) [[ "${FAIL_BANK:-}" != ecb ]] && cp "$T/ecb-hist.xml" "$2" ;;
        *fed.example/range*) [[ "${FAIL_BANK:-}" != fed ]] && cp "$T/fed-hist.csv" "$2" ;;
        *ecb*) [[ "${FAIL_BANK:-}" != ecb ]] && cp "$T/ecb.xml" "$2" ;;
        *fed*) [[ "${FAIL_BANK:-}" != fed ]] && cp "$T/fed.csv" "$2" ;;
        *) return 1 ;;
      esac
    }
    spl_cost_hub_login() { echo login >>"$T/posts"; }
    spl_hub_operator_call() {
      printf "%s %s %s\n" "$1" "$2" "$3" >>"$T/posts"
      SPL_HUB_OP_STATUS=200
      SPL_HUB_OP_BODY="$(jq -c "{rows: (.rows | length), written: (.rows | length)}" <<<"$3")"
    }
    do_spl_fx_rates_fetch' >"$T/o" 2>"$T/e"
}

# 1 + 2: the parsers -------------------------------------------------------
# shellcheck source=../run/spl-fx-rates-fetch.func.sh
( source "$FUNC"
  spl_fx_ecb_rows "$T/ecb.xml" "EUR GBP SEK" 2026-10-01 >"$T/ecb.tsv"
  spl_fx_fed_rows "$T/fed.csv" "EUR GBP SEK" 2026-10-01 >"$T/fed.tsv"
  spl_fx_latest "$T/ecb.tsv" >"$T/ecb.latest" )
want_ecb=$(printf '%s\n' \
  $'2026-10-09\tEUR\t0.8888888889\tECB' $'2026-10-09\tGBP\t0.8\tECB' $'2026-10-09\tSEK\t10\tECB' \
  $'2026-10-12\tEUR\t0.8\tECB' $'2026-10-12\tGBP\t0.7\tECB')
[[ "$(cat "$T/ecb.tsv")" == "$want_ecb" ]] && pass "1 ECB: USD-based (GBP 0.9/1.125 = 0.8, EUR 1/1.125), European only (no JPY)" ||
  fail "1 ECB rows: $(tr '\n' '|' <"$T/ecb.tsv")"
grep -q $'^2026-10-1[01]\t' "$T/ecb.tsv" && fail "1 a weekend row was written" || pass "1 no Saturday or Sunday row"
[[ "$(cat "$T/ecb.latest")" == 2026-10-12 ]] && pass "1 latest day is the last published one" || fail "1 latest $(cat "$T/ecb.latest")"
# shellcheck source=../run/spl-fx-rates-fetch.func.sh
( source "$FUNC"; spl_fx_ecb_rows "$T/ecb.xml" "EUR GBP SEK" 2026-10-01 | grep -v 2026-10-12 >"$T/fri.tsv"; spl_fx_latest "$T/fri.tsv" >"$T/fri.latest" )
[[ "$(cat "$T/fri.latest")" == 2026-10-09 ]] && pass "1 read on the Sunday, the latest day is the Friday 2026-10-09" ||
  fail "1 Sunday latest $(cat "$T/fri.latest")"
want_fed=$(printf '%s\n' \
  $'2026-10-08\tAUD\t2\tFED' $'2026-10-08\tJPY\t158\tFED' $'2026-10-12\tAUD\t1.6\tFED' $'2026-10-12\tJPY\t159.5\tFED')
[[ "$(cat "$T/fed.tsv")" == "$want_fed" ]] && pass "2 Fed: CRLF read, ND skipped, AUD inverted (1/0.5), EUR and GBP left to the ECB" ||
  fail "2 Fed rows: $(tr '\n' '|' <"$T/fed.tsv")"
# shellcheck source=../run/spl-fx-rates-fetch.func.sh
( source "$FUNC"; spl_fx_ecb_rows "$T/ecb.xml" "EUR" 2026-10-10 >"$T/since.tsv" )
[[ "$(cut -f 1 "$T/since.tsv" | sort -u)" == 2026-10-12 ]] && pass "1 the days before SINCE are not posted" || fail "1 since: $(tr '\n' '|' <"$T/since.tsv")"

# 3: dry run and the post --------------------------------------------------
runa "$T/cnf.yaml" ENV=dev
if [[ $? == 0 ]] && [[ ! -s "$T/posts" ]] && grep -q "ECB rows=5 latest=2026-10-12 FED rows=4 latest=2026-10-12" "$T/e"; then
  pass "3 DRY_RUN=1 (default) reads both banks and posts nothing"
else
  fail "3 dry run: posts=$(cat "$T/posts") err=$(tail -n 3 "$T/e" | tr '\n' ' ')"
fi
runa "$T/cnf.yaml" ENV=dev DRY_RUN=0 FX_POST_CHUNK=4
rc=$?
n_calls=$(grep -c '^POST /v1/operator/fx/rates ' "$T/posts")
n_rows=$(grep '^POST ' "$T/posts" | sed 's|^POST /v1/operator/fx/rates ||' | jq -s '[.[].rows | length] | add')
src=$(grep '^POST ' "$T/posts" | sed 's|^POST /v1/operator/fx/rates ||' | jq -rs '[.[].rows[] | select(.quote == "AUD" and .day == "2026-10-12") | "\(.source) \(.rate)"] | .[0]')
if [[ $rc == 0 && $n_calls == 3 && $n_rows == 9 && "$src" == "FED 1.6" ]] && [[ "$(sed -n 1p "$T/posts")" == login ]]; then
  pass "3 DRY_RUN=0 logs in, then posts the 9 rows in 3 chunks of up to 4, rate a number (AUD 1.6 FED)"
else
  fail "3 post: rc=$rc calls=$n_calls rows=$n_rows aud=$src err=$(tail -n 3 "$T/e" | tr '\n' ' ')"
fi

# 4: one bank down ---------------------------------------------------------
runa "$T/cnf.yaml" ENV=dev DRY_RUN=0 FAIL_BANK=fed
rc=$?
n_rows=$(grep '^POST ' "$T/posts" | sed 's|^POST /v1/operator/fx/rates ||' | jq -s '[.[].rows | length] | add')
if [[ $rc != 0 && $n_rows == 5 ]] && grep -q "WARN the Fed H.10 rates were not read" "$T/e"; then
  pass "4 the Fed down: the 5 ECB rows still post, the run is non-zero and names the Fed"
else
  fail "4 one bank: rc=$rc rows=$n_rows err=$(tail -n 3 "$T/e" | tr '\n' ' ')"
fi

# 5: refusals --------------------------------------------------------------
runa "$T/cnf.yaml" ENV=lde
[[ $? != 0 && ! -s "$T/gets" ]] && pass "5 ENV=lde refused" || fail "5 ENV=lde ran"
for bad in 0 91 x; do
  runa "$T/cnf.yaml" ENV=dev FX_DAYS="$bad"
  [[ $? != 0 && ! -s "$T/gets" ]] && grep -q "FX_DAYS" "$T/e" && pass "5 FX_DAYS=$bad refused before any download" || fail "5 FX_DAYS=$bad"
done
cnf "$T/nourl.yaml" "" ""
runa "$T/nourl.yaml" ENV=dev
[[ $? != 0 && ! -s "$T/gets" ]] && grep -q "no default" "$T/e" && pass "5 no URL in cnf: refused, no default" || fail "5 no URL ran"
cnf "$T/noeur.yaml" https://ecb.example/x https://fed.example/y "GBP"
runa "$T/noeur.yaml" ENV=dev
[[ $? != 0 && ! -s "$T/gets" ]] && pass "5 an ECB list without EUR refused" || fail "5 no EUR ran"
yq -r '.env.fx.days, .env.fx.ecb_url, .env.fx.fed_url, (.env.fx.ecb_currencies | join(" "))' "$REAL_CNF" >"$T/real"
if [[ "$(sed -n 1p "$T/real")" =~ ^[0-9]+$ ]] && grep -q '^https://' <(sed -n 2,3p "$T/real") && [[ " $(sed -n 4p "$T/real") " == *" EUR "* ]]; then
  pass "5 the real cnf (all.env.yaml env.fx) has days, two https URLs and EUR in the ECB list"
else
  fail "5 real cnf env.fx: $(tr '\n' '|' <"$T/real")"
fi

# 6: FX_FROM, a historical range ----------------------------------------------
runa "$T/cnf.yaml" ENV=dev FX_FROM=2024-07-01
rc=$?
if [[ $rc == 0 && ! -s "$T/posts" ]] && grep -q "since=2024-07-01 ECB rows=4 latest=2026-10-12 FED rows=4 latest=2026-10-12" "$T/e"; then
  pass "6 FX_FROM=2024-07-01 DRY_RUN: since 2024-07-01, ECB 4 and FED 4 rows (2024-06-28 dropped), nothing posted"
else
  fail "6 FX_FROM dry run: rc=$rc posts=$(cat "$T/posts") err=$(tail -n 3 "$T/e" | tr '\n' ' ')"
fi
want_gets=$'https://ecb.example/hist.xml\nhttps://fed.example/range.csv?from=07%2F01%2F2024&to='"$(date -u +%m)%2F$(date -u +%d)%2F$(date -u +%Y)"
[[ "$(cat "$T/gets")" == "$want_gets" ]] && pass "6 FX_FROM reads the ECB full file and the Fed range from=07/01/2024 to=today (encoded)" ||
  fail "6 FX_FROM urls: $(tr '\n' '|' <"$T/gets")"
runa "$T/cnf.yaml" ENV=dev FX_FROM=2024-07-01 DRY_RUN=0 FX_POST_CHUNK=3
rc=$?
n_calls=$(grep -c '^POST /v1/operator/fx/rates ' "$T/posts")
first=$(grep '^POST ' "$T/posts" | sed 's|^POST /v1/operator/fx/rates ||' | jq -rs '[.[].rows[].day] | min')
if [[ $rc == 0 && $n_calls == 3 && "$first" == 2024-07-01 ]]; then
  pass "6 FX_FROM DRY_RUN=0 posts the 8 rows in 3 chunks of up to 3, earliest day 2024-07-01"
else
  fail "6 FX_FROM post: rc=$rc calls=$n_calls first=$first err=$(tail -n 3 "$T/e" | tr '\n' ' ')"
fi
for bad in "FX_FROM=2024-07-01 FX_DAYS=30" FX_FROM=2024-7-1 FX_FROM=2024-02-30 FX_FROM=1998-12-31 "FX_FROM=$(date -u -d '+2 days' +%F)"; do
  # shellcheck disable=SC2086 # the VAR=val pairs split on purpose
  runa "$T/cnf.yaml" ENV=dev $bad
  [[ $? != 0 && ! -s "$T/gets" ]] && grep -q "FX_FROM" "$T/e" && pass "6 $bad refused before any download" || fail "6 $bad: $(tail -n 2 "$T/e" | tr '\n' ' ')"
done
cnf "$T/nohist.yaml" https://ecb.example/rates.xml https://fed.example/h10.csv "EUR, GBP" "" "https://fed.example/range.csv"
runa "$T/nohist.yaml" ENV=dev FX_FROM=2024-07-01
[[ $? != 0 && ! -s "$T/gets" ]] && pass "6 FX_FROM without an ECB history URL or a Fed range URL with {from}/{to}: refused" || fail "6 no hist url ran"
runa "$T/nohist.yaml" ENV=dev
[[ $? == 0 ]] && pass "6 the daily run (no FX_FROM) needs no history URL" || fail "6 daily run needs the hist url: $(tail -n 2 "$T/e" | tr '\n' ' ')"
yq -r '.env.fx.ecb_hist_url, .env.fx.fed_range_url' "$REAL_CNF" >"$T/realh"
if [[ "$(sed -n 1p "$T/realh")" == https://* && "$(sed -n 2p "$T/realh")" == https://*'{from}'*'{to}'* ]]; then
  pass "6 the real cnf has an https ECB history URL and a Fed range URL with {from} and {to}"
else
  fail "6 real cnf history urls: $(tr '\n' '|' <"$T/realh")"
fi

echo
(( fails == 0 )) && { echo "ALL PASS"; exit 0; }
echo "$fails FAILED"; exit 1
