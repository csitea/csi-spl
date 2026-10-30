#!/usr/bin/env bash
# test-timeout: 300 -- ~13 real ./run calls (the pre-push hook and the harness guard), ~1.5 s each
#------------------------------------------------------------------------------
# Purpose: the owner-order gate, ORDER_CMD=gate of do_spl_owner_order
#          (spl-owner-order-gate.func.sh, owner-order-guard.inc.sh,
#          owner-order-guard-hook.sh, hooks/pre-push), and its
#          callers: the pre-push part and the harness guard (spec 168 part c,
#          build row B3, SPL-4372). A fixture repo, synthetic orders only (the
#          real ledger lives outside git):
#            O_GO  gate go       docs/**
#            O_CT  gate content  frozen/**
#            O_NO  gate none     free/**
#   1. an uncited change to a covered path is refused (rc 3), the refusal
#      names the order's id8 and the trailer to add, and prints no order text
#   2. the cited one passes: hub-checked (an owner message naming the id8);
#      without a hub on form only, said so ("NOT hub-checked"); two commits
#      citing one go read the hub once
#   3. N1: a go that names another order's id8, a go from an agent, the
#      order's own id and a message the hub lacks are refused
#   4. an uncovered path passes
#   5. W5: a move out of a covered folder plus an edit is refused, the old
#      path named (--no-renames); with gate go a pure move needs the go too
#   6. W6 gate content: a pure rename (R100) passes, a hunk is refused, a
#      move plus an edit is refused
#   7. CONTROL: gate none is never refused; the same order as gate go
#      refuses the same commit
#   8. N3: a lift is re-read on the hub: one whose message does not name the
#      order does not lift it (even marked source hub); one that does lifts
#   9. fail closed: a malformed ledger is rc 2, a failed hub read rc 1;
#      CONTROL: no ledger passes
#  10. the staged change (the commit guard): uncited refused, cited passes
#  11. the pre-push hook: refused with SPL_PREPUSH_OVERRIDE=1 too; the cited
#      push passes; a refs/heads/wip/* push is not asked
#  12. the harness guard (owner_order_guard_check + the hook script): git
#      commit uncited / cited, a git add earlier in the same command, git
#      push of an uncited commit, an uncovered change, a repo with no ledger;
#      claude exit 2, agy exit 0 + deny JSON, a non-shell tool is allowed
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0
command -v jq >/dev/null || { echo "FAIL: jq is required"; exit 1; }
SA="$PROJ_ROOT/src/bash/features/spawn-agents"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
unset ORDER_GO_HUB OWNER_ORDER_DIR SPL_PREPUSH_OVERRIDE 2>/dev/null || true

O_GO=aaaaaaaa-1111-4bbb-8ccc-000000000001 O_CT=bbbbbbbb-1111-4bbb-8ccc-000000000002
O_NO=cccccccc-1111-4bbb-8ccc-000000000003
G_OK=d0d0d0d0-2222-4bbb-8ccc-000000000004 G_OTHER=d1d1d1d1-2222-4bbb-8ccc-000000000005
G_AGENT=d2d2d2d2-2222-4bbb-8ccc-000000000006 G_GONE=d3d3d3d3-2222-4bbb-8ccc-000000000007
G_CT=d4d4d4d4-2222-4bbb-8ccc-000000000008 L_OK=e0e0e0e0-2222-4bbb-8ccc-000000000009
L_BAD=e1e1e1e1-2222-4bbb-8ccc-00000000000a G_FAIL=e2e2e2e2-2222-4bbb-8ccc-00000000000b
SECRET='TEXT-OF-THE-ORDER-NEVER-PRINTED'
b64() { printf '%s' "$1" | base64 -w0; }
# The hub stub: psql's aligned output of _spl_oo_hub's one-column select.
row() { echo " OO|$2|t|2026-10-30T10:00:00Z|$(b64 "$3")"; }
STUB='do_spl_db_query() {
  echo "$SQL" >>"$STUB_LOG"
  echo "INFO proxy up"; echo "   r"; echo "-----"
  case "$SQL" in
    *'"$G_OK"'*) echo "'"$(row x HUM-10 "go for ${O_GO:0:8}: edit the docs")"'" ;;
    *'"$G_CT"'*) echo "'"$(row x HUM-10 "yes, change ${O_CT:0:8} contents")"'" ;;
    *'"$G_OTHER"'*) echo "'"$(row x HUM-10 "go for ${O_CT:0:8} only")"'" ;;
    *'"$G_AGENT"'*) echo "'"$(row x c-001 "go for ${O_GO:0:8}")"'" ;;
    *'"$L_OK"'*) echo "'"$(row x HUM-10 "lift ${O_GO:0:8}, the docs are done")"'" ;;
    *'"$L_BAD"'*) echo "'"$(row x HUM-10 "thanks, all good")"'" ;;
    *'"$G_FAIL"'*) echo "FATAL the proxy did not come up" >&2; return 1 ;;
    *) echo "(0 rows)"; return 0 ;;
  esac
  echo "(1 row)"
}
'
order() {  # <id> <gate> <glob>
  jq -n -c --arg o "$1" --arg g "$2" --arg p "$3" --arg t "$SECRET" '{op: "add", order: $o, repo: "repo-g",
    paths: [$p], text: $t, source: "hub", gate: $g, ts: "2026-10-29T10:00:00Z", owner: "HUM-10", topic: "",
    expires: "", note: "", by: "c-900", at: "2026-10-29T10:00:00Z"}'
}
lift() { jq -n -c --arg o "$1" --arg l "$2" '{op: "lift", order: $o, lift_msg: $l, source: "hub", reason: "x", by: "c-900", at: "2026-10-30T10:00:00Z"}'; }
D="$T/oo"; mkdir -p "$D"
{ order "$O_GO" go 'docs/**'; order "$O_CT" content 'frozen/**'; order "$O_NO" none 'free/**'; } >"$D/repo-g.jsonl"

