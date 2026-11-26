#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: step y9 gives agy and qwen every fleet-rule part that binds their
# seats (SPL-6533), not only 25-stay-in-your-lane. Hermetic: a throwaway HOME.
#   1. a fresh HOME: each Y9_PARTS part (25 AND 28 named) has its own agy
#      rules file, always_on frontmatter first, one fragment; QWEN.md carries
#      each part once, in part order; no Y9_SKIP part, no {{placeholder}}
#   2. each rendered fragment is its part file byte for byte
#   3. a QWEN.md as the old y9 left it (25 only + qwen's memory): one run adds
#      the rest, 25 stays once, the memory is kept, ONE backup (the old file);
#      a re-run writes nothing; no staging dir is left in ~/.qwen; the
#      backup is mode 600
#   4. a hand-edited 28 block in QWEN.md is left alone and named, rc 0
#   5. DRY=1 writes nothing
#   6. every part in claude-md/ is in exactly one of Y9_PARTS / Y9_SKIP, and
#      both lists name only parts that exist
#   7. a part that fails with an error y9 does not know (a QWEN.md that is not
#      UTF-8): rc != 0, the error reaches stderr, QWEN.md unchanged, no staging dir
#   8. all 99 backup names of one UTC second taken: rc != 0, "no free backup
#      name", no -100 backup, QWEN.md unchanged
#   9. the k=1 backup name of this UTC second taken (umask 022): the backup
#      goes to -2, mode 600, the old file; the k=1 one is untouched
#  10. an OS error other than "name taken" fails at once with that error, never
#      "no free backup name": through y9, an unreadable QWEN.md (mode 000,
#      non-root): rc != 0, "Permission denied", QWEN.md kept, no staging dir;
#      _y9_qwen_backup alone on a missing dir (ENOENT) and on a read-only
#      ~/.qwen (mode 500, non-root, EACCES)
# Control: on the tree before SPL-6533 (y9 renders 25 only), 1 and 3 FAIL;
# before SPL-6556 (stderr kept only on 4 known texts, an uncapped backup loop),
# 7 and 8 FAIL. Before SPL-6598 (every backup error read as a taken name),
# 10 FAILS (bug round 51 rc01-b51.sh).
#------------------------------------------------------------------------------
# shellcheck disable=SC2016,SC2015  # the bash -c body expands in the child; pass || fail
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
FEAT="$(cd "$TEST_DIR/.." && pwd)"
Y9="$FEAT/steps/y9-vendor-lane-rule.sh"
MD="$FEAT/assets/claude/claude-md"
fails=0 n=0
pass() { n=$((n + 1)); echo "PASS: $1"; }
fail() { n=$((n + 1)); echo "FAIL: $1"; fails=$((fails + 1)); }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
unset DRY FORCE_SKILLS SPOOL_INSTALL_VENDOR_RULES SPOOL_INSTALL_CLAUDE_ASSETS
y9() { local h="$1"; shift; env HOME="$h" "$@" bash -c 'source "$0" && spool_install_vendor_lane_rule' "$Y9"; }
WANT_PARTS="22-ui-forms-for-user-input 25-stay-in-your-lane 27-lane-issue-and-docs 28-wiki-designated-team-branch 30-cross-lane-findings"
SKIP_PARTS="00-title 05-agents-run-as-agent-user 07-permission-mode-bypass 10-push-and-deploy 20-spawn-an-agent"
frag() { awk -v p="<!-- fragment spool-install/$2 -->" '$0 == p {on = 1; next} on && $0 == "<!-- /fragment -->" {exit} on' "$1"; }

