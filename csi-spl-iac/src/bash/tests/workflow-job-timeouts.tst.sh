#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Reliability/DoS: every runner job in .github/workflows declares
# `timeout-minutes`. Without it a hung step holds a runner until GitHub's 6-hour
# ceiling (measured on this repo: a no-timeout check hung ~5 h and stalled the
# fleet gate). Reusable-workflow caller jobs (`uses: ./…`) take no
# `timeout-minutes` — the timeout lives on the called workflow's own job — so
# they are exempt; every job with `runs-on:` must set it.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
WF_DIR="$APP_ROOT/.github/workflows"

fails=0

# Print "file: job" for every job that has runs-on: but no timeout-minutes:.
jobs_missing_timeout() {
  awk '
    /^jobs:[[:space:]]*$/ { injobs=1; next }
    injobs && /^[a-zA-Z]/ { injobs=0 }
    injobs && match($0, /^  [a-zA-Z0-9_-]+:[[:space:]]*$/) {
      if (cur != "" && ro[cur] && !to[cur]) print FILENAME ": " cur
      cur=$0; sub(/:.*/,"",cur); gsub(/ /,"",cur); ro[cur]=0; to[cur]=0
    }
    injobs && /^    runs-on:/     { if (cur!="") ro[cur]=1 }
    injobs && /^    timeout-minutes:/ { if (cur!="") to[cur]=1 }
    END { if (cur != "" && ro[cur] && !to[cur]) print FILENAME ": " cur }
  ' "$1"
}

[[ -d "$WF_DIR" ]] || { fail "no workflows dir at $WF_DIR"; exit 1; }

# --- negative control: a runs-on job with no timeout-minutes is caught --------
CTL=$(mktemp)
printf 'jobs:\n  a:\n    runs-on: ubuntu-latest\n    steps: []\n' >"$CTL"
if [[ -n "$(jobs_missing_timeout "$CTL")" ]]; then
  pass "CONTROL: a runs-on job with no timeout-minutes is detected"
else
  fail "CONTROL: the checker missed a job with no timeout-minutes"
fi
rm -f "$CTL"
# --- positive control: a reusable-caller job (uses:, no runs-on) is exempt ----
CTL2=$(mktemp)
printf 'jobs:\n  v:\n    uses: ./.github/workflows/x.yml\n' >"$CTL2"
if [[ -z "$(jobs_missing_timeout "$CTL2")" ]]; then
  pass "CONTROL: a reusable-workflow caller job is exempt (no runs-on)"
else
  fail "CONTROL: a reusable-caller job was wrongly flagged"
fi
rm -f "$CTL2"

n=0
for f in "$WF_DIR"/*.yml; do
  b=$(basename "$f"); n=$((n + 1))
  miss=$(jobs_missing_timeout "$f")
  if [[ -z "$miss" ]]; then
    pass "$b: every runs-on job sets timeout-minutes"
  else
    fail "$b: job(s) with no timeout-minutes:"
    sed 's/^/      /' <<<"$miss"
  fi
done
[[ "$n" -gt 0 ]] && pass "checked job timeouts on $n workflow file(s)" || fail "no workflow files found"

[[ "$fails" -eq 0 ]] && echo "PASS: all workflow-job-timeouts.tst.sh assertions"
exit "$fails"
