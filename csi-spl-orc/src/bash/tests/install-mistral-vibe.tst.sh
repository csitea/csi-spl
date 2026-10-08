#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_install_mistral_vibe (spec 110 2.2 / 2.4, test 7f), hermetic: a
#          temp agent home, a temp cnf, uv / pipx / python / vibe stubs.
#   1. a fresh install: the exact pipx line (mistral-vibe==<cnf pin>), the
#      flag contract checked, the dependency list printed, active_model
#      pinned in ~/.vibe/config.toml (600, dir 700, other lines kept), the
#      login named by mode and owner only
#   2. a re-run at the pin installs nothing and rewrites nothing; an
#      active_model set by hand is kept and named
#   3. uv when present (uv tool install, uv pip freeze); an older vibe is
#      replaced
#   4. CONTROLS: a cnf pin of latest or empty, and python 3.11, are refused
#      (exit 2) before anything is installed; a vibe that lacks a flag of the
#      contract is refused (exit 4)
#   5. key leak: a planted key in ~/.vibe/.env and one exported in the env
#      are in no output and no stub log; vibe never runs with the env key
#      (CONTROL: the same check catches a planted echo)
#   6. env override: the planned launch line carries env -u MISTRAL_API_KEY
#      (CONTROL: a line without it fails the same check)
#   7. nothing outside the agent home is touched; DRY_RUN=1 changes nothing
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0
command -v yq >/dev/null || { echo "SKIP: no yq"; exit 0; }

ME="$(id -un)"
KEY="canaryFileK3y${RANDOM}${RANDOM}Z"
ENVKEY="canaryEnvK3y${RANDOM}${RANDOM}Z"
B="$T/bin"; mkdir -p "$B" "$T/spool"
: >"$T/calls.log"

# the vibe a stub install lays down: --version, --help (FAKE_VIBE_DROP removes
# one flag), and whether MISTRAL_API_KEY reached it (never its value)
cat >"$T/vibe.tpl" <<'EOF'
#!/usr/bin/env bash
echo "vibe $1 key-in-env=${MISTRAL_API_KEY:+yes}" >>"$STUB_LOG"
case "$1" in
  --version) echo "vibe @VER@" ;;
  --help) printf '%s\n' 'usage: vibe [-h] [-p [TEXT]] [--auto-approve] [--workdir DIR]' \
    '            [-c | --resume [SESSION_ID]]' '  -p, --prompt [TEXT]   programmatic mode' \
    '  --auto-approve, --yolo' '  -c, --continue        Continue' '  --resume [SESSION_ID]' |
    grep -v -- "${FAKE_VIBE_DROP:-@none@}" ;;
esac
EOF
# pipx / uv: `install --force mistral-vibe==V` lays vibe V into ~/.local/bin
for t in pipx uv; do
  cat >"$B/$t" <<EOF
#!/usr/bin/env bash
echo "$t \$* key-in-env=\${MISTRAL_API_KEY:+yes}" >>"\$STUB_LOG"
case "\$*" in
  *"install --force mistral-vibe=="*) v="\${@: -1}"; v="\${v##*==}"; mkdir -p "\$HOME/.local/bin"
    sed "s/@VER@/\$v/" "$T/vibe.tpl" >"\$HOME/.local/bin/vibe"; chmod +x "\$HOME/.local/bin/vibe" ;;
  "runpip mistral-vibe freeze"|"pip freeze --python "*) printf 'httpx==0.28.1\nmistralai==1.9.0\n' ;;
