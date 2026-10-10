#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_skills_refresh, hermetic. Two throwaway HOMEs (this user and
# "other", reached through a SPOOL_REFRESH_AS stub standing in for
# `sudo -n -u`), each holding the five config paths a full install writes, a
# STALE marked exit-clean and an UNMARKED agent-msg. The skills come from this
# checkout's spawn-agents/assets through install.sh's own step-5b renderer.
# Every check has a failing control.
#   1. the dry run names the stale file and touches nothing
#   2. a live run: exit-clean is the new text in both homes, the unmarked
#      file is untouched, and the five config paths are byte-identical
#   3. the SPOOL_ROOT default per user: the fleet's, else the state dir
#   4. a second run writes nothing (the trees are identical)
#   5. control: a renderer that also writes the agent env is caught and named
#   6. a checkout that is not at trunk is refused before any write
#   7. a refused user hop fails the run
#   8. a home with ~/.vibe (mistral) gets the skills in ~/.vibe/skills, one
#      without it gets none; control: a renderer with no vibe target
#   9. the same for grok: ~/.grok/skills where ~/.grok exists; control: a
#      renderer with no grok target
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0

H1="$T/h1"; H2="$T/h2"
EC=.claude/skills/exit-clean/SKILL.md AM=.claude/skills/agent-msg/SKILL.md
NEW='types `/exit` into your'
printf '#!/bin/sh\necho "$1" >>"%s/hops"; shift; [ "$1" = -- ] && shift; exec "$@"\n' "$T" >"$T/as"
printf '#!/bin/sh\necho "sudo: a password is required" >&2; exit 1\n' >"$T/as-fail"
chmod +x "$T/as" "$T/as-fail"
# stale <file>: an old exit-clean carrying a valid spool-install marker (5b's business)
stale() { python3 -c 'import hashlib,sys; t="# old exit-clean\n"; open(sys.argv[1],"w").write(t+"\n<!-- spool-install: sha256=%s -->\n" % hashlib.sha256(t.encode()).hexdigest())' "$1"; }
for h in "$H1" "$H2"; do
  mkdir -p "$h/.config/spool-agent" "$h/.claude/skills/exit-clean" "$h/.claude/skills/agent-msg" "$h/.local/mcp-bot"
  printf 'SPOOL_ENV=prd\nSPOOL_TENANT=t1\n' >"$h/.config/spool-agent/env"
  printf 'export X=%s\n' "${h##*/}" >"$h/.bashrc"
  printf '{}\n' >"$h/.claude/settings.json"
  for n in mcp-start.sh mcp-start-chrome.sh reap-profiles.sh; do ln -s "/elsewhere/$n" "$h/.local/mcp-bot/$n"; done
  stale "$h/$EC"
  printf '# my own agent-msg, no marker\n' >"$h/$AM"
done
printf '<!-- spool-install: begin claude-md -->\n' >"$H1/.claude/CLAUDE.md"
printf '# rules\n' >"$H2/.claude/CLAUDE.md"
cp "$H1/$AM" "$T/am.orig"
# tree: every path under both homes with its type, link target and sha
tree() { find "$H1" "$H2" -printf '%p %y %l\n' | sort; find "$H1" "$H2" -type f -exec sha256sum {} + | sort; }
cfg() { for h in "$H1" "$H2"; do sha256sum "$h/.config/spool-agent/env" "$h/.bashrc" "$h/.claude/CLAUDE.md" "$h/.claude/settings.json"; ls -l "$h/.local/mcp-bot" | awk 'NR>1{print $9,$10,$11}'; done; }
refresh() {
  SNIPPET='do_spl_skills_refresh' in_orc HOME="$H1" XDG_CONFIG_HOME= MCP_BOT_HOME= SPOOL_ROOT= \
    SPOOL_REFRESH_USERS="tester other" SPOOL_REFRESH_HOMES="other=$H2" SPOOL_REFRESH_AS="$T/as" \
    SKILLS_REFRESH_CHECKOUT="$APP_ROOT" SKILLS_REFRESH_TRUNK=HEAD USER=tester "$@" 2>&1
}
cfg0="$(cfg)"

# 1. dry run
t0="$(tree)"
out="$(refresh)"; rc=$?
[ "$rc" -eq 0 ] && [ "$(tree)" = "$t0" ] && grep -q 'OK DRY_RUN nothing was touched' <<<"$out" \
  && pass "1. the dry run touches nothing" || fail "1. dry run (rc $rc: $out)"
