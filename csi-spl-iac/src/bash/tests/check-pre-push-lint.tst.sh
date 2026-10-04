#!/usr/bin/env bash
# serial
# The lint() calls in this file take about a minute on their own. Run beside
# three other tests, that crosses the suite's 120s kill, so it runs alone.
#------------------------------------------------------------------------------
# Purpose: the LINT parts of do_check_pre_push (check-pre-push-lint.func.sh)
#          run CI's scanner actions on the TOUCHED files and block a new
#          finding, but never a finding in a file the push does not touch.
#   1. a pushed .sh with an SC1087 error is REFUSED (PART lint-shellcheck FAIL)
#   2. a clean pushed .sh passes, although an UNTOUCHED file carries a finding
#   3. a touched file whose finding is already on the base -> WARN, not blocking
#   4. a missing shellcheck is a FAIL naming do_install_lint_tools, not a skip
#   5. a broken .json is a lint-syntax FAIL
#   6. routing: workflow -> actionlint, Dockerfile -> hadolint, wui .mjs ->
#      eslint, a hub .sh -> syntax but not shellcheck (not CI 67's scope), the
#      action sec-shellcheck itself -> its whole scope (ALL)
#   7. the FAIL prints the exact command that reproduces the finding
#   8. with the REAL shellcheck (when installed): SC1087 refused, clean passes
#   9. PRE_PUSH_LINT=0 skips every lint part (the rollback), and says so
#  10. an extension-less #!/bin/bash script with a syntax error -> lint-syntax FAIL
#  11. a touched .md with a broken relative link -> lint-mdlinks FAIL
#  12. deleting a file an UNTOUCHED .md links to -> lint-mdlinks FAIL (referrer)
#  13. typos (real binary, when installed): a typo on an ADDED line WARNs and
#      never blocks; the same typo on an untouched line is not reported
#  14. a YAML duplicate key (yq/jq accept it) is a lint-syntax FAIL
#  15. editing a migration that is already on the base is a lint-migration
#      FAIL; SPL_MIGRATION_EDIT_OK=<file> allows it; a NEW one passes
#  16. a new migration that is not PG16 SQL -> FAIL (pglast, when installed)
#  23. migration prefixes (spec 072 A45): a copied prefix is REFUSED naming
#      both files; a new file below the head (a late 0002 past 0003) or one
#      that skips a number is REFUSED; the grandfathered 0021 pair passes and
#      a third 0021 does not
#  17. a docker-compose file with an unknown service key -> lint-compose FAIL
#      (when docker compose is installed)
#  20. lint-py (real ruff, when installed): an undefined name in a new .py,
#      and a python heredoc that does not compile in a .sh, are REFUSED
#  21. lint-tf (real terraform, when installed): an unformatted .tf and a
#      .tfvars that does not parse are REFUSED; a formatted .tf passes
#  22. lint-sigpipe: a pushed .sh with `| grep -q` under pipefail is REFUSED
#      and names its reproduce command; the fixed form passes
#  18. a .vue whose TEMPLATE does not compile -> lint-wui-syntax FAIL; a clean
#      one passes (when this checkout's csi-spl-wui/node_modules exists)
#   Scanners are stubs on PATH (hermetic: the CI runner has no shellcheck);
#   leg 8 uses the real binary that do_install_lint_tools puts on the box.
#------------------------------------------------------------------------------
set -uo pipefail
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_QUARANTINE_PATH GIT_COMMON_DIR GIT_PREFIX 2>/dev/null || true
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
RUN_DIR=$(cd "$TEST_DIR/../run" && pwd)

fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1 -- ${2:-}"; fails=$((fails + 1)); }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
REAL_SC="$(command -v shellcheck 2>/dev/null || true)"
[[ -z "$REAL_SC" && -x "$HOME/.local/bin/shellcheck" ]] && REAL_SC="$HOME/.local/bin/shellcheck"

# --- stub scanners --------------------------------------------------------
STUB="$T/stub"; mkdir -p "$STUB"
# The shellcheck stub flags the control, and any "$name[" (SC1087) in a scanned file.
cat >"$STUB/shellcheck" <<'EOF'
#!/usr/bin/env bash
[[ "${SEC_SHELLCHECK_PHASE:-}" == control ]] && { echo "bad.sh:2:1: error: glob [SC2144]"; exit 1; }
rc=0
for f in "$@"; do
  [[ -f "$f" ]] || continue
  if grep -qE '"\$[A-Za-z_]+\[' "$f"; then echo "$f:1:1: error: braces [SC1087]"; rc=1; fi
