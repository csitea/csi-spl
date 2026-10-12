#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_report_ci_red_note sends ONE note per red job per red streak
#          (spec 131 C2). Hermetic: `gh` is stubbed with canned API JSON (its
#          --jq runs through real jq), the sender is a stub that logs each
#          send, the repo is a throwaway git tree.
#   1. a red job over three ticks -> exactly 1 send, a blocker to the holder
#      on task dispatch-ci-red, naming the first red run, the last green and
#      the signature
#   2. the range lists only the commits that touch the job's tree (orc), in
#      <last green>..<first red>, not a hub commit and not an older orc one
#   3. a gate-fail-fast stopped job is no verdict: no note for it
#   4. a second job red -> 2 sends in all
#   5. the first job green -> one `green` send, its streak closed; the second
#      job, still red, sends nothing
#   6. the holder on another box -> nothing sent
#   7. a job whose runner was lost (no steps, no log, one annotation) is a red
#      (runner-lost, an infra red like a timeout) and the annotation is its
#      signature (dispatch holder, note 9a44e278)
#   8. the lane note (spec 133 action 7): a red job whose suspect commit a
#      lane branch of this box made (here through `rebase (finish) onto`)
#      sends that lane ONE note over three ticks - job, first FAIL line, run
#      link, its commit; a lane whose commit is outside the job's tree, and a
#      lane that only fast-forwarded to master, get nothing
#   9. the holder on another box: the lane note is still sent (box-local)
#  10. the job green again, then red from a new sha: one more lane note
#   CONTROL a. the state file wiped before every tick -> 3 sends for 3 ticks
#              of the same red, so check 1 FAILS without the streak key
#   CONTROL b. the annotation hidden -> "no FAIL line", so check 7 FAILS
#              without the annotation fallback
#   CONTROL c. the lane state wiped before every tick -> 3 lane notes, so
#              check 8 FAILS without its key
#   CONTROL d. the lane branch deleted -> no lane note, so the lane is found
#              from its branch, not from the commit text
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
FUNC="$PROJ_ROOT/src/bash/run/report-ci-red-note.func.sh"
GATE="$PROJ_ROOT/src/bash/run/report-ci-gate.func.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fails=0
command -v jq >/dev/null || { echo "FAIL: jq is required"; exit 1; }

# --- the throwaway repo: base, an orc commit (the culprit), a hub commit ----
R="$T/repo"; mkdir -p "$R/csi-spl-orc" "$R/csi-spl-api"
g() { git -c user.name=t -c user.email=t@example.com -C "$R" "$@"; }
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
g init -q
echo 0 >"$R/csi-spl-orc/a"; g add -A; g commit -qm "orc: an older change"
echo 0 >"$R/README"; g add -A; g commit -qm "base"
GREEN=$(g rev-parse HEAD)
echo 1 >"$R/csi-spl-orc/a"; g commit -qam "orc: the culprit"
echo 1 >"$R/csi-spl-api/b"; g add -A; g commit -qm "hub: an unrelated change"
RED1=$(g rev-parse HEAD)
echo 2 >"$R/README"; g commit -qam "docs"
RED2=$(g rev-parse HEAD)

mkdir -p "$T/stub" "$T/api"
cat >"$T/stub/gh" <<'STUB'
#!/usr/bin/env bash
args=("$@"); jqf=""
for ((i = 0; i < ${#args[@]}; i++)); do [[ "${args[i]}" == "--jq" ]] && jqf="${args[i+1]}"; done
src=""
case "${args[0]}" in
  run) src="$GH_STUB_DIR/runs.json" ;;
  api)
    case "${args[1]}" in
      */runs/*/jobs) src="$GH_STUB_DIR/jobs-$(sed 's|.*/runs/\([0-9]*\)/jobs|\1|' <<<"${args[1]}").json" ;;
      */actions/jobs/[0-9]*[0-9]) src="$GH_STUB_DIR/job-${args[1]##*/}.json" ;;
      */jobs/*/logs) cat "$GH_STUB_DIR/log-$(sed 's|.*/jobs/\([0-9]*\)/logs|\1|' <<<"${args[1]}").txt" 2>/dev/null; exit 0 ;;
      */check-runs/*/annotations)
        src="$GH_STUB_DIR/ann-$(sed 's|.*/check-runs/\([0-9]*\)/annotations|\1|' <<<"${args[1]}").json"
        [[ -f "$src" ]] || src="$GH_STUB_DIR/ann-none.json" ;;
    esac ;;