# ── 1. a fresh HOME ───────────────────────────────────────────────────────────
H="$T/h1"; mkdir -p "$H/.gemini" "$H/.qwen"
y9 "$H" 2>"$T/err1"; rc=$?
[ "$rc" = 0 ] && pass "1: y9 exits 0" || { fail "1: y9 rc=$rc"; cat "$T/err1"; }
R="$H/.gemini/config/rules" Q="$H/.qwen/QWEN.md"
for p in 25-stay-in-your-lane 28-wiki-designated-team-branch; do
  [ -f "$R/$p.md" ] && grep -qx "<!-- fragment spool-install/$p -->" "$R/$p.md" && pass "1: agy rules dir has $p" || fail "1: agy rules dir lacks $p"
  [ "$(grep -cx "<!-- fragment spool-install/$p -->" "$Q" 2>/dev/null)" = 1 ] && pass "1: QWEN.md has $p once" || fail "1: QWEN.md lacks $p"
done
ok=1
for p in $WANT_PARTS; do
  [ "$(head -n 3 "$R/$p.md" 2>/dev/null)" = $'---\ntrigger: always_on\n---' ] && [ "$(grep -c '^<!-- fragment ' "$R/$p.md")" = 1 ] || ok=0
done
[ "$ok" = 1 ] && pass "1: each of the 5 parts: its own agy file, frontmatter first, one fragment" || fail "1: an agy part file is missing or wrong"
got=$(grep '^<!-- fragment spool-install/' "$Q" 2>/dev/null | sed 's|^<!-- fragment spool-install/||; s| -->$||' | tr '\n' ' ')
[ "$got" = "$WANT_PARTS " ] && pass "1: QWEN.md carries the 5 parts in part order" || fail "1: QWEN.md parts: '$got'"
bad=0; for p in $SKIP_PARTS; do [ -e "$R/$p.md" ] || grep -q "fragment spool-install/$p " "$Q" 2>/dev/null && bad=1; done
[ "$bad" = 0 ] && pass "1: no Y9_SKIP part rendered" || fail "1: a skipped part was rendered"
! grep -qE '\{\{[A-Z_]+\}\}' "$Q" "$R"/*.md 2>/dev/null && pass "1: no {{placeholder}} left" || fail "1: a placeholder left"

# ── 2. byte for byte ──────────────────────────────────────────────────────────
ok=1
for p in $WANT_PARTS; do
  cmp -s <(frag "$Q" "$p") "$MD/$p.md" && cmp -s <(frag "$R/$p.md" "$p") "$MD/$p.md" || ok=0
done
[ "$ok" = 1 ] && pass "2: every rendered fragment is its part file byte for byte" || fail "2: a fragment differs from its part"

# ── 3. the upgrade of a QWEN.md the old y9 wrote ──────────────────────────────
H="$T/h3"; mkdir -p "$H/.qwen"; Q="$H/.qwen/QWEN.md"
Y8_ONLY=25-stay-in-your-lane Y8_TAG=lane-rule python3 "$FEAT/steps/y8-vibe-agents.py" "$MD" "$Q" 0 0 2>/dev/null
printf '\n## Qwen Added Memories\n- keep me\n' >>"$Q"
old=$(sha256sum <"$Q")
y9 "$H" 2>/dev/null; rc=$?
got=$(grep -c '^<!-- fragment spool-install/' "$Q")
[ "$rc" = 0 ] && [ "$got" = 5 ] && [ "$(grep -cx '<!-- fragment spool-install/25-stay-in-your-lane -->' "$Q")" = 1 ] &&
  pass "3: the old 25-only QWEN.md gets the other 4 parts, 25 stays once" || fail "3: rc=$rc, $got fragments"
grep -qx -- '- keep me' "$Q" && pass "3: qwen's memory text kept" || fail "3: qwen's memory text lost"
baks=$(find "$H/.qwen" -maxdepth 1 -name 'QWEN.md.bak-spool-install-*')
[ "$(printf '%s' "$baks" | grep -c .)" = 1 ] && [ "$(sha256sum <"$baks")" = "$old" ] &&
  pass "3: exactly one backup, and it is the old file" || fail "3: backups: $(printf '%s' "$baks" | grep -c .)"
mode=$(stat -c %a "$baks" 2>/dev/null)
[ "$mode" = 600 ] && pass "3: the backup is mode 600" || fail "3: backup mode '$mode'"
before=$(sha256sum <"$Q"); y9 "$H" 2>/dev/null
[ "$(sha256sum <"$Q")" = "$before" ] && [ "$(find "$H/.qwen" -name '*.bak-spool-install-*' | wc -l)" = 1 ] &&
  pass "3: a re-run writes nothing" || fail "3: a re-run wrote"
[ -z "$(find "$H/.qwen" -mindepth 1 -maxdepth 1 -name '.y9-stage.*')" ] && pass "3: no staging dir left" || fail "3: a staging dir was left"

# ── 4. a hand-edited block ────────────────────────────────────────────────────
sed -i 's/^## Never add or move a wiki page.*/## my own words/' "$Q"
y9 "$H" 2>"$T/err4"; rc=$?
[ "$rc" = 0 ] && grep -qx '## my own words' "$Q" && grep -q "$Q: the spool-install block was edited by hand" "$T/err4" &&
  pass "4: a hand-edited 28 block is left alone and named" || { fail "4: rc=$rc"; cat "$T/err4"; }