done
exit $rc
EOF
cat >"$STUB/gitleaks" <<'EOF'
#!/usr/bin/env bash
[[ "${SEC_SCAN_PHASE:-}" == control ]] && { echo "leaks found: 1"; exit 1; }
exit 0
EOF
cat >"$STUB/semgrep" <<'EOF'
#!/usr/bin/env bash
[[ "${SEC_SEMGREP_PHASE:-}" == control ]] && { echo '{"results":[{"check_id":"control-eval"}]}'; exit 1; }
echo '{"results":[]}'
EOF
cat >"$STUB/trufflehog" <<'EOF'
#!/usr/bin/env bash
[[ "${SEC_TRUFFLEHOG_PHASE:-}" == control ]] && echo '{"DetectorName":"AWS"}'
exit 0
EOF
chmod +x "$STUB"/*
# yq/jq/python3 are real (/usr/bin, /usr/local/bin); shellcheck only via STUB.
BASE_PATH="$STUB:/usr/local/bin:/usr/bin:/bin"

do_log() { echo "$*"; }
do_check_dist_hygiene() { return 0; }
# shellcheck source=../run/sec-shellcheck.func.sh
. "$RUN_DIR/sec-shellcheck.func.sh"
# shellcheck source=../run/sec-trufflehog.func.sh
. "$RUN_DIR/sec-trufflehog.func.sh"
# shellcheck source=../run/sec-semgrep.func.sh
. "$RUN_DIR/sec-semgrep.func.sh"
# shellcheck source=../run/sec-scan.func.sh
. "$RUN_DIR/sec-scan.func.sh"
# shellcheck source=../run/check-pre-push.func.sh
. "$RUN_DIR/check-pre-push.func.sh"

# A repo whose base carries an UNTOUCHED script with a finding.
R="$T/repo"; SH="csi-spl-orc/src/bash/run"
new_repo() {
  rm -rf "$R"; mkdir -p "$R/$SH" "$R/csi-spl-api/src/bash"
  git -C "$R" init -q
  printf '#!/bin/bash\narr=(a b)\necho "$arr[1]"\n' >"$R/$SH/old-bad.sh"
  printf '#!/bin/bash\necho ok\n' >"$R/$SH/edited.sh"
  echo '{}' >"$R/seed.json"
  echo 'title = "x"' >"$R/.gitleaks.toml"
  echo '# rule|path|count' >"$R/.semgrep-baseline.txt"
  echo '# code|path|count' >"$R/.shellcheck-warning-baseline.txt"
  git -C "$R" add -A; git -C "$R" commit -qm seed; git -C "$R" branch -f base
}
commit() { git -C "$R" add -A; git -C "$R" commit -qm "$1"; }

# Run the lint parts; echo "rc|<verdict lines>".
LOG="$T/pre-push.log"
lint() {
  : >"$LOG"
  local out rc=0
  out="$(PATH="${PP_PATH:-$BASE_PATH}" PRE_PUSH_EXTRA_PATH='' PRE_PUSH_ONLY=lint PRE_PUSH_TREE="$R" \
    PRE_PUSH_BASE=base PRE_PUSH_LOG="$LOG" PRE_PUSH_NO_CACHE=1 PRE_PUSH_CACHE="$T/cache" \
    do_check_pre_push 2>&1)" || rc=$?
  printf '%s\n' "$out" >"$T/out"
  echo "$rc"
}
verdict() { sed -nE "s/.* PART $1 ([A-Za-z-]+) .*/\\1/p" "$LOG" | tail -1; }

# 1. a new .sh with SC1087 is refused
new_repo
printf '#!/bin/bash\narr=(a b)\necho "$arr[0]"\n' >"$R/$SH/new-bad.sh"; commit bad
rc="$(lint)"
[[ "$rc" == 1 && "$(verdict lint-shellcheck)" == FAIL ]] \
  && pass "1. SC1087 in a pushed .sh is REFUSED" || fail "1. SC1087 refused" "rc=$rc verdict=$(verdict lint-shellcheck)"
# 7. ... and the FAIL names the command that reproduces it
grep -q "SEC_SHELLCHECK_FILES=.*$SH/new-bad.sh.*do_sec_shellcheck" "$T/out" \
  && pass "7. the FAIL prints the reproduce command" || fail "7. reproduce command" "$(grep -m1 reproduce "$T/out")"