grep -q "would write $H1/$EC" <<<"$out" && grep -q "would write $H2/$EC" <<<"$out" && ! grep -q "would write $H1/$AM" <<<"$out" \
  && pass "1. ...and names the stale marked file, not the unmarked one" || fail "1. plan ($out)"

# 2. live run
out="$(refresh DRY_RUN=0)"; rc=$?
[ "$rc" -eq 0 ] && [ "$(grep -c "$NEW" "$H1/$EC")" = 1 ] && [ "$(grep -c "$NEW" "$H2/$EC")" = 1 ] \
  && pass "2. a live run puts the new exit-clean in both homes" || fail "2. live (rc $rc: $out)"
cmp -s "$H1/$AM" "$T/am.orig" && cmp -s "$H2/$AM" "$T/am.orig" && grep -q "$H1/$AM is not ours" <<<"$out" \
  && pass "2. ...the unmarked file is left alone and named" || fail "2. unmarked ($out)"
[ "$(cfg)" = "$cfg0" ] && grep -q 'OK config: the five config paths are byte-identical' <<<"$out" \
  && pass "2. ...the five config paths are byte-identical" || fail "2. config changed ($out)"
[ "$(sort -u "$T/hops")" = other ] && pass "2. ...the other user is reached through the hop" || fail "2. hops ($(cat "$T/hops"))"
[ -f "$H1/.claude/commands/claude-spawn.md" ] && [ ! -e "$H1/.local/share/spool-agent/tmux-agent-status.conf" ] \
  && pass "2. ...commands written, nothing outside the skill dirs" || fail "2. extent ($(ls -R "$H1/.local"))"

# 3. SPOOL_ROOT per user
grep -q '/var/spool-hub' "$H1/$EC" && grep -q "$H2/.local/state/spool-hub" "$H2/$EC" && ! grep -q '{{' "$H1/$EC" \
  && pass "3. the fleet home renders /var/spool-hub, the other its state dir" || fail "3. root ($(grep -o '[^ ]*spool-hub' "$H2/$EC" | sort -u))"

# 4. a second run writes nothing
t1="$(tree)"
out="$(refresh DRY_RUN=0)"; rc=$?
[ "$rc" -eq 0 ] && [ "$(tree)" = "$t1" ] && grep -q 'skills: 0 written' <<<"$out" \
  && pass "4. a second run changes nothing" || fail "4. idempotent (rc $rc: $out)"
out="$(refresh)"; grep -q 'would write 0 file(s)' <<<"$out" && pass "4. ...and its dry run plans nothing" || fail "4. dry plan ($out)"

# 5. control: a renderer that also runs the env step
python3 - "$PROJ_ROOT/src/bash/features/spool-install/install.sh" "$T/mutant.sh" <<'EOF'
import sys
s = open(sys.argv[1]).read()
k = "wrote = same = 0\n"
assert k in s
open(sys.argv[2], "w").write(s.replace(k, k + 'open(os.path.join(home, ".config", "spool-agent", "env"), "w").write("SPOOL_ENV=dev\\nSPOOL_TENANT=\\n")\n', 1))
EOF
out="$(refresh DRY_RUN=0 SKILLS_REFRESH_INSTALLER="$T/mutant.sh")"; rc=$?
[ "$rc" -ne 0 ] && grep -q "CHANGED config: $H1/.config/spool-agent/env" <<<"$out" && [ "$(cfg)" != "$cfg0" ] \
  && pass "5. control: a renderer that rewrites the agent env fails and is named" || fail "5. control (rc $rc: $out)"
for h in "$H1" "$H2"; do printf 'SPOOL_ENV=prd\nSPOOL_TENANT=t1\n' >"$h/.config/spool-agent/env"; done
[ "$(cfg)" = "$cfg0" ] || fail "5. restore"
out="$(refresh DRY_RUN=0 SKILLS_REFRESH_INSTALLER="$T/as")"; rc=$?
[ "$rc" -ne 0 ] && grep -q "renderer .* is not in $T/as" <<<"$out" && pass "5. an installer without 5b's renderer is refused" || fail "5. no renderer (rc $rc: $out)"