esac
[[ -f "$src" ]] || { echo "gh: stub has no canned $src" >&2; exit 1; }
if [[ -n "$jqf" ]]; then jq -r "$jqf" "$src"; else cat "$src"; fi
STUB
cat >"$T/stub/send" <<'STUB'
#!/usr/bin/env bash
# one line per send: from to kind task, then the body on the next lines
args=("$@"); out="$CRN_SENT"
for ((i = 0; i < ${#args[@]}; i++)); do
  case "${args[i]}" in --from) f=${args[i+1]} ;; --to) t=${args[i+1]} ;; --kind) k=${args[i+1]} ;; --task) s=${args[i+1]} ;; --body) b=${args[i+1]} ;; esac
done
{ echo "SEND from=$f to=$t kind=$k task=$s"; echo "$b"; } >>"$out"
STUB
chmod +x "$T/stub/gh" "$T/stub/send"
echo '[]' >"$T/api/ann-none.json"

# runs <json rows...> - the canned run list, newest first
runs() { printf '[%s]\n' "$(IFS=,; echo "$*")" >"$T/api/runs.json"; }
row() { printf '{"databaseId":%s,"conclusion":"%s","createdAt":"2026-01-05T10:%02d:00Z","headSha":"%s","headBranch":"master"}' "$1" "$2" "$3" "$4"; }
jobs() { local id=$1; shift; printf '{"jobs":[%s]}\n' "$(IFS=,; echo "$*")" >"$T/api/jobs-$id.json"; }
job() { printf '{"id":%s,"name":"%s","conclusion":"%s"}' "$1" "$2" "$3"; }
ORC="orc: hermetic action tests 1/2"; HUB="hub: go test"
# 960 green (GREEN), 961 orc red (RED1), 962 orc red + hub stopped by fail-fast (RED2)
jobs 960 "$(job 9600 "$ORC" success)" "$(job 9601 "$HUB" success)"
jobs 961 "$(job 9610 "$ORC" failure)" "$(job 9611 "$HUB" success)"
jobs 962 "$(job 9620 "$ORC" failure)" "$(job 9621 "$HUB" failure)"
echo '[{"message":"gate fail-fast: stopped, so the next gate run starts; red in this run: orc"}]' >"$T/api/ann-9621.json"
printf '2026-01-05T10:00:01Z PASS: 1. something FAIL (never OK)\n2026-01-05T10:00:02Z FAIL: the handoff file is missing\n' >"$T/api/log-9610.txt"
runs "$(row 962 failure 20 "$RED2")" "$(row 961 failure 10 "$RED1")" "$(row 960 success 0 "$GREEN")"

export CRN_SENT="$T/sent"; : >"$CRN_SENT"
STATE="$T/state.tsv"
tick() {
  ( cd "${TREE:-$R}" && env PATH="$T/stub:$PATH" GH_STUB_DIR="$T/api" CI_RED_NOTE_STATE="$STATE" \
      CI_RED_NOTE_LANE_STATE="${LSTATE:-$T/lane.tsv}" CI_RED_NOTE_TO="${TO:-c-900@b1}" CI_RED_NOTE_BOX=b1 CI_RED_NOTE_SEND="$T/stub/send" \
      bash -c 'do_log() { echo "$*"; }; source "'"$GATE"'"; source "'"$FUNC"'"; do_report_ci_red_note' ) >"$T/out" 2>&1
}
sends() { grep -c '^SEND .*kind=blocker' "$CRN_SENT"; }
lanes() { grep -c '^SEND .*kind=note' "$CRN_SENT"; }