R="$T/w/repo-g"
git init -q "$R"
mkdir -p "$R/docs" "$R/frozen" "$R/free" "$R/other"
for f in docs/a.md docs/b.md frozen/r.md free/x.md other/o.md; do printf '%s\nline 2\nline 3\n' "$f" >"$R/$f"; done
git -C "$R" add -A && git -C "$R" commit -qm seed
SEED=$(git -C "$R" rev-parse HEAD)
reset() { git -C "$R" reset -q --hard "$SEED"; git -C "$R" clean -qfd; }
commit() {  # <message> -- after the caller changed the tree
  git -C "$R" add -A && git -C "$R" commit -qm "$1"
}

gate() {  # [VAR=value]...: the gate in-process (the hub stub), on HEAD~1..HEAD
  SNIPPET="${STUB}do_spl_owner_order" in_orc OWNER_ORDER_DIR="$D" ORDER_CMD=gate ORDER_REPO_DIR="$R" \
    ORDER_REVS='HEAD~1..HEAD' ORDER_GO_HUB=prd "$@" >"$T/o" 2>&1
  RC=$?
}
out() { cat "$T/o"; }

# 1. uncited
reset; echo more >>"$R/docs/a.md"; commit "docs: edit"
gate
[[ $RC -eq 3 ]] && grep -q "REFUSED .* order ${O_GO:0:8} (gate go, source hub): docs/a.md" "$T/o" &&
  grep -q "Owner-go: <the owner's go message uuid; its body names ${O_GO:0:8}>" "$T/o" &&
  pass "1. an uncited change to a covered path is refused (rc 3), with the id8 and the trailer to add" || fail "1. uncited (rc=$RC): $(out)"
! grep -q "$SECRET" "$T/o" && pass "1. the refusal prints no order text" || fail "1. order text on stdout: $(out)"

# 2. cited
git -C "$R" commit -q --amend -m "docs: edit" -m "Owner-go: $G_OK"
gate
[[ $RC -eq 0 ]] && grep -q "PASS .* order ${O_GO:0:8} (gate go) go ${G_OK:0:8} (hub-checked on prd: from HUM-10" "$T/o" &&
  pass "2. the cited change passes: hub-checked, an owner message naming the id8" || fail "2. cited (rc=$RC): $(out)"
git -C "$R" commit -q --amend -m "docs: edit" -m "Owner-go: $G_GONE"
gate ORDER_GO_HUB=none
[[ $RC -eq 0 ]] && grep -q "NOT hub-checked" "$T/o" &&
  pass "2. without a hub the go is checked on form only, and the PASS says so" || fail "2. no hub (rc=$RC): $(out)"

