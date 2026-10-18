#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the heredoc-collision matcher
# (features/spawn-agents/lib/heredoc-collision-guard.inc.sh), SPL-2474:
#   1. refused: rc 2, one "heredoc-collision: refused:" line - the a-779
#      command shape (outer << 'EOF', inner <<'EOF' stub, a later EOF), every
#      quoting of the delimiter, <<- with tabs
#   2. allowed: rc 0, nothing on stderr - unique delimiters, a nested
#      heredoc inside a uniquely-delimited outer one, a body that only
#      mentions <<EOF, here-strings, arithmetic shifts, commands with no <<
#   3. the hook path: force-push-guard-hook.sh refuses the a-779 shape for
#      claude (exit 2) and agy (deny JSON, exit 0) and lets a unique
#      delimiter through
#   3b. the mistral vibe pre_tool hook denies it; 3c. spool-install y13
#      copies the matcher next to the hook, and that copy refuses it
#   4. the direct CLI form (--check) answers the same, and a bad call is 64
#   5. fail closed: with no python3 on PATH a heredoc command is refused
# RED CONTROL: a matcher that allows everything fails every case in 1 (run
# below with the check stubbed out).
# The cases are TEXT only: nothing here is ever run as a command.
#------------------------------------------------------------------------------
# shellcheck disable=SC2016,SC1091  # the cases are literal commands, never expanded
set -uo pipefail
SA="$(cd "$(dirname "$0")/../features/spawn-agents" && pwd)"
G="$SA/lib/heredoc-collision-guard.inc.sh"
HOOK="$SA/scripts/force-push-guard-hook.sh"
# shellcheck source=../features/spawn-agents/lib/heredoc-collision-guard.inc.sh
. "$G"
fails=0 n=0
pass() { n=$((n + 1)); echo "PASS: $1"; }
fail() { n=$((n + 1)); echo "FAIL: $1"; fails=$((fails + 1)); }
label() { printf '%s' "${1%%$'\n'*}"; }

refuse() {  # <name> <command>
  local err rc
  err="$(heredoc_collision_check "$2" 2>&1 >/dev/null)"; rc=$?
  if [ "$rc" = 2 ] && [ "$(printf '%s\n' "$err" | wc -l)" = 1 ] && [[ "$err" == "heredoc-collision: refused: "* ]]
  then pass "refused: $1"; else fail "should refuse (rc=$rc err=$err): $1"; fi
}
allow() {  # <name> <command>
  local err rc
  err="$(heredoc_collision_check "$2" 2>&1 >/dev/null)"; rc=$?
  if [ "$rc" = 0 ] && [ -z "$err" ]; then pass "allowed: $1"; else fail "should allow (rc=$rc err=$err): $1"; fi
}

