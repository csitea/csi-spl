#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_agent_cred_sync (SPL-6487) on a temp tree: two fake homes,
# "here" (box-a) and a sandboxed fake peer (box-b, reached through
# CRED_PEER_CMD, no ssh), FAKE agy and claude logins (no real login is read),
# fake agy and claude CLIs in each home for the proof: each logs its box,
# CLAUDE_CONFIG_DIR and args, then prints FAKE_PROOF_OUT (default ok):
#   1. agy, the source expires later -> both files copied (600, the old ones
#      kept as .bak-cred-<UTC>), the proof ran on the target box, exit 0
#   2. the source expires earlier -> nothing copied; the same files -> up to date
#   3. a file of the source login missing -> REFUSED, exit 2, nothing copied
#   4. the proof fails on the target -> every file put back from its .bak, a
#      file the copy made removed, exit 1
#   5. the output names sha prefixes only: no token, no file path, no account id
#   6. DRY_RUN=1 (the default) plans and changes nothing; peer -> here works
#   7. claude: main is never written with another account (REFUSED, exit 2);
#      slot 2 with another account is replaced, only the two .claude.json
#      fields cross; the slot 2 proof runs with CLAUDE_CONFIG_DIR
#   8. refusals: same box, neither box here, no such vendor or slot
#  10. (R7 W1) an expiry that cannot be read at the source or an existing
#      target, or a target that cannot be reached -> REFUSED, exit 2
#  11. (R7 W2) claude main whose target has a credential but no account ->
#      REFUSED, exit 2 (its label is unknown), even when the source is newer
#  12. (R7 N5) a claude proof failure puts back the credential and the
#      .claude.json; a copy that fails at file 2 puts file 1 back
#   9. do_spl_agent_login2_sync is the wrapper: CRED_* boxes in the caller's
#      env do not reach it; no cron row runs do_spl_agent_cred_sync (owner N)
#   CONTROL (red): cases 1, 2, 3, 4, 5, 10 and 11 each FAIL on a copy of the action with
#   that guard taken out
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0

SECRET="fake-refresh-token-$$"
ME="$(id -un)"; CRED="$PROJ_ROOT/src/bash/scripts/agent-login-cred.sh"
HH="$T/h"; PH="$T/p"; PLOG="$T/probe.log"
AT=.gemini/antigravity-cli/antigravity-oauth-token; AS=.config/antigravity/credential-user-scope
mkagy() { mkdir -p "$1/${AT%/*}" "$1/${AS%/*}"; printf '{"token":{"refresh_token":"%s","expiry":"%s"}}\n' "$SECRET" "$2" > "$1/$AT"; printf 'scope-%s-%s\n' "$SECRET" "$2" > "$1/$AS"; }
mkclaude() { mkdir -p "$1/$2"; printf '{"claudeAiOauth":{"refreshToken":"%s","expiresAt":%s}}\n' "$SECRET" "$3" > "$1/$2/.credentials.json"
  printf '{"oauthAccount":{"accountUuid":"%s"},"hasCompletedOnboarding":true,"projects":{"p":1}}\n' "$4" > "$1/$5"; }
lab() { printf 'acct-%s' "$(printf '%s' "$1" | sha256sum | cut -c1-8)"; }
reset() { local h b; rm -rf "$HH" "$PH" "$PLOG"; : > "$PLOG"
  for h in "$HH" "$PH"; do mkdir -p "$h/.local/bin"; for b in agy claude; do
    printf '#!/bin/bash\necho "${PROBE_AT:-box-a}|${CLAUDE_CONFIG_DIR:-}|$*" >> %q\necho "${FAKE_PROOF_OUT:-ok}"\n' "$PLOG" > "$h/.local/bin/$b"; chmod +x "$h/.local/bin/$b"
  done; done; }
P1='-p Reply with the single word ok.' 
PCMD="f() { PROBE_AT=box-b LOGIN_AGENT_USER=$ME LOGIN_AGENT_HOME=$PH LOGIN_SUDO= bash $CRED \"\${@:2}\"; }; f"
# runner: PROJ (the orc tree) VAR=value...
runner() { local p="$1"; shift; PROJ_ROOT="$p" SNIPPET='do_spl_agent_cred_sync' in_orc SPOOL_AGENT_USER="$ME" SPOOL_ROOT="$T/spool" \
  SPOOL_BOX_ENV="$T/spool/box.env" SPOOL_BOX_TAG=box-a CRED_PEERS=box-b=peer-dest CRED_PEER_CMD="$PCMD" CRED_AGENT_HOME="$HH" CRED_SUDO= \
  CRED_SYNC_CNF="$APP_ROOT/csi-spl-cnf/csi-spl/all.env.yaml" "$@" 2>&1; }
