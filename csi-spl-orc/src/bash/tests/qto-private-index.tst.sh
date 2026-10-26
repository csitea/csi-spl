#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the hand-copy check of the public repository (SPL-3541, spec 114
#          section 9.4 guard 2): qto-private-index.py and do_spl_private_doc_index.
#   1. this tree with no index: a WARN that the check was NOT RUN, exit 0;
#      CONTROL: once cnf docs.private_index_required is true, a FAIL
#   2. build: hashes only (no title in the index or its output), mode 600,
#      the 3-word / 16-character floor, text the public tree holds dropped
#   3. check: a fixture tree passes; CONTROLS, each red, naming file:line and
#      never the text: a pasted title heading, a pasted doc id, a pasted
#      section heading; a short heading under the floor is not indexed
#   4. CONTROLS, fail closed: a corrupt index, an unreadable cnf, an index
#      file tracked in the tree
#   5. this tree passes with a synthetic index of made-up private titles
#   6. do_check_qto_doc_drift rule 7 runs it (red on the planted file, WARN
#      with no index)
#   7. do_spl_private_doc_index (the hub stubbed): a dry run calls nothing;
#      it refuses a public workspace, an index inside the repo, no tenants;
#      DRY_RUN=0 builds the index from list + export, no title in its output
#   Nothing outside the throwaway dirs is written.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
APP_ROOT=$(cd "$PROJ_ROOT/.." && pwd)
PY="$PROJ_ROOT/src/bash/run/qto-private-index.py"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fails=0 passes=0
pass() { echo "PASS: $1"; passes=$((passes + 1)); }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
CNF="$APP_ROOT/csi-spl-cnf/csi-spl/all.env.yaml"
TITLE="Pricing Plan For Customer Alpha"
HEAD2="Rollout of the Alpha billing switch"
ID=44444444-4444-4444-8444-444444444444

cnf() { printf 'env:\n  docs:\n    repo_export_tenants: [system, t1]\n    private_index_required: %s\n' "$2" >"$1"; }
records() {
  printf '{"kind":"id","value":"%s"}\n{"kind":"text","value":"%s"}\n' "$ID" "$TITLE"
  printf '{"kind":"text","value":"## 1.2 %s\\n"}\n{"kind":"text","value":"## Overview\\n"}\n' "$HEAD2"
  printf '{"kind":"text","value":"## Already public in the fixture\\n"}\n'
}
mk_tree() {
  rm -rf "$1"; mkdir -p "$1/doc"
  printf '# Fixture\n\n## Overview\n\nAlready public in the fixture\n' >"$1/doc/a.md"
}
# run <label> <want rc> <want substring> <check args...>
expect() {
  local label="$1" want="$2" grep_for="$3" out rc=0
  shift 3
  out="$(python3 "$PY" check "$@" 2>&1)" || rc=$?
  if [[ "$rc" == "$want" && "$out" == *"$grep_for"* && "$out" != *"$TITLE"* && "$out" != *"$HEAD2"* ]]; then
    pass "$label"
  else fail "$label: rc=$rc (want $want), no '$grep_for' (or the text leaked) in: $out"; fi
}

# 1. no index
cnf "$T/cnf.off" false; cnf "$T/cnf.on" true
expect "1a this tree with no index: WARN, check NOT RUN, exit 0" 0 "WARN no private index: hand-copy check NOT RUN" "$APP_ROOT" "$T/none" "$CNF"
expect "1b CONTROL docs.private_index_required true: no index is a FAIL" 1 "FAIL no private doc index" "$APP_ROOT" "$T/none" "$T/cnf.on"
expect "1c CI with no secret (empty path), required false: WARN" 0 "NOT RUN" "$APP_ROOT" "" "$T/cnf.off"
expect "1d CONTROL CI with no secret, required true: FAIL" 1 "FAIL no private doc index (QTO_PRIVATE_INDEX unset)" "$APP_ROOT" "" "$T/cnf.on"

