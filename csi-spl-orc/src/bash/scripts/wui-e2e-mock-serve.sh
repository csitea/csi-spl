#!/usr/bin/env bash
#------------------------------------------------------------------------------
# wui-e2e-mock-serve.sh <cmd>... - serve the generated mock-tenant WUI bundle
# (csi-spl-wui/.output/public) with a signed-out API stub beside it, then run
# <cmd> with BASE_URL pointing at it. Workflows 10 and 11 both run their
# browser e2e through it (was the same ~60 inline lines in each, CLE-77928).
# Run from csi-spl-wui after `pnpm run generate`; CHROME_PATH must be set.
# Logs: $RUNNER_TEMP/wui-e2e-{api,serve}.log in CI; elsewhere a private
# mktemp -d dir, removed on exit.
#------------------------------------------------------------------------------
set -euo pipefail
: "${CHROME_PATH:?CHROME_PATH unset}"
[[ $# -gt 0 ]] || { echo "usage: $0 <cmd>..." >&2; exit 2; }
here=$(cd "$(dirname "$0")" && pwd)
# RUNNER_TEMP is per job. Without it, fixed names in the shared /tmp met a
# file another user owned: the servers never started and the script printed
# that user's old log as this run's (SPL-2920). So a private dir, never a
# log this run did not write.
priv=""
if [[ -n "${RUNNER_TEMP:-}" ]]; then logs="$RUNNER_TEMP"
else priv=$(mktemp -d "${TMPDIR:-/tmp}/wui-e2e-mock-serve.XXXXXX"); logs="$priv"
fi
api_pid="" serve_pid=""
cleanup() {
  [[ -z "$api_pid$serve_pid" ]] || kill ${api_pid:+"$api_pid"} ${serve_pid:+"$serve_pid"} 2>/dev/null || true
  [[ -z "$priv" ]] || rm -rf "$priv"
}
trap cleanup EXIT
api_log="$logs/wui-e2e-api.log" serve_log="$logs/wui-e2e-serve.log"

# Free ports, never fixed ones: four runners share one box, and a stale server
# left on :4173 (a prd bundle, 2026-09-22) answered the probe while the job's
# own server died on EADDRINUSE, so every route "failed" against the prd api.
read -r web_port api_port < <(python3 -c 'import socket
s=[socket.socket() for _ in range(2)]
[x.bind(("127.0.0.1",0)) for x in s]
print(*[x.getsockname()[1] for x in s])')

python3 "$here/wui-e2e-mock-api.py" "$api_port" >"$api_log" 2>&1 &
api_pid=$!
node src/node/test/serve-generated.mjs --port "$web_port" --api "http://127.0.0.1:$api_port" \
  >"$serve_log" 2>&1 &
serve_pid=$!

for _ in $(seq 1 40); do
  curl -fsS -o /dev/null "http://127.0.0.1:$web_port/login" && break
  sleep 0.25
done
curl -fsS -o /dev/null "http://127.0.0.1:$web_port/login" \
  || { echo "::error::generated bundle not serving on :$web_port"; cat "$serve_log"; exit 1; }
# The answer must come from THIS job's servers, not a squatter.
kill -0 "$serve_pid" && kill -0 "$api_pid" \
  || { echo "::error::a server of this job died; the port answered from elsewhere"; cat "$serve_log" "$api_log"; exit 1; }

export BASE_URL="http://127.0.0.1:$web_port"
"$@"