git -C "$R" commit -q --amend -m "docs: edit" -m "Owner-go: $G_OK"
echo more >>"$R/docs/b.md"; git -C "$R" add -A; git -C "$R" commit -qm "docs: b" -m "Owner-go: $G_OK"
: >"$T/calls.log"
gate ORDER_REVS='HEAD~2..HEAD'
[[ $RC -eq 0 && "$(grep -c "$G_OK" "$T/calls.log")" == 1 ]] && grep -q "PASS 2 commit(s)" "$T/o" &&
  pass "2. two commits citing the same go: one hub read (the verdict is cached for the run)" || fail "2. cache (rc=$RC, reads $(grep -c "$G_OK" "$T/calls.log")): $(out)"

# 3. N1 and the other refused gos
for c in "$G_OTHER|does not name the order's id8 ${O_GO:0:8}|a go naming another order's id8 (N1)" \
         "$G_AGENT|not an owner|a go from an agent" "$O_GO|the order's own id is not a go|the order's own id" \
         "$G_GONE|is not on the prd hub|a message the hub lacks"; do
  IFS='|' read -r g why what <<<"$c"
  git -C "$R" commit -q --amend -m "docs: edit" -m "Owner-go: $g"
  gate
  [[ $RC -eq 3 ]] && grep -qF "$why" "$T/o" && grep -q REFUSED "$T/o" &&
    pass "3. refused: $what" || fail "3. $what (rc=$RC): $(out)"
done

# 4. uncovered
reset; echo more >>"$R/other/o.md"; commit "other: edit"
gate
[[ $RC -eq 0 ]] && grep -q "PASS 1 commit(s)" "$T/o" && pass "4. an uncovered path passes" || fail "4. uncovered (rc=$RC): $(out)"

# 5. W5: a move out of a covered folder
reset; git -C "$R" mv docs/b.md other/b.md; echo edit >>"$R/other/b.md"; commit "move b out and edit"
gate
[[ $RC -eq 3 ]] && grep -q "REFUSED .* ${O_GO:0:8} .*: docs/b.md" "$T/o" &&
  pass "5. W5: a move out of a covered folder plus an edit is refused, the old path named" || fail "5. W5 (rc=$RC): $(out)"
reset; git -C "$R" mv docs/b.md other/b.md; commit "move b out"
gate
[[ $RC -eq 3 ]] && pass "5. gate go: a pure move out needs the go too" || fail "5. go pure move (rc=$RC): $(out)"

# 6. W6 gate content
reset; mkdir -p "$R/frozen/sub"; git -C "$R" mv frozen/r.md frozen/sub/r.md; commit "restructure frozen"
gate
[[ $RC -eq 0 ]] && pass "6. gate content: a pure rename (R100) passes" || fail "6. R100 (rc=$RC): $(out)"
reset; echo hunk >>"$R/frozen/r.md"; commit "edit frozen"
gate
[[ $RC -eq 3 ]] && grep -q "REFUSED .* ${O_CT:0:8} (gate content" "$T/o" &&
  pass "6. gate content: a content hunk is refused" || fail "6. hunk (rc=$RC): $(out)"
git -C "$R" commit -q --amend -m "edit frozen" -m "Owner-go: $G_CT"
gate
[[ $RC -eq 0 ]] && pass "6. CONTROL: the same hunk with its go passes" || fail "6. hunk cited (rc=$RC): $(out)"
reset; mkdir -p "$R/frozen/sub"; git -C "$R" mv frozen/r.md frozen/sub/r.md; echo hunk >>"$R/frozen/sub/r.md"; commit "move+edit frozen"
gate
[[ $RC -eq 3 ]] && pass "6. gate content: a move plus an edit is refused" || fail "6. move+edit (rc=$RC): $(out)"

# 7. CONTROL gate none
reset; echo more >>"$R/free/x.md"; commit "free: edit"
gate
[[ $RC -eq 0 ]] && pass "7. CONTROL: gate none is never refused" || fail "7. none (rc=$RC): $(out)"
mkdir -p "$T/oo-go"; { order "$O_NO" go 'free/**'; } >"$T/oo-go/repo-g.jsonl"
gate OWNER_ORDER_DIR="$T/oo-go"
[[ $RC -eq 3 ]] && pass "7. CONTROL: the same order as gate go refuses the same commit" || fail "7. none->go (rc=$RC): $(out)"

