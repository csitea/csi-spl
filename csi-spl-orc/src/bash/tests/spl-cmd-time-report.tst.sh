#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_cmd_time_report, the read-only "where do agents wait" table
#          over Claude Code transcripts. A fixture projects dir and spool root
#          in a throwaway dir; the action runs under ./run's set -E + ERR trap.
#          Each case has its CONTROL: one input flipped.
#   1. ranking + numbers: do_a (2 calls, 10 + 20 s) above git fetch (5 s),
#      share / median / max as computed by hand
#   2. secrets: a fixture command carries a token and paths; the report shows
#      action names only. Control: the token IS in the fixture
#   3. window: a call before SINCE is left out. Control: a wider SINCE counts it
#   4. run_in_background and an unanswered call are skipped. Control: the same
#      background command without the flag is counted
#   5. roles: a csi-spl-wt/c-001 cwd is orch through CMD_TIME_ROLES, ROLE=lane
#      drops it. Control: ROLE=orch keeps only it
#   6. the role map comes from lease.conf + registry.tsv (rundir basenames)
#   7. usage: a bad ROLE / SINCE exit 2
#   8. the normaliser, one command -> one action, incl. wrappers and loops
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
export SPOOL_TEST=1
unset SINCE UNTIL ROLE CMD_TIME_TOP CMD_TIME_USERS CMD_TIME_DIRS CMD_TIME_ROLES
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
S="$T/spool"; P="$T/projects/-x-csi-spl-wt-c-777"; mkdir -p "$S/dispatch" "$T/bin" "$P"
case "$S" in /var/spool-hub*) echo "FAIL: refusing a live spool root"; exit 1 ;; esac
printf 'SPOOL_AGENT_USER=%s\n' "$(id -un)" >"$S/box.env"
cat >"$T/bin/act" <<'EOF'
#!/usr/bin/env bash
set -E
trap 'echo "ERRTRAP: $BASH_COMMAND (line $LINENO)"; exit 99' ERR
do_log() { echo "$*" >&2; }
do_require_bin() { command -v "$1" >/dev/null; }
source "$PROJ_PATH/src/bash/run/spl-cmd-time-report.func.sh"
do_spl_cmd_time_report || exit $?
EOF
chmod +x "$T/bin/act"
export PROJ_PATH="$PROJ_ROOT" SPOOL_ROOT="$S" SPOOL_BOX_ENV="$S/box.env"

# fixture: call <id> <start> <secs|-> <cwd> <command> [bg]
python3 - "$P/s1.jsonl" <<'EOF'
import json, sys, datetime
rows = [
    ("t1", "2026-10-07T10:00:00Z", 10, "/x/csi-spl-wt/c-777", "./run -a do_a", False),
    ("t2", "2026-10-07T10:01:00Z", 20, "/x/csi-spl-wt/c-777",
     "sudo -u someone bash -c 'cd /x && ENV=prd ./run -a do_a --token SEKRET-42'", False),
    ("t3", "2026-10-07T10:02:00Z", 5, "/x/csi-spl-wt/c-001", "git -C /x/private-dir fetch origin master", False),
    ("t4", "2026-10-07T10:03:00Z", 3, "/x/csi-spl-wt/c-777",
     "curl -H 'X-Probe: SEKRET-42' https://host.example.com/x", False),
    ("t5", "2026-10-07T08:00:00Z", 7, "/x/csi-spl-wt/c-777", "./run -a do_early", False),
    ("t6", "2026-10-07T10:04:00Z", 9, "/x/csi-spl-wt/c-777", "./run -a do_bg", True),
    ("t7", "2026-10-07T10:05:00Z", None, "/x/csi-spl-wt/c-777", "./run -a do_cut", False),
    ("t8", "2026-10-07T10:06:00Z", 4, "/x/csi-spl-wt/c-777",
     "until gh run view 1 --json status; do sleep 30; done", False),
]
def at(s, plus=0):
    t = datetime.datetime.fromisoformat(s.replace("Z", "+00:00")) + datetime.timedelta(seconds=plus)
    return t.strftime("%Y-%m-%dT%H:%M:%S.000Z")