# 2. a clean new .sh passes; the untouched old-bad.sh is not scanned
new_repo
printf '#!/bin/bash\necho "${arr[0]:-}"\n' >"$R/$SH/new-good.sh"; commit good
rc="$(lint)"
[[ "$rc" == 0 && "$(verdict lint-shellcheck)" == PASS ]] \
  && pass "2. a clean .sh passes; an untouched file's finding does not block" \
  || fail "2. clean passes" "rc=$rc verdict=$(verdict lint-shellcheck) $(grep -m2 -E 'SC1087|FATAL' "$T/out")"

# 3. editing a file whose finding is already on base -> WARN-pre-existing
new_repo
echo '# touched' >>"$R/$SH/old-bad.sh"; commit touch-old
rc="$(lint)"
[[ "$rc" == 0 && "$(verdict lint-shellcheck)" == WARN-pre-existing ]] \
  && pass "3. a pre-existing finding in a touched file WARNs, not blocks" \
  || fail "3. pre-existing WARN" "rc=$rc verdict=$(verdict lint-shellcheck)"

# 4. no shellcheck on PATH -> FAIL naming the installer
new_repo
printf '#!/bin/bash\necho ok\n' >"$R/$SH/edited.sh"; echo '# x' >>"$R/$SH/edited.sh"; commit edit
NOSC="$T/nosc"; mkdir -p "$NOSC"; cp "$STUB/trufflehog" "$NOSC/"
cp "$STUB/gitleaks" "$NOSC/"
rc="$(PP_PATH="$NOSC:/usr/local/bin:/usr/bin:/bin" lint)"
if command -v -p shellcheck >/dev/null 2>&1 || [[ -x /usr/local/bin/shellcheck ]]; then
  pass "4. (system shellcheck present; missing-tool leg not applicable on this host)"
else
  [[ "$rc" == 1 && "$(verdict lint-shellcheck)" == FAIL ]] && grep -q 'do_install_lint_tools' "$T/out" \
    && pass "4. a missing shellcheck is a FAIL naming do_install_lint_tools" \
    || fail "4. missing tool FAILs" "rc=$rc verdict=$(verdict lint-shellcheck)"
fi

# 5. broken JSON -> lint-syntax FAIL
new_repo
echo '{ "a": ' >"$R/broken.json"; commit json
rc="$(lint)"
[[ "$rc" == 1 && "$(verdict lint-syntax)" == FAIL ]] \
  && pass "5. a broken .json is a lint-syntax FAIL" || fail "5. json syntax" "rc=$rc verdict=$(verdict lint-syntax)"

# 9. PRE_PUSH_LINT=0: the one-variable rollback skips the lint parts, loudly
new_repo
printf '#!/bin/bash\narr=(a b)\necho "$arr[0]"\n' >"$R/$SH/new-bad.sh"; commit bad
rc="$(PRE_PUSH_LINT=0 lint)"
[[ "$rc" == 0 ]] && grep -q 'PRE_PUSH_LINT=0' "$T/out" \
  && pass "9. PRE_PUSH_LINT=0 skips the lint parts and says so" || fail "9. kill switch" "rc=$rc"

# 10. an extension-less shell script is syntax-checked
new_repo
printf '#!/bin/bash\nif true; then\n' >"$R/$SH/hook"; commit hook
rc="$(lint)"
[[ "$rc" == 1 && "$(verdict lint-syntax)" == FAIL ]] \
  && pass "10. an extension-less #!/bin/bash script is bash -n checked" || fail "10. shebang syntax" "rc=$rc verdict=$(verdict lint-syntax)"

# 11. broken relative link in a touched .md
new_repo
mkdir -p "$R/doc"; printf '# x\n\nsee [it](./nope.md)\n' >"$R/doc/a.md"; commit md
rc="$(lint)"
[[ "$rc" == 1 && "$(verdict lint-mdlinks)" == FAIL ]] && grep -q 'broken relative link' "$T/out" \
  && pass "11. a broken relative link in a touched .md is a FAIL" || fail "11. mdlinks" "rc=$rc verdict=$(verdict lint-mdlinks)"

# 12. a deleted target breaks an untouched referrer
new_repo
mkdir -p "$R/doc"; echo t >"$R/doc/target.md"; printf 'see [t](./target.md)\n' >"$R/doc/index.md"
git -C "$R" add -A; git -C "$R" commit -qm docs; git -C "$R" branch -f base
git -C "$R" rm -q "$R/doc/target.md"; git -C "$R" commit -qm rm
rc="$(lint)"
[[ "$rc" == 1 && "$(verdict lint-mdlinks)" == FAIL ]] \
  && pass "12. deleting a linked-to file fails the untouched .md that links to it" || fail "12. referrer" "rc=$rc verdict=$(verdict lint-mdlinks)"

