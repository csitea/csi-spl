#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the three tf-infra entrypoints exit before sleep infinity when
#          setup fails (refactor round 3, row 15). Stubs stand in for poetry,
#          perl, git and sleep. No container is started.
#          1. tpl-gen: poetry exits 1 -> rc != 0 and a FATAL line
#          2. conf-validator: poetry exits 1 -> rc != 0 and a FATAL line
#          3. tpl-gen success -> rc 0 and the ~/.bashrc source + cd lines
#          4. conf-validator success -> rc 0 and the ~/.bashrc source + cd lines
#          5. tf-runner success -> rc 0 and the ~/.bashrc PATH + cd lines
#          6. tf-runner: a planted gsheet-secrets-to-gcp venv is not copied
#          CONTROL: HOME_IAC_PROJ_PATH unset -> tf-runner rc != 0
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
ORC=$(cd "$TEST_DIR/../../.." && pwd)
SCRIPTS="$ORC/src/bash/scripts"
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }

root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT
stub="$root/bin"
mkdir -p "$stub"

# Filter form (perl -ne on a pipe): identity, so a fixture path with no
# /home/$APPUSR prefix is unchanged. -pi form: success and do not edit a file.
cat >"$stub/perl" <<'EOF'
#!/bin/bash
if [[ "${1:-}" == -pi ]]; then
  exit 0
fi
cat
exit 0
EOF
cat >"$stub/git" <<'EOF'
#!/bin/bash
exit 0
EOF
cat >"$stub/sleep" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod +x "$stub/perl" "$stub/git" "$stub/sleep"

write_poetry() {
  printf '%s\n' '#!/bin/bash' 'touch "$HOME/poetry-ran"' "exit $1" >"$stub/poetry"
  chmod +x "$stub/poetry"
}

unset HOME_IAC_PROJ_PATH IAC_PROJ_PATH PROJ_PATH CNF_PROJ_PATH BASE_PATH APPUSR PROJ

# run_init <home> <script> [env(1) args...] -> writes <home>/rc and <home>/out
run_init() {
  local home=$1 script=$2 rc
  shift 2
  mkdir -p "$home"
  rm -f "$home/poetry-ran" "$home/.bashrc" "$home/.profile" "$home/out" "$home/rc"
  rc=0
  env HOME="$home" PATH="$stub:/usr/bin:/bin" "$@" \
    timeout 15 bash "$script" >"$home/out" 2>&1 || rc=$?
  printf '%s' "$rc" >"$home/rc"
}

mod_tree() {
  local base=$1 module=$2
  mkdir -p "$base/src/python/$module"
}

tpl="$SCRIPTS/docker-init-tpl-gen.sh"
cnf="$SCRIPTS/docker-init-conf-validator.sh"
tf="$SCRIPTS/docker-init-tf-runner.sh"

home="$root/tpl-fail"
proj="$root/proj-tpl-fail"
mod_tree "$proj" tpl-gen
write_poetry 1
run_init "$home" "$tpl" APPUSR=appusr PROJ_PATH="$proj"
rc=$(cat "$home/rc")
if [[ "$rc" != 0 ]] && grep -q 'FATAL poetry install' "$home/out" \
  && [[ -f "$home/poetry-ran" ]] && [[ ! -f "$home/.bashrc" ]]; then
  pass "tpl-gen: poetry failure exits before the keep-alive (rc $rc, FATAL)"
else
  fail "tpl-gen poetry failure (rc $rc): $(tr '\n' ' ' <"$home/out")"
fi

home="$root/cnf-fail"
proj="$root/proj-cnf-fail"
mod_tree "$proj" conf-validator
write_poetry 1
run_init "$home" "$cnf" APPUSR=appusr CNF_PROJ_PATH="$proj"
rc=$(cat "$home/rc")
if [[ "$rc" != 0 ]] && grep -q 'FATAL poetry install' "$home/out" \
  && [[ -f "$home/poetry-ran" ]] && [[ ! -f "$home/.bashrc" ]]; then
  pass "conf-validator: poetry failure exits before the keep-alive (rc $rc, FATAL)"
else
  fail "conf-validator poetry failure (rc $rc): $(tr '\n' ' ' <"$home/out")"
fi