# ── 5. DRY=1 ──────────────────────────────────────────────────────────────────
H="$T/h5"; mkdir -p "$H/.gemini" "$H/.qwen"
y9 "$H" DRY=1 >/dev/null 2>&1
[ -z "$(find "$H" -mindepth 2)" ] && pass "5: DRY=1 writes nothing" || fail "5: DRY=1 wrote: $(find "$H" -mindepth 2)"

# ── 6. every part is placed ───────────────────────────────────────────────────
lists=$(env -i bash -c 'source "$0" && echo "$Y9_PARTS|$Y9_SKIP"' "$Y9")
have=$(find "$MD" -maxdepth 1 -name '[0-9][0-9]-*.md' -printf '%f\n' | sed 's/\.md$//' | sort | tr '\n' ' ')
named=$(echo "${lists//|/ }" | tr ' ' '\n' | grep . | sort | tr '\n' ' ')
dups=$(echo "${lists//|/ }" | tr ' ' '\n' | grep . | sort | uniq -d)
[ "$named" = "$have" ] && [ -z "$dups" ] && pass "6: every part is in exactly one of Y9_PARTS / Y9_SKIP" ||
  fail "6: put each new part in Y9_PARTS (agy + qwen get it) or Y9_SKIP (with its reason): have '$have', named '$named', dups '$dups'"

# ── 7. an unexpected part error reaches stderr ───────────────────────────────
H="$T/h7"; mkdir -p "$H/.qwen"; Q="$H/.qwen/QWEN.md"
printf '\xff\xfe not utf-8\n' >"$Q"
before=$(sha256sum <"$Q")
y9 "$H" 2>"$T/err7"; rc=$?
[ "$rc" != 0 ] && grep -q 'UnicodeDecodeError' "$T/err7" && [ "$(sha256sum <"$Q")" = "$before" ] &&
  [ -z "$(find "$H/.qwen" -mindepth 1 -maxdepth 1 -name '.y9-stage.*')" ] &&
  pass "7: an unexpected part error fails, reaches stderr, QWEN.md kept, no staging dir" || { fail "7: rc=$rc"; cat "$T/err7"; }

# ── 8. every backup name taken ────────────────────────────────────────────────
H="$T/h8"; mkdir -p "$H/.qwen" "$T/bin8"; Q="$H/.qwen/QWEN.md"
printf '#!/bin/sh\necho 20261126T000000Z\n' >"$T/bin8/date"; chmod +x "$T/bin8/date"
printf 'keep original\n' >"$Q"
before=$(sha256sum <"$Q")
: >"$Q.bak-spool-install-20261126T000000Z"
for (( k = 2; k < 100; k++ )); do : >"$Q.bak-spool-install-20261126T000000Z-$k"; done
y9 "$H" PATH="$T/bin8:$PATH" 2>"$T/err8"; rc=$?
[ "$rc" != 0 ] && grep -q 'no free backup name' "$T/err8" && [ ! -e "$Q.bak-spool-install-20261126T000000Z-100" ] &&
  [ "$(sha256sum <"$Q")" = "$before" ] &&
  pass "8: all 99 backup names taken: refused, no -100, QWEN.md kept" || { fail "8: rc=$rc"; cat "$T/err8"; }