# 6. not at trunk: a throwaway two-commit checkout, so HEAD~1 exists in CI's
# depth-1 clone too; its harness and installer link to this checkout's
CO="$T/co"; orc="${PROJ_ROOT##*/}"
mkdir -p "$CO/$orc/src/bash/features"
for d in spawn-agents spool-install; do ln -s "$PROJ_ROOT/src/bash/features/$d" "$CO/$orc/src/bash/features/$d"; done
gt() { git -C "$CO" -c user.name=t -c user.email=t@example.com -c commit.gpgsign=false "$@" >/dev/null 2>&1; }
gt init -q && gt add -A && gt commit -qm one && gt commit -q --allow-empty -m two || fail "6. throwaway checkout"
stale "$H1/$EC"; t2="$(tree)"
out="$(refresh DRY_RUN=0 SKILLS_REFRESH_CHECKOUT="$CO" SKILLS_REFRESH_TRUNK=HEAD~1)"; rc=$?
[ "$rc" -ne 0 ] && [ "$(tree)" = "$t2" ] && grep -q 'fetch first' <<<"$out" \
  && pass "6. a checkout not at trunk is refused before any write" || fail "6. trunk (rc $rc: $out)"

# 7. a refused hop
out="$(refresh DRY_RUN=0 SPOOL_REFRESH_AS="$T/as-fail")"; rc=$?
[ "$rc" -ne 0 ] && grep -qE 'FAIL skills other|other unreadable' <<<"$out" \
  && pass "7. a refused user hop fails the run" || fail "7. hop (rc $rc: $out)"

# 8. mistral: ~/.vibe/skills where ~/.vibe exists (vibe 2.26.0 reads it)
VEC=.vibe/skills/exit-clean/SKILL.md
mkdir -p "$H1/.vibe"
python3 - "$PROJ_ROOT/src/bash/features/spool-install/install.sh" "$T/novibe.sh" <<'EOF'
import sys
s = open(sys.argv[1]).read()
k = 'if vibe == "1":'
assert k in s
open(sys.argv[2], "w").write(s.replace(k, "if False:", 1))
EOF
out="$(refresh DRY_RUN=0 SKILLS_REFRESH_INSTALLER="$T/novibe.sh")"; rc=$?
[ "$rc" -eq 0 ] && [ ! -e "$H1/$VEC" ] && pass "8. control: a renderer with no vibe target leaves ~/.vibe/skills absent" || fail "8. control (rc $rc: $out)"
out="$(refresh)"; grep -q "would write $H1/$VEC" <<<"$out" && pass "8. the dry run names ~/.vibe/skills/exit-clean" || fail "8. dry ($out)"
out="$(refresh DRY_RUN=0)"; rc=$?
[ "$rc" -eq 0 ] && grep -q 'whose body starts with `ACCEPTED`' "$H1/$VEC" && [ ! -e "$H2/.vibe" ] \
  && pass "8. a home with ~/.vibe gets exit-clean in ~/.vibe/skills, one without gets none" || fail "8. vibe (rc $rc: $out)"

# 9. grok: ~/.grok/skills where ~/.grok exists (Grok Build 1.0.50 reads it first)
GEC=.grok/skills/exit-clean/SKILL.md
mkdir -p "$H1/.grok"
python3 - "$PROJ_ROOT/src/bash/features/spool-install/install.sh" "$T/nogrok.sh" <<'EOF'
import sys
s = open(sys.argv[1]).read()
open(sys.argv[2], "w").write(s.replace('if grok == "1":', "if False:", 1))
EOF
out="$(refresh DRY_RUN=0 SKILLS_REFRESH_INSTALLER="$T/nogrok.sh")"; rc=$?
[ "$rc" -eq 0 ] && [ ! -e "$H1/$GEC" ] && pass "9. control: a renderer with no grok target leaves ~/.grok/skills absent" || fail "9. control (rc $rc: $out)"
out="$(refresh)"; grep -q "would write $H1/$GEC" <<<"$out" && pass "9. the dry run names ~/.grok/skills/exit-clean" || fail "9. dry ($out)"
out="$(refresh DRY_RUN=0)"; rc=$?
[ "$rc" -eq 0 ] && grep -q 'whose body starts with `ACCEPTED`' "$H1/$GEC" && [ ! -e "$H2/.grok" ] \
  && pass "9. a home with ~/.grok gets exit-clean in ~/.grok/skills, one without gets none" || fail "9. grok (rc $rc: $out)"

[ "$fails" -eq 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