# --- 1. the same red over three ticks -> 1 send ------------------------------
tick; tick; tick
if [[ "$(sends)" == 1 ]] && grep -qx 'SEND from=c-900 to=c-900@b1 kind=blocker task=dispatch-ci-red' "$CRN_SENT" \
   && grep -q "^## CI red on master: $ORC" "$CRN_SENT" \
   && grep -q "Red since run 961 (sha ${RED1:0:8}" "$CRN_SENT" && grep -q "Last green: run 960 (sha ${GREEN:0:8})" "$CRN_SENT" \
   && grep -q 'Signature: FAIL: the handoff file is missing' "$CRN_SENT"; then
  pass "1. three ticks of the same red orc job: 1 blocker to the holder, first red 961, last green 960, the real FAIL line"
else
  fail "1. the red was not sent exactly once ($(sends) sends)"; sed 's/^/    | /' "$CRN_SENT" "$T/out"
fi
# --- 2. the range: orc commits in GREEN..RED1 only ---------------------------
if grep -q -- '- [0-9a-f]* orc: the culprit' "$CRN_SENT" && ! grep -q 'hub: an unrelated change' "$CRN_SENT" \
   && ! grep -q 'orc: an older change' "$CRN_SENT"; then
  pass "2. the suspect list is the orc commit in last green..first red, not the hub commit nor an older orc one"
else
  fail "2. the suspect range is wrong"; sed 's/^/    | /' "$CRN_SENT"
fi
# --- 3. the fail-fast stopped hub job sent nothing ----------------------------
grep -q "CI red on master: $HUB" "$CRN_SENT" && fail "3. a job stopped by gate-fail-fast got a note" \
  || pass "3. the hub job gate-fail-fast stopped is no verdict: no note"

# --- 4. a second job red -> 2 ------------------------------------------------
jobs 963 "$(job 9630 "$ORC" failure)" "$(job 9631 "$HUB" failure)"
runs "$(row 963 failure 30 "$RED2")" "$(row 962 failure 20 "$RED2")" "$(row 961 failure 10 "$RED1")" "$(row 960 success 0 "$GREEN")"
tick; tick
[[ "$(sends)" == 2 ]] && grep -q "CI red on master: $HUB" "$CRN_SENT" \
  && pass "4. a second red job (hub) adds exactly 1 send: 2 in all" \
  || { fail "4. want 2 sends, got $(sends)"; sed 's/^/    | /' "$CRN_SENT"; }

# --- 5. orc green again -> 1 green line, hub still red -> nothing -------------
jobs 964 "$(job 9640 "$ORC" success)" "$(job 9641 "$HUB" failure)"
runs "$(row 964 failure 40 "$RED2")" "$(row 963 failure 30 "$RED2")" "$(row 962 failure 20 "$RED2")" "$(row 961 failure 10 "$RED1")" "$(row 960 success 0 "$GREEN")"
tick; tick
if [[ "$(sends)" == 3 ]] && grep -q "^CI green again on master: $ORC (run 964)" "$CRN_SENT" \
   && ! grep -qF "$ORC" "$STATE" && grep -qF "$HUB" "$STATE"; then
  pass "5. orc green: one green line, its streak closed; hub, still red, sends nothing (3 in all)"
else
  fail "5. want 3 sends with a green line, got $(sends)"; sed 's/^/    | /' "$CRN_SENT" "$STATE"
fi

# --- 6. the holder is on another box -> nothing --------------------------------
: >"$STATE"; : >"$CRN_SENT"
TO=c-900@other tick
[[ "$(sends)" == 0 ]] && grep -q 'not on this box' "$T/out" \
  && pass "6. the holder on another box: nothing sent from this one" \
  || { fail "6. sent from a box that is not the holder's ($(sends))"; sed 's/^/    | /' "$T/out"; }

# --- CONTROL a. no streak key -> one send per tick ----------------------------
: >"$CRN_SENT"
runs "$(row 962 failure 20 "$RED2")" "$(row 961 failure 10 "$RED1")" "$(row 960 success 0 "$GREEN")"
for _ in 1 2 3; do : >"$STATE"; tick; done
[[ "$(sends)" == 3 ]] \
  && pass "CONTROL a. with the state wiped every tick the same red sends 3 times, so check 1 FAILS without the streak key" \
  || { fail "CONTROL a. want 3 sends without the state, got $(sends): check 1 proves nothing"; sed 's/^/    | /' "$T/out"; }

