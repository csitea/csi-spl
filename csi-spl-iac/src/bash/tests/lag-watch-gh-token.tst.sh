#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: CI panel 2026-10-28 row F1 (SPL-4127) - every workflow step that
# runs do_check_deploy_lag gives gh its token.
# The action dates a lag from the PUSH that brought the commit to trunk, read
# with `gh api .../activity`. In CI gh needs GH_TOKEN for that; without it the
# read fails and the age falls back to the author's commit time
# (`age_from=commit:gh-api-failed`): 4 of 4 wf 00 lag jobs after f396f2ba8 did,
# and an ordinary ~45 min hub roll crossed the 45 min grace and went red.
# What must hold, over every .github/workflows/*.yml:
#   1. at least one step runs `do_check_deploy_lag` (the test checks something)
#   2. each such step has GH_TOKEN in its env, or in its job's, or the
#      workflow's top-level env
#   CONTROL: the same files with GH_TOKEN removed from one such step are
#   reported.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
W="$APP_ROOT/.github/workflows"
fails=0
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

# lag_token_problems <wf file>... -> "OK <n>", then one line per step that runs
# do_check_deploy_lag with no GH_TOKEN in reach
lag_token_problems() {
  python3 - "$@" <<'PY'
import os, re, sys, yaml
rx = re.compile(r"run -a do_check_deploy_lag\b")
n, bad = 0, []
for f in sys.argv[1:]:
    wf = yaml.safe_load(open(f)) or {}
    top = wf.get("env") or {}
    for jid, job in (wf.get("jobs") or {}).items():
        jenv = (job or {}).get("env") or {}
        for i, st in enumerate((job or {}).get("steps") or []):
            if not rx.search(str(st.get("run", ""))): continue
            n += 1
            if not any("GH_TOKEN" in e for e in (st.get("env") or {}, jenv, top)):
                bad.append("%s jobs.%s step '%s': runs do_check_deploy_lag with no GH_TOKEN"
                           % (os.path.basename(f), jid, st.get("name", i)))
print("OK %d" % n)
print("\n".join(bad))
PY
}

mapfile -t files < <(ls "$W"/*.yml)
out=$(lag_token_problems "${files[@]}")
n=$(sed -n '1s/^OK //p' <<<"$out"); p=$(sed '1d;/^$/d' <<<"$out")
[[ "${n:-0}" -ge 1 ]] && pass "$n workflow step(s) run do_check_deploy_lag" \
  || fail "no workflow step runs do_check_deploy_lag: the contract checks nothing"
[[ -z "$p" ]] && pass "every do_check_deploy_lag step gives gh its GH_TOKEN" \
  || fail "$(tr '\n' '|' <<<"$p")"

# --- control: drop GH_TOKEN from the first such step, it must be reported -----
mkdir -p "$T/wf"
python3 - "$T/wf" "${files[@]}" <<'PY'
import os, re, sys, yaml
rx = re.compile(r"run -a do_check_deploy_lag\b"); done = False
for f in sys.argv[2:]:
    wf = yaml.safe_load(open(f)) or {}
    for job in (wf.get("jobs") or {}).values():
        for st in (job or {}).get("steps") or []:
            if not done and rx.search(str(st.get("run", ""))):
                for e in (st.get("env"), job.get("env"), wf.get("env")):
                    if e: e.pop("GH_TOKEN", None)
                done = True
    yaml.safe_dump(wf, open(os.path.join(sys.argv[1], os.path.basename(f)), "w"), sort_keys=False)
PY
c=$(lag_token_problems "$T"/wf/*.yml | sed '1d;/^$/d')
[[ -n "$c" ]] && pass "CONTROL: a lag step without GH_TOKEN is reported" \
  || fail "CONTROL: a lag step without GH_TOKEN passed"

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