run() { runner "$PROJ_ROOT" "$@"; }
mkdir -p "$T/spool"; : > "$T/spool/box.env"
ALL=""

# ---- the checks; each takes a runner, so the controls rerun them on a broken copy
c1_newer() { local r="$1" out rc
  reset; mkagy "$HH" 2030-01-01T00:00:00Z; mkagy "$PH" 2029-01-01T00:00:00Z
  out="$($r CRED_VENDOR=agy CRED_SRC_BOX=box-a CRED_DST_BOX=box-b DRY_RUN=0)"; rc=$?; ALL+="$out"
  [[ $rc == 0 && "$out" == *"copied $(sha256sum < "$HH/$AT" | cut -c1-12) $(sha256sum < "$HH/$AS" | cut -c1-12), expires 2030-01-01T00:00:00Z; the agy -p proof is ok"* ]] &&
    cmp -s "$HH/$AT" "$PH/$AT" && cmp -s "$HH/$AS" "$PH/$AS" && [[ "$(stat -c %a "$PH/$AT" "$PH/$AS" | tr '\n' ' ')" == "600 600 " ]] &&
    grep -q 2029 "$PH/$AT".bak-cred-* && grep -q 2029 "$PH/$AS".bak-cred-* && [[ "$(cat "$PLOG")" == "box-b||$P1" ]] || { echo "  rc=$rc out=$out probe=$(cat "$PLOG")"; return 1; }
}
c2_older() { local r="$1" out rc out2
  reset; mkagy "$HH" 2028-01-01T00:00:00Z; mkagy "$PH" 2029-01-01T00:00:00Z
  out="$($r CRED_VENDOR=agy CRED_SRC_BOX=box-a CRED_DST_BOX=box-b DRY_RUN=0)"; rc=$?; ALL+="$out"
  cp -p "$HH/$AT" "$T/keep"; mkagy "$HH" 2029-01-01T00:00:00Z
  out2="$($r CRED_VENDOR=agy CRED_SRC_BOX=box-a CRED_DST_BOX=box-b DRY_RUN=0)"; ALL+="$out2"
  [[ $rc == 0 && "$out" == *"the source is not newer"*"nothing copied"* && "$out2" == *"up to date"* ]] && grep -q 2029 "$PH/$AT" &&
    ! ls "$PH/$AT".bak-cred-* >/dev/null 2>&1 && [[ ! -s "$PLOG" ]] || { echo "  rc=$rc out=$out / $out2"; return 1; }
}
c3_missing() { local r="$1" out rc
  reset; mkagy "$HH" 2030-01-01T00:00:00Z; mkagy "$PH" 2029-01-01T00:00:00Z; rm "$HH/$AS"
  out="$($r CRED_VENDOR=agy CRED_SRC_BOX=box-a CRED_DST_BOX=box-b DRY_RUN=0)"; rc=$?; ALL+="$out"
  [[ $rc == 2 && "$out" == *"REFUSED the source has no file 2 of 2"* ]] && grep -q 2029 "$PH/$AT" && grep -q 2029 "$PH/$AS" ||
    { echo "  rc=$rc out=$out"; return 1; }
}
c4_proof() { local r="$1" out rc
  reset; mkagy "$HH" 2030-01-01T00:00:00Z; mkagy "$PH" 2029-01-01T00:00:00Z; rm "$PH/$AS"
  out="$($r CRED_VENDOR=agy CRED_SRC_BOX=box-a CRED_DST_BOX=box-b DRY_RUN=0 FAKE_PROOF_OUT='please run /login')"; rc=$?; ALL+="$out"
  [[ $rc == 1 && "$out" == *"FAILED the agy -p proof on the target (expired)"*"put back from its .bak (restored removed)"* ]] &&
    grep -q 2029 "$PH/$AT" && [[ ! -e "$PH/$AS" ]] && ! ls "$PH/$AT".bak-cred-* >/dev/null 2>&1 || { echo "  rc=$rc out=$out"; return 1; }
}
c10_expiry() { local r="$1" out rc o2 rc2 o3 rc3
  reset; mkagy "$HH" 2030-01-01T00:00:00Z; mkagy "$PH" GARBLED-DATE
  out="$($r CRED_VENDOR=agy CRED_SRC_BOX=box-a CRED_DST_BOX=box-b DRY_RUN=0)"; rc=$?; ALL+="$out"
  rm -rf "${PH:?}/.gemini" "$PH/.config"; mkagy "$HH" NOT-A-DATE
  o2="$($r CRED_VENDOR=agy CRED_SRC_BOX=box-a CRED_DST_BOX=box-b DRY_RUN=0)"; rc2=$?; ALL+="$o2"
  o3="$($r CRED_VENDOR=agy CRED_SRC_BOX=box-a CRED_DST_BOX=box-b CRED_PEER_CMD=false)"; rc3=$?; ALL+="$o3"
  [[ $rc == 2 && "$out" == *"REFUSED the target's token names no expiry"* && $rc2 == 2 && "$o2" == *"REFUSED the source token names no expiry"* &&
     $rc3 == 2 && "$o3" == *"REFUSED the target's file 1 cannot be read (unreachable)"* ]] && [[ ! -e "$PH/$AT" ]] && [[ ! -s "$PLOG" ]] ||
    { echo "  rc=$rc/$rc2/$rc3 out=$out / $o2 / $o3"; return 1; }
}
c11_noacct() { local r="$1" out rc
  reset; mkclaude "$HH" .claude 1950000000000 uuid-a .claude.json; mkclaude "$PH" .claude 1800000000000 uuid-b .claude.json; rm "$PH/.claude.json"
  out="$($r CRED_VENDOR=claude CRED_SRC_BOX=box-a CRED_DST_BOX=box-b DRY_RUN=0)"; rc=$?; ALL+="$out"
  [[ $rc == 2 && "$out" == *"REFUSED the target's main login names no account"* ]] && grep -q 1800000000000 "$PH/.claude/.credentials.json" &&
    [[ ! -e "$PH/.claude.json" ]] || { echo "  rc=$rc out=$out"; return 1; }
}
c5_quiet() { local all="$1"
  [[ -n "$all" && "$all" != *"$SECRET"* && "$all" != *"$T"* && "$all" != *uuid-* && "$all" != *antigravity* && "$all" != *credentials* ]] ||
    { echo "  leaked: $all"; return 1; }
}