# 13. typos: WARN on an added line only, never a block
REAL_TY="$(command -v typos 2>/dev/null || true)"
[[ -z "$REAL_TY" && -x "$HOME/.local/bin/typos" ]] && REAL_TY="$HOME/.local/bin/typos"
if [[ -n "$REAL_TY" ]]; then
  TY="$T/ty"; mkdir -p "$TY"; ln -sf "$REAL_TY" "$TY/typos"; cp "$STUB/"* "$TY/"
  new_repo
  mkdir -p "$R/doc"; printf 'old line wheather\n' >"$R/doc/n.md"
  git -C "$R" add -A; git -C "$R" commit -qm seedtypo; git -C "$R" branch -f base
  printf 'new line recieve\n' >>"$R/doc/n.md"; commit addtypo
  rc="$(PP_PATH="$TY:/usr/local/bin:/usr/bin:/bin" lint)"
  { [[ "$rc" == 0 && "$(verdict lint-typos)" == WARN-typos ]] && grep -q 'recieve' "$T/out" && ! grep -q 'wheather' "$T/out"; } \
    && pass "13. typos WARNs on the added line only, and does not block" \
    || fail "13. typos added-lines WARN" "rc=$rc verdict=$(verdict lint-typos)"
else
  echo "INFO: no typos binary on this host -- leg 13 not run (./run -a do_install_lint_tools)"
fi

# 14. YAML duplicate key
new_repo
printf 'a: 1\nb: 2\na: 3\n' >"$R/dup.yaml"; commit dup
rc="$(lint)"
[[ "$rc" == 1 && "$(verdict lint-syntax)" == FAIL ]] && grep -q 'duplicate key' "$T/out" \
  && pass "14. a YAML duplicate key is a lint-syntax FAIL" || fail "14. dup key" "rc=$rc verdict=$(verdict lint-syntax)"

# 15. migrations are forward-only
MIG="csi-spl-rdb/src/sql/postgres/spool-hub"
mig_repo() {
  new_repo; mkdir -p "$R/$MIG"
  printf 'CREATE TABLE a (id int);\n' >"$R/$MIG/0001_a.sql"
  git -C "$R" add -A; git -C "$R" commit -qm mig; git -C "$R" branch -f base
}
# The forward-only legs need no parser: where pglast is not installed (CI),
# a stand-in python that accepts everything satisfies the tool check.
PGPY="${XDG_CACHE_HOME:-$HOME/.cache}/csi-spl/lint-venv-pglast/bin/python"
MIG_CACHE="${XDG_CACHE_HOME:-$HOME/.cache}"
if [[ ! -x "$PGPY" ]]; then
  MIG_CACHE="$T/xdg"; mkdir -p "$MIG_CACHE/csi-spl/lint-venv-pglast/bin"
  printf '#!/bin/sh\nexit 0\n' >"$MIG_CACHE/csi-spl/lint-venv-pglast/bin/python"; chmod +x "$MIG_CACHE/csi-spl/lint-venv-pglast/bin/python"
fi
mig_repo; printf -- '-- changed\n' >>"$R/$MIG/0001_a.sql"; commit edit-mig
export XDG_CACHE_HOME_SAVED="${XDG_CACHE_HOME:-}"; export XDG_CACHE_HOME="$MIG_CACHE"
rc="$(lint)"
[[ "$rc" == 1 && "$(verdict lint-migration)" == FAIL ]] && grep -q 'add a NEW NNNN file' "$T/out" \
  && pass "15a. editing a migration already on the base is REFUSED" || fail "15a. migration edit" "rc=$rc verdict=$(verdict lint-migration)"
rc="$(SPL_MIGRATION_EDIT_OK="$MIG/0001_a.sql" lint)"
[[ "$(verdict lint-migration)" != FAIL ]] \
  && pass "15b. SPL_MIGRATION_EDIT_OK=<file> allows that one edit" || fail "15b. edit ok" "rc=$rc verdict=$(verdict lint-migration)"
mig_repo; git -C "$R" rm -q "$R/$MIG/0001_a.sql"; commit rm-mig
rc="$(lint)"
[[ "$rc" == 1 && "$(verdict lint-migration)" == FAIL ]] \
  && pass "15c. deleting a migration already on the base is REFUSED" || fail "15c. migration delete" "rc=$rc verdict=$(verdict lint-migration)"