# the a-779 command shape (a779-check.md section 1), shortened
A779="sudo -u owner bash -c 'cat > /tmp/x/orphan-process-reap.tst.sh' << 'EOF'
#!/usr/bin/env bash
set -uo pipefail
T=\$(mktemp -d /tmp/opr.XXXXXX)
BIN=\"\$T/bin\" PROC=\"\$T/proc\"
cat >\"\$BIN/send-stub\" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x \"\$BIN\"/*
clear_procs() { rm -rf \"\$PROC\"/*; }
clear_procs
EOF"

run_refusals() {
  refuse "the a-779 shape" "$A779"
  refuse "unquoted inner and outer" 'cat > f <<EOF
x
cat > g <<EOF
y
EOF
rm -rf "$D"/*
EOF'
  refuse "double-quoted outer, backslash inner" 'cat > f << "END"
cat > g <<\END
y
END
echo after
END'
  refuse "<<- with tab-indented ends" "$(printf 'cat > f <<-EOF\n\tcat > g <<-EOF\n\ty\n\tEOF\n\techo after\n\tEOF')"
  refuse "second heredoc on a later line collides" 'echo start
tee f >/dev/null <<'"'"'EOF_A'"'"'
cat <<EOF_A
EOF_A
echo runs
EOF_A'
}
run_refusals

# 2. allowed
allow "unique inner delimiter" 'cat > f << '"'"'EOF'"'"'
cat >"$BIN/stub" <<'"'"'EOF_STUB'"'"'
exit 0
EOF_STUB
rm -rf "$PROC"/*
EOF'
allow "a-779 shape inside a uniquely-delimited outer heredoc (data)" "cat > f <<'EOF_OUTER'
$A779
EOF_OUTER"
allow "a body that only mentions <<EOF" 'cat > note.md <<EOF
write it as cat <<EOF in the docs
EOF'
allow "two heredocs in a row, same word" 'cat > a <<EOF
1
EOF
cat > b <<EOF
2
EOF'
allow "here-string" 'grep -c x <<< "$(cat <<<EOF)"'
allow "arithmetic shift" 'echo $((1<<4)) $(( x <<y ))'
allow "no heredoc at all" 'rm -rf "$T"; echo done'
allow "a comment that names <<EOF" '# never nest <<EOF
cat <<EOF
x
EOF
echo EOF'

# 3. through the shared hook (claude / agy contracts)
hook() {  # <harness> <command> -> "rc|stdout"
  local p out rc
  p="$(python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.argv[1]},"toolCall":{"name":"run_command","args":{"CommandLine":sys.argv[1]}}}))' "$2")"
  out="$(printf '%s' "$p" | bash "$HOOK" "$1" 2>/dev/null)"; rc=$?
  printf '%s|%s' "$rc" "$out"
}
r="$(hook claude "$A779")"
if [ "${r%%|*}" = 2 ] && [[ "$r" == *heredoc-collision* ]]; then pass "hook claude: a-779 shape exit 2"; else fail "hook claude: $r"; fi
r="$(hook agy "$A779")"
if [ "${r%%|*}" = 0 ] && [[ "$r" == *'"decision": "deny"'*heredoc-collision* ]]; then pass "hook agy: a-779 shape deny JSON"; else fail "hook agy: $r"; fi
r="$(hook claude 'cat > f <<EOF_X
y
EOF_X')"
if [ "$r" = "0|" ]; then pass "hook claude: unique delimiter passes"; else fail "hook claude unique: $r"; fi
r="$(hook agy 'cat > f <<EOF_X
y
EOF_X')"
if [ "$r" = '0|{"decision":"allow"}' ]; then pass "hook agy: unique delimiter allow"; else fail "hook agy unique: $r"; fi

# 3b. mistral: the vibe pre_tool hook (vibe-push-guard.py) denies it too
VIBE="$SA/../spool-install/assets/vibe-push-guard/vibe-push-guard.py"
vibe() {  # <command> -> "rc|stdout"
  local out rc
  out="$(python3 -c 'import json,sys; print(json.dumps({"hook_event_name":"pre_tool","tool_name":"bash","tool_input":{"command":sys.argv[1]}}))' "$1" |
    SPOOL_PUSH_GUARD_MATCHER="$SA/lib/force-push-guard.inc.sh" SPOOL_HEREDOC_GUARD_MATCHER="$G" python3 "$VIBE" 2>/dev/null)"; rc=$?
  printf '%s|%s' "$rc" "$out"
}
r="$(vibe "$A779")"
if [ "${r%%|*}" = 0 ] && [[ "$r" == *'"decision": "deny"'*heredoc-collision* ]]; then pass "vibe hook: a-779 shape denied"; else fail "vibe hook: $r"; fi
r="$(vibe 'cat > f <<EOF_X
y
EOF_X')"
if [ "$r" = "0|" ]; then pass "vibe hook: unique delimiter passes"; else fail "vibe hook unique: $r"; fi

# 3c. spool-install y13 copies the matcher next to the hook it installs
y13d="$(mktemp -d)"
mkdir -p "$y13d/home/.claude"
python3 "$SA/../spool-install/steps/y13-force-push-guard.py" "$y13d/home" "$y13d/guard" 0 \
  "$HOOK" "$SA/lib/force-push-guard.inc.sh" "$G" >/dev/null 2>&1
if cmp -s "$G" "$y13d/guard/heredoc-collision-guard.inc.sh"; then
  r="$(python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.argv[1]}}))' "$A779" |
    bash "$y13d/guard/force-push-guard-hook.sh" claude >/dev/null 2>&1; echo $?)"
  if [ "$r" = 2 ]; then pass "y13: the installed hook copy refuses the a-779 shape"; else fail "y13 installed hook rc=$r"; fi
else fail "y13 did not copy heredoc-collision-guard.inc.sh"; fi
rm -rf -- "$y13d"

# 4. the CLI form
bash "$G" --check "$A779" 2>/dev/null; rc=$?
if [ "$rc" = 2 ]; then pass "--check refuses the a-779 shape"; else fail "--check rc=$rc"; fi
bash "$G" --check 'echo hi' 2>/dev/null; rc=$?
if [ "$rc" = 0 ]; then pass "--check allows a plain command"; else fail "--check plain rc=$rc"; fi
bash "$G" 2>/dev/null; rc=$?
if [ "$rc" = 64 ]; then pass "a bad call is 64"; else fail "bad call rc=$rc"; fi

# 5. fail closed
nopy="$(mktemp -d)"
ln -s "$(command -v bash)" "$nopy/bash"
PATH="$nopy" bash "$G" --check 'cat <<EOF
x
EOF' 2>/dev/null; rc=$?
rm -rf -- "$nopy"
if [ "$rc" = 2 ]; then pass "no python3: refused (fail closed)"; else fail "no python3 rc=$rc"; fi

# RED CONTROL: with the matcher stubbed to allow, every refusal case fails
heredoc_collision_check() { return 0; }
real_fails="$fails" real_n="$n"
run_refusals >/dev/null
red=$((fails - real_fails)) cases=$((n - real_n))
fails="$real_fails" n="$real_n"
if [ "$cases" -gt 0 ] && [ "$red" = "$cases" ]; then pass "red control: an allow-all matcher fails $red/$cases refusal cases"
else fail "red control: an allow-all matcher failed only $red/$cases"; fi

echo "heredoc-collision-guard: $((n - fails))/$n passed"
[ "$fails" = 0 ]