with open(sys.argv[1], "w") as f:
    for tid, start, secs, cwd, cmd, bg in rows:
        inp = {"command": cmd, "description": "x"}
        if bg:
            inp["run_in_background"] = True
        f.write(json.dumps({"type": "assistant", "timestamp": at(start), "cwd": cwd, "message": {
            "role": "assistant", "content": [{"type": "tool_use", "id": tid, "name": "Bash", "input": inp}]}}) + "\n")
        if secs is not None:
            f.write(json.dumps({"type": "user", "timestamp": at(start, secs), "cwd": cwd, "message": {
                "role": "user", "content": [{"type": "tool_result", "tool_use_id": tid,
                                             "content": "out SEKRET-42", "is_error": False}]}}) + "\n")
    f.write("not json\n")
EOF
touch -d 2026-10-07T11:00:00Z "$P/s1.jsonl"
W=(SINCE=2026-10-07T09:00:00Z UNTIL=2026-10-07T12:00:00Z CMD_TIME_DIRS="$T/projects" CMD_TIME_ROLES="c-001=orch")
go() { env "${W[@]}" "$@" "$T/bin/act" >"$T/o" 2>"$T/e"; echo $?; }
row() { grep -F "| \`$1\` |" "$T/o"; }

# --- 1. ranking and numbers -----------------------------------------------------------
rc=$(go)
[[ "$rc" == 0 ]] && pass "1 exit 0" || { fail "1 exit $rc"; cat "$T/o" "$T/e"; }
grep -q '5 calls, 42 s total' "$T/o" && pass "1 header: 5 calls, 42 s" || { fail "1 header"; head -1 "$T/o"; }
[[ "$(row do_a)" == '| 1 | `do_a` | 2 | 30 | 71.4 | 15.0 | 20.0 | 20.0 | lane 100% |' ]] && pass "1 do_a ranks first: 2 calls, 30 s, 71.4 %, median 15" || { fail "1 do_a row"; cat "$T/o"; }
[[ "$(row 'git fetch')" == '| 2 | `git fetch` | 1 | 5 | 11.9 | 5.0 | 5.0 | 5.0 | orch 100% |' ]] && pass "1 git fetch second, paid by orch" || { fail "1 git fetch row"; cat "$T/o"; }

# --- 2. action names only --------------------------------------------------------------
grep -q SEKRET "$P/s1.jsonl" && pass "2 control: the fixture holds the token" || fail "2 control: token missing from fixture"
if grep -qE 'SEKRET|private-dir|example\.com|origin|--token|X-Probe|ENV=' "$T/o" "$T/e"; then fail "2 an argument leaked"; grep -E 'SEKRET|private-dir|example|origin|token|X-Probe|ENV=' "$T/o" "$T/e"
else pass "2 no argument, path or output in the report"; fi
row curl >/dev/null && pass "2 the curl call is named by its program only" || fail "2 curl row missing"

# --- 3. window -------------------------------------------------------------------------
row do_early >/dev/null && fail "3 a call before SINCE was counted" || pass "3 a call before SINCE is left out"
go SINCE=2026-10-07T07:00:00Z >/dev/null
row do_early >/dev/null && pass "3 control: a wider SINCE counts it" || fail "3 control: do_early missing"

# --- 4. background and unanswered calls --------------------------------------------------
row do_bg >/dev/null && fail "4 run_in_background counted" || pass "4 run_in_background skipped"
row do_cut >/dev/null && fail "4 an unanswered call counted" || pass "4 an unanswered call skipped"
sed 's/, "run_in_background": true//' "$P/s1.jsonl" >"$T/bg.jsonl" && mv "$T/bg.jsonl" "$P/s1.jsonl"
touch -d 2026-10-07T11:00:00Z "$P/s1.jsonl"
go >/dev/null
row do_bg >/dev/null && pass "4 control: without the flag it is counted" || fail "4 control: do_bg missing"
row 'poll-loop gh run view' >/dev/null && pass "4 an until loop is a poll-loop of its condition" || { fail "4 poll-loop row"; cat "$T/o"; }

# --- 5. roles ---------------------------------------------------------------------------
go ROLE=lane >/dev/null
row 'git fetch' >/dev/null && fail "5 ROLE=lane kept the orch call" || pass "5 ROLE=lane drops the orch call"
go ROLE=orch >/dev/null
[[ "$(grep -c '^| [0-9]' "$T/o")" == 1 ]] && row 'git fetch' >/dev/null && pass "5 control: ROLE=orch keeps only it" || { fail "5 control: ROLE=orch"; cat "$T/o"; }

