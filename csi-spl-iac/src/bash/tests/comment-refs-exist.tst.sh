#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: a comment in production bash that names a *.sh or *.tst.sh file
#          names one `git ls-files` contains. The basename is what is checked,
#          so a path and a bare name are the same question.
#          Allow-list:
#            external programs and other repos (dockerd-rootless-setuptool.sh,
#            and csi-rel's verify-api-health.sh)
#            shape tokens that are not files (func.sh, kebab-case.func.sh,
#            node-jira-bind.func.sh, sN.sh)
#            KNOWN pins: a missing name cited only from a file this row does
#            not own. The same name in any other file fails. A pin the scan
#            no longer sees is a NOTE, so the list can shrink.
#          A comment ending in "-" is joined to the next comment (a repeated
#          @tag on that next line is dropped) so a wrap is one basename.
#          *.func.sh globs are not names. Tests are not production.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

# External: not a file of this repo.
EXTERNAL=(
  dockerd-rootless-setuptool.sh
  verify-api-health.sh
)

# A calling convention or a filename shape, not a file to open.
PATTERN=(
  func.sh
  kebab-case.func.sh
  node-jira-bind.func.sh
  sN.sh
)

# "basename path" for a citation this row must not rewrite.
# config.sh is the GitHub runner program, named only from oss-runners-move.
# zip-jira-ticket.func.sh remains in the row-28 validate-params copies.
# The harvest notes (destroy.sh, sweep.sh, d-tenants.sh, t1-owner.sh,
# inbox-send.sh, agent-id-restart.sh) and the pas-psf log.func.sh history
# line name scripts that were never files of this tree.
KNOWN=(
  "agent-id-restart.sh csi-spl-orc/src/bash/features/spawn-agents/scripts/agent-name-resume.sh"
  "config.sh csi-spl-orc/src/bash/run/oss-runners-move.func.sh"
  "d-tenants.sh csi-spl-orc/src/bash/run/spl-db-query.func.sh"
  "destroy.sh csi-spl-orc/src/bash/run/tf-deprovision-steps.func.sh"
  "inbox-send.sh csi-spl-orc/src/bash/features/spawn-agents/scripts/spool-send.sh"
  "log.func.sh csi-spl-iac/src/bash/run/run.sh"
  "log.func.sh csi-spl-orc/src/bash/run/run.sh"
  "project.conf.sh csi-spl-iac/lib/bash/funcs/verify-symlinks.func.sh"
  "project.conf.sh csi-spl-orc/lib/bash/funcs/verify-symlinks.func.sh"
  "stub.sh csi-spl-orc/src/bash/run/spl-hook-ping.func.sh"
  "sweep.sh csi-spl-orc/src/bash/run/tf-sweep-steps.func.sh"
  "t1-owner.sh csi-spl-orc/src/bash/run/spl-db-query.func.sh"
  "t1-owner.sh csi-spl-orc/src/bash/run/spl-tenant-member-role.func.sh"
  "wait-for-cert-parses-conditions.tst.sh csi-spl-orc/src/bash/run/spl-wait-for-mapping-cert.func.sh"
  "zip-jira-ticket.func.sh csi-spl-iac/lib/bash/funcs/validate-params.func.sh"
  "zip-jira-ticket.func.sh csi-spl-orc/lib/bash/funcs/validate-params.func.sh"
)