# 8. N3: every lift re-read on the hub
reset; echo more >>"$R/docs/a.md"; commit "docs: edit"
mkdir -p "$T/oo-lift"
{ cat "$D/repo-g.jsonl"; lift "$O_GO" "$L_BAD"; } >"$T/oo-lift/repo-g.jsonl"
gate OWNER_ORDER_DIR="$T/oo-lift"
[[ $RC -eq 3 ]] && grep -q "WARN order ${O_GO:0:8}: its lift ${L_BAD:0:8} does not hold" "$T/o" &&
  pass "8. N3: a 'source hub' lift whose owner message does not name the order does not lift it" || fail "8. N3 bad lift (rc=$RC): $(out)"
{ cat "$D/repo-g.jsonl"; lift "$O_GO" "$L_OK"; } >"$T/oo-lift/repo-g.jsonl"
gate OWNER_ORDER_DIR="$T/oo-lift"
[[ $RC -eq 0 ]] && grep -q "order ${O_GO:0:8} is lifted on ${L_OK:0:8} (hub-checked" "$T/o" &&
  pass "8. CONTROL: a lift whose owner message names the order lifts it" || fail "8. N3 ok lift (rc=$RC): $(out)"

# 9. fail closed
mkdir -p "$T/oo-bad"; { cat "$D/repo-g.jsonl"; echo '{"op": "add", broken'; } >"$T/oo-bad/repo-g.jsonl"
gate OWNER_ORDER_DIR="$T/oo-bad"
[[ $RC -eq 2 ]] && pass "9. a malformed ledger is rc 2, never a pass" || fail "9. malformed (rc=$RC): $(out)"
git -C "$R" commit -q --amend -m "docs: edit" -m "Owner-go: $G_FAIL"
gate
[[ $RC -eq 1 ]] && grep -q "hub read for go $G_FAIL failed" "$T/o" &&
  pass "9. a failed hub read is rc 1, never a pass" || fail "9. hub fail (rc=$RC): $(out)"
gate OWNER_ORDER_DIR="$T/none"
[[ $RC -eq 0 ]] && grep -q "PASS no ledger for repo-g" "$T/o" && pass "9. CONTROL: no ledger passes" || fail "9. no ledger (rc=$RC): $(out)"

# 10. the staged change
reset; echo more >>"$R/docs/a.md"; git -C "$R" add docs/a.md
gate ORDER_STAGED=1
[[ $RC -eq 3 ]] && grep -q "REFUSED the staged change .* ${O_GO:0:8}" "$T/o" && grep -q "add this line to the commit message" "$T/o" &&
  pass "10. an uncited staged change to a covered path is refused" || fail "10. staged (rc=$RC): $(out)"
gate ORDER_STAGED=1 ORDER_GO_MSGS="$G_OK"
[[ $RC -eq 0 ]] && pass "10. the staged change with its go passes" || fail "10. staged cited (rc=$RC): $(out)"
reset

# 11. the pre-push hook (real ./run; no hub)
export ORDER_GO_HUB=none OWNER_ORDER_DIR="$D" OOG_ORC_DIR="$PROJ_ROOT" SPL_PREPUSH_LOG_DIR="$T/pplog"
L="$R/csi-spl-orc/src/bash/features/spawn-agents/lib"; mkdir -p "$L" "$T/hooks"
cp "$SA/lib/owner-order-guard.inc.sh" "$SA/lib/force-push-guard.inc.sh" "$L/"
printf 'csi-spl-orc/\n' >>"$R/.git/info/exclude"
cp "$SA/hooks/pre-push" "$T/hooks/pre-push"; chmod +x "$T/hooks/pre-push"
git init -q --bare "$T/remote.git"; git -C "$R" remote add origin "$T/remote.git"
git -C "$R" push -q origin "$SEED:refs/heads/base" 2>/dev/null; git -C "$R" fetch -q origin
push() { git -C "$R" -c core.hooksPath="$T/hooks" push origin "$@" >"$T/o" 2>&1; RC=$?; }
echo more >>"$R/docs/a.md"; commit "docs: edit"
SPL_PREPUSH_OVERRIDE=1 push HEAD:refs/heads/lane
[[ $RC -ne 0 ]] && grep -q "owner order ${O_GO:0:8}" "$T/o" && grep -q "SPL_PREPUSH_OVERRIDE=1 does not skip this" "$T/o" &&
  ! git -C "$T/remote.git" rev-parse -q --verify refs/heads/lane >/dev/null &&
  pass "11. pre-push: an uncited push is refused, SPL_PREPUSH_OVERRIDE=1 included, nothing pushed" || fail "11. hook uncited (rc=$RC): $(out)"