# 2. build
F="$T/f"; mk_tree "$F"; records >"$T/rec.jsonl"
out="$(python3 "$PY" build "$T/rec.jsonl" "$T/idx" "$F" 2>&1)"; rc=$?
n="$(grep -c '^[0-9a-f]\{16\}$' "$T/idx" 2>/dev/null)"
if (( rc == 0 )) && [[ "$n" == 3 && "$(stat -c %a "$T/idx")" == 600 && "$out" == *"3 entries written (1 dropped: already in the public tree)"* ]] &&
  ! grep -qiF "alpha" "$T/idx" && ! grep -qiF "$ID" "$T/idx" && [[ "$out" != *"$TITLE"* ]]; then
  pass "2 build: 3 hashes (id, title, heading), Overview under the floor, public text dropped, mode 600, no text in index or output"
else fail "2 build: rc=$rc n=$n mode=$(stat -c %a "$T/idx" 2>&1) out=$out"; fi

# 3. check
expect "3a a fixture tree passes" 0 "OK private doc index: 1 md files, 3 entries, no match" "$F" "$T/idx" "$T/cnf.off"
printf '# %s\n\ntext\n' "$TITLE" >"$F/doc/pasted.md"
expect "3b CONTROL a pasted private title is red, file:line, no text" 1 "FAIL doc/pasted.md:1: matches a private workspace doc" "$F" "$T/idx" "$T/cnf.off"
mk_tree "$F"; printf 'see qto doc `%s` here\n' "$ID" >"$F/doc/id.md"
expect "3c CONTROL a pasted private doc id is red" 1 "FAIL doc/id.md:1:" "$F" "$T/idx" "$T/cnf.off"
mk_tree "$F"; printf '# Mine\n\n### 4 **%s**\n' "${HEAD2^^}" >"$F/doc/h.md"
expect "3d CONTROL a pasted section heading (other level, number, case, bold) is red" 1 "FAIL doc/h.md:3:" "$F" "$T/idx" "$T/cnf.off"
mk_tree "$F"
expect "3e a heading under the floor (Overview) was not indexed: no match" 0 "no match" "$F" "$T/idx" "$T/cnf.off"

# 4. fail closed
printf 'not an index\n' >"$T/bad"
expect "4a CONTROL a corrupt index is red" 1 "not a private doc index" "$F" "$T/bad" "$T/cnf.off"
expect "4b CONTROL an unreadable cnf is red" 1 "cnf docs.private_index_required is not readable" "$F" "$T/idx" "$T/no-cnf"
G="$T/g"; mk_tree "$G"; cp "$T/idx" "$G/qto-private-index.txt"; git -C "$G" init -q && git -C "$G" add doc qto-private-index.txt
expect "4c CONTROL an index file tracked in the tree is red" 1 "FAIL qto-private-index.txt: a private doc index is tracked" "$G" "$G/qto-private-index.txt" "$T/cnf.off"

# 5. this tree with a synthetic index
expect "5 this tree passes with a synthetic private index" 0 "entries, no match" "$APP_ROOT" "$T/idx" "$CNF"

# 6. do_check_qto_doc_drift rule 7
D="$T/d"; mkdir -p "$D/csi-spl-doc/doc/md" "$D/csi-spl-cnf/csi-spl"; : >"$D/csi-spl-doc/doc/md/qto-docs.tsv"
cnf "$D/csi-spl-cnf/csi-spl/all.env.yaml" false; printf '# %s\n' "$TITLE" >"$D/x.md"
drift() { env "$@" bash -c "do_log() { echo \"\$*\"; }; source '$PROJ_ROOT/src/bash/run/check-qto-doc-drift.func.sh'; QTO_DRIFT_TREE='$D' do_check_qto_doc_drift" 2>&1; }
rc=0; out="$(drift QTO_PRIVATE_INDEX="$T/idx")" || rc=$?
[[ $rc == 1 && "$out" == *"FAIL x.md:1: matches a private workspace doc"* && "$out" != *"$TITLE"* ]] &&
  pass "6a CONTROL do_check_qto_doc_drift runs rule 7: the planted file is red" || fail "6a drift rule 7: rc=$rc $out"
rc=0; out="$(drift QTO_PRIVATE_INDEX="$T/none")" || rc=$?
[[ $rc == 0 && "$out" == *"hand-copy check NOT RUN"* ]] && pass "6b with no index the drift check WARNs NOT RUN, exit 0" || fail "6b: rc=$rc $out"