# --- 6. role map from lease.conf + registry ----------------------------------------------
printf 'LEASE_MASTER=c-002\nLEASE_FAILOVER=c-003\nLEASE_ORCH=c-001\n' >"$S/dispatch/lease.conf"
printf 'c-001\tclaude\t%%1\t/x/csi-spl-wt/CLE-001\t20261002T022543Z\nc-001\tclaude\t%%2\t/x/csi-spl-wt/c-001\t20261007T184241Z\nc-777\tclaude\t%%3\t/x/csi-spl-wt/c-777\t20261007T000000Z\n' >"$S/registry.tsv"
m="$(bash -c 'source "$1"; spl_cmd_time_rolemap "$2"' _ "$PROJ_ROOT/src/bash/run/spl-cmd-time-report.func.sh" "$S")"
[[ "$m" == "c-001=orch,CLE-001=orch,c-001=orch,c-002=dispatcher,c-003=dispatcher" ]] && pass "6 role map: seats by id and rundir" || fail "6 role map: '$m'"
go CMD_TIME_ROLES= >/dev/null
[[ "$(row 'git fetch')" == *"| lane 100% |" ]] && pass "6 control: an empty role map makes c-001 a lane" || fail "6 control: $(row 'git fetch')"
W=(SINCE=2026-10-07T09:00:00Z UNTIL=2026-10-07T12:00:00Z CMD_TIME_DIRS="$T/projects")
go >/dev/null
[[ "$(row 'git fetch')" == *"| orch 100% |" ]] && pass "6 the default map reads the lease: c-001 is orch" || fail "6 default map: $(row 'git fetch')"

# --- 7. usage ------------------------------------------------------------------------------
[[ "$(go ROLE=boss)" == 2 ]] && pass "7 a bad ROLE exits 2" || fail "7 bad ROLE"
[[ "$(go SINCE=not-a-date)" == 2 ]] && pass "7 a bad SINCE exits 2" || fail "7 bad SINCE"
[[ "$(go SINCE=2026-10-08T00:00:00Z)" == 2 ]] && pass "7 SINCE after UNTIL exits 2" || fail "7 SINCE after UNTIL"
[[ "$(go ROLE=lane)" == 0 ]] && pass "7 control: a good ROLE exits 0" || fail "7 control"

# --- 8. the normaliser --------------------------------------------------------------------
out="$(python3 - "$PROJ_ROOT/src/bash/run/spl-cmd-time-report.py" <<'EOF'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("m", sys.argv[1]); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
cases = {
    "cd /x && ./run -a do_check_pre_push": "do_check_pre_push",
    "sudo -u u env A=1 LEASE_CMD=show ./run -a do_spl_dispatch_lease": "do_spl_dispatch_lease",
    "sudo -u u git -C /x log --oneline -3": "git log",
    "SPOOL_ROOT=/v /x/bin/spool recv --as c-1": "spool recv",
    "bash /x/scripts/spool-send.sh --from c-1 --body 'a b'": "spool-send.sh",
    "S=/x/spool-send.sh; bash $S --from c-1": "spool-send.sh",
    'G="sudo -u u git -C /x"; $G push origin HEAD:master': "git push",
    "sudo -u u bash -lc 'pnpm install --frozen-lockfile'": "pnpm install",
    "echo start; gh run list --commit abc": "gh run list",
    "X=$(git rev-parse HEAD); gh run watch $X": "gh run watch",
    "gh api repos/o/r/actions/runs": "gh api",
    "for i in $(seq 1 60); do grep -q done f && break; sleep 10; done": "poll-loop grep",
    "for f in a b; do wc -l $f; done": "wc",
    "end=$((SECONDS+60)); while [ $SECONDS -lt $end ]; do sleep 1; done": "poll-loop test",
    "(cd x && make do-tf-plan)": "make do-tf-plan",
    "python3 - <<EOF\nprint(1)\nEOF": "python3",
    "timeout 60 bash x/tests/run-all-tests.sh": "run-all-tests.sh",
    "curl -s 'https://h/$(cat key)'": "curl",
    "$UNKNOWN --flag": "<other>",
}
bad = [f"{c!r}: {m.action(c)!r} != {w!r}" for c, w in cases.items() if m.action(c) != w]
print("\n".join(bad) if bad else f"OK {len(cases)}")
EOF
)"
[[ "$out" == OK* ]] && pass "8 normaliser: $out cases" || { fail "8 normaliser"; echo "$out"; }

echo "--- spl-cmd-time-report: $fails failure(s)"
(( fails == 0 ))