# 23. migration prefixes (spec 072 A45)
mig_repo; cp "$R/$MIG/0001_a.sql" "$R/$MIG/0001_x.sql"; commit copy-mig
rc="$(lint)"
[[ "$rc" == 1 && "$(verdict lint-migration)" == FAIL ]] && grep -q 'prefix 0001 is taken by more than one file: 0001_a.sql 0001_x.sql' "$T/out" \
  && pass "23a. a copied migration prefix is REFUSED, naming both files" || fail "23a. dup prefix" "rc=$rc verdict=$(verdict lint-migration)"
# 23b-e call the rule itself: a whole lint run per leg pushed this file past
# run-all-tests' 120 s ceiling on a loaded box.
prefixes() { _ppl_migration_prefixes "$R" base >"$T/out" 2>&1; }
mig_repo; printf 'CREATE TABLE c (id int);\n' >"$R/$MIG/0003_c.sql"; commit hole; git -C "$R" branch -f base
printf 'CREATE TABLE b (id int);\n' >"$R/$MIG/0002_b.sql"; commit late-mig
! prefixes && grep -q '0002_b.sql is new but its prefix is not 0004' "$T/out" \
  && pass "23b. a new migration below the head (a late 0002) is REFUSED" || fail "23b. below head" "$(cat "$T/out")"
mig_repo; printf 'CREATE TABLE c (id int);\n' >"$R/$MIG/0003_c.sql"; commit skip-mig
! prefixes && grep -q '0003_c.sql is new but its prefix is not 0002' "$T/out" \
  && pass "23c. a new migration that skips a prefix is REFUSED" || fail "23c. skip" "$(cat "$T/out")"
mig_repo
printf 'SELECT 1;\n' >"$R/$MIG/0021_rls_fail_closed.sql"; printf 'SELECT 1;\n' >"$R/$MIG/0021_tenant_rbac.sql"
commit pair; git -C "$R" branch -f base
printf 'SELECT 1;\n' >"$R/$MIG/0022_n.sql"; printf 'SELECT 1;\n' >"$R/$MIG/0023_m.sql"; commit next-mig
prefixes && pass "23d. the grandfathered 0021 pair + new 0022, 0023 pass" || fail "23d. grandfathered" "$(cat "$T/out")"
printf 'SELECT 1;\n' >"$R/$MIG/0021_third.sql"; commit third
! prefixes && grep -q 'prefix 0021 is taken' "$T/out" \
  && pass "23e. a third 0021 is REFUSED (the pair is grandfathered by name)" || fail "23e. third 0021" "$(cat "$T/out")"
if [[ -n "$XDG_CACHE_HOME_SAVED" ]]; then export XDG_CACHE_HOME="$XDG_CACHE_HOME_SAVED"; else unset XDG_CACHE_HOME; fi
if [[ -x "$PGPY" ]]; then
  mig_repo; printf 'CREATE TABLE b (id int);\n' >"$R/$MIG/0002_b.sql"; commit new-mig
  rc="$(lint)"
  [[ "$rc" == 0 && "$(verdict lint-migration)" == PASS ]] \
    && pass "15d. a NEW valid migration passes" || fail "15d. new migration" "rc=$rc verdict=$(verdict lint-migration)"
  mig_repo; printf 'CREATE TABLE c (id int,;\n' >"$R/$MIG/0002_c.sql"; commit bad-mig
  rc="$(lint)"
  [[ "$rc" == 1 && "$(verdict lint-migration)" == FAIL ]] && grep -q 'PG16 parse' "$T/out" \
    && pass "16. a new migration that is not PG16 SQL is a FAIL" || fail "16. pg parse" "rc=$rc verdict=$(verdict lint-migration)"
else
  echo "INFO: no pglast venv on this host -- legs 15d/16 not run (./run -a do_install_lint_tools)"
fi

# 17. compose schema
if docker compose version >/dev/null 2>&1; then
  new_repo
  printf 'services:\n  a:\n    image: busybox\n    portz: ["1:1"]\n' >"$R/docker-compose.yml"; commit compose
  rc="$(PP_PATH="$STUB:$(dirname "$(command -v docker)"):/usr/local/bin:/usr/bin:/bin" lint)"
  [[ "$rc" == 1 && "$(verdict lint-compose)" == FAIL ]] \
    && pass "17. a compose file with an unknown key is a lint-compose FAIL" || fail "17. compose" "rc=$rc verdict=$(verdict lint-compose)"
