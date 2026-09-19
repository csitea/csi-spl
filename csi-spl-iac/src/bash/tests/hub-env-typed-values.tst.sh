#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: every hub env var that cnf renders into 030 and whose Go field is
#          TYPED (int / bool / time.Duration / float) parses as that type. A
#          placeholder string in a typed field crashes the hub at boot even when
#          the feature is off (measured 2026-09-19: SPOOL_HUB_MAIL_SMTP_PORT=
#          PLACEHOLDER-smtp-port -> "parse error on field SMTPPort", revision
#          failed its startup probe). CONTROL: a planted placeholder fails.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
APP_ROOT=$(cd "$TEST_DIR/../../../.." && pwd)
GO="$APP_ROOT/csi-spl-api/src/go/spool-hub-api"
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }

check() {  # <go-root> <tfvars> -> "ok N" or the offending keys
  python3 - "$1" "$2" <<'PY'
import json, re, sys, pathlib
typed = {}
for f in pathlib.Path(sys.argv[1]).rglob("*.go"):
    if f.name.endswith("_test.go"): continue
    for m in re.finditer(r'^\s*\w+\s+(\*?[\w.]+)\s+`[^`]*env:"([A-Z0-9_]+)', f.read_text(), re.M):
        t = m.group(1).lstrip("*")
        if t in ("int", "int32", "int64", "uint", "uint32", "uint64", "bool", "time.Duration", "float64", "float32"):
            typed[m.group(2)] = t
line = next(l for l in open(sys.argv[2]) if l.startswith("environment_variables "))
env = json.loads(line.split("=", 1)[1])
dur = re.compile(r'^(\d+(\.\d+)?(ns|us|µs|ms|s|m|h))+$|^0$')
bad = []
for k, v in env.items():
    t = typed.get(k)
    if not t: continue
    ok = (re.fullmatch(r'-?\d+', v) is not None) if t.startswith(("int", "uint")) else \
         (v.lower() in ("1","0","t","f","true","false")) if t == "bool" else \
         (dur.fullmatch(v) is not None) if t == "time.Duration" else \
         (re.fullmatch(r'-?\d+(\.\d+)?', v) is not None)
    if not ok: bad.append(f"{k}={v!r} ({t})")
print(f"ok {sum(1 for k in env if k in typed)} of {len(typed)} typed" if not bad else "BAD " + "; ".join(bad))
PY
}

for env in dev prd; do
  r=$(check "$GO" "$APP_ROOT/csi-spl-cnf/csi-spl/$env/tf/030-cloud-run-hub.vars.tfvars")
  [[ "$r" == ok* ]] && pass "$env every typed hub env value parses ($r)" || fail "$env $r"
done

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
sed 's/"SPOOL_HUB_MAIL_SMTP_PORT": "[^"]*"/"SPOOL_HUB_MAIL_SMTP_PORT": "PLACEHOLDER-smtp-port"/' \
  "$APP_ROOT/csi-spl-cnf/csi-spl/dev/tf/030-cloud-run-hub.vars.tfvars" >"$T/x.tfvars"
r=$(check "$GO" "$T/x.tfvars")
[[ "$r" == BAD*SPOOL_HUB_MAIL_SMTP_PORT* ]] && pass "control: a placeholder in the int SMTP port is caught" || fail "control not caught: $r"

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