esac
EOF
done
printf '#!/bin/sh\necho 3.13\n' >"$B/py313"; printf '#!/bin/sh\necho 3.11\n' >"$B/py311"
chmod +x "$B"/*
cnf() { printf 'env:\n  box:\n    mistral_vibe:\n      version: %s\n      model: mistral-vibe-cli-latest\n' "$1" >"$T/cnf.yaml"; }
cnf 2.26.0

H="$T/agent-home"; mkdir -p "$H/.vibe"
printf 'MISTRAL_API_KEY=%s\n' "$KEY" >"$H/.vibe/.env"; chmod 600 "$H/.vibe/.env"
printf '[[models]]\nname = "mistral-vibe-cli-latest"\n' >"$H/.vibe/config.toml"
# mi [VAR=value]...: the action as the hermetic agent; output in $T/o. PATH
# holds no vibe, uv or pipx of this machine: the stubs come by their names.
mi() {
  PATH="$H/.local/bin:/usr/local/bin:/usr/bin:/bin" in_orc SPOOL_ROOT="$T/spool" SPOOL_AGENT_USER="$ME" \
    MISTRAL_VIBE_AGENT_HOME="$H" MISTRAL_VIBE_CNF="$T/cnf.yaml" SNIPPET=do_install_mistral_vibe \
    SPOOL_INSTALL_UV="$T/no-uv" SPOOL_INSTALL_PIPX="$B/pipx" SPOOL_INSTALL_PYTHON="$B/py313" "$@" >"$T/o" 2>&1
}
installs() { grep -c 'install --force' "$T/calls.log"; }
cfg="$H/.vibe/config.toml"
touch -d '1 minute ago' "$T/marker"
real_vibe="$(stat -c '%Y %s' "$HOME/.vibe/config.toml" 2>/dev/null)"

# --- 1. a fresh install --------------------------------------------------------------------------
mi MISTRAL_API_KEY="$ENVKEY"; rc=$?
if [[ $rc -eq 0 ]] && grep -qx "pipx install --force mistral-vibe==2.26.0 key-in-env=" "$T/calls.log" &&
   [[ "$(installs)" == 1 ]] && [[ -x "$H/.local/bin/vibe" ]]; then
  pass "1: the exact pipx line, mistral-vibe==2.26.0 (the cnf pin), one install"
else fail "1: install (rc=$rc): $(tail -n4 "$T/o") / $(cat "$T/calls.log")"; fi
[[ "$(sed -n 1p "$cfg")" == 'active_model = "mistral-vibe-cli-latest"' ]] && grep -qxF '[[models]]' "$cfg" &&
  [[ "$(stat -c %a "$cfg") $(stat -c %a "$H/.vibe")" == "600 700" ]] &&
  pass "1: active_model pinned first in config.toml (600 in 700), other lines kept" || fail "1: config: $(cat "$cfg")"
grep -q 'flag contract ok' "$T/o" && grep -q '2 dependencies of mistral-vibe 2.26.0' "$T/o" &&
  grep -q 'dep mistralai==1.9.0' "$T/o" && grep -q "runpip mistral-vibe freeze" "$T/calls.log" &&
  pass "1: flag contract checked, dependency list printed" || fail "1: contract/deps: $(cat "$T/o")"
grep -q "login $H/.vibe/.env mode 600 owner $ME" "$T/o" && pass "1: the login is named by mode and owner" ||
  fail "1: login line: $(grep login "$T/o")"

# --- 2. re-run at the pin --------------------------------------------------------------------------
sum="$(sha256sum <"$cfg")"
mi; rc=$?
[[ $rc -eq 0 && "$(installs)" == 1 && "$(sha256sum <"$cfg")" == "$sum" ]] && grep -q 'is at the pin 2.26.0: not reinstalled' "$T/o" &&
  pass "2: a re-run at the pin installs nothing, rewrites nothing" || fail "2: re-run (rc=$rc installs=$(installs)): $(tail -n3 "$T/o")"
sed -i 's/^active_model = .*/active_model = "mistral-large"/' "$cfg"; sum="$(sha256sum <"$cfg")"
mi; rc=$?
[[ $rc -eq 0 && "$(sha256sum <"$cfg")" == "$sum" ]] && grep -q 'WARN mistral: .* keeps active_model = "mistral-large", set by hand' "$T/o" &&
  pass "2: an active_model set by hand is kept and named" || fail "2: hand model (rc=$rc): $(cat "$cfg")"

# --- 3. uv, and an older vibe ----------------------------------------------------------------------
sed 's/@VER@/2.25.0/' "$T/vibe.tpl" >"$H/.local/bin/vibe"
mi SPOOL_INSTALL_UV="$B/uv"; rc=$?
[[ $rc -eq 0 ]] && grep -qx "uv tool install --force mistral-vibe==2.26.0 key-in-env=" "$T/calls.log" &&
  grep -q 'replacing 2.25.0' "$T/o" && grep -q '^uv pip freeze --python ' "$T/calls.log" &&
  pass "3: uv when present; an older vibe (2.25.0) is replaced" || fail "3: uv (rc=$rc): $(tail -n3 "$T/o")"