else
  echo "INFO: no docker compose on this host -- leg 17 not run"
fi

# 18. Vue SFC compile
WUI_NM="$(cd "$TEST_DIR/../../../.." && pwd)/csi-spl-wui/node_modules"
if [[ -d "$WUI_NM/vue" && -d "$WUI_NM/typescript" ]] && _pp_pnpm >/dev/null; then
  NODE_DIR="$(dirname "$(command -v node)")"
  wui_repo() { new_repo; mkdir -p "$R/csi-spl-wui/src"; ln -s "$WUI_NM" "$R/csi-spl-wui/node_modules"; echo '{}' >"$R/csi-spl-wui/package.json"
    printf 'node_modules\n' >"$R/.gitignore"; git -C "$R" add -A; git -C "$R" commit -qm wui; git -C "$R" branch -f base; }
  wui_repo
  printf '<template>\n  <p v-if="a">x</p>\n  <p v-else-if>bad</p>\n</template>\n<script setup lang="ts">\nconst a = true\n</script>\n' >"$R/csi-spl-wui/src/Bad.vue"; commit badvue
  rc="$(PP_PATH="$STUB:$NODE_DIR:/usr/local/bin:/usr/bin:/bin" lint)"
  [[ "$rc" == 1 && "$(verdict lint-wui-syntax)" == FAIL ]] && grep -q 'template:' "$T/out" \
    && pass "18a. a .vue template that does not compile is REFUSED" || fail "18a. sfc" "rc=$rc verdict=$(verdict lint-wui-syntax)"
  wui_repo
  printf '<template>\n  <p v-if="a">x</p>\n  <p v-else>y</p>\n</template>\n<script setup lang="ts">\nconst a: boolean = true\n</script>\n' >"$R/csi-spl-wui/src/Good.vue"; commit goodvue
  rc="$(PP_PATH="$STUB:$NODE_DIR:/usr/local/bin:/usr/bin:/bin" lint)"
  [[ "$rc" == 0 && "$(verdict lint-wui-syntax)" == PASS ]] \
    && pass "18b. a clean .vue passes" || fail "18b. sfc clean" "rc=$rc verdict=$(verdict lint-wui-syntax) $(grep -m3 -E 'Good|FATAL' "$T/out")"
else
  echo "INFO: no csi-spl-wui/node_modules (vue + typescript) or no pnpm here -- leg 18 not run"
fi

# 19. a whole-scope part's cache key follows the tree (it once was constant)
new_repo
declare -A _PPL_FILES=([lint-gitleaks]=ALL)
k1="$(_pp_key "$R" lint-gitleaks fast)"
echo y >"$R/seed2.txt"; commit another
k2="$(_pp_key "$R" lint-gitleaks fast)"
[[ -n "$k1" && -n "$k2" && "$k1" != "$k2" ]] \
  && pass "19. a whole-scope lint part's green verdict is keyed by the tree, not reused across trees" \
  || fail "19. whole-scope cache key" "k1=$k1 k2=$k2"
unset _PPL_FILES

# 20. lint-py
REAL_RUFF="$(command -v ruff 2>/dev/null || true)"
[[ -z "$REAL_RUFF" && -x "$HOME/.local/bin/ruff" ]] && REAL_RUFF="$HOME/.local/bin/ruff"
if [[ -n "$REAL_RUFF" ]]; then
  RF="$T/rf"; mkdir -p "$RF"; ln -sf "$REAL_RUFF" "$RF/ruff"; cp "$STUB/"* "$RF/"
  new_repo
  printf 'import os\nprint(undefined_name)\n' >"$R/csi-spl-orc/src/bash/run/p.py"; commit py
  rc="$(PP_PATH="$RF:/usr/local/bin:/usr/bin:/bin" lint)"
  [[ "$rc" == 1 && "$(verdict lint-py)" == FAIL ]] && grep -q 'F821' "$T/out" \
    && pass "20a. an undefined name in a pushed .py is REFUSED (ruff F821)" || fail "20a. ruff" "rc=$rc verdict=$(verdict lint-py)"
  new_repo
  printf '#!/bin/bash\npython3 - <<'"'"'PY'"'"'\nif True print(1)\nPY\n' >"$R/$SH/h.sh"; commit heredoc
  rc="$(PP_PATH="$RF:/usr/local/bin:/usr/bin:/bin" lint)"
  [[ "$rc" == 1 && "$(verdict lint-py)" == FAIL ]] \
    && pass "20b. a python heredoc that does not compile in a .sh is REFUSED" || fail "20b. heredoc" "rc=$rc verdict=$(verdict lint-py)"
