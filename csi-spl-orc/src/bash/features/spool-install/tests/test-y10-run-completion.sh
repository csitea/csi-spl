#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: spec 069 lane Y10 - ./run tab completion moves into csi-spl.
#   1. the completion, in a clean `bash --norc` shell: ./run -a <TAB> lists the
#      actions of csi-spl-iac and of csi-spl-orc (both forms, prefix filtered),
#      an action's `# @arg` flags complete after it, a dir with no
#      src/bash/run completes nothing, <dir>/run completes <dir>'s actions
#   2. the install step on a sandbox rc: the engine line is replaced in place
#      by ONE marked csi-spl line, a duplicate is dropped, every other line
#      (a personal one, a commented completion line) is kept, a backup is made
#   3. idempotent: a re-run leaves the file byte-identical and says current
#   4. a moved checkout: the marked line is repointed, not added to
#   5. no rc -> created; a symlinked rc is written through, the link kept
#   6. --dry-run prints the diff and changes nothing; SPOOL_INSTALL_COMPLETION=0
#      skips the step
#   7. install.sh calls the step exactly once
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
FEAT="$(cd "$TEST_DIR/.." && pwd)"
ORC="$(cd "$FEAT/../../../.." && pwd)"
ROOT="$(cd "$ORC/.." && pwd)"
IAC="$ROOT/$(basename "$ORC" | sed 's/-orc$//')-iac"
COMP="$ORC/lib/bash/completions/run.completion.bash"
STEP="$FEAT/steps/y10-run-completion.sh"
fails=0 n=0
pass() { n=$((n + 1)); echo "PASS: $1"; }
fail() { n=$((n + 1)); echo "FAIL: $1"; fails=$((fails + 1)); }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

