#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_install_openai_codex (spec 161 2.2, row B3), hermetic: a temp
#          agent home, a temp cnf, an npm stub that lays down a codex stub.
#   1. DRY_RUN is the default: the plan names the exact npm line with the
#      cnf pin, npm never runs, nothing is written anywhere
#   2. a fake installer (OPENAI_CODEX_INSTALLER): the action hands it the cnf
#      pin and --cli codex --cli-only, plus --dry-run unless DRY_RUN=0
#   3. DRY_RUN=0: one npm install of @openai/codex@<pin> into the agent's
#      prefix, the flag contract checked, ~/.codex/config.toml gets
#      cli_auth_credentials_store = "file" and [analytics] enabled = false
#      (600 in 700), "no login yet" named
#   4. a re-run at the pin installs nothing and rewrites nothing; a login
#      (~/.codex/auth.json) is named by mode and owner, never read
#   5. CONTROLS: a cnf pin of latest, empty or absent is refused (exit 2)
#      before anything runs; install.sh itself refuses
#      SPOOL_INSTALL_CODEX_VERSION=latest; a codex without
#      --dangerously-bypass-approvals-and-sandbox is refused (exit 4)
#   6. key leak: an OPENAI_API_KEY in the env and a planted auth.json are in
#      no output and no stub log; codex and npm never run with the key
#      (CONTROL: the same check catches a planted echo)
#   7. the real cnf: a pinned X.Y.Z, auth_marker.codex = .codex/auth.json,
#      and codex has no weight in agent_split or any agent_split_by_kind row
#      (off until the owner's login is on the box)
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0
command -v yq >/dev/null || { echo "SKIP: no yq"; exit 0; }

ME="$(id -un)"
PIN=0.166.0
ENVKEY="canaryEnvK3y${RANDOM}${RANDOM}Z"
AUTH="canaryAuthT0k${RANDOM}${RANDOM}Z"
B="$T/bin"; mkdir -p "$B" "$T/spool"
: >"$T/calls.log"

# the codex an npm stub install lays down: --version, --help
# (FAKE_CODEX_DROP removes one entry), and whether a key reached it
cat >"$T/codex.tpl" <<'EOF'
#!/usr/bin/env bash
echo "codex $1 key-in-env=${OPENAI_API_KEY:+yes}${CODEX_API_KEY:+yes}" >>"$STUB_LOG"
case "$1" in
  --version) echo "codex-cli @VER@" ;;
  --help) printf '%s\n' 'Usage: codex [OPTIONS] [PROMPT]' 'Commands:' '  exec    Run Codex non-interactively' \
    '  login   Manage login' '  resume  Resume a previous interactive session' 'Options:' \
    '  -a, --ask-for-approval <APPROVAL_POLICY>' '      --dangerously-bypass-approvals-and-sandbox' |
    grep -v -- "${FAKE_CODEX_DROP:-@none@}" ;;
esac
EOF
# npm: `install --prefix P -g @openai/codex@V` lays codex V into P/bin
cat >"$B/npm" <<EOF
#!/usr/bin/env bash
echo "npm \$* key-in-env=\${OPENAI_API_KEY:+yes}" >>"\$STUB_LOG"
if [[ "\$1 \$2" == "install --prefix" && "\$4 \$5" == "-g @openai/codex@"* ]]; then
  mkdir -p "\$3/bin"; sed "s/@VER@/\${5##*@}/" "$T/codex.tpl" >"\$3/bin/codex"; chmod +x "\$3/bin/codex"
