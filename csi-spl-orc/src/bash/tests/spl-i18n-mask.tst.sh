#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the masked copy of spec 115 (T9, owner Q2 "2b"). An i18n task with
#          LANE_MIX_SENSITIVE=1 is secret: claude, grok or mistral drafts it,
#          and the pick carries flag=needs_masked_agy_review. do_spl_i18n_mask
#          writes agy/, the copy agy reviews, with emails, phones and the
#          listed names and workspace names replaced by tokens; map.tsv (0600,
#          outside agy/) takes them back with do_spl_i18n_unmask. The copy is
#          checked before agy/ exists: any hit -> exit 3 and no agy/.
#          Every fixture here is SYNTHETIC (example.org/.net addresses, made-up
#          names and numbers): never real workspace data in this test.
#          Each guard has a control that must turn it red.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
APP_ROOT=$(cd "$PROJ_ROOT/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
FUNC="$PROJ_ROOT/src/bash/run/spl-i18n-mask.func.sh"
UNMASK="$PROJ_ROOT/src/bash/run/spl-i18n-unmask.func.sh"

# run <func-file> <action> [VAR=val...]: one action in a clean shell, the
# output in $T/out
run() {
  local file="$1" act="$2"; shift 2
  env -u I18N_MASK_SRC -u I18N_MASK_TERMS -u I18N_MASK_OUT -u I18N_UNMASK_DST -u LANE_MIX_TASK \
    SPOOL_ROOT="$T/spool" FUNC_FILE="$file" UNMASK_FILE="${UNMASK:-}" ACT="$act" "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    do_require_bin() { command -v "$1" >/dev/null; }
    source "$FUNC_FILE"; [[ -z "${UNMASK_FILE:-}" ]] || source "$UNMASK_FILE"
    "$ACT"' >"$T/out" 2>&1 </dev/null
}

# the synthetic fixture: three locales, one nested, one binary file
SRC="$T/work/locales"
mkdir -p "$SRC/help" "$T/spool"
cat >"$SRC/en.json" <<'EOF'
{"welcome": "Welcome back, Testi Henkilö!", "contact": "Write to anna.fixture@example.org or call +358 40 123 4567.", "ws": "Workspace fixture-acme-ws is ready.", "ver": "Updated 2026-10-12, version 1.3.0, 25 messages"}
EOF
cat >"$SRC/fi.json" <<'EOF'
{"welcome": "Tervetuloa takaisin, Testi Henkilölle!", "contact": "Kirjoita osoitteeseen Anna.Fixture@Example.org tai soita 040 123 4567.", "ws": "Työtila fixture-acme-ws on valmis."}
EOF
cat >"$SRC/help/bg.md" <<'EOF'
# Помощ

Добре дошъл, Иван Тестов! Пишете на ivan.testov@example.net или 0888 123 456.
Работното пространство fixture-acme-ws е готово.
EOF
printf '\x89PNG\r\n\x1a\n\x00\x00Testi Henkilö' >"$SRC/logo.bin"
TERMS="$T/work/terms.txt"
printf '# synthetic\nname Testi Henkilö\nname Иван Тестов\nworkspace fixture-acme-ws\n' >"$TERMS"
# every personal value of the fixture, for the independent grep below
PII=("Testi Henkilö" "Henkilölle" "anna.fixture@example.org" "+358 40 123 4567" "040 123 4567"
     "Иван Тестов" "ivan.testov@example.net" "0888 123 456" "fixture-acme-ws")
# leaks <dir>: how many of PII occur in <dir> (case-insensitive, plain string),
# plus any address-shaped string: the test's own count, not the action's check
leaks() {
  local n=0 v
  for v in "${PII[@]}"; do n=$((n + $(grep -rFio -- "$v" "$1" 2>/dev/null | wc -l))); done
  n=$((n + $(grep -rEo '[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+\.[A-Za-z]+' "$1" 2>/dev/null | wc -l)))
  echo "$n"
}

# --- 0. the action exists ----------------------------------------------------
[[ -f "$FUNC" ]] && bash -n "$FUNC" && pass "0. spl-i18n-mask.func.sh exists and parses" \
  || { fail "0. no $FUNC: the masked copy of spec 115 is not built"; echo "FAILED: $fails"; exit 1; }
(( $(leaks "$SRC") >= ${#PII[@]} )) && pass "0. the fixture carries its synthetic personal data (control for the leak count)" \
  || fail "0. fixture: leaks=$(leaks "$SRC")"

# --- 1. the masked copy: 0 PII hits, the text kept (T9) ----------------------
OUT="$T/spool/dispatch/task-1/i18n-mask"
run "$FUNC" do_spl_i18n_mask I18N_MASK_SRC="$SRC" I18N_MASK_TERMS="$TERMS" LANE_MIX_TASK=task-1
rc=$?
[[ $rc == 0 && -d "$OUT/agy" ]] && grep -qx "agy_review_dir=$OUT/agy" "$T/out" \
  && pass "1. mask: rc 0, agy/ under \$SPOOL_ROOT/dispatch/<task>/i18n-mask" || fail "1. mask rc=$rc: $(cat "$T/out")"
[[ "$(leaks "$OUT/agy")" == 0 ]] && pass "1. agy/ carries 0 of the ${#PII[@]} personal values and no address" \
  || fail "1. agy/ leaks $(leaks "$OUT/agy")"
grep -q 'masked: files=3 email=3 phone=3 name=3 workspace=1 other=0' "$T/out" \
  && pass "1. the counts: 3 text files, each class found" || fail "1. counts: $(grep masked: "$T/out")"
[[ ! -e "$OUT/agy/logo.bin" ]] && pass "1. a binary file is left out of agy/" || fail "1. binary copied to agy/"
grep -q 'Welcome back, \[NAME_[0-9]\]!' "$OUT/agy/en.json" && grep -q 'Updated 2026-10-12, version 1.3.0, 25 messages' "$OUT/agy/en.json" \
  && grep -q 'Работното пространство \[WORKSPACE_1\] е готово' "$OUT/agy/help/bg.md" \
  && jq -e . "$OUT/agy/en.json" "$OUT/agy/fi.json" >/dev/null \
  && pass "1. the text around the data is kept: words, dates, versions, valid JSON" \
  || fail "1. text changed: $(cat "$OUT/agy/en.json")"
[[ -f "$OUT/map.tsv" && "$(stat -c %a "$OUT/map.tsv")" == 600 && -z "$(find "$OUT/agy" -name 'map*')" ]] \
  && pass "1. map.tsv is 0600 and outside agy/" || fail "1. map: $(ls -la "$OUT")"
# agy never receives the original: no file of agy/ equals its source, and
# nothing under agy/ links outside it
same=0
while IFS= read -r f; do cmp -s "$OUT/agy/$f" "$SRC/$f" && same=$((same + 1)); done < <(cd "$OUT/agy" && find . -type f -printf '%P\n')
[[ $same == 0 && -z "$(find "$OUT/agy" -type l)" ]] && pass "1. no file of agy/ is its original, no link in agy/" \
  || fail "1. agy/ holds $same originals"
# CONTROL: the same leak count on the unmasked tree must see every value
(( $(leaks "$SRC") > 0 )) && pass "1. CONTROL: the leak count sees the originals" || fail "1. CONTROL: leak count is blind"

# --- 2. the check refuses a copy that still carries data ----------------------
# CONTROL: a copy of the action whose mask step copies the text unchanged must
# exit 3, print hits without values, and leave no agy/
sed 's/s\/(\$EMAIL)|(\$PHONE)|.*\/gie;/1;/' "$FUNC" >"$T/nomask.func.sh"
grep -q '\$s =~ 1;$' "$T/nomask.func.sh" || fail "2. CONTROL: the sed did not disarm the mask"
run "$T/nomask.func.sh" do_spl_i18n_mask I18N_MASK_SRC="$SRC" I18N_MASK_TERMS="$TERMS" I18N_MASK_OUT="$T/out-nomask"
rc=$?
[[ $rc == 3 && ! -e "$T/out-nomask/agy" && ! -e "$T/out-nomask/agy.tmp" ]] && grep -q '^en.json:1 email$' "$T/out" \
  && grep -q '^help/bg.md:3 name$' "$T/out" && grep -q '^fi.json:1 workspace$' "$T/out" \
  && pass "2. CONTROL: an unmasked copy is refused (rc 3, hits listed, no agy/)" \
  || fail "2. CONTROL: unmasked copy rc=$rc: $(cat "$T/out")"
! grep -qiF 'anna.fixture' "$T/out" && ! grep -qF 'Иван' "$T/out" \
  && pass "2. the hit lines never print the value" || fail "2. a value printed: $(cat "$T/out")"

# --- 3. the term list is the drafter's to complete -----------------------------
# a name the list does not name is NOT masked: the test's own count sees it
printf 'name Testi Henkilö\nworkspace fixture-acme-ws\n' >"$T/work/terms-short.txt"
run "$FUNC" do_spl_i18n_mask I18N_MASK_SRC="$SRC" I18N_MASK_TERMS="$T/work/terms-short.txt" I18N_MASK_OUT="$T/out-short"
[[ "$(grep -rFc 'Иван Тестов' "$T/out-short/agy" | awk -F: '{s += $2} END {print s + 0}')" == 1 ]] \
  && pass "3. CONTROL: a name missing from the list reaches agy/ and the leak count would see it" \
  || fail "3. CONTROL short list: $(cat "$T/out")"
run "$FUNC" do_spl_i18n_mask I18N_MASK_SRC="$SRC" I18N_MASK_OUT="$T/out-x"
[[ $? != 0 && ! -e "$T/out-x/agy" ]] && grep -q 'FATAL I18N_MASK_TERMS must name the term list' "$T/out" \
  && pass "3. no term list -> FATAL, nothing written" || fail "3. no terms: $(cat "$T/out")"
printf 'person Testi Henkilö\n' >"$T/work/terms-bad.txt"
run "$FUNC" do_spl_i18n_mask I18N_MASK_SRC="$SRC" I18N_MASK_TERMS="$T/work/terms-bad.txt" I18N_MASK_OUT="$T/out-bad"
[[ $? != 0 && ! -e "$T/out-bad/agy" ]] && grep -q 'term list line 1' "$T/out" \
  && pass "3. a term line of an unknown class -> refused" || fail "3. bad class: $(cat "$T/out")"
run "$FUNC" do_spl_i18n_mask I18N_MASK_SRC="$SRC" I18N_MASK_TERMS="$TERMS"
[[ $? != 0 ]] && grep -q 'FATAL set I18N_MASK_OUT, or LANE_MIX_TASK' "$T/out" \
  && pass "3. no out dir and no task -> FATAL" || fail "3. no out: $(cat "$T/out")"

# --- 4. the copy and the original never share a tree ---------------------------
run "$FUNC" do_spl_i18n_mask I18N_MASK_SRC="$SRC" I18N_MASK_TERMS="$TERMS" I18N_MASK_OUT="$SRC/masked"
[[ $? != 0 && ! -e "$SRC/masked" ]] && grep -q 'overlap' "$T/out" \
  && pass "4. an out dir inside the source -> refused" || fail "4. out in src: $(cat "$T/out")"
run "$FUNC" do_spl_i18n_mask I18N_MASK_SRC="$SRC" I18N_MASK_TERMS="$TERMS" I18N_MASK_OUT="$T/work"
[[ $? != 0 ]] && grep -q 'overlap' "$T/out" && pass "4. an out dir holding the source -> refused" \
  || fail "4. src in out: $(cat "$T/out")"

# --- 5. unmask: the reviewed copy back to the original --------------------------
run "$FUNC" do_spl_i18n_unmask LANE_MIX_TASK=task-1 I18N_UNMASK_DST="$T/back"
rc=$?
[[ $rc == 0 ]] && diff -r -x logo.bin "$SRC" "$T/back" >/dev/null \
  && pass "5. unmask of the unchanged copy gives the original back, byte for byte" \
  || fail "5. unmask rc=$rc: $(cat "$T/out"; diff -r -x logo.bin "$SRC" "$T/back" | sed -n 1,5p)"
sed -i 's/Welcome back, \[NAME_[0-9]\]!/Welcome back!/' "$OUT/agy/en.json"
run "$FUNC" do_spl_i18n_unmask LANE_MIX_TASK=task-1 I18N_UNMASK_DST="$T/back2"
rc=$?
[[ $rc == 4 ]] && grep -q '^missing \[NAME_[0-9]\]$' "$T/out" && grep -q '"welcome": "Welcome back!"' "$T/back2/en.json" \
  && pass "5. CONTROL: a token the review dropped -> exit 4, missing <token>" || fail "5. dropped token rc=$rc: $(cat "$T/out")"
run "$FUNC" do_spl_i18n_unmask LANE_MIX_TASK=task-1 I18N_UNMASK_DST="$OUT/agy/x"
[[ $? != 0 ]] && grep -q 'overlap' "$T/out" && pass "5. unmask into agy/ -> refused" || fail "5. into agy: $(cat "$T/out")"

# --- 6. the pick: sensitive i18n carries flag=needs_masked_agy_review ----------
H="$T/home"
mkdir -p "$H/.local/bin" "$H/.grok" "$H/.vibe"
for c in claude grok agy vibe; do printf '#!/bin/sh\n' >"$H/.local/bin/$c"; chmod +x "$H/.local/bin/$c"; done
: >"$H/.grok/auth.json"; : >"$H/.vibe/.env"; touch -d '-1 day' "$H/.vibe/.env"
: >"$T/registry.tsv"
CNF="$T/all.env.yaml"
yq '.env.box.agent_split_by_kind.i18n = {"agy": 100, "backup": "claude"}
  | .env.box.agent_split_by_kind.secret = {"claude": 100, "backup": "mistral"}' \
  "$APP_ROOT/csi-spl-cnf/csi-spl/all.env.yaml" >"$CNF"
mix() {
  env -u LANE_MIX_DIFFICULTY -u LANE_MIX_SENSITIVE -u LANE_MIX_SPLIT -u LANE_MIX_SPLIT_KIND -u LANE_MIX_KIND \
    -u LANE_MIX_TASK -u LANE_MIX_JOURNAL -u SPOOL_AGENT_USER -u LANE_MIX_WD_DIR \
    -u CLAUDE_BIN -u GROK_BIN -u AGY_BIN -u QWEN_BIN -u MISTRAL_BIN -u LANE_FLEET -u LANE_HUB_CMD -u ENV \
    PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" SPOOL_ROOT="$T/spool" LANE_MIX_INSTANCE=0 LANE_MIX_REPORT=0 \
    LANE_MIX_REGISTRY="$T/registry.tsv" LANE_MIX_AGENT_HOME="$H" LANE_MIX_CNF="$CNF" "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    do_spl_lane_mix' >"$T/out" 2>&1 </dev/null
}
mix LANE_MIX_KIND=i18n LANE_MIX_SENSITIVE=1
grep -q '^pick=claude launcher=/claude-spawn kind=secret flag=needs_masked_agy_review reason=.*do_spl_i18n_mask' "$T/out" \
  && pass "6. i18n + LANE_MIX_SENSITIVE=1 -> claude, kind secret, flag=needs_masked_agy_review" \
  || fail "6. sensitive i18n: $(tail -n 1 "$T/out")"
mix LANE_MIX_KIND=complex_coding LANE_MIX_SENSITIVE=1
grep -q '^pick=claude launcher=/claude-spawn kind=secret reason=' "$T/out" && ! grep -q 'flag=' "$T/out" \
  && pass "6. CONTROL: sensitive work that is not i18n carries no flag" || fail "6. sensitive coding: $(tail -n 1 "$T/out")"
mkdir -p "$T/spool/dispatch"
for v in claude claude mistral mistral; do
  printf 'task-h\tsecret\t%s\t%s-%s\t%s\tfail:F2\twd\n' "$v" "${v:0:1}" "$RANDOM" "$(date +%s)" >>"$T/spool/dispatch/attempts.tsv"
done
mix LANE_MIX_KIND=i18n LANE_MIX_SENSITIVE=1 LANE_MIX_TASK=task-h
grep -q '^pick=hold launcher=- kind=secret reason=' "$T/out" && ! grep -q 'flag=' "$T/out" && ! grep -q 'pick=agy' "$T/out" \
  && pass "6. sensitive i18n with claude and mistral exhausted -> hold, no flag, never agy" || fail "6. none left: $(tail -n 1 "$T/out")"

echo "---"
(( fails == 0 )) && { echo "ALL PASS"; exit 0; }
echo "FAILED: $fails"; exit 1