home="$root/tpl-ok"
proj="$root/proj-tpl-ok"
mod_tree "$proj" tpl-gen
write_poetry 0
run_init "$home" "$tpl" APPUSR=appusr PROJ_PATH="$proj"
rc=$(cat "$home/rc")
if [[ "$rc" == 0 ]] && [[ -f "$home/poetry-ran" ]] \
  && grep -qF "source $proj/src/python/tpl-gen/.venv/bin/activate" "$home/.bashrc" \
  && grep -qF "cd $proj" "$home/.bashrc"; then
  pass "tpl-gen: poetry success stays up and writes the bashrc lines"
else
  fail "tpl-gen success (rc $rc): $(tr '\n' ' ' <"$home/out")"
fi

home="$root/cnf-ok"
proj="$root/proj-cnf-ok"
mod_tree "$proj" conf-validator
write_poetry 0
run_init "$home" "$cnf" APPUSR=appusr CNF_PROJ_PATH="$proj"
rc=$(cat "$home/rc")
if [[ "$rc" == 0 ]] && [[ -f "$home/poetry-ran" ]] \
  && grep -qF "source $proj/src/python/conf-validator/.venv/bin/activate" "$home/.bashrc" \
  && grep -qF "cd $proj" "$home/.bashrc"; then
  pass "conf-validator: poetry success stays up and writes the bashrc lines"
else
  fail "conf-validator success (rc $rc): $(tr '\n' ' ' <"$home/out")"
fi

home="$root/tf-ok"
proj="$root/proj-tf-ok"
mkdir -p "$proj"
write_poetry 0
run_init "$home" "$tf" APPUSR=appusr HOME_IAC_PROJ_PATH="$proj" IAC_PROJ_PATH="$proj"
rc=$(cat "$home/rc")
if [[ "$rc" == 0 ]] && [[ ! -f "$home/poetry-ran" ]] \
  && grep -qF 'export PATH=$PATH:$HOME/.local/bin/' "$home/.bashrc" \
  && grep -qF "cd $proj" "$home/.bashrc"; then
  pass "tf-runner: setup success stays up and writes the bashrc lines"
else
  fail "tf-runner success (rc $rc): $(tr '\n' ' ' <"$home/out")"
fi

home="$root/tf-unset"
proj="$root/proj-tf-unset"
mkdir -p "$proj" "$home"
rc=0
env -u HOME_IAC_PROJ_PATH HOME="$home" PATH="$stub:/usr/bin:/bin" \
  APPUSR=appusr IAC_PROJ_PATH="$proj" \
  timeout 15 bash "$tf" >"$home/out" 2>&1 || rc=$?
if [[ "$rc" != 0 ]] && [[ ! -f "$home/.bashrc" ]]; then
  pass "control: HOME_IAC_PROJ_PATH unset -> tf-runner rc $rc"
else
  fail "control HOME_IAC_PROJ_PATH unset (rc $rc): $(tr '\n' ' ' <"$home/out")"
fi

# B19: the start path must not copy a gsheet-secrets-to-gcp venv. The module
# is not in this tree, so a planted tree is the case that used to be a no-op
# only because the directory was absent.
home="$root/tf-nogs"
proj="$root/proj-tf-nogs"
mount="$root/mount-tf-nogs"
mkdir -p "$proj/src/python/gsheet-secrets-to-gcp/.venv/bin" "$mount"
printf '%s\n' 'echo planted' >"$proj/src/python/gsheet-secrets-to-gcp/.venv/bin/activate"
write_poetry 0
run_init "$home" "$tf" APPUSR=appusr HOME_IAC_PROJ_PATH="$proj" IAC_PROJ_PATH="$mount"
rc=$(cat "$home/rc")
copied=no
[[ -e "$mount/src/python/gsheet-secrets-to-gcp" ]] && copied=yes
if [[ "$rc" == 0 && "$copied" == no ]] \
  && ! grep -q 'gsheet-secrets-to-gcp' "$tf" \
  && grep -qF 'export PATH=$PATH:$HOME/.local/bin/' "$home/.bashrc" \
  && grep -qF "cd $proj" "$home/.bashrc"; then
  pass "tf-runner: start path does not copy a gsheet-secrets-to-gcp venv"
else
  fail "tf-runner gsheet venv (rc $rc, copied=$copied): $(tr '\n' ' ' <"$home/out")"
fi

echo "fails=$fails"
exit $(( fails > 0 ))
