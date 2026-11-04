#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the local dev mode one-liner works where spec 148 4.1 says it
# does, from the clone root (SPL-4756, findings D2 + D3 of SPL-4533). A
# clone root had no `run`: `./run -a do_dev_mode_up` there was rc 127.
#   1. the root `run` is tracked as a symbolic link to csi-spl-orc/run, so a
#      fresh clone has it
#   2. the command spec 148 4.1 documents is `./run -a do_dev_mode_up`, and
#      DEPLOY.md, CONTRIBUTING.md and the local dev mode guide name it
#   3. that command, run from the clone root, reaches the prerequisite check:
#      docker is a stub, DEV_PREFLIGHT_UNAME_S fails check 1 -> rc 1 with the
#      preflight's ERROR line, compose up never runs
#   4. the host ports spec 148 5.2 lists are the ones the root
#      docker-compose.yml publishes (D3: it listed pg 5432 and s3 9000)
#   CONTROLS:
#     a. the same command from a directory with no root `run` -> rc 127
#     b. a compose file that also publishes 5432 -> the port check fails
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0
SPEC="$APP_ROOT/csi-spl-doc/specs/148-local-dev-mode/spec.md"

# --- 1. the root link is tracked ----------------------------------------------------
ent=$(git -C "$APP_ROOT" ls-files -s -- run)
tgt=$(git -C "$APP_ROOT" cat-file -p "$(awk '{print $2}' <<<"$ent")" 2>/dev/null)
[[ "$ent" == 120000\ * && "$tgt" == csi-spl-orc/run ]] &&
  pass "1. root run is a tracked link to csi-spl-orc/run" || fail "1. root run in the index: '$ent' -> '$tgt'"

# --- 2. the documented command --------------------------------------------------------
cmd=$(awk '/^### 4.1 /{s=1} s && /^```bash/{getline; print; exit}' "$SPEC")
[[ "$cmd" == "./run -a do_dev_mode_up" ]] && pass "2. spec 148 4.1 documents '$cmd'" ||
  fail "2. spec 148 4.1 command: '$cmd'"
for d in DEPLOY.md CONTRIBUTING.md csi-spl-doc/doc/md/local-dev-mode-guide.md; do
  # the text joined into one line: a sentence may wrap anywhere
  txt=$(tr -s '\n ' '  ' <"$APP_ROOT/$d")
  grep -qF -- "./run -a do_dev_mode_up" <<<"$txt" && grep -qi 'root of [a-z ]*clone' <<<"$txt" &&
    pass "2. $d names the one-liner from the clone root" || fail "2. $d does not name it"
done

# --- 3. from the clone root it reaches the preflight --------------------------------
mkdir -p "$T/bin" "$T/norun"
cat >"$T/bin/docker" <<'D'
#!/usr/bin/env bash
echo "ARGS $*" >>"$DOCKER_LOG"
D
chmod +x "$T/bin/docker"
one_liner() {  # <dir>: the documented command run there; OUT + RC
  : >"$T/d.log"
  OUT=$(cd "$1" && env PATH="$T/bin:$PATH" DOCKER_LOG="$T/d.log" DEV_PREFLIGHT_UNAME_S=Plan9 \
    bash -c "$cmd" 2>&1)
  RC=$?
}
one_liner "$APP_ROOT"
[[ $RC == 1 ]] && grep -q '^ERROR: Unsupported operating system' <<<"$OUT" &&
  grep -q 'FATAL dev preflight check 1 failed' <<<"$OUT" && ! grep -q ' up ' "$T/d.log" &&
  pass "3. from the clone root: rc 1 at preflight check 1, compose up never runs" ||
  fail "3. rc $RC: $(tail -5 <<<"$OUT") / $(cat "$T/d.log")"
one_liner "$T/norun"
[[ $RC == 127 ]] && pass "a. no root run: rc 127 (the D2 defect)" || fail "a. no root run: rc $RC"

# --- 4. spec 148 5.2 host ports = the compose file's --------------------------------
compose_ports() {  # <compose file>: the default host port of every published port
  awk '/^ *ports:/{p=1; next} p && /^ *- /{print; next} {p=0}' "$1" |
    sed -nE 's/.*:-([0-9]+)\}:[0-9]+"?$/\1/p' | sort -n | tr '\n' ' '
}
spec_ports() {  # the ports spec 148 5.2 says the host gets
  awk '/^### 5.2 /{s=1} s && /Host ports/{h=1} h{print} h && /Mailpit UI/{exit}' "$SPEC" |
    sed 's/.*127\.0\.0\.1://' | grep -oE '\b[0-9]{4}\b' | sort -n | tr '\n' ' '
}
want=$(spec_ports)
got=$(compose_ports "$APP_ROOT/docker-compose.yml")
[[ -n "$want" && "$want" == "$got" ]] && pass "4. spec 148 5.2 host ports [$want] = docker-compose.yml" ||
  fail "4. spec 148 5.2 [$want] vs docker-compose.yml [$got]"
sed -E 's/^( *)- "127\.0\.0\.1:\$\{SPOOL_MAILPIT_UI_PORT:-8025\}:8025"/&\n\1- "127.0.0.1:${SPOOL_PG_PORT:-5432}:5432"/' \
  "$APP_ROOT/docker-compose.yml" >"$T/planted.yml"
got=$(compose_ports "$T/planted.yml")
[[ "$got" == *5432* && "$want" != "$got" ]] && pass "b. a compose file publishing 5432 fails the port check" ||
  fail "b. planted ports [$got] vs spec [$want]"

echo
[[ $fails -eq 0 ]] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