push HEAD:refs/heads/wip/lane
[[ $RC -eq 0 ]] && pass "11. pre-push: a refs/heads/wip/* push is not asked" || fail "11. hook wip (rc=$RC): $(out)"
git -C "$R" commit -q --amend -m "docs: edit" -m "Owner-go: $G_OK"
push HEAD:refs/heads/lane
[[ $RC -eq 0 ]] && git -C "$T/remote.git" rev-parse -q --verify refs/heads/lane >/dev/null &&
  pass "11. pre-push: the cited push passes" || fail "11. hook cited (rc=$RC): $(out)"

# 12. the harness guard (real ./run; no hub)
# shellcheck source=../features/spawn-agents/lib/owner-order-guard.inc.sh
source "$SA/lib/owner-order-guard.inc.sh"
guard() { owner_order_guard_check "$1" "${2:-$T}" 2>"$T/o"; RC=$?; }
reset; git -C "$R" fetch -q origin; echo more >>"$R/docs/a.md"; git -C "$R" add docs/a.md
guard "git -C $R commit -m 'docs: edit'"
[[ $RC -eq 2 ]] && grep -q "owner-order-guard: refused: git commit in $R" "$T/o" && grep -q "${O_GO:0:8}" "$T/o" &&
  pass "12. guard: an uncited git commit of a covered path is refused" || fail "12. guard commit (rc=$RC): $(out)"
guard "git -C $R commit -m 'docs: edit' -m 'Owner-go: $G_OK'"
[[ $RC -eq 0 ]] && pass "12. guard: the cited git commit is allowed" || fail "12. guard cited (rc=$RC): $(out)"
git -C "$R" reset -q
guard "cd $R && git add docs/a.md && git commit -m 'docs: edit'"
[[ $RC -eq 2 ]] && pass "12. guard: a git add earlier in the same command counts (the index is not written yet)" || fail "12. guard add&&commit (rc=$RC): $(out)"
reset; echo more >>"$R/docs/a.md"; commit "docs: edit"
guard "git push origin HEAD:refs/heads/other" "$R"
[[ $RC -eq 2 ]] && grep -q "git push in $R" "$T/o" && pass "12. guard: git push of an uncited commit is refused" || fail "12. guard push (rc=$RC): $(out)"
reset; echo more >>"$R/other/o.md"; git -C "$R" add other/o.md
guard "git -C $R commit -m 'other: edit'"
[[ $RC -eq 0 ]] && pass "12. guard: an uncovered change is allowed" || fail "12. guard uncovered (rc=$RC): $(out)"
git init -q "$T/w/no-ledger"; echo x >"$T/w/no-ledger/docs.md"; git -C "$T/w/no-ledger" add -A
guard "git -C $T/w/no-ledger commit -m x"
[[ $RC -eq 0 ]] && pass "12. guard: a repo with no ledger is not asked" || fail "12. guard no ledger (rc=$RC): $(out)"
reset; echo more >>"$R/docs/a.md"; git -C "$R" add docs/a.md
hook() { printf '%s' "$2" | bash "$SA/scripts/owner-order-guard-hook.sh" "$1" >"$T/o" 2>"$T/e"; RC=$?; }
hook claude "$(jq -n -c --arg c "git commit -m x" --arg d "$R" '{tool_name: "Bash", tool_input: {command: $c}, cwd: $d}')"
[[ $RC -eq 2 ]] && grep -q "owner-order-guard: refused" "$T/e" && pass "12. hook: claude, refused with exit 2" || fail "12. hook claude (rc=$RC): $(cat "$T/e")"
hook agy "$(jq -n -c --arg c "cd $R && git commit -m x" '{toolCall: {name: "run_command", args: {CommandLine: $c}}}')"
[[ $RC -eq 0 ]] && jq -e '.decision == "deny"' "$T/o" >/dev/null && pass "12. hook: agy, exit 0 + a deny decision" || fail "12. hook agy (rc=$RC): $(cat "$T/o")"
hook claude '{"tool_name": "Read", "tool_input": {"file_path": "/x"}}'
[[ $RC -eq 0 ]] && pass "12. hook: a non-shell tool is allowed" || fail "12. hook read (rc=$RC): $(cat "$T/e")"
reset

((fails == 0)) && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