# --- 7. a lost runner: red, the annotation is the signature -------------------
LOST="The self-hosted runner lost communication with the server. Verify the machine is running and has a healthy network connection. Anything in your workflow that terminates the runner process, starves it for CPU/Memory, or blocks its network access can cause this error."
WUI="wui: browser e2e (mock, generated) 1/3"
jobs 970 "$(job 9700 "$WUI" success)"
jobs 971 "$(job 9710 "$WUI" failure)"
jq -n --arg m "$LOST" '[{annotation_level: "failure", message: $m}]' >"$T/api/ann-9710.json"
runs "$(row 971 failure 10 "$RED1")" "$(row 970 success 0 "$GREEN")"
: >"$STATE"; : >"$CRN_SENT"; tick
if [[ "$(sends)" == 1 ]] && grep -qF "Signature: The self-hosted runner lost communication with the server." "$CRN_SENT"; then
  pass "7. a lost runner (no log) is a red with the annotation as its signature"
else
  fail "7. lost runner: $(sends) sends"; sed 's/^/    | /' "$CRN_SENT" "$T/out"
fi
# --- CONTROL b. the annotation hidden -> no signature ---------------------------
mv "$T/api/ann-9710.json" "$T/api/ann-9710.hidden"
: >"$STATE"; : >"$CRN_SENT"; tick
grep -q 'Signature: (no FAIL line in the job log, no failure annotation)' "$CRN_SENT" \
  && pass "CONTROL b. with the annotation hidden the note reads 'no FAIL line', so check 7 FAILS without the fallback" \
  || { fail "CONTROL b. the signature did not depend on the annotation"; sed 's/^/    | /' "$CRN_SENT"; }

# --- 8. the lane note --------------------------------------------------------
# R2: master at base; c-777 commits an orc fix on its branch, rebases it over
# a hub commit (reflog: commit, then rebase (finish) onto master) and lands
# it; g-888 lands a README commit; c-999 only fast-forwards to master.
R2="$T/repo2"; mkdir -p "$R2/csi-spl-orc" "$R2/csi-spl-api"
g2() { git -c user.name=t -c user.email=t@example.com -C "$R2" "$@"; }
g2 init -q -b master
echo 0 >"$R2/csi-spl-orc/a"; g2 add -A; g2 commit -qm "base"
G2=$(g2 rev-parse HEAD)
g2 checkout -qb c-777-orc-fix
echo 1 >"$R2/csi-spl-orc/a"; g2 commit -qam "orc: lane culprit"
g2 checkout -q master
echo 1 >"$R2/csi-spl-api/b"; g2 add -A; g2 commit -qm "hub: landed meanwhile"
g2 checkout -q c-777-orc-fix; g2 rebase -q master; g2 checkout -q master; g2 merge -q --ff-only c-777-orc-fix
g2 checkout -qb g-888-readme; echo 1 >"$R2/README"; g2 add -A; g2 commit -qm "docs: readme"
g2 checkout -q master; g2 merge -q --ff-only g-888-readme
g2 checkout -qb c-999-idle; g2 checkout -q master
R3=$(g2 rev-parse HEAD)
jobs 980 "$(job 9800 "$ORC" success)"
jobs 981 "$(job 9810 "$ORC" failure)"
printf '2026-01-05T10:00:02Z FAIL: lane case broke\n' >"$T/api/log-9810.txt"
echo '{"html_url":"https://ci.example.org/run/981/job/9810"}' >"$T/api/job-9810.json"
runs "$(row 981 failure 10 "$R3")" "$(row 980 success 0 "$G2")"
: >"$STATE"; : >"$CRN_SENT"; LS="$T/lane2.tsv"; : >"$LS"
TREE="$R2" LSTATE="$LS" tick; TREE="$R2" LSTATE="$LS" tick; TREE="$R2" LSTATE="$LS" tick
if [[ "$(lanes)" == 1 ]] && grep -qx 'SEND from=c-900 to=c-777 kind=note task=dispatch-ci-red' "$CRN_SENT" \
   && grep -q -- "- Job: $ORC" "$CRN_SENT" && grep -q -- '- First FAIL line: FAIL: lane case broke' "$CRN_SENT" \
   && grep -q -- '- Run: https://ci.example.org/run/981/job/9810' "$CRN_SENT" \
   && grep -qxE -- '- Last green: (run [0-9]+ \(sha [0-9a-f]+\)|none in the window)' "$CRN_SENT" \
   && grep -q -- '- [0-9a-f]* orc: lane culprit' "$CRN_SENT" && ! grep -q 'to=g-888\|to=c-999' "$CRN_SENT"; then
  pass "8. three ticks of a red: 1 note to the lane that made the suspect commit (via rebase finish), with job, FAIL line, run link; g-888 and c-999 nothing"
