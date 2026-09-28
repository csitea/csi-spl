#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_oss_mirror (spec 044, CLE-35070) on a throwaway ops repo and a
#          bare "public" remote that share history. The export + gate is a stub
#          (git archive of the allow-list; a tree holding LEAK fails, rc 1), so
#          this pins the MIRROR's contract; do_oss_export/do_oss_gate have
#          their own test (oss-export-gate.tst.sh).
#          - the first run needs OSS_MIRROR_BASE = the public master, and a
#            wrong one is refused
#          - the first public commit is the projection: non-product paths gone
#          - an ops commit that changes no product path publishes nothing
#          - a product commit: same author, redacted message, Ops-Commit trailer
#          - a commit that FAILS the gate is never in the public history; the
#            next passing commit carries its change and says so
#          - newest commit failing -> exit 1, the passing ones before it pushed
#          - a commit on the public master that did not come from the mirror
#            is refused (exit 1) and not overwritten
#          - DRY_RUN=1 pushes nothing
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
fails=0
ok() { echo "PASS: $1"; }
no() { echo "FAIL: $1"; fails=$((fails + 1)); }
bash -n "$PROJ_ROOT/src/bash/run/oss-mirror.func.sh" || { echo "FAIL: bash -n"; exit 1; }
python3 -m py_compile "$PROJ_ROOT/src/bash/scripts/oss-redact.py" || { echo "FAIL: py_compile"; exit 1; }
for b in git python3; do command -v "$b" >/dev/null || { echo "SKIP: $b not installed"; exit 0; }; done

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export GIT_AUTHOR_NAME=Ops GIT_AUTHOR_EMAIL=ops@example.com GIT_COMMITTER_NAME=Ops GIT_COMMITTER_EMAIL=ops@example.com
OPS="$T/ops"; mkdir -p "$OPS/x-y-orc/cnf/oss" "$OPS/x-y-orc/src/bash/scripts" "$OPS/api" "$OPS/cnf"
cp "$PROJ_ROOT/src/bash/scripts/oss-redact.py" "$PROJ_ROOT/src/bash/scripts/oss-gate.py" "$OPS/x-y-orc/src/bash/scripts/"
printf 'api\nLICENSE\n?README.md\n' >"$OPS/x-y-orc/cnf/oss/export-allow-list.txt"
printf 'private-host\tprivate host\tsecret\\.example\\.internal\n' >"$OPS/x-y-orc/cnf/oss/banned-literals.tsv"
echo code >"$OPS/api/main.go"; echo AGPL >"$OPS/LICENSE"; echo values >"$OPS/cnf/all.yaml"; echo ops >"$OPS/CLAUDE.md"
git init -q -b master "$OPS"; git -C "$OPS" add -A; git -C "$OPS" commit -qm "base"
BASE=$(git -C "$OPS" rev-parse HEAD)
git init -q --bare "$T/pub.git"; git -C "$OPS" push -q "$T/pub.git" master:master

ops_commit() {  # <msg> <author> <file> <content>
  mkdir -p "$(dirname "$OPS/$3")"; echo "$4" >"$OPS/$3"; git -C "$OPS" add -A
  GIT_AUTHOR_NAME="$2" GIT_AUTHOR_EMAIL="$2@example.com" git -C "$OPS" commit -qm "$1"; git -C "$OPS" rev-parse HEAD
}
mirror() {
  ( LOGF="$T/log"
    do_log() { printf '%s\n' "$*" >>"$LOGF"; }
    do_require_bin() { :; }
    spl_dry_run() { [[ "${DRY_RUN:-1}" == 1 ]]; }
    oss_gate_cnf_vars() { return 1; }
    do_oss_export() {  # stub: archive the allow-list at OSS_REF, fail on LEAK
      local p paths=(); mkdir -p "$OUT_DIR"
      while IFS= read -r p; do p="${p#\?}"; [[ -n "$p" ]] && git -C "$APP_PATH" cat-file -e "$OSS_REF:$p" 2>/dev/null && paths+=("$p"); done <"$OSS_ALLOW_LIST"
      git -C "$APP_PATH" archive "$OSS_REF" -- "${paths[@]}" | tar -x -C "$OUT_DIR"
      if grep -rq LEAK "$OUT_DIR"; then printf 'TOTAL\t1\n'; echo "private-host	api/x	1	x" >"$OUT_DIR.oss-gate-report.tsv"; return 1; fi
      printf 'TOTAL\t0\n'; return 0; }
    APP_PATH="$OPS" PROJ_PATH="$OPS/x-y-orc" OSS_MIRROR_URL="$T/pub.git" OSS_REF=master
    source "$PROJ_ROOT/src/bash/run/oss-mirror.func.sh"
    do_oss_mirror ) >/dev/null 2>&1
}
pub() { git -C "$T/pub.git" "$@"; }

