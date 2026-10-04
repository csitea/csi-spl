#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: one true set of agent-connect instructions (spec 072 A65, F38, F45).
#          doc/help/connect-an-agent.md names no literal hosted domain (the
#          WUI fills {{api}} / {{site}} from the site it runs on) and no
#          legacy agent id (spec 061 section 0: ^[acgq]-[0-9]{3}$). The help
#          page and the root README give the same two choices (the installer,
#          or the spool CLI + MCP), and the README's "another machine"
#          paragraph keeps the root key on the first machine. Getting
#          started heads no sign-in method "(Recommended)": a self-hosted
#          stack configures no social provider (review 17-18 N3).
#          CONTROLS: a copy with a planted hosted URL, a planted legacy id,
#          a README copy that teaches copying the key, and a getting-started
#          copy that recommends social sign-in are each refused.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0

HELP="$APP_ROOT/csi-spl-doc/doc/help/connect-an-agent.md"
README="$APP_ROOT/README.md"
START="$APP_ROOT/csi-spl-doc/doc/help/getting-started.md"
domain=$(command grep -m1 -oE '^[[:space:]]*BASE_DOMAIN:[[:space:]]*[^[:space:]#]+' "$APP_ROOT/csi-spl-cnf/csi-spl/all.env.yaml" | awk '{print $2}' | tr -d "\"'")
[[ -n "$domain" ]] || { fail "cannot read env.dns.BASE_DOMAIN from the cnf"; exit 1; }

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

# check_help <page> -> the problems, one per line; nothing = ok
check_help() {
  local page="$1"
  command grep -qF "$domain" "$page" && echo "names the hosted domain (use {{api}} / {{site}})"
  command grep -qE '\b(CLE|GRK|AGY|QWN)-[0-9]+' "$page" && echo "names a legacy agent id"
  command grep -qF "'https://{{api}}'" "$page" || echo "SPOOL_HUB_URL is not the {{api}} token"
  command grep -qF 'spool-install/install.sh' "$page" || echo "does not offer the installer"
  command grep -qF 'spool mcp --as' "$page" || echo "does not offer the CLI + MCP path"
}

# check_readme <readme> -> the problems, one per line; nothing = ok
check_readme() {
  local readme="$1" para
  para=$(awk '/^On another machine/{on=1} on&&/^## /{exit} on' "$readme")
  [[ -n "$para" ]] || { echo "no \"On another machine\" paragraph"; return; }
  command grep -qiE 'copy the (root )?key' <<<"$para" && echo "the another-machine paragraph teaches copying the root key"
  command grep -qF -- '--env self' <<<"$para" || echo "the another-machine paragraph omits --env self"
  command grep -qF 'ROOT_KEY_JSON' <<<"$para" || echo "the another-machine paragraph does not say to leave ROOT_KEY_JSON out"
  command grep -qF 'install.sh' "$readme" || echo "does not offer the installer"
  command grep -qF 'connect-an-agent.md' "$readme" || echo "does not point at the CLI + MCP help page"
}

# check_start <page> -> the problems, one per line; nothing = ok
check_start() {
  command grep -qiE '^#+ .*\(Recommended\)' "$1" && echo "heads a sign-in method (Recommended)"
}

out=$(check_help "$HELP")
[[ -z "$out" ]] && pass "connect-an-agent.md: no hosted domain, no legacy id, both choices" || fail "connect-an-agent.md: $(tr '\n' ';' <<<"$out")"
out=$(check_readme "$README")
[[ -z "$out" ]] && pass "README: the another-machine paragraph keeps the root key, both choices" || fail "README: $(tr '\n' ';' <<<"$out")"

{ cat "$HELP"; echo "export SPOOL_HUB_URL='https://api.$domain'"; } >"$T/url.md"
[[ "$(check_help "$T/url.md")" == *"hosted domain"* ]] && pass "control: a planted hosted URL is refused" || fail "control: a planted hosted URL passed"
{ cat "$HELP"; echo 'exec spool mcp --as CLE-02'; } >"$T/legacy.md"
[[ "$(check_help "$T/legacy.md")" == *"legacy agent id"* ]] && pass "control: a planted legacy id is refused" || fail "control: a planted legacy id passed"
out=$(check_start "$START")
[[ -z "$out" ]] && pass "getting-started.md: no sign-in method headed (Recommended)" || fail "getting-started.md: $(tr '\n' ';' <<<"$out")"

sed 's/^### 2.1 Social Identity Providers.*/### 2.1 Social Identity Providers (Recommended)/' "$START" >"$T/start.md"
[[ "$(check_start "$T/start.md")" == *"(Recommended)"* ]] && pass "control: social sign-in headed (Recommended) is refused" || fail "control: social sign-in headed (Recommended) passed"
sed 's/^On another machine.*/On another machine, copy the key file there (0600)./' "$README" >"$T/README.md"
[[ "$(check_readme "$T/README.md")" == *"copying the root key"* ]] && pass "control: a README that copies the key is refused" || fail "control: a README that copies the key passed"

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