else
  echo "INFO: no ruff on this host -- leg 20 not run (./run -a do_install_lint_tools)"
fi

# 21. lint-tf
REAL_TF="$(command -v terraform 2>/dev/null || true)"
[[ -z "$REAL_TF" && -x "$HOME/.local/bin/terraform" ]] && REAL_TF="$HOME/.local/bin/terraform"
if [[ -n "$REAL_TF" ]]; then
  TFB="$T/tfb"; mkdir -p "$TFB"; ln -sf "$REAL_TF" "$TFB/terraform"; cp "$STUB/"* "$TFB/"
  TFD="csi-spl-iac/src/terraform/x"
  new_repo; mkdir -p "$R/$TFD"; printf 'variable "a" {\ntype=string\n}\n' >"$R/$TFD/main.tf"; commit tf
  rc="$(PP_PATH="$TFB:/usr/local/bin:/usr/bin:/bin" lint)"
  [[ "$rc" == 1 && "$(verdict lint-tf)" == FAIL ]] \
    && pass "21a. an unformatted .tf is REFUSED (terraform fmt -check)" || fail "21a. tf fmt" "rc=$rc verdict=$(verdict lint-tf)"
  new_repo; mkdir -p "$R/$TFD"; printf 'a = "x\n' >"$R/$TFD/v.tfvars"; commit tfvars
  rc="$(PP_PATH="$TFB:/usr/local/bin:/usr/bin:/bin" lint)"
  [[ "$rc" == 1 && "$(verdict lint-tf)" == FAIL ]] && grep -q 'HCL parse' "$T/out" \
    && pass "21b. a .tfvars that does not parse is REFUSED" || fail "21b. tfvars" "rc=$rc verdict=$(verdict lint-tf)"
  new_repo; mkdir -p "$R/$TFD"; printf 'variable "a" {\n  type = string\n}\n' >"$R/$TFD/main.tf"; commit tfok
  rc="$(PP_PATH="$TFB:/usr/local/bin:/usr/bin:/bin" lint)"
  [[ "$rc" == 0 && "$(verdict lint-tf)" == PASS ]] \
    && pass "21c. a formatted .tf passes" || fail "21c. tf ok" "rc=$rc verdict=$(verdict lint-tf)"
else
  echo "INFO: no terraform on this host -- leg 21 not run (./run -a do_install_lint_tools)"
fi

# 22. lint-sigpipe
new_repo
printf '#!/bin/bash\nset -o pipefail\nls | grep -q x && echo y\n' >"$R/$SH/pipe.sh"; commit sigpipe
rc="$(lint)"
[[ "$rc" == 1 && "$(verdict lint-sigpipe)" == FAIL ]] && grep -q "sigpipe-lint.sh $SH/pipe.sh" "$T/out" \
  && pass "22a. | grep -q under pipefail in a pushed .sh is a lint-sigpipe FAIL" || fail "22a. sigpipe" "rc=$rc verdict=$(verdict lint-sigpipe)"
printf '#!/bin/bash\nset -o pipefail\nls | grep x >/dev/null && echo y\n' >"$R/$SH/pipe.sh"; commit sigpipe-fix
rc="$(lint)"
[[ "$(verdict lint-sigpipe)" == PASS ]] \
  && pass "22b. the fixed form passes lint-sigpipe" || fail "22b. sigpipe fixed" "rc=$rc verdict=$(verdict lint-sigpipe)"

# 6. routing (the planner alone)
plan_of() {  # <changed-files...>
  local -A _PPL_FILES=()
  local _PPL_SELECTED=""
  _ppl_plan "$(printf '%s\n' "$@")" fast fast "$R"
  echo "$_PPL_SELECTED"
}
new_repo
mkdir -p "$R/.github/workflows" "$R/csi-spl-orc/src/docker/x" "$R/csi-spl-wui/src/lib" "$R/csi-spl-iac/src/bash/run"
mkdir -p "$R/csi-spl-wui"; echo '{}' >"$R/csi-spl-wui/package.json"
for f in .github/workflows/a.yml csi-spl-orc/src/docker/x/Dockerfile csi-spl-wui/src/lib/a.mjs \
         csi-spl-api/src/bash/h.sh csi-spl-iac/src/bash/run/sec-shellcheck.func.sh; do echo x >"$R/$f"; done