chk() { "$1" "$2" > "$T/msg"; }
chk c1_newer run && pass "1. agy, newer source: both files copied, 600, .bak-cred kept, the proof on the target" || fail "1. $(cat "$T/msg")"
chk c2_older run && pass "2. older source: nothing copied; the same files: up to date" || fail "2. $(cat "$T/msg")"
chk c3_missing run && pass "3. a missing source file: REFUSED, exit 2, nothing copied" || fail "3. $(cat "$T/msg")"
chk c4_proof run && pass "4. a failed proof: the .bak put back, a new file removed, exit 1" || fail "4. $(cat "$T/msg")"

reset; mkagy "$HH" 2030-01-01T00:00:00Z; mkagy "$PH" 2029-01-01T00:00:00Z
out="$(run CRED_VENDOR=agy CRED_SRC_BOX=box-a CRED_DST_BOX=box-b)"; rc=$?; ALL+="$out"
[[ $rc == 0 && "$out" == *"PLAN copied"*"(DRY_RUN)"* ]] && grep -q 2029 "$PH/$AT" && [[ ! -s "$PLOG" ]] && pass "6. DRY_RUN=1 by default: plans, changes nothing, no proof" || fail "6. rc=$rc $out"
reset; mkagy "$HH" 2028-01-01T00:00:00Z; mkagy "$PH" 2029-01-01T00:00:00Z
out="$(run CRED_VENDOR=agy CRED_SRC_BOX=box-b CRED_DST_BOX=box-a DRY_RUN=0)"; rc=$?; ALL+="$out"
[[ $rc == 0 ]] && cmp -s "$PH/$AT" "$HH/$AT" && [[ "$(cat "$PLOG")" == "box-a||$P1" ]] && pass "6. peer -> here: copied, the proof here" || fail "6b. rc=$rc $out"

reset; mkclaude "$HH" .claude 1893456000000 uuid-a .claude.json; mkclaude "$PH" .claude 1861920000000 uuid-b .claude.json
out="$(run CRED_VENDOR=claude CRED_SRC_BOX=box-a CRED_DST_BOX=box-b DRY_RUN=0)"; rc=$?; ALL+="$out"
[[ $rc == 2 && "$out" == *"REFUSED the target's main login is another account ($(lab uuid-b)"* ]] && grep -q 1861920000000 "$PH/.claude/.credentials.json" &&
  pass "7. claude main with another account: REFUSED, exit 2" || fail "7. rc=$rc $out"
