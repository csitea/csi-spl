#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: spec 065 L4 do_spl_release_note_bans_check against a stubbed gcloud
#          (the slot) and a stubbed hub (curl): it probes one literal per ban
#          line, passes only when the hub redacts every probe and NOT the
#          control, never lets a literal reach argv or the output, and needs a
#          seeded slot.
#          CONTROLS: a hub without the env (redacts nothing) FAILS; a hub that
#          redacts everything (control redacted) FAILS; a hub that STORES a
#          probe FAILS.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0
mkdir -p "$T/store" "$T/home" "$T/bin"
SLOT=csi-spl-hub-release-note-bans
# synthetic bans: three with a literal, one without (no probe for it)
printf '%s\n' '(?i)\balphaone\b|beta' 'gamma\.example|delta' '(?i)@zeta\.test|eta\.test' '/x/[a-z]+/' >"$T/store/$SLOT"

# stub hub: HUB=bans redacts a subject holding any word in $T/live, HUB=none
# redacts nothing, HUB=all redacts everything, HUB=store stores the row
cat >"$T/bin/curl" <<'SH'
#!/usr/bin/env bash
echo "$*" >>"$ARGV.curl"
out="" body=""
while (( $# )); do
  case "$1" in -o) out="$2"; shift ;; --data) body="${2#@}"; shift ;; esac; shift
done
s=$(jq -r '.notes[0].subject' "$body")
r=0
case "$HUB" in
  bans) grep -qiF -f "$LIVE" <<<"$s" && r=1 ;;
  all) r=1 ;;
esac
if [[ "$HUB" == store ]]; then echo '{"stored":1,"redacted":0,"states":{},"rejected":[]}' >"$out"
else printf '{"stored":0,"redacted":%d,"states":{},"rejected":[{"sha":"x","why":"sha"}]}\n' "$r" >"$out"; fi
printf 200
SH
chmod +x "$T/bin/curl"
printf '%s\n' alphaone gamma.example eta.test >"$T/live"

run_act() {  # [VAR=value ...]
  env PATH="$T/bin:$PATH" PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" HOME="$T/home" SPL_STATE_DIR="$T/state" \
      STORE="$T/store" ARGV="$T/argv" LIVE="$T/live" HUB=bans ENV=dev GCP_ACCOUNT=stub-sa@example.com "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    gcloud() {
      echo "$*" >>"$ARGV"
      case "$*" in
        "auth print-access-token"*) echo "ya29.stub_token_value_long_enough" ;;
        "auth print-identity-token"*) echo "eyJ.stub.idtoken" ;;
        "secrets versions access latest --secret="*)
          local s="${5#--secret=}"; [[ -f "$STORE/$s" ]] || return 1; cat "$STORE/$s" ;;
        *) return 0 ;;
      esac
    }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    do_spl_release_note_bans_check' 2>&1
}

out=$(run_act); rc=$?
[[ $rc -eq 0 ]] && grep -q '"probed":3,"redacted":3,"missed":0' <<<"$out" && pass "a hub that redacts every ban passes (3 probes, the literal-less line skipped)" || fail "bans hub: rc=$rc $out"
[[ $(grep -c 'release-notes' "$T/argv.curl") -eq 4 ]] && pass "one control + one probe per literal POSTed" || fail "posts: $(grep -c 'release-notes' "$T/argv.curl")"
leak=0
for w in alphaone gamma.example eta.test; do
  grep -qiF "$w" <<<"$out" && leak=1; grep -qiF "$w" "$T/argv.curl" "$T/argv" && leak=1
done
[[ $leak -eq 0 ]] && pass "no literal in the output, curl argv or gcloud argv" || fail "a literal leaked"
[[ $(grep -vc -- '--account=stub-sa@example.com' "$T/argv") -eq 0 ]] && pass "every gcloud call carries --account" || fail "unpinned gcloud call"
out=$(run_act HUB=none); rc=$?
[[ $rc -ne 0 ]] && grep -q '"missed":3' <<<"$out" && pass "control: a hub without the env (redacts nothing) fails" || fail "none hub: rc=$rc $out"
out=$(run_act HUB=all); rc=$?
[[ $rc -ne 0 ]] && grep -q 'control probe' <<<"$out" && pass "control: a hub that redacts the control fails" || fail "all hub: rc=$rc $out"
out=$(run_act HUB=store); rc=$?
[[ $rc -ne 0 ]] && pass "control: a hub that stores a probe fails" || fail "store hub: rc=$rc $out"
rm -f "$T/store/$SLOT"
out=$(run_act); rc=$?
[[ $rc -ne 0 ]] && grep -q 'seed' <<<"$out" && pass "an unseeded slot is refused" || fail "no slot version: rc=$rc $out"

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
