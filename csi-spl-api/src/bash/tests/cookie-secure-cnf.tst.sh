#!/usr/bin/env bash
# SPL-1285: the auth session + OAuth-state cookies set Secure = cfg.CookieSecure
# (SPOOL_HUB_AUTH_COOKIE_SECURE). That Go line is nosemgrep'd on the promise
# that every DEPLOYED env runs with the flag ON; this gate is that promise. If
# dev or prd cnf ever drops Secure, the suppression becomes unsafe and this
# reddens locally before the hub can ship an insecure cookie. lde (local http
# dev) is the one env allowed "false".
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CNF="$HERE/../../../../csi-spl-cnf/csi-spl"
VAR=SPOOL_HUB_AUTH_COOKIE_SECURE

# read_val <file> <key-in-context>: pull "<var>": "<value>" (tfvars/json) from a file.
read_val() { grep -oE "\"$VAR\": \"[^\"]*\"" "$1" | sed -n 1p | sed -E 's/.*: "([^"]*)"/\1/'; }

fail=0
for env in dev prd; do
  f="$CNF/$env/tf/030-cloud-run-hub.vars.tfvars"
  [[ -f "$f" ]] || { echo "FAIL - no rendered cnf at $f"; exit 1; }
  val=$(read_val "$f")
  if [[ "$val" == "true" ]]; then
    echo "ok   - $env: $VAR=true"
  else
    echo "FAIL - $env cnf has $VAR=\"${val:-<unset>}\" (must be \"true\"; the Go nosemgrep on the cookie Secure flag relies on it)"
    fail=1
  fi
done
[[ $fail -eq 0 ]] || exit 1

# CONTROL: the gate must be able to SEE a "false" rather than always passing.
# lde is the one env that legitimately carries it, so it proves the parse works.
lde="$CNF/lde.env.yaml"
if [[ -f "$lde" ]]; then
  lval=$(grep -oE "$VAR: \"[^\"]*\"" "$lde" | sed -n 1p | sed -E 's/.*: "([^"]*)"/\1/')
  if [[ "$lval" == "false" ]]; then
    echo "ok   - control: lde $VAR=false is parsed (the gate can detect a false)"
  else
    echo "FAIL - control: expected lde $VAR=false, got \"${lval:-<unset>}\" (the gate may be blind to a false)"
    exit 1
  fi
fi

echo "ALL cookie-secure cnf CHECKS PASSED"