mkclaude "$PH" .claude-2 1924992000000 uuid-b .claude-2/.claude.json
out="$(run CRED_VENDOR=claude CRED_SLOT=2 CRED_SRC_BOX=box-a CRED_DST_BOX=box-b DRY_RUN=0)"; rc=$?; ALL+="$out"
[[ $rc == 0 && "$out" == *"replaced the stale account $(lab uuid-b) with $(lab uuid-a)"* ]] && cmp -s "$HH/.claude/.credentials.json" "$PH/.claude-2/.credentials.json" &&
  [[ "$(jq -c '[.oauthAccount.accountUuid, (keys | length)]' "$PH/.claude-2/.claude.json")" == '["uuid-a",3]' && "$(cat "$PLOG")" == "box-b|$PH/.claude-2|$P1 --model haiku" ]] &&
  pass "7. claude slot 2, another account: replaced (older though), two fields, proof under CLAUDE_CONFIG_DIR" || fail "7b. rc=$rc $out $(cat "$PLOG")"
out="$(run CRED_VENDOR=claude CRED_SLOT=2 CRED_SRC_BOX=box-a CRED_DST_BOX=box-b DRY_RUN=0)"; ALL+="$out"
[[ "$out" == *"up to date ($(lab uuid-a), "* ]] && pass "7. claude slot 2 again: up to date" || fail "7c. $out"

for a in "CRED_SRC_BOX=box-a CRED_DST_BOX=box-a|the same box" "CRED_SRC_BOX=box-c CRED_DST_BOX=box-b|neither box is this one" \
         "CRED_VENDOR=grok CRED_SRC_BOX=box-a CRED_DST_BOX=box-b|no cnf" "CRED_SLOT=3 CRED_SRC_BOX=box-a CRED_DST_BOX=box-b|no cnf"; do
  # shellcheck disable=SC2086  # the case's VAR=value words
  out="$(run CRED_VENDOR=agy ${a%%|*} DRY_RUN=0)"; rc=$?
  [[ $rc == 2 && "$out" == *"REFUSED"*"${a#*|}"* ]] && pass "8. ${a%%|*}: REFUSED" || fail "8. ${a%%|*} rc=$rc $out"
done

out="$(SNIPPET='do_spl_agent_login2_sync' in_orc SPOOL_AGENT_USER="$ME" LOGIN2_SUDO= HOME="$T/home" SPOOL_ROOT="$T/spool" SPOOL_BOX_ENV="$T/spool/box.env" \
  CRED_SRC_BOX=box-a CRED_DST_BOX=box-b CLAUDE2_CONFIG_DIR="$T/x" DRY_RUN=0 2>&1)"; rc=$?
[[ $rc == 0 && "$out" == "login2-sync: WARN no source set"* ]] && pass "9. login2-sync is the wrapper: the caller's CRED_* boxes do not reach it" || fail "9. rc=$rc $out"
! grep -q cred_sync "$PROJ_ROOT/cnf/box-crons/box-crons.manifest" && pass "9. no cron row runs do_spl_agent_cred_sync (on demand only)" || fail "9. a cron row"

chk c10_expiry run && pass "10. an unreadable expiry (target, source) or an unreachable target: REFUSED, exit 2" || fail "10. $(cat "$T/msg")"
chk c11_noacct run && pass "11. claude main, a target credential with no account: REFUSED, exit 2" || fail "11. $(cat "$T/msg")"

reset; mkclaude "$HH" .claude 1950000000000 uuid-a .claude.json; mkclaude "$PH" .claude-2 1800000000000 uuid-a .claude-2/.claude.json
cp -p "$PH/.claude-2/.credentials.json" "$T/c2"; cp -p "$PH/.claude-2/.claude.json" "$T/j2"
out="$(run CRED_VENDOR=claude CRED_SLOT=2 CRED_SRC_BOX=box-a CRED_DST_BOX=box-b DRY_RUN=0 FAKE_PROOF_OUT='hit your limit')"; rc=$?; ALL+="$out"
[[ $rc == 1 && "$out" == *"FAILED the claude -p proof on the target (limited)"*"(restored restored)"* ]] && cmp -s "$T/c2" "$PH/.claude-2/.credentials.json" && cmp -s "$T/j2" "$PH/.claude-2/.claude.json" &&
  pass "12. a claude proof failure: the credential and the .claude.json put back" || fail "12. rc=$rc $out"