# 7. the action, hub stubbed
HUB="$T/hub"; mkdir -p "$HUB"
printf '{"docs":[{"id":"%s","title":"%s"}]}\n' "$ID" "$TITLE" >"$HUB/list"
printf '# %s\n\n## 1 %s\n\nbody\n' "$TITLE" "$HEAD2" >"$HUB/export"
act() {
  env PROJ_PATH="$PROJ_ROOT" HUB="$HUB" CALLS="$T/calls" ENV=prd QTO_TENANT_CNF="$T/cnf.off" "$@" bash -c '
    do_log() { echo "$*"; }
    do_require_bin() { return 0; }
    spl_dry_run() { local d="${DRY_RUN:-1}"; [[ "$d" == 0 || "$d" == 1 ]] || return 2; [[ "$d" == 1 ]]; }
    do_spl_desk_doctree() {
      echo "$TENANT_ID $DESK_AGENT $DOCTREE_ARGS" >>"$CALLS"
      case "$DOCTREE_ARGS" in list) cat "$HUB/list" ;; export\ *) cat "$HUB/export" ;; *) return 1 ;; esac
    }
    source "$PROJ_PATH/src/bash/run/spl-private-doc-index.func.sh"
    do_spl_private_doc_index' 2>&1
}
: >"$T/calls"; rc=0; out="$(act PRIVATE_INDEX_TENANTS=csitea PRIVATE_INDEX_SEAT=c-914 QTO_PRIVATE_INDEX="$T/out/idx")" || rc=$?
[[ $rc == 0 && ! -s "$T/calls" && ! -e "$T/out/idx" && "$out" == *"OK DRY_RUN nothing was read or written"* ]] &&
  pass "7a the default dry run calls no hub and writes nothing" || fail "7a dry run: rc=$rc $out / $(cat "$T/calls")"
rc=0; out="$(act PRIVATE_INDEX_TENANTS="csitea t1" PRIVATE_INDEX_SEAT=c-914 QTO_PRIVATE_INDEX="$T/out/idx" DRY_RUN=0)" || rc=$?
[[ $rc == 1 && ! -s "$T/calls" && "$out" == *"FATAL t1 is in cnf docs.repo_export_tenants"* ]] &&
  pass "7b CONTROL a public workspace (t1) is refused, no hub call" || fail "7b: rc=$rc $out"
rc=0; out="$(act PRIVATE_INDEX_TENANTS=csitea PRIVATE_INDEX_SEAT=c-914 QTO_PRIVATE_INDEX="$APP_ROOT/csi-spl-doc/idx.txt" DRY_RUN=0)" || rc=$?
[[ $rc == 1 && ! -s "$T/calls" && ! -e "$APP_ROOT/csi-spl-doc/idx.txt" && "$out" == *"must live outside the repository"* ]] &&
  pass "7c CONTROL an index path inside the repo is refused" || fail "7c: rc=$rc $out"
rc=0; out="$(act PRIVATE_INDEX_SEAT=c-914 DRY_RUN=0)" || rc=$?
[[ $rc == 1 && "$out" == *"FATAL PRIVATE_INDEX_TENANTS must name"* ]] && pass "7d no tenants is refused" || fail "7d: rc=$rc $out"
rc=0; out="$(act PRIVATE_INDEX_TENANTS=csitea PRIVATE_INDEX_SEAT=c-914 QTO_PRIVATE_INDEX="$T/out/idx" DRY_RUN=0)" || rc=$?
if [[ $rc == 0 && "$(cat "$T/calls")" == "csitea c-914 list
csitea c-914 export $ID" && "$(stat -c %a "$T/out/idx")" == 600 && "$out" == *"OK 1 private doc(s) of 1 workspace(s) hashed"* && "$out" != *"$TITLE"* && "$out" != *"$HEAD2"* ]] &&
  ! grep -qi alpha "$T/out/idx"; then
  pass "7e DRY_RUN=0: list + export per doc, an index of hashes, mode 600, no title in the output"
else fail "7e: rc=$rc $out / $(cat "$T/calls")"; fi
printf '## %s\n' "$HEAD2" >"$F/doc/late.md"
expect "7f CONTROL the index the action built fails a pasted heading" 1 "FAIL doc/late.md:1:" "$F" "$T/out/idx" "$T/cnf.off"

echo "qto-private-index: $passes passed, $fails failed"
(( fails == 0 ))