# ── 9. the k=1 name taken: -2, mode 600 ──────────────────────────────────────
H="$T/h9"; mkdir -p "$H/.qwen"; Q="$H/.qwen/QWEN.md"; B="$Q.bak-spool-install-20261126T000000Z"
printf 'old qwen content\n' >"$Q"; printf 'existing k1\n' >"$B"
old=$(sha256sum <"$Q"); k1=$(sha256sum <"$B")
(umask 0022; y9 "$H" PATH="$T/bin8:$PATH" 2>"$T/err9"); rc=$?
mode=$(stat -c %a "$B-2" 2>/dev/null)
[ "$rc" = 0 ] && [ "$mode" = 600 ] && [ "$(sha256sum <"$B-2")" = "$old" ] && [ "$(sha256sum <"$B")" = "$k1" ] &&
  pass "9: k=1 taken: the backup is -2, mode 600, the old file; k=1 untouched" || { fail "9: rc=$rc mode='$mode'"; cat "$T/err9"; }

# ── 10. any other OS error fails at once, with that error ─────────────────────
bk() { bash -c 'source "$0" && _y9_qwen_backup "$1"' "$Y9" "$1"; }
out=$(bk "$T/no-such-dir/QWEN.md" 2>&1); rc=$?
[ "$rc" != 0 ] && grep -q 'No such file or directory' <<<"$out" && ! grep -q 'no free backup name' <<<"$out" &&
  pass "10: _y9_qwen_backup on a missing dir: ENOENT, not \"no free backup name\"" || fail "10: ENOENT rc=$rc: $out"
if [ "$(id -u)" != 0 ]; then
  H="$T/h10"; mkdir -p "$H/.qwen"; Q="$H/.qwen/QWEN.md"
  printf 'keep unreadable original\n' >"$Q"; before=$(sha256sum <"$Q"); chmod 000 "$Q"
  y9 "$H" 2>"$T/err10"; rc=$?
  chmod 600 "$Q"
  [ "$rc" != 0 ] && grep -qi 'permission denied' "$T/err10" && ! grep -q 'no free backup name' "$T/err10" &&
    [ "$(sha256sum <"$Q")" = "$before" ] && [ -z "$(find "$H/.qwen" -mindepth 1 -maxdepth 1 -name '.y9-stage.*')" ] &&
    pass "10: y9 on an unreadable QWEN.md: Permission denied, QWEN.md kept, no staging dir" || { fail "10: unreadable rc=$rc"; cat "$T/err10"; }
  H="$T/h10ro"; mkdir -p "$H/.qwen"; Q="$H/.qwen/QWEN.md"; printf 'keep me\n' >"$Q"; chmod 0500 "$H/.qwen"
  out=$(bk "$Q" 2>&1); rc=$?
  chmod 0700 "$H/.qwen"
  [ "$rc" != 0 ] && grep -qi 'permission denied' <<<"$out" && ! grep -q 'no free backup name' <<<"$out" &&
    pass "10: _y9_qwen_backup on a read-only ~/.qwen: EACCES, not \"no free backup name\"" || fail "10: EACCES rc=$rc: $out"
else
  echo "SKIP: 10: unreadable QWEN.md and read-only ~/.qwen need a non-root user"
fi

echo "== y9 agy + qwen fleet rules: $((n - fails))/$n passed"
[ "$fails" = 0 ]
