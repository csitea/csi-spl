#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: no tracked *.sh under a src/bash tree copies or symlinks a host
#          coreutils binary (sleep, cat, ...) to ANOTHER name (SPL-5657,
#          ci-failures-50-2026-11-15.md T3 / S3).
#          On ubuntu 26.04 coreutils is the uutils multi-call binary: it picks
#          its applet from argv[0], so a copy of sleep named go exits at once.
#          GNU sleep keeps running under the new name, so the box is green and
#          CI red: check-pre-push-lint-timeout.tst.sh:62 at cc0a51eeb (fixed by
#          7ae1ba7ad), the second time after 10-25 T2/S2. Play a renamed
#          process with a bash child that writes its own /proc/self/comm
#          instead (that test's fix shows how).
#   1. CONTROL: cc0a51eeb's exact line, ln -s, ln -sf, cp -p, which, type -P,
#      /bin/ and /usr/bin/ sources, after && / ; / sudo -- all flagged at
#      file:line
#   2. allowed: the same name (ln -sf of mktemp to pb/mktemp), a directory
#      target ending in /, a non-coreutils binary (bash copied to claude),
#      a comment, a plain file copy
#   3. every tracked *.sh under a src/bash tree passes
#   4. MUTATION: cc0a51eeb's line appended to a copy of every tracked file is
#      caught in each one
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$TEST_DIR/../../../.." && pwd)

fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1 -- ${2:-}"; fails=$((fails + 1)); }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

# GNU coreutils program names; uutils ships them all in one multi-call binary.
CORE=" arch b2sum base32 base64 basename basenc cat chcon chgrp chmod chown chroot cksum comm cp csplit cut date dd df dir dircolors dirname du echo env expand expr factor false fmt fold groups head hostid id install join link ln logname ls md5sum mkdir mkfifo mknod mktemp mv nice nl nohup nproc numfmt od paste pathchk pinky pr printenv printf ptx pwd readlink realpath rm rmdir runcon seq sha1sum sha224sum sha256sum sha384sum sha512sum shred shuf sleep sort split stat stdbuf stty sum sync tac tail tee test timeout touch tr true truncate tsort tty uname unexpand uniq unlink uptime users vdir wc who whoami yes "