p="$(plan_of .github/workflows/a.yml)";              [[ " $p " == *" lint-actionlint "* ]] && pass "6a. workflow -> actionlint" || fail "6a" "$p"
p="$(plan_of csi-spl-orc/src/docker/x/Dockerfile)";  [[ " $p " == *" lint-hadolint "* ]]   && pass "6b. Dockerfile -> hadolint" || fail "6b" "$p"
p="$(plan_of csi-spl-wui/src/lib/a.mjs)";            [[ " $p " == *" lint-eslint "* ]]     && pass "6c. wui .mjs -> eslint" || fail "6c" "$p"
p="$(plan_of csi-spl-api/src/bash/h.sh)"
[[ " $p " == *" lint-syntax "* && " $p " != *" lint-shellcheck "* ]] && pass "6d. hub .sh -> syntax, not shellcheck (not CI 67 scope)" || fail "6d" "$p"
declare -A _PPL_FILES=()
_ppl_plan "csi-spl-iac/src/bash/run/sec-shellcheck.func.sh" fast fast "$R" >/dev/null
[[ "${_PPL_FILES[lint-shellcheck]:-}" == ALL ]] && pass "6e. the shellcheck action changed -> its whole scope" || fail "6e" "${_PPL_FILES[lint-shellcheck]:-none}"
p="$(plan_of csi-spl-wui/package.json)"; [[ " $p " == *" lint-wui-lock "* ]] && pass "6g. wui package.json -> lockfile drift" || fail "6g" "$p"
mkdir -p "$R/csi-spl-api/src/go/spool-hub-api"; echo 'package x' >"$R/csi-spl-api/src/go/spool-hub-api/x.go"; echo 'module x' >"$R/csi-spl-api/src/go/spool-hub-api/go.mod"
p="$(plan_of csi-spl-api/src/go/spool-hub-api/x.go)"; [[ " $p " == *" lint-semgrep "* && " $p " != *" lint-gomod "* ]] && pass "6h. a hub .go -> semgrep on that file" || fail "6h" "$p"
p="$(plan_of csi-spl-api/src/go/spool-hub-api/go.mod)"; [[ " $p " == *" lint-gomod "* ]] && pass "6i. go.mod -> go mod tidy -diff" || fail "6i" "$p"
mkdir -p "$R/csi-spl-wui/tests/e2e"; echo x >"$R/csi-spl-wui/tests/e2e/a.test.mjs"
p="$(plan_of csi-spl-wui/tests/e2e/a.test.mjs)"; [[ " $p " == *" lint-tmp-path "* ]] && pass "6j. an e2e test -> lint-tmp-path" || fail "6j" "$p"
p="$(plan_of doc/readme.md)"
[[ " $p " != *" lint-shellcheck "* && " $p " != *" lint-syntax "* ]] && pass "6f. a doc-only push runs no scanner but trufflehog" || fail "6f" "$p"
unset _PPL_FILES

# 8. the REAL shellcheck, when installed
if [[ -n "$REAL_SC" ]]; then
  REAL="$T/real"; mkdir -p "$REAL"; ln -s "$REAL_SC" "$REAL/shellcheck"; cp "$STUB/trufflehog" "$STUB/gitleaks" "$REAL/"
  new_repo
  printf '#!/bin/bash\narr=(a b)\necho "$arr[0]"\n' >"$R/$SH/new-bad.sh"; commit bad
  rc="$(PP_PATH="$REAL:/usr/local/bin:/usr/bin:/bin" lint)"
  [[ "$rc" == 1 ]] && grep -q 'SC1087' "$T/out" \
    && pass "8a. real shellcheck: SC1087 refused" || fail "8a. real SC1087" "rc=$rc"
  new_repo
  printf '#!/bin/bash\narr=(a b)\necho "${arr[0]}"\n' >"$R/$SH/new-good.sh"; commit good
  rc="$(PP_PATH="$REAL:/usr/local/bin:/usr/bin:/bin" lint)"
  [[ "$rc" == 0 ]] && pass "8b. real shellcheck: clean passes, untouched finding ignored" || fail "8b. real clean" "rc=$rc $(grep -m3 SC "$T/out")"
else
  echo "INFO: no real shellcheck on this host -- leg 8 not run (./run -a do_install_lint_tools)"
fi

echo "-- check-pre-push-lint.tst.sh: $fails failed"
[ "$fails" -eq 0 ]