# --- 4. controls -------------------------------------------------------------------------------------
n0="$(installs)"
for p in latest '""'; do
  cnf "$p"; mi; rc=$?
  [[ $rc -eq 2 && "$(installs)" == "$n0" ]] && grep -q 'must be one pinned X.Y.Z' "$T/o" &&
    pass "4: CONTROL: cnf pin $p refused (exit 2), nothing installed" || fail "4: pin $p (rc=$rc): $(tail -n2 "$T/o")"
done
cnf 2.26.0; rm -f "$H/.local/bin/vibe"
mi SPOOL_INSTALL_PYTHON="$B/py311"; rc=$?
[[ $rc -eq 2 && "$(installs)" == "$n0" ]] && grep -q 'needs python 3.12 or newer.*is 3.11' "$T/o" &&
  pass "4: CONTROL: python 3.11 refused (exit 2), nothing installed" || fail "4: py311 (rc=$rc): $(tail -n2 "$T/o")"
mi FAKE_VIBE_DROP=--resume; rc=$?
[[ $rc -eq 4 ]] && grep -q 'lacks the flag contract: --resume - the pin 2.26.0 is refused' "$T/o" &&
  pass "4: CONTROL: a vibe without --resume: the pin is refused (exit 4)" || fail "4: contract (rc=$rc): $(tail -n2 "$T/o")"

# --- 5. key leak ---------------------------------------------------------------------------------------
mi MISTRAL_API_KEY="$ENVKEY"; cp "$T/o" "$T/o.env"
no_leak() { ! grep -qE "$KEY|$ENVKEY" "$@"; }
no_leak "$T/o" "$T/o.env" "$T/calls.log" && pass "5: neither planted key is in the output or a stub log (n=1 each)" ||
  fail "5: a key leaked: $(grep -lE "$KEY|$ENVKEY" "$T/o" "$T/o.env" "$T/calls.log")"
grep -q '^vibe ' "$T/calls.log" && ! grep -q '^vibe .*key-in-env=yes' "$T/calls.log" &&
  pass "5: vibe never ran with MISTRAL_API_KEY in its env" || fail "5: vibe saw the env key: $(grep '^vibe' "$T/calls.log")"
{ cat "$T/o"; echo "MISTRAL_API_KEY=$KEY"; } >"$T/o.planted"
no_leak "$T/o.planted" && fail "5: CONTROL: the planted echo was NOT caught" || pass "5: CONTROL: the leak check catches a planted echo"

# --- 6. env override -------------------------------------------------------------------------------------
launch_ok() { grep -E 'launch line: env -u MISTRAL_API_KEY vibe --auto-approve' "$1" >/dev/null; }
launch_ok "$T/o.env" && grep -q 'WARN mistral: MISTRAL_API_KEY is set in this environment' "$T/o.env" &&
  pass "6: with MISTRAL_API_KEY exported, the launch line carries env -u MISTRAL_API_KEY" || fail "6: launch: $(grep launch "$T/o.env")"
sed 's/env -u MISTRAL_API_KEY //' "$T/o.env" >"$T/o.bad"
launch_ok "$T/o.bad" && fail "6: CONTROL: a launch line without env -u passed" || pass "6: CONTROL: a launch line without env -u fails"

# --- 7. nothing outside the home; DRY_RUN ------------------------------------------------------------------
out="$(find "$T" -newer "$T/marker" -type f ! -path "$H/*" ! -path "$T/o*" ! -name calls.log ! -name cnf.yaml ! -path "$T/bin/*" ! -name vibe.tpl)"
[[ -z "$out" && "$(stat -c '%Y %s' "$HOME/.vibe/config.toml" 2>/dev/null)" == "$real_vibe" ]] &&
  pass "7: nothing outside the agent home was written" || fail "7: written outside the home: $out"
H="$T/home-dry"; mkdir -p "$H"; n0="$(installs)"
mi DRY_RUN=1; rc=$?
[[ $rc -eq 0 && "$(installs)" == "$n0" && -z "$(ls -A "$H")" ]] && grep -q "would: $B/pipx install --force mistral-vibe==2.26.0" "$T/o" &&
  pass "7: DRY_RUN=1 plans the install, runs none, writes nothing" || fail "7: dry (rc=$rc): $(cat "$T/o")"

echo "---"; [[ $fails -eq 0 ]] && { echo "ALL PASS"; exit 0; } || { echo "$fails FAILED"; exit 1; }
