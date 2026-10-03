#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: spec 065 L4 do_spl_release_note_bans_seed, CALLED against a stubbed
#          gcloud with a file-backed secret store (as wui-key-mail-seed.tst.sh):
#          - the patterns come from the REAL 10 ci distribution-hygiene Sweep
#            (one list for the fleet), all of them, as RE2 (compiled by Go
#            when it is on PATH);
#          - dry run adds nothing; DRY_RUN=0 adds ONE version that is exactly
#            the rendered list; a re-run adds nothing; a missing slot is
#            refused; no pattern is in any output or gcloud argv; every gcloud
#            call carries --account.
#          CONTROLS (synthetic workflows): a lookahead is dropped (wider ban);
#          a backreference is refused and stores nothing; a workflow with no
#          Sweep patterns is refused.
#          No assertion prints a pattern: the real ones are personal data.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0
mkdir -p "$T/store" "$T/home"
WF="$APP_ROOT/.github/workflows/10_ci-quality.yml"
SLOT=csi-spl-hub-release-note-bans

run_act() {  # [VAR=value ...]
  env PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" HOME="$T/home" SPL_STATE_DIR="$T/state" \
      STORE="$T/store" ARGV="$T/argv" ENV=dev GCP_ACCOUNT=stub-sa@example.com "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    gcloud() {
      echo "$*" >>"$ARGV"
      case "$*" in
        "auth print-access-token"*) echo "ya29.stub_token_value_long_enough" ;;
        "secrets describe "*) [[ "${NO_SLOT:-0}" == 1 ]] && return 1; return 0 ;;
        "secrets versions access latest --secret="*)
          local s="${5#--secret=}"; [[ -f "$STORE/$s" ]] || return 1; cat "$STORE/$s" ;;
        "secrets versions add "*)
          local s="$4" df; for a in "$@"; do [[ "$a" == --data-file=* ]] && df="${a#--data-file=}"; done
          cat "$df" >"$STORE/$s"; echo add "$s" >>"$STORE/.adds" ;;
        *) return 0 ;;
      esac
    }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    do_spl_release_note_bans_seed' 2>&1
}
render() {  # <workflow> -> the rendered list on stdout, the log on stderr
  bash -c 'do_log() { echo "$*" >&2; }; source "$1/src/bash/run/spl-release-note-bans-seed.func.sh"; spl_release_note_bans_render "$2"' _ "$PROJ_ROOT" "$1"
}
adds() { grep -c . "$T/store/.adds" 2>/dev/null || echo 0; }

# ------------------------------------------------- the real Sweep list ----
render "$WF" >"$T/bans" 2>/dev/null; rc=$?
nsweep=$(yq -r '.jobs."distribution-hygiene".steps[] | select(.name == "Sweep") | .run' "$WF" | grep -cE "^[[:space:]]*sweep[[:space:]]+\"")
nbans=$(grep -c . "$T/bans")
[[ $rc -eq 0 && $nsweep -gt 0 && $nbans -eq $nsweep ]] && pass "render: one RE2 line per Sweep pattern ($nbans of $nsweep)" || fail "render: rc=$rc $nbans line(s) for $nsweep sweep(s)"
grep -qE '\(\?<?[!=]' "$T/bans" && fail "render: a lookaround survived" || pass "render: no lookaround left"
GO=$(command -v go || { [[ -x /usr/local/go/bin/go ]] && echo /usr/local/go/bin/go; })
if [[ -n "$GO" ]]; then
  mkdir -p "$T/re2"
  printf 'package main\nimport ("bufio";"os";"regexp")\nfunc main(){s:=bufio.NewScanner(os.Stdin);for s.Scan(){if _,e:=regexp.Compile(s.Text());e!=nil{os.Exit(1)}}}\n' >"$T/re2/main.go"
  (cd "$T/re2" && GOCACHE="$T/gocache" GOFLAGS=-mod=mod "$GO" run main.go <"$T/bans") >/dev/null 2>&1 \
    && pass "render: every line compiles as Go RE2 (the hub's regexp)" || fail "render: a line does not compile as Go RE2"
else
  echo "SKIP: no go on PATH (RE2 compile)"
fi

# ---------------------------------------------------------- the action ----
out=$(run_act); rc=$?
[[ $rc -eq 0 && $(adds) -eq 0 ]] && pass "default is a dry run, nothing added" || fail "dry run: rc=$rc adds=$(adds) $out"
out=$(run_act DRY_RUN=0 NO_SLOT=1); rc=$?
[[ $rc -ne 0 && $(adds) -eq 0 ]] && pass "a missing 030 slot is refused" || fail "no slot: rc=$rc"
out=$(run_act DRY_RUN=0); rc=$?
[[ $rc -eq 0 && $(adds) -eq 1 ]] && cmp -s "$T/store/$SLOT" "$T/bans" && pass "DRY_RUN=0 adds ONE version that is exactly the rendered Sweep list" || fail "real run: rc=$rc adds=$(adds)"
leak=0
while IFS= read -r p; do
  grep -qF -- "$p" <<<"$out" && leak=1
  grep -qF -- "$p" "$T/argv" && leak=1
done <"$T/bans"
[[ $leak -eq 0 ]] && pass "no pattern in the output or in gcloud argv" || fail "a pattern leaked into the output or gcloud argv"
out=$(run_act DRY_RUN=0); rc=$?
[[ $rc -eq 0 && $(adds) -eq 1 ]] && pass "a re-run with the same Sweep adds nothing" || fail "re-run: rc=$rc adds=$(adds)"
[[ $(grep -vc -- '--account=stub-sa@example.com' "$T/argv") -eq 0 ]] && pass "every gcloud call carries --account" || fail "unpinned gcloud call"

# ------------------------------------------------------------ controls ----
mkwf() {  # <pattern> -> a synthetic workflow with one Sweep line
  printf 'jobs:\n  distribution-hygiene:\n    steps:\n      - name: Sweep\n        run: |\n          sweep "x" %s\n          exit 0\n' "'$1'" >"$T/wf.yml"
}
mkwf '(?i)\balpha\b(?!-beta)|gamma'
[[ "$(render "$T/wf.yml" 2>/dev/null)" == '(?i)\balpha\b|gamma' ]] && pass "control: a lookahead is dropped (the ban only widens)" || fail "control lookahead: $(render "$T/wf.yml" 2>&1)"
mkwf '(alpha)\1'
o=$(render "$T/wf.yml" 2>/dev/null); rc=$?
[[ $rc -ne 0 && -z "$o" ]] && pass "control: a backreference is refused with nothing rendered" || fail "control backref: rc=$rc"
n=$(adds); out=$(run_act DRY_RUN=0 HYGIENE_WORKFLOW="$T/wf.yml"); rc=$?
[[ $rc -ne 0 && $(adds) -eq $n ]] && pass "control: the action stores nothing for a non-RE2 Sweep" || fail "control backref action: rc=$rc"
printf 'jobs:\n  distribution-hygiene:\n    steps:\n      - name: Sweep\n        run: exit 0\n' >"$T/wf.yml"
o=$(render "$T/wf.yml" 2>/dev/null); rc=$?
[[ $rc -ne 0 && -z "$o" ]] && pass "control: a workflow with no Sweep patterns is refused" || fail "control empty: rc=$rc"

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