fi
EOF
# the fake installer: records its args and the pin it was handed
cat >"$B/fake-install.sh" <<'EOF'
#!/usr/bin/env bash
echo "fake-install $* pin=${SPOOL_INSTALL_CODEX_VERSION:-}" >>"$STUB_LOG"
EOF
chmod +x "$B"/*
cnf() {
  if [[ "$1" == none ]]; then printf 'env:\n  box: {}\n'
  else printf 'env:\n  box:\n    openai_codex:\n      version: %s\n' "$1"; fi >"$T/cnf.yaml"
}
cnf "$PIN"

H="$T/agent-home"; mkdir -p "$H"
# oc [VAR=value]...: the action as the hermetic agent; output in $T/o. PATH
# holds no codex or npm of this machine: the stubs come by their names.
oc() {
  PATH="$H/.local/bin:/usr/local/bin:/usr/bin:/bin" in_orc SPOOL_ROOT="$T/spool" SPOOL_AGENT_USER="$ME" \
    OPENAI_CODEX_AGENT_HOME="$H" OPENAI_CODEX_CNF="$T/cnf.yaml" SNIPPET=do_install_openai_codex \
    SPOOL_INSTALL_NPM="$B/npm" "$@" >"$T/o" 2>&1
}
installs() { grep -c '^npm install' "$T/calls.log"; }
cfg="$H/.codex/config.toml"
touch -d '1 minute ago' "$T/marker"
real_codex="$(stat -c '%Y %s' "$HOME/.codex/config.toml" 2>/dev/null)"

# --- 1. DRY_RUN is the default ------------------------------------------------------------------
oc; rc=$?
[[ $rc -eq 0 && "$(installs)" == 0 && -z "$(ls -A "$H")" ]] &&
  grep -q "would: $B/npm install --prefix $H/.local -g @openai/codex@$PIN" "$T/o" && grep -q 'DRY RUN - nothing changed' "$T/o" &&
  pass "1: DRY_RUN unset = a dry run: the npm line with the cnf pin $PIN planned, npm never ran, the home is empty" ||
  fail "1: dry default (rc=$rc installs=$(installs)): $(cat "$T/o")"
out="$(find "$T" -newer "$T/marker" -type f ! -path "$T/o*" ! -name calls.log ! -name cnf.yaml ! -path "$B/*" ! -name codex.tpl)"
[[ -z "$out" && "$(stat -c '%Y %s' "$HOME/.codex/config.toml" 2>/dev/null)" == "$real_codex" ]] &&
  pass "1: the dry run wrote no file (n=1 run)" || fail "1: the dry run wrote: $out"

# --- 2. the fake installer: the pin is what it is handed -----------------------------------------
oc OPENAI_CODEX_INSTALLER="$B/fake-install.sh"; rc=$?
[[ $rc -eq 0 ]] && grep -qx "fake-install --cli codex --cli-only --dry-run pin=$PIN" "$T/calls.log" &&
  pass "2: the installer gets --cli codex --cli-only --dry-run and the cnf pin $PIN" || fail "2: fake dry (rc=$rc): $(cat "$T/calls.log")"
oc OPENAI_CODEX_INSTALLER="$B/fake-install.sh" DRY_RUN=0; rc=$?
[[ $rc -eq 0 ]] && grep -qx "fake-install --cli codex --cli-only pin=$PIN" "$T/calls.log" &&
  pass "2: DRY_RUN=0 drops --dry-run, same pin" || fail "2: fake real (rc=$rc): $(tail -n2 "$T/calls.log")"

# --- 3. DRY_RUN=0: a fresh install ----------------------------------------------------------------
oc DRY_RUN=0; rc=$?
[[ $rc -eq 0 && "$(installs)" == 1 && -x "$H/.local/bin/codex" ]] &&
  grep -qx "npm install --prefix $H/.local -g @openai/codex@$PIN key-in-env=" "$T/calls.log" &&
  pass "3: one npm install of @openai/codex@$PIN (the cnf pin) into the agent's prefix" ||
  fail "3: install (rc=$rc installs=$(installs)): $(tail -n4 "$T/o")"
grep -q 'flag contract ok' "$T/o" && grep -q "codex: $H/.local/bin/codex (codex $PIN)" "$T/o" &&
  pass "3: the flag contract checked, the version read back" || fail "3: contract: $(cat "$T/o")"
[[ "$(sed -n 1p "$cfg")" == 'cli_auth_credentials_store = "file"' ]] && grep -qx '\[analytics\]' "$cfg" &&
  grep -qx 'enabled = false' "$cfg" && [[ "$(stat -c %a "$cfg") $(stat -c %a "$H/.codex")" == "600 700" ]] &&
  pass "3: config.toml: the login in a file, analytics off (600 in 700)" || fail "3: config: $(cat "$cfg" 2>&1)"
grep -q "no login yet ($H/.codex/auth.json)" "$T/o" && pass "3: no login yet: named, nothing written" || fail "3: login line: $(grep login "$T/o")"

# --- 4. re-run at the pin; a login is named, never read -------------------------------------------
printf '{"tokens":{"access_token":"%s"}}\n' "$AUTH" >"$H/.codex/auth.json"; chmod 600 "$H/.codex/auth.json"
auth_sum="$(sha256sum <"$H/.codex/auth.json")"; sum="$(sha256sum <"$cfg")"
oc DRY_RUN=0 OPENAI_API_KEY="$ENVKEY"; rc=$?; cp "$T/o" "$T/o.env"
[[ $rc -eq 0 && "$(installs)" == 1 && "$(sha256sum <"$cfg")" == "$sum" ]] && grep -q "is at the pin $PIN: not reinstalled" "$T/o" &&
  pass "4: a re-run at the pin installs nothing, rewrites nothing" || fail "4: re-run (rc=$rc installs=$(installs)): $(tail -n3 "$T/o")"
grep -q "login $H/.codex/auth.json mode 600 owner $ME" "$T/o" && [[ "$(sha256sum <"$H/.codex/auth.json")" == "$auth_sum" ]] &&
  pass "4: the login is named by mode and owner, unchanged" || fail "4: login: $(grep login "$T/o")"
printf 'cli_auth_credentials_store = "keyring"\n' >"$cfg"; oc DRY_RUN=0
grep -q 'WARN codex: .* keeps cli_auth_credentials_store = "keyring", set by hand' "$T/o" && grep -q '^cli_auth_credentials_store = "keyring"$' "$cfg" &&
  grep -qx 'enabled = false' "$cfg" && pass "4: a store set by hand is kept and named; analytics still turned off" ||
  fail "4: hand store: $(cat "$cfg")"

# --- 5. controls ------------------------------------------------------------------------------------
n0="$(installs)"
for p in latest '""' none; do
  cnf "$p"; oc DRY_RUN=0; rc=$?
  [[ $rc -eq 2 && "$(installs)" == "$n0" ]] && grep -q 'must be one pinned X.Y.Z' "$T/o" &&
    pass "5: CONTROL: cnf pin $p refused (exit 2), nothing installed" || fail "5: pin $p (rc=$rc): $(tail -n2 "$T/o")"
done
cnf "$PIN"
HOME="$H" PATH="$H/.local/bin:/usr/local/bin:/usr/bin:/bin" SPOOL_INSTALL_NPM="$B/npm" STUB_LOG="$T/calls.log" \
  SPOOL_INSTALL_CODEX_VERSION=latest bash "$PROJ_ROOT/src/bash/features/spool-install/install.sh" --cli codex --cli-only >"$T/o" 2>&1; rc=$?
[[ $rc -eq 2 && "$(installs)" == "$n0" ]] && grep -q "got 'latest': never latest" "$T/o" &&
  pass "5: CONTROL: install.sh --cli codex refuses SPOOL_INSTALL_CODEX_VERSION=latest (exit 2)" || fail "5: install.sh latest (rc=$rc): $(tail -n2 "$T/o")"
rm -f "$H/.local/bin/codex"
oc DRY_RUN=0 FAKE_CODEX_DROP=--dangerously-bypass; rc=$?
[[ $rc -eq 4 ]] && grep -q "lacks the flag contract: --dangerously-bypass-approvals-and-sandbox - the pin $PIN is refused" "$T/o" &&
  pass "5: CONTROL: a codex without --dangerously-bypass-approvals-and-sandbox: the pin is refused (exit 4)" ||
  fail "5: contract (rc=$rc): $(tail -n2 "$T/o")"

# --- 6. key leak ---------------------------------------------------------------------------------------
no_leak() { ! grep -qE "$AUTH|$ENVKEY" "$@"; }
no_leak "$T/o.env" "$T/o" "$T/calls.log" && pass "6: neither the env key nor the planted login is in the output or a stub log" ||
  fail "6: leaked: $(grep -lE "$AUTH|$ENVKEY" "$T/o.env" "$T/o" "$T/calls.log")"
grep -q '^codex ' "$T/calls.log" && ! grep -qE '^(codex|npm) .*key-in-env=yes' "$T/calls.log" && grep -q 'WARN codex: an OpenAI key is set' "$T/o.env" &&
  pass "6: codex and npm never ran with OPENAI_API_KEY in their env (named once)" || fail "6: key in env: $(grep key-in-env=yes "$T/calls.log")"
{ cat "$T/o.env"; echo "token $AUTH"; } >"$T/o.planted"
no_leak "$T/o.planted" && fail "6: CONTROL: the planted echo was NOT caught" || pass "6: CONTROL: the leak check catches a planted echo"

# --- 7. the real cnf: pinned, a marker, weighted only where SPL-5454 put it --------------------------------------------------
REAL="$APP_ROOT/csi-spl-cnf/csi-spl/all.env.yaml"
v="$(yq -r '.env.box.openai_codex.version // ""' "$REAL")"
[[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] && pass "7: the real cnf pins one X.Y.Z ($v)" || fail "7: real pin '$v'"
[[ "$(yq -r '.env.box.agent_split.auth_marker.codex' "$REAL")" == .codex/auth.json ]] &&
  pass "7: auth_marker.codex = .codex/auth.json" || fail "7: marker: $(yq -r '.env.box.agent_split.auth_marker.codex' "$REAL")"
# SPL-5454 (spec 161 section 5.2.1, GO c-002 msg c691eae1): flat row 0, 15 in tests and simple_coding only, never a backup.
w="$(yq -r '[.env.box.agent_split_by_kind | to_entries[] | select((.value.codex // 0) > 0) | "\(.key)=\(.value.codex)"] | sort | join(",")' "$REAL")"
[[ "$w" == "simple_coding=15,tests=15" ]] && pass "7: codex weighs 15 in tests and simple_coding, no other kind" || fail "7: codex weighted in: '$w'"
[[ "$(yq -r '.env.box.agent_split.codex // 0' "$REAL")" == 0 ]] && pass "7: the flat agent_split row gives codex 0" || fail "7: flat codex: $(yq -r '.env.box.agent_split.codex' "$REAL")"
b="$(yq -r '[.env.box.agent_split_by_kind[] | select(.backup == "codex")] | length' "$REAL")"
[[ "$b" == 0 ]] && pass "7: codex is no backup in any agent_split_by_kind row" || fail "7: codex is backup in $b row(s)"
printf 'env:\n  box:\n    agent_split_by_kind:\n      tests: { claude: 85, codex: 15, backup: grok }\n' >"$T/w.yaml"
w="$(yq -r '[.env.box.agent_split.codex, (.env.box.agent_split_by_kind[] | (.codex, (.backup | select(. == "codex"))))] | map(select(. != null)) | length' "$T/w.yaml")"
[[ "$w" == 1 ]] && pass "7: CONTROL: a row with codex: 15 is caught by the same query" || fail "7: control read $w"

echo "---"; [[ $fails -eq 0 ]] && { echo "ALL PASS"; exit 0; } || { echo "$fails FAILED"; exit 1; }