# complete <dir> <words...>: the COMPREPLY of a clean shell in <dir>, one per line.
complete_in() {
  local dir="$1"; shift
  ( cd "$dir" && env -i PATH="$PATH" HOME="$T" bash --norc --noprofile -c '
      . "$1"; shift
      COMP_WORDS=("$@"); COMP_CWORD=$(( $# - 1 ))
      _spl_run_completions
      printf "%s\n" "${COMPREPLY[@]}"' _ "$COMP" "$@" )
}
has() { grep -qxF -- "$2" <<<"$1"; }

# ── 1. the completion ─────────────────────────────────────────────────────────
out="$(complete_in "$IAC" ./run -a "")"
has "$out" do_check_dist_hygiene && has "$out" check-dist-hygiene &&
  pass "iac: ./run -a <TAB> lists do_check_dist_hygiene and check-dist-hygiene" ||
  fail "iac: ./run -a <TAB> lacks check-dist-hygiene ($(wc -l <<<"$out") words)"
want="$(find "$IAC/src/bash/run" -type f -name '*.func.sh' ! -name '*.pre.func.sh' ! -name '*.post.func.sh' | wc -l)"
got="$(grep -c '^do_' <<<"$out")"
[ "$got" = "$want" ] && pass "iac: one do_ form per action file ($got)" ||
  fail "iac: $got do_ words for $want action files"
out="$(complete_in "$IAC" ./run -a do_check_dist)"
[ -n "$out" ] && ! grep -qv '^do_check_dist' <<<"$out" && pass "iac: the prefix filters (do_check_dist -> $(tr '\n' ' ' <<<"$out"))" ||
  fail "iac: prefix do_check_dist gave: $out"
out="$(complete_in "$ORC" ./run -a "")"
has "$out" do_check_ysg_box_deps && has "$out" do_spl_dispatch_lease &&
  pass "orc: ./run -a <TAB> lists do_check_ysg_box_deps and do_spl_dispatch_lease" ||
  fail "orc: ./run -a <TAB> lacks the orc actions ($(wc -l <<<"$out") words)"
grep -q '^do_require_bin$' <<<"$out" && fail "orc: offers the lib helper do_require_bin" ||
  pass "orc: lib/bash/funcs helpers are not offered"
out="$(complete_in "$ORC" ./run -a do_gandi_get_nameservers -)"
has "$out" --domain && pass "orc: the action's @arg flag completes (--domain)" || fail "orc: @arg flags gave: $out"
out="$(complete_in "$ORC" ./run -a gandi-get-nameservers --d)"
has "$out" --domain && pass "orc: the kebab form finds its @arg flags too" || fail "orc: kebab @arg gave: $out"
out="$(complete_in "$T" ./run -a "")"
[ -z "$out" ] && pass "a dir with no src/bash/run completes no action" || fail "outside a project: $out"
out="$(complete_in "$ROOT" "$(basename "$IAC")/run" -a do_check_dist_hyg)"
has "$out" do_check_dist_hygiene && pass "<dir>/run from the repo root completes <dir>'s actions" ||
  fail "<dir>/run gave: $out"
out="$(complete_in "$IAC" ./run "")"
has "$out" -a && pass "no action yet: the run flags complete" || fail "flags gave: $out"
reg="$(env -i PATH="$PATH" bash --norc --noprofile -c '. "$1"; complete -p ./run run' _ "$COMP" 2>&1)"
[ "$(grep -c '_spl_run_completions' <<<"$reg")" = 2 ] && pass "registered for ./run and run" || fail "complete -p: $reg"
start=$(date +%s%N); complete_in "$ORC" ./run -a "" >/dev/null; ms=$(( ($(date +%s%N) - start) / 1000000 ))
[ "$ms" -lt 2000 ] && pass "orc <TAB> answers in ${ms} ms" || fail "orc <TAB> took ${ms} ms"

# ── 2..6. the install step ────────────────────────────────────────────────────
# shellcheck source=../steps/y10-run-completion.sh
. "$STEP"
OLD='[ -r "/opt/box-user/engine/utl/lib/bash/completions/run.completion.bash" ] && . "/opt/box-user/engine/utl/lib/bash/completions/run.completion.bash"'
WANT="[ -r \"$COMP\" ] && . \"$COMP\"  # csi-spl: run completion (spec 069 Y10)"
rc="$T/bashrc"
{ echo 'export PATH="$HOME/bin:$PATH"'
  echo "$OLD"
  echo '# [ -r /old/run.completion.bash ] && . /old/run.completion.bash'
  echo 'wifi-up() { bash "/opt/box-user/engine/dotfiles/wifi-up.sh"; }'
  echo "source /opt/box-user/engine/utl/lib/bash/completions/run.completion.bash"
  echo 'alias ll="ls -l"'; } >"$rc"
cp "$rc" "$T/orig"
spl_install_run_completion "$ORC" "$rc" 0 2>/dev/null; rc_s=$?
[ "$rc_s" = 0 ] && pass "the step exits 0" || fail "the step exited $rc_s"
[ "$(grep -c 'run.completion.bash' "$rc")" = 2 ] && [ "$(grep -cxF "$WANT" "$rc")" = 1 ] &&
  pass "one marked csi-spl line; the commented line is the only other mention" ||
  fail "after the step: $(grep -n 'run.completion' "$rc")"
[ "$(sed -n 2p "$rc")" = "$WANT" ] && pass "the engine line is replaced in place (line 2)" || fail "line 2 is: $(sed -n 2p "$rc")"
[ "$(grep -c '/opt/box-user/' "$rc")" = 1 ] && grep -q wifi-up "$rc" &&
  pass "only the personal wifi-up line still points at the engine" || fail "engine lines left: $(grep -n '/opt/box-user/' "$rc")"
grep -qxF 'alias ll="ls -l"' "$rc" && grep -qxF 'export PATH="$HOME/bin:$PATH"' "$rc" &&
  pass "every other line is kept" || fail "a line was lost: $(cat "$rc")"
cmp -s "$rc.bak-spool-install" "$T/orig" && pass "the original is kept as .bak-spool-install" || fail "no or wrong backup"
cp "$rc" "$T/after1"
msg="$(spl_install_run_completion "$ORC" "$rc" 0 2>&1)"
cmp -s "$rc" "$T/after1" && grep -q 'already current' <<<"$msg" && pass "a re-run changes nothing (already current)" ||
  fail "a re-run changed the rc or said: $msg"
spl_install_run_completion "/elsewhere/csi-spl-orc" "$rc" 0 2>/dev/null
[ "$(grep -c 'run.completion.bash' "$rc")" = 2 ] && grep -q '"/elsewhere/csi-spl-orc/lib/bash/completions/run.completion.bash"' "$rc" &&
  ! grep -qF "$COMP" "$rc" && pass "a moved checkout repoints the marked line (not a second one)" ||
  fail "moved checkout: $(grep -n 'run.completion' "$rc")"
cmp -s "$rc.bak-spool-install" "$T/orig" && pass "the backup keeps the FIRST original" || fail "the backup was overwritten"
mkdir -p "$T/none"
spl_install_run_completion "$ORC" "$T/none/.bashrc" 0 2>/dev/null
[ "$(cat "$T/none/.bashrc" 2>/dev/null)" = "$WANT" ] && pass "no rc: it is created with the one line" ||
  fail "no rc: $(cat "$T/none/.bashrc" 2>&1)"
echo "$OLD" >"$T/dotfile"; ln -s "$T/dotfile" "$T/linkrc"
spl_install_run_completion "$ORC" "$T/linkrc" 0 2>/dev/null
[ -L "$T/linkrc" ] && [ "$(cat "$T/dotfile")" = "$WANT" ] && pass "a symlinked rc is written through, the link kept" ||
  fail "symlink: $(ls -l "$T/linkrc"; cat "$T/dotfile")"
echo "$OLD" >"$T/dry"; cp "$T/dry" "$T/dry.orig"
out="$(spl_install_run_completion "$ORC" "$T/dry" 1 2>&1)"
cmp -s "$T/dry" "$T/dry.orig" && [ ! -e "$T/dry.bak-spool-install" ] && grep -qF -- "-$OLD" <<<"$out" && grep -qF -- "+$WANT" <<<"$out" &&
  pass "dry run prints the -engine/+csi-spl diff and changes nothing" || fail "dry run: $out"
out="$(SPOOL_INSTALL_COMPLETION=0 spl_install_run_completion "$ORC" "$T/dry" 0 2>&1)"
cmp -s "$T/dry" "$T/dry.orig" && grep -q skipped <<<"$out" && pass "SPOOL_INSTALL_COMPLETION=0 skips it" || fail "opt-out: $out"
mkdir -p "$T/ro"; echo "$OLD" >"$T/ro/rc"; chmod 444 "$T/ro/rc"
if [ "$(id -u)" != 0 ]; then
  spl_install_run_completion "$ORC" "$T/ro/rc" 0 2>/dev/null; rc_s=$?
  [ "$rc_s" = 7 ] && pass "an rc it cannot write -> 7" || fail "read-only rc exited $rc_s"
fi

# ── 7. install.sh calls it once ───────────────────────────────────────────────
c="$(grep -c 'spl_install_run_completion "\$ORC" "\$HOME/.bashrc" "\$DRY"' "$FEAT/install.sh")"
[ "$c" = 1 ] && pass "install.sh calls the step exactly once" || fail "install.sh calls it $c times"

echo "test-y10-run-completion: $((n - fails))/$n passed"
[ "$fails" -eq 0 ]