# alias_line <text>: prints "<source> -> <target>" for each cp / ln of a
# coreutils binary to another name on that line; exit 1 when there is none.
alias_line() {
  local code="$1" seg w src tgt hit=1
  local ref='\$\((command -v|which|type -P)[[:space:]]+([a-z0-9]+)\)'
  [[ "$code" =~ ^[[:space:]]*# ]] && return 1
  code="${code%%[[:space:]]#*}"
  code="${code//&&/;}"; code="${code//||/;}"; code="${code//|/;}"
  local IFS=';'
  for seg in $code; do
    IFS=$' \t'
    # shellcheck disable=SC2086 # word-split on purpose: the last word is the target
    set -- $seg
    [[ "${1:-}" == sudo ]] && shift
    [[ "${1:-}" == cp || "${1:-}" == ln ]] || continue
    shift; src="" tgt=""
    for w in "$@"; do
      w="${w//[\"\']/}"
      [[ "$w" == -* && -z "$src" ]] && continue
      if [[ -z "$src" ]]; then src="$w"; else tgt="$w"; fi
    done
    [[ -n "$tgt" ]] || continue
    if [[ "$seg" =~ $ref ]]; then src="${BASH_REMATCH[2]}"
    elif [[ "$src" =~ ^(/usr)?/bin/([a-z0-9]+)$ ]]; then src="${BASH_REMATCH[2]}"
    else continue; fi
    [[ "$CORE" == *" $src "* ]] || continue
    [[ "$tgt" == */ ]] && continue
    [[ "${tgt##*/}" == "$src" ]] && continue
    echo "$src -> $tgt"; hit=0
  done
  return "$hit"
}

# alias_scan <file>...: prints <file>:<line>: <text> per alias; exit 1 on any.
# grep keeps the candidate lines (a cp / ln with a binary lookup), bash judges.
alias_scan() {
  local loc line bad=0
  while IFS= read -r loc; do
    line="${loc#*:}"; line="${line#*:}"
    if alias_line "$line" >/dev/null; then
      printf '%s: host binary under another name: %s\n' "${loc%":$line"}" "$line"; bad=1
    fi
  done < <(grep -HnE '(^|[^a-z_])(cp|ln)[[:space:]].*(command -v|which|type -P|/bin/)' -- "$@" 2>/dev/null)
  return "$bad"
}

# Fixture lines are printed with %s so this file's own text never matches.
# shellcheck disable=SC2016 # the $(...) is fixture text, never expanded
OLD_LINE="$(printf '      cp "$(command -v %s)" "$LINT_TO_DIR/go"' sleep)"

# 1. CONTROL
printf '#!/usr/bin/env bash\n%s\n' "$OLD_LINE" >"$T/old.sh"
out="$(alias_scan "$T/old.sh")"; rc=$?
[[ "$rc" == 1 && "$out" == "$T/old.sh:2: host binary under another name: $OLD_LINE" ]] \
  && pass "1. CONTROL: cc0a51eeb's check-pre-push-lint-timeout.tst.sh:62 line is flagged at file:line" \
  || fail "1. control" "rc=$rc out=$out"
# shellcheck disable=SC2016 # fixture text
for spell in 'ln -s "$(command -v %s)" "$T/go"' 'ln -sf "$(which %s)" "$T/bin/go"' \
  'cp -p "$(type -P %s)" "$T/fake"' 'cp /bin/%s "$T/x"' 'ln -s /usr/bin/%s "$T/x"' \
  'mkdir -p "$T/b" && cp "$(command -v %s)" "$T/b/go"' 'x=1; ln -sf "$(command -v %s)" "$T/y"' \
  'sudo cp "$(command -v %s)" "$T/z"'; do
  # shellcheck disable=SC2059 # the spelling is the format on purpose
  printf "$spell\n" sleep >"$T/spell.sh"
  alias_scan "$T/spell.sh" >/dev/null && fail "1. '$(cat "$T/spell.sh")' is flagged" "passed" \
    || pass "1. '$(cat "$T/spell.sh")' is flagged"
done
# shellcheck disable=SC2016 # fixture text
printf 'ln -s "$(command -v %s)" "$T/go"\n' cat >"$T/cat.sh"
alias_scan "$T/cat.sh" >/dev/null && fail "1. another coreutils binary (cat) is flagged" "passed" \
  || pass "1. another coreutils binary (cat) is flagged"

# 2. allowed
# shellcheck disable=SC2016 # fixture text
{
  printf 'ln -sf "$(command -v %s)" "$T/pb/mktemp"; ln -sf "$(command -v %s)" "$T/pb/rm"\n' mktemp rm
  printf 'cp "$(command -v %s)" "$T/bin/"\n' sleep
  printf 'cp "$(command -v %s)" "$T/agent/claude"\n' bash
  printf '# cp "$(command -v %s)" "$T/go"  (a comment)\n' sleep
  printf 'echo x # then cp "$(command -v %s)" "$T/go"\n' sleep
  printf 'cp "$RB/bin/crontab" "$BB/bin/crontab"\n'
  printf 'cp /usr/bin/%s "$T/bin/sleep"\n' sleep
} >"$T/good.sh"
out="$(alias_scan "$T/good.sh")"; rc=$?
[[ "$rc" == 0 && -z "$out" ]] && pass "2. same name, dir target, non-coreutils binary, comment, plain copy pass" \
  || fail "2. allowed" "rc=$rc out=$out"

# 3. every tracked *.sh under a src/bash tree
mapfile -t files < <(git -C "$REPO_ROOT" ls-files -- ':(glob)**/src/bash/**/*.sh')
if [[ "${#files[@]}" -lt 500 ]]; then
  fail "3. tracked *.sh" "only ${#files[@]} found under $REPO_ROOT"
elif out="$(cd "$REPO_ROOT" && alias_scan "${files[@]}")"; then
  pass "3. none of the ${#files[@]} tracked src/bash *.sh copies a coreutils binary to another name"
else
  fail "3. play a renamed process with a bash child that sets /proc/self/comm, never a renamed coreutils copy" "$out"
fi

# 4. MUTATION: the old line appended to a copy of every tracked file is caught
mkdir -p "$T/mut"; i=0
for f in "${files[@]}"; do i=$((i + 1)); { cat "$REPO_ROOT/$f"; printf '\n%s\n' "$OLD_LINE"; } >"$T/mut/$i.sh"; done
hits="$(alias_scan "$T"/mut/*.sh | grep 'host binary under another name: .*LINT_TO_DIR/go"$' | cut -d: -f1 | sort -u | wc -l)"
[[ "$hits" == "${#files[@]}" ]] && pass "4. MUTATION: the appended cc0a51eeb line is caught in all $hits copies" \
  || fail "4. mutation" "caught in $hits of ${#files[@]} copies"

echo ""
if [[ "$fails" -eq 0 ]]; then echo "no-host-binary-alias: ALL PASS"; exit 0; fi
echo "no-host-binary-alias: $fails FAILED"; exit 1