reset; mkagy "$HH" 2030-01-01T00:00:00Z; mkagy "$PH" 2029-01-01T00:00:00Z; chmod 500 "$PH/${AS%/*}"
out="$(run CRED_VENDOR=agy CRED_SRC_BOX=box-a CRED_DST_BOX=box-b DRY_RUN=0)"; rc=$?; ALL+="$out"; chmod 700 "$PH/${AS%/*}"
[[ $rc == 1 && "$out" == *"FAILED the copy of file 2"*"(restored kept)"* ]] && grep -q 2029 "$PH/$AT" && grep -q 2029 "$PH/$AS" && [[ ! -s "$PLOG" ]] &&
  pass "12. a copy that fails at file 2: file 1 put back, no proof" || fail "12b. rc=$rc $out"

chk c5_quiet "$ALL" && pass "5. every output: sha prefixes and labels only, no token, path or account id" || fail "5. $(cat "$T/msg")"

# ---- red controls: a copy of the orc tree whose action lost one guard
broken() { local d="$T/ctl-$1/csi-spl-orc"; mkdir -p "$d/src/bash"
  ln -sfn "$PROJ_ROOT/lib" "$d/lib"; ln -sfn "$PROJ_ROOT/src/bash/scripts" "$d/src/bash/scripts"
  mkdir -p "$d/src/bash/run"; cp "$PROJ_ROOT"/src/bash/run/spl-agent-{cred,login2}-sync.func.sh "$d/src/bash/run/"
  sed -i "$2" "$d/src/bash/run/spl-agent-cred-sync.func.sh"; echo "$d"; }
C1="$(broken copy 's/((CS_SEXP > CS_DEXP))/false/')"
C10="$(broken expiry 's/((CS_SEXP > 0)) ||/true ||/')"
C11="$(broken noacct 's/\[\[ "\${CS_DNEW\[0\]}" == 1 \]\] || { _cs_say "REFUSED the target.s main login names no account/true || { _cs_say "x/')"
C2="$(broken newer 's/((CS_SEXP > CS_DEXP))/true/')"
C3="$(broken missing 's/\[\[ "\$sst" =~ \^\[0-9a-f\]{12}\\ \[0-9\]+\$ \]\] ||/true ||/')"
C4="$(broken restore 's/^_cs_restore() {/_cs_restore() { echo skipped; return; /')"
C5="$(broken quiet 's/^_cs_say() { echo /_cs_say() { _cs_at "$CS_SRC" fget "${CS_SFILES[0]}" 2>\/dev\/null; echo /')"
rc1() { IN_ORC_RUN="spl-agent-cred-sync spl-agent-login2-sync" runner "$C1" "$@"; }
rc10() { IN_ORC_RUN="spl-agent-cred-sync spl-agent-login2-sync" runner "$C10" "$@"; }
rc11() { IN_ORC_RUN="spl-agent-cred-sync spl-agent-login2-sync" runner "$C11" "$@"; }
rc2() { IN_ORC_RUN="spl-agent-cred-sync spl-agent-login2-sync" runner "$C2" "$@"; }
rc3() { IN_ORC_RUN="spl-agent-cred-sync spl-agent-login2-sync" runner "$C3" "$@"; }
rc4() { IN_ORC_RUN="spl-agent-cred-sync spl-agent-login2-sync" runner "$C4" "$@"; }
rc5() { IN_ORC_RUN="spl-agent-cred-sync spl-agent-login2-sync" runner "$C5" "$@"; }
c1_newer rc1 >/dev/null && fail "CONTROL 1: the newer copy taken out, case 1 still passes" || pass "CONTROL 1: the newer copy taken out, case 1 FAILS"
c2_older rc2 >/dev/null && fail "CONTROL 2: newer-only taken out, case 2 still passes" || pass "CONTROL 2: newer-only taken out, case 2 FAILS"
c3_missing rc3 >/dev/null && fail "CONTROL 3: the missing-source refusal taken out, case 3 still passes" || pass "CONTROL 3: the missing-source refusal taken out, case 3 FAILS"
c4_proof rc4 >/dev/null && fail "CONTROL 4: the restore taken out, case 4 still passes" || pass "CONTROL 4: the restore taken out, case 4 FAILS"
c10_expiry rc10 >/dev/null && fail "CONTROL 10: the source-expiry refusal taken out, case 10 still passes" || pass "CONTROL 10: the source-expiry refusal taken out, case 10 FAILS"
c11_noacct rc11 >/dev/null && fail "CONTROL 11: the unknown-label refusal taken out, case 11 still passes" || pass "CONTROL 11: the unknown-label refusal taken out, case 11 FAILS"
ALL=""; c1_newer rc5 >/dev/null
c5_quiet "$ALL" >/dev/null && fail "CONTROL 5: a file printed, case 5 still passes" || pass "CONTROL 5: a file printed, case 5 FAILS"

(( fails == 0 )) && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