AWK=$(cat <<'END'
function comment_body(line) {
  sub(/^[[:space:]]*#[[:space:]]?/, "", line)
  return line
}
function rstrip(s) {
  sub(/[[:space:]]+$/, "", s)
  return s
}
function join_body(text, nxt,   rest) {
  rest = nxt
  sub(/^[[:space:]]+/, "", rest)
  sub(/^@[A-Za-z0-9_-]+[[:space:]]+/, "", rest)
  sub(/^[[:space:]]+/, "", rest)
  if (rest ~ /^[A-Za-z0-9]/) return text rest
  return ""
}
function each_name(text, want_print, rel,    s, tok) {
  s = text
  while (match(s, /(^|[^A-Za-z0-9_.-])[A-Za-z0-9_][A-Za-z0-9_.-]*\.sh([^A-Za-z0-9_.-]|$)/)) {
    tok = substr(s, RSTART, RLENGTH)
    sub(/^[^A-Za-z0-9_]/, "", tok)
    if (tok !~ /\.sh$/) sub(/.$/, "", tok)
    if (want_print) print tok
    else consider(tok, rel)
    s = substr(s, RSTART + RLENGTH)
  }
}
function load_set(path, arr,    line) {
  while ((getline line < path) > 0) if (line != "") arr[line] = 1
  close(path)
}
function consider(tok, rel) {
  seen[tok "\t" rel] = 1
  if (tok in tracked) return
  if (tok in external) { ext++; return }
  if (tok in pattern) { pat++; return }
  if ((tok "\t" rel) in known) { pins++; return }
  miss++
  print "FAIL " rel " " tok
}
BEGIN {
  if (mode == "extract") {
    while ((getline line) > 0) each_name(line, 1, "")
    exit 0
  }
  if (mode == "join") {
    if ((getline a) > 0 && (getline b) > 0) {
      text = rstrip(comment_body(a))
      joined = join_body(text, comment_body(b))
      if (joined != "") print joined
      else print text
    }
    exit 0
  }
  load_set(bases, tracked)
  load_set(extf, external)
  load_set(patf, pattern)
  load_set(knownf, known)
  files = 0
  while ((getline rel < prodf) > 0) {
    if (rel == "") continue
    files++
    path = app "/" rel
    n = 0
    while ((getline line < path) > 0) buf[++n] = line
    close(path)
    i = 1
    while (i <= n) {
      if (buf[i] !~ /^[[:space:]]*#/) { i++; continue }
      text = rstrip(comment_body(buf[i]))
      if (text ~ /-$/ && i < n && buf[i + 1] ~ /^[[:space:]]*#/) {
        joined = join_body(text, comment_body(buf[i + 1]))
        if (joined != "") { text = joined; i++ }
      }
      each_name(text, 0, rel)
      i++
    }
  }
  close(prodf)
  notes = 0
  for (k in known) if (!(k in seen)) { notes++; print "NOTE stale pin " k }
  print "RESULT files=" files " miss=" miss+0 " pins=" pins+0 " external=" ext+0 " pattern=" pat+0 " notes=" notes+0
  exit 0
}
END
)

printf '%s\n' "${EXTERNAL[@]}" >"$T/external"
printf '%s\n' "${PATTERN[@]}" >"$T/pattern"
pin_lines=()
for row in "${KNOWN[@]}"; do
  pin_lines+=("${row%% *}	${row#* }")
done
printf '%s\n' "${pin_lines[@]}" >"$T/known"

# --- controls: the extractor and the wrap join, not the tree -----------------
got=$(printf '%s\n' \
  'see dockerd-rootless-setuptool.sh and a *.func.sh glob' \
  'lib/bash/funcs/define-all-run-vars.func.sh' \
  'no-such-script-r3-30.tst.sh' \
  | awk -v mode=extract "$AWK")
[[ "$got" == $'dockerd-rootless-setuptool.sh\ndefine-all-run-vars.func.sh\nno-such-script-r3-30.tst.sh' ]] \
  && pass "CONTROL: a path yields its basename, a glob yields nothing, a missing name is kept" \
  || fail "CONTROL extract got: [$got]"

joined=$(printf '%s\n' \
  '# @description empty (wait-for-cert-parses-' \
  '# @description conditions.tst.sh), so' \
  | awk -v mode=join "$AWK")
[[ "$joined" == *'wait-for-cert-parses-conditions.tst.sh'* ]] \
  && pass "CONTROL: a hyphen wrap joined across a repeated @tag is one basename" \
  || fail "CONTROL join got: [$joined]"

# --- the tree ----------------------------------------------------------------
git -C "$APP_ROOT" ls-files >"$T/all" || { fail "git ls-files failed"; echo "FAIL: $fails"; exit 1; }
awk -F/ '{print $NF}' "$T/all" | sort -u >"$T/bases"
grep -E '^(csi-spl-(iac|orc|cnf))/(src/bash|lib/bash)/.*\.sh$' "$T/all" | grep -v '/tests/' >"$T/prod" || true
nprod=$(wc -l <"$T/prod" | tr -d ' ')
[[ "$nprod" -ge 400 ]] && pass "scanning $nprod production shell files" \
  || fail "only $nprod production shell files: the walk is broken"

scan=$(awk -v mode=scan -v app="$APP_ROOT" -v bases="$T/bases" -v extf="$T/external" \
  -v patf="$T/pattern" -v knownf="$T/known" -v prodf="$T/prod" "$AWK")
printf '%s\n' "$scan" | grep '^FAIL ' || true
printf '%s\n' "$scan" | grep '^NOTE ' || true
result=$(printf '%s\n' "$scan" | grep '^RESULT ' || true)
[[ -n "$result" ]] && pass "scan finished ($result)" || fail "scan printed no RESULT line"
miss=$(printf '%s\n' "$result" | sed -n 's/.* miss=\([0-9]*\).*/\1/p')
[[ "$miss" == 0 ]] && pass "every comment .sh basename is tracked, external, a shape token, or a pinned out-of-scope cite" \
  || fail "unpinned dangling comment refs: $miss"

# --- row 30: the five sites are fixed, and not hidden by a pin ---------------
vars="$APP_ROOT/csi-spl-orc/lib/bash/funcs/define-all-run-vars.func.sh"
grep -q 'define-all-run-vars\.func\.sh' "$vars" \
  && pass "site 1 names define-all-run-vars.func.sh" \
  || fail "site 1 does not name define-all-run-vars.func.sh"
grep -q 'set -u -o pipefail' "$vars" && grep -q 'CALLER' "$vars" \
  && pass "site 1 says set -u -o pipefail changes the caller shell options" \
  || fail "site 1 missing the caller-options description"
if grep -E -q 'define-all-run-vars\.sh($|[^A-Za-z0-9_.])' "$vars"; then
  fail "site 1 still cites define-all-run-vars.sh"
else
  pass "site 1 dropped the extension-less name"
fi

prov="$APP_ROOT/csi-spl-orc/src/bash/run/spl-tenant-host-provision.func.sh"
grep -q 'csi-spl-orc/src/bash/tests/tenant-host.tst.sh' "$prov" \
  && pass "site 2 names tenant-host.tst.sh" || fail "site 2 does not name tenant-host.tst.sh"
grep -q 'spl-tenant-host\.tst\.sh' "$prov" \
  && fail "site 2 still cites spl-tenant-host.tst.sh" || pass "site 2 dropped spl-tenant-host.tst.sh"

tf="$APP_ROOT/csi-spl-orc/src/bash/run/tf-030-import-existing-cloud-run.func.sh"
grep -q 'tf-120-import' "$tf" && fail "site 3 still cites tf-120-import" || pass "site 3 dropped tf-120-import"
grep -q 'src/bash/scripts/tf-030-import-existing-cloud-run.sh' "$tf" \
  && grep -q 'src/bash/scripts/tf-import-table.sh' "$tf" \
  && pass "site 3 names the 030 importer and tf-import-table.sh" \
  || fail "site 3 missing a real importer path"
grep -q '@output' "$tf" && pass "site 3 has an @output line" || fail "site 3 has no @output"

pm="$APP_ROOT/csi-spl-orc/lib/bash/funcs/parse-metadata.func.sh"
grep -q 'zip-jira-ticket' "$pm" && fail "site 4 still cites zip-jira-ticket" || pass "site 4 dropped zip-jira-ticket"
grep -q 'src/bash/run/tf-030-import-existing-cloud-run.func.sh' "$pm" \
  && pass "site 4 example is a real action" || fail "site 4 example is not the 030 action"

sm="$APP_ROOT/csi-spl-iac/src/bash/run/gcp-sm-secrets-to-env-file.func.sh"
grep -q 'csi-spl-dev-api-' "$sm" && fail "site 5 still hardcodes csi-spl-dev-api-" || pass "site 5 dropped csi-spl-dev-api-"
grep -F -q '<org>-<app>-<env>-api-' "$sm" \
  && pass "site 5 uses the generic secret prefix" || fail "site 5 missing <org>-<app>-<env>-api-"
grep -q 'ILM_OPA' "$sm" && fail "site 5 still names another org prefix" || pass "site 5 dropped the other-org prefix"
grep -F -q '<ORG>_<APP>_<ENV>_API_' "$sm" \
  && pass "site 5 uses the generic variable prefix" || fail "site 5 missing the generic variable prefix"
grep -F -q 'does not exist in this tree' "$sm" \
  && pass "site 5 header says OUTPUT_FILE directory is absent" \
  || fail "site 5 header does not say the OUTPUT_FILE directory is absent"

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"
exit 1