else
  fail "8. lane note: $(lanes) lane sends"; sed 's/^/    | /' "$CRN_SENT" "$T/out"
fi
# --- 9. the holder elsewhere: the lane note is still sent ----------------------
: >"$CRN_SENT"; : >"$LS"
TO=c-900@other TREE="$R2" LSTATE="$LS" tick
[[ "$(lanes)" == 1 && "$(sends)" == 0 ]] && grep -q 'to=c-777 ' "$CRN_SENT" \
  && pass "9. the holder on another box: no holder note here, the lane note still goes to this box's lane" \
  || { fail "9. holder elsewhere: $(sends) holder, $(lanes) lane sends"; sed 's/^/    | /' "$CRN_SENT" "$T/out"; }
# --- 10. green, then red again from a new sha -> one more ------------------------
jobs 982 "$(job 9820 "$ORC" success)"
runs "$(row 982 success 20 "$R3")" "$(row 981 failure 10 "$R3")" "$(row 980 success 0 "$G2")"
: >"$CRN_SENT"; TREE="$R2" LSTATE="$LS" tick
[[ -s "$LS" ]] && fail "10. the green run left the lane key: $(cat "$LS")"
jobs 983 "$(job 9830 "$ORC" failure)"
echo '{"html_url":"https://ci.example.org/run/983/job/9830"}' >"$T/api/job-9830.json"
runs "$(row 983 failure 30 "$R3")" "$(row 982 success 20 "$G2")" "$(row 981 failure 10 "$R3")" "$(row 980 success 0 "$G2")"
TREE="$R2" LSTATE="$LS" tick; TREE="$R2" LSTATE="$LS" tick
[[ "$(lanes)" == 1 ]] && grep -q -- '- Run: https://ci.example.org/run/983/job/9830' "$CRN_SENT" \
  && pass "10. green closes the lane key; a new red streak tells the lane once more" \
  || { fail "10. new red: $(lanes) lane sends"; sed 's/^/    | /' "$CRN_SENT" "$T/out"; }
# --- CONTROL c. no lane key -> one note per tick -------------------------------
runs "$(row 981 failure 10 "$R3")" "$(row 980 success 0 "$G2")"
: >"$CRN_SENT"
for _ in 1 2 3; do : >"$LS"; TREE="$R2" LSTATE="$LS" tick; done
[[ "$(lanes)" == 3 ]] \
  && pass "CONTROL c. with the lane state wiped every tick the lane gets 3 notes, so check 8 FAILS without the key" \
  || { fail "CONTROL c. want 3 lane notes, got $(lanes): check 8 proves nothing"; sed 's/^/    | /' "$T/out"; }
# --- CONTROL d. no lane branch -> no lane note -----------------------------------
g2 branch -qD c-777-orc-fix
: >"$CRN_SENT"; : >"$LS"; TREE="$R2" LSTATE="$LS" tick
[[ "$(lanes)" == 0 ]] \
  && pass "CONTROL d. the c-777 branch deleted: no lane note, so the lane comes from its branch reflog" \
  || { fail "CONTROL d. a lane was told without its branch ($(lanes))"; sed 's/^/    | /' "$CRN_SENT"; }

if [[ $fails -eq 0 ]]; then
  echo "PASS: all report-ci-red-note.tst.sh assertions"
else
  echo "FAIL: $fails assertion(s) in report-ci-red-note.tst.sh"
fi
[[ $fails -eq 0 ]]