# --- first run ---------------------------------------------------------------
mirror; rc=$?; [[ $rc == 2 ]] && ok "first run without OSS_MIRROR_BASE refuses (2)" || no "first run without base rc=$rc"
c1=$(ops_commit "feat: one" Alice api/main.go v1)
OSS_MIRROR_BASE=$c1 mirror; rc=$?; [[ $rc == 1 ]] && ok "a base that is not the public master is refused (1)" || no "wrong base rc=$rc"
OSS_MIRROR_BASE=$BASE DRY_RUN=1 mirror; rc=$?
[[ $rc == 0 && "$(pub rev-parse master)" == "$BASE" ]] && ok "DRY_RUN=1 exits 0 and pushes nothing" || no "dry run rc=$rc or pushed"
OSS_MIRROR_BASE=$BASE DRY_RUN=0 mirror; rc=$?; [[ $rc == 0 ]] && ok "first run publishes (0)" || no "first run rc=$rc: $(tail -3 "$T/log")"
first=$(pub rev-list --reverse "$BASE..master" | head -1)
[[ "$(pub ls-tree --name-only "$first")" == $'LICENSE\napi' ]] && ok "the first public commit is the projection (cnf, CLAUDE.md, orc gone)" || no "first tree: $(pub ls-tree --name-only "$first" | tr '\n' ' ')"
pub log -1 --format=%B "$first" | grep -qx "Ops-Commit: $BASE" && ok "first commit trailer = the base" || no "first trailer"
[[ "$(pub show master:api/main.go)" == v1 ]] && ok "c1 published" || no "c1 not published"
pub log -1 --format='%an|%B' master | grep -q '^Alice|feat: one' && ok "author and message kept" || no "author/message: $(pub log -1 --format='%an|%s' master)"

# --- ops-only commit publishes nothing; redaction; leak folding ---------------
before=$(pub rev-parse master)
ops_commit "chore: cnf only" Bob cnf/all.yaml v2 >/dev/null
DRY_RUN=0 mirror; [[ "$(pub rev-parse master)" == "$before" ]] && ok "an ops-only commit publishes nothing" || no "ops-only commit was published"
ops_commit "fix: reach secret.example.internal now" Carol api/main.go v2 >/dev/null
DRY_RUN=0 mirror
pub log -1 --format=%B master | grep -q 'reach \[redacted\] now' && ok "a banned literal in the message is redacted" || no "message not redacted: $(pub log -1 --format=%s master)"
pub log --format=%B master | grep -q 'secret\.example\.internal' && no "the literal reached the public history" || ok "the literal never reached the public history"
leak=$(ops_commit "feat: oops" Dave api/cfg.txt LEAK)
DRY_RUN=0 mirror; rc=$?
[[ $rc == 1 ]] && ok "newest commit failing the gate -> exit 1" || no "leak tip rc=$rc"
pub log --format=%B master | grep -q "Ops-Commit: $leak" && no "the failing commit was published" || ok "the failing commit is not published"
ops_commit "fix: drop the leak" Dave api/cfg.txt clean >/dev/null
DRY_RUN=0 mirror; rc=$?; [[ $rc == 0 ]] && ok "the fix publishes (0)" || no "fix rc=$rc"
pub log -1 --format=%B master | grep -q 'carries 1 earlier commit' && ok "the fix commit says it folds the failing one" || no "no fold note"
bad=0; for c in $(pub rev-list master); do pub grep -q LEAK "$c" -- 2>/dev/null && bad=1; done
((bad == 0)) && ok "no public commit ever held the leaked tree" || no "a public commit holds LEAK"

# --- a foreign commit on the public master -------------------------------------
git clone -q "$T/pub.git" "$T/w"; echo x >"$T/w/api/pr.go"; git -C "$T/w" add -A; git -C "$T/w" commit -qm "merged PR"; git -C "$T/w" push -q origin master
foreign=$(pub rev-parse master)
ops_commit "feat: more" Erin api/main.go v3 >/dev/null
DRY_RUN=0 mirror; rc=$?
[[ $rc == 1 && "$(pub rev-parse master)" == "$foreign" ]] && ok "a non-mirror public commit is refused and kept" || no "foreign commit rc=$rc / overwritten"

echo "=== oss-mirror: $fails failure(s)"
[[ "$fails" -eq 0 ]]
