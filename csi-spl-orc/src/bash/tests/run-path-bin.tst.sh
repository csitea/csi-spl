#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the path step of do_set_vars gives the same values through the
# spl-run-path binary as through today's Bash path (SPL-5985, spec 027
# rust-run-path.md), so the Bash path never rots and the binary never drifts.
# Every case runs BOTH ways in a throwaway tree: once with the binary at
# <dir of $0>/../bin/spl-run-path (the probe must see RUN_PATH_NOTE empty),
# once without it (the note names the missing binary); the printed
# unit_run_dir, RUN_UNIT, PROJ_PATH, APP_PATH, ORG_PATH, BASE_PATH,
# HOST_NAME, ORG, APP, PROJ and PROJ_KIND must be equal.
#   1..9  the $0 spellings of run-paths-symlink.tst.sh and more: absolute,
#         ./run, a relative path from another cwd, ../<module>/run, a link
#         chain through B's run.sh linked to A's, a linked ancestor, bash
#         run.sh, a link dir that only spells src/bash/run, a 3-link chain
#   10    a wrong-version binary and a failing binary: Bash values, a note
#   11    the fallback logs ONE DEBUG line in the run log
#   12    a dangling $0 fails both ways
#   13    the version pin: Cargo.toml's version == run.sh RUN_PATH_BIN_VERSION,
#         and the four run.sh copies are byte-identical
#   15..17 do_build_spl_run_path (stubs): dry run by default, a wrong version
#         refused, cargo built in the crate dir and installed in <repo>/bin
#   14    RED CONTROL: a binary that resolves one hop wrongly (follows every
#         link to the end, readlink -f) is caught, by name, in case 5
# The binary: SPL_RUN_PATH_TEST_BIN, else <repo>/bin/spl-run-path when its
# version matches; with neither the binary half is SKIPPED (CI's rust-suite
# job builds it and sets SPL_RUN_PATH_TEST_REQUIRE=1, which turns the skip
# into a failure).
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0
RUN_SH="$PROJ_ROOT/src/bash/run/run.sh"
want_ver=$(sed -n 's/^RUN_PATH_BIN_VERSION=//p' "$RUN_SH")

# case 13 first: it needs no binary
crate_ver=$(sed -n 's/^version = "\(.*\)"/\1/p' "$PROJ_ROOT/src/rust/spl-run-path/Cargo.toml" | sed -n 1p)
[[ -n "$want_ver" && "$crate_ver" == "$want_ver" ]] && pass "13. Cargo.toml version $crate_ver == run.sh RUN_PATH_BIN_VERSION" ||
  fail "13. Cargo.toml version '$crate_ver' != run.sh RUN_PATH_BIN_VERSION '$want_ver'"
for c in csi-spl-iac/src/bash/run/run.sh csi-spl-utl/src/bash/run/run.sh src/bash/run/run.sh; do
  cmp -s "$RUN_SH" "$APP_ROOT/$c" || fail "13. $c differs from orc's run.sh"
done

# 15..17: do_build_spl_run_path with stubs (no toolchain needed), in a
# subshell: it sources the action with do_log on stdout
(
  fails=0
  do_log() { echo "$*"; }
  # shellcheck source=../run/build-spl-run-path.func.sh
  . "$PROJ_ROOT/src/bash/run/build-spl-run-path.func.sh"
  export RUN_PATH_BIN_VERSION="$want_ver"
  PROJ_PATH="$T/act/repo/csi-x-orc" APP_PATH="$T/act/repo"
  mkdir -p "$PROJ_PATH/src/rust/spl-run-path" "$T/act/stub"
  stub() { # <file> <version>: a binary that prints <version> and PROJ_PATH
    printf '#!/bin/sh\n[ "$1" = --version ] && echo "spl-run-path %s" && exit 0\necho SPL_RUN_PATH_VERSION=%s\necho PROJ_PATH=%s\n' \
      "$2" "$2" "$PROJ_PATH" >"$1" && chmod +x "$1"
  }
  out=$(SPL_RUN_PATH_BIN="$T/x" do_build_spl_run_path)
  [[ "$out" == *"PLAN $T/x -> $APP_PATH/bin/spl-run-path"*"DRY RUN"* && ! -e "$APP_PATH/bin" ]] &&
    pass "15. dry run by default: a plan, nothing written" || fail "15. dry run: $out"
  stub "$T/act/old" 0.0.0
  SPL_RUN_PATH_BIN="$T/act/old" DRY_RUN=0 do_build_spl_run_path >"$T/act/o" && rc=0 || rc=$?
  ((rc == 1)) && [[ ! -e "$APP_PATH/bin/spl-run-path" ]] &&
    pass "16. a wrong-version binary is refused, nothing installed" || fail "16. rc=$rc: $(cat "$T/act/o")"
  stub "$T/act/cargo-out" "$want_ver"
  printf '#!/bin/sh\npwd >"%s"\n' "$T/act/cargo-cwd" >"$T/act/stub/cargo" && chmod +x "$T/act/stub/cargo"
  mkdir -p "$T/act/td/target/spl-run-path/x86_64-unknown-linux-musl/release"
  cp "$T/act/cargo-out" "$T/act/td/target/spl-run-path/x86_64-unknown-linux-musl/release/spl-run-path"
  PATH="$T/act/stub:$PATH" SPL_RUST_HOME="$T/act/td" DRY_RUN=0 do_build_spl_run_path >"$T/act/o" 2>&1 && rc=0 || rc=$?
  ((rc == 0)) && [[ "$(cat "$T/act/cargo-cwd" 2>/dev/null)" == "$PROJ_PATH/src/rust/spl-run-path" ]] &&
    [[ "$("$APP_PATH/bin/spl-run-path" --version)" == "spl-run-path $want_ver" ]] &&
    pass "17. no SPL_RUN_PATH_BIN: cargo runs in the crate dir, the binary lands in <repo>/bin" ||
    fail "17. rc=$rc: $(cat "$T/act/o")"
  exit "$fails"
) || fails=$((fails + $?))

BIN="${SPL_RUN_PATH_TEST_BIN:-}"
if [[ -z "$BIN" && -x "$APP_ROOT/bin/spl-run-path" ]] &&
  [[ "$("$APP_ROOT/bin/spl-run-path" --version 2>/dev/null)" == "spl-run-path $want_ver" ]]; then
  BIN="$APP_ROOT/bin/spl-run-path"
fi
if [[ -z "$BIN" || ! -x "$BIN" ]]; then
  if [[ "${SPL_RUN_PATH_TEST_REQUIRE:-0}" == 1 ]]; then
    fail "no spl-run-path binary (SPL_RUN_PATH_TEST_BIN='$BIN') and SPL_RUN_PATH_TEST_REQUIRE=1"
  else
    echo "SKIP: the binary half: no SPL_RUN_PATH_TEST_BIN and no $APP_ROOT/bin/spl-run-path $want_ver (build: cd csi-spl-orc && ./run -a do_build_spl_run_path)"
  fi
  echo "run-path-bin: $fails failure(s)"
  (( fails == 0 ))
  exit
fi

# probe_mod <root> <kind>: a <root>/csi-x/csi-x-<kind> module whose
# do_paths_probe prints every value the path step sets; the caller adds run.sh
probe_mod() {
  local d="$1/csi-x/csi-x-$2"
  mkdir -p "$d/src/bash/run" "$d/lib/bash"
  cp -r "$PROJ_ROOT/lib/bash/funcs" "$d/lib/bash/funcs"
  ln -s src/bash/run/run.sh "$d/run"
  cat >"$d/src/bash/run/paths-probe.func.sh" <<'EOF'
do_paths_probe() {
  echo "V unit_run_dir=$unit_run_dir RUN_UNIT=$RUN_UNIT PROJ_PATH=$PROJ_PATH APP_PATH=$APP_PATH ORG_PATH=$ORG_PATH BASE_PATH=$BASE_PATH HOST_NAME=$HOST_NAME ORG=$ORG APP=$APP PROJ=$PROJ PROJ_KIND=$PROJ_KIND"
  echo "NOTE=${RUN_PATH_NOTE:-}"
}
EOF
  echo "$d"
}

# probe <cwd> <argv0> <out> [<interpreter>]: run the probe action
probe() {
  (cd "$1" && env -u ORG -u APP -u PROJ_KIND -u XDG_CACHE_HOME -u RUN_LOG HOME="$T/home" VAR_DIR="$T/var" \
    ${4:-} "$2" -a do_paths_probe </dev/null >"$3" 2>&1)
}

# bin_at <cwd> <argv0>: where run.sh looks for the binary for this $0
bin_at() {
  local d="${2%/*}"
  [[ "$d" == "$2" ]] && d=.
  [[ "$d" == /* ]] || d="$1/$d"
  echo "$d/../bin/spl-run-path"
}

# both <n> <label> <cwd> <argv0> [<interpreter>]: binary way, then Bash way
both() {
  local n="$1" label="$2" cwd="$3" a0="$4" ip="${5:-}" at vb vs nb ns
  at=$(bin_at "$cwd" "$a0")
  mkdir -p "${at%/*}" && cp "$BIN" "$at"
  probe "$cwd" "$a0" "$T/out.bin" "$ip"
  rm -f "$at"
  probe "$cwd" "$a0" "$T/out.sh" "$ip"
  vb=$(grep '^V ' "$T/out.bin") vs=$(grep '^V ' "$T/out.sh")
  nb=$(grep '^NOTE=' "$T/out.bin") ns=$(grep '^NOTE=' "$T/out.sh")
  if [[ -z "$vs" ]]; then
    fail "$n. $label: the Bash way printed no values: $(head -c 300 "$T/out.sh")"
  elif [[ "$nb" != "NOTE=" ]]; then
    fail "$n. $label: the binary was not taken: $nb"
  elif [[ "$ns" != "NOTE=no binary at "* ]]; then
    fail "$n. $label: the Bash way has no note: $ns"
  elif [[ "$vb" != "$vs" ]]; then
    fail "$n. $label: binary and Bash differ:"$'\n'"  bin  $vb"$'\n'"  bash $vs"
  else
    pass "$n. $label: same values both ways"
  fi
}

mkdir -p "$T/home" "$T/var"
r="$T/r"
a="$(probe_mod "$r" utl)"
cp "$RUN_SH" "$a/src/bash/run/run.sh"
b="$(probe_mod "$r" orc)"
ln -s ../../../../csi-x-utl/src/bash/run/run.sh "$b/src/bash/run/run.sh"
mkdir -p "$r/bin" && ln -s "$b/run" "$r/bin/xrun"
ln -s "$r/csi-x" "$r/csi-x-link"
mkdir -p "$r/shim/src/bash" && ln -s "$r/bin" "$r/shim/src/bash/run"
mkdir -p "$r/l1" "$r/l2" "$r/l3"
ln -s ../csi-x/csi-x-utl/run "$r/l3/run3"
ln -s ../l3/run3 "$r/l2/run2"
ln -s ../l2/run2 "$r/l1/run1"

both 1 "absolute \$0, today's layout" "$T" "$a/run"
both 2 "./run in the module" "$a" ./run
both 3 "a relative path from the repo root" "$r/csi-x" csi-x-utl/run
both 4 "../<module>/run from another module" "$b" ../csi-x-utl/run
both 5 "a bin link to B/run, B's run.sh linked to A's" "$T" "$r/bin/xrun"
both 6 "a linked ancestor" "$T" "$r/csi-x-link/csi-x-orc/run"
both 7 "bash run.sh in B's run dir" "$b/src/bash/run" run.sh bash
both 8 "a link dir that only spells src/bash/run" "$T" "$r/shim/src/bash/run/xrun"
both 9 "a 3-link relative chain" "$r" l1/run1

# 10: a binary that answers another version, and one that fails
bash_vals=$(probe "$a" ./run "$T/o" && grep '^V ' "$T/o")
mkdir -p "$r/csi-x/bin"
fake="$r/csi-x/bin/spl-run-path"
printf '#!/bin/sh\n"%s" "$@" | sed "1s/=.*/=0.0.0/"\n' "$BIN" >"$fake" && chmod +x "$fake"
probe "$a" ./run "$T/o"
[[ "$(grep '^V ' "$T/o")" == "$bash_vals" ]] && grep -q '^NOTE=.* is not version .*: SPL_RUN_PATH_VERSION=0.0.0' "$T/o" &&
  pass "10. a wrong-version binary: the Bash values, a note" ||
  fail "10. wrong version: $(grep '^V \|^NOTE' "$T/o")"
printf '#!/bin/sh\nexit 3\n' >"$fake"
probe "$a" ./run "$T/o"
[[ "$(grep '^V ' "$T/o")" == "$bash_vals" ]] && grep -q '^NOTE=.* exited 3$' "$T/o" &&
  pass "10. a failing binary: the Bash values, a note" ||
  fail "10. failing binary: $(grep '^V \|^NOTE' "$T/o")"

# 11: one DEBUG line per fallback run in the module's run log
rm -rf "${T:?}/var" && mkdir -p "$T/var"
probe "$a" ./run "$T/o"
n=$(grep -rh 'run path: .* exited 3; took the Bash path' "$T/var" 2>/dev/null | wc -l)
((n == 1)) && pass "11. the fallback logs one line" || fail "11. the fallback logged $n lines"
rm -f "$fake"

# 12: a dangling $0 fails both ways
ln -s /nonexistent-spl5985/foo/run "$r/dang"
cp "$BIN" "$r/bin/spl-run-path"
probe "$T" "$r/dang" "$T/o" && rc1=0 || rc1=$?
rm -f "$r/bin/spl-run-path"
probe "$T" "$r/dang" "$T/o2" && rc2=0 || rc2=$?
((rc1 != 0 && rc2 != 0)) && pass "12. a dangling \$0 fails both ways" ||
  fail "12. a dangling \$0 exited $rc1 (binary) / $rc2 (Bash)"

# 14: RED CONTROL. A binary that follows $0's links to the end (readlink -f)
# instead of stopping at the first src/bash/run dir must be caught in case 5.
mutant="$T/mutant"
cat >"$mutant" <<EOF
#!/bin/bash
"$BIN" "\$@" | while IFS= read -r l; do
  case "\$l" in
  unit_run_dir=*) d=\$(dirname "\$(readlink -f "\$2")"); echo "unit_run_dir=\$d" ;;
  PROJ_PATH=*) echo "PROJ_PATH=\$(cd "\$d/../../.." && pwd)" ;;
  *) echo "\$l" ;;
  esac
done
EOF
chmod +x "$mutant"
real_bin="$BIN" && BIN="$mutant" && fails_before=$fails
both 5 "CONTROL a bin link to B/run, B's run.sh linked to A's" "$T" "$r/bin/xrun" >"$T/ctl" 2>&1
BIN="$real_bin" && fails=$fails_before
grep -q '^FAIL: 5\. CONTROL .*binary and Bash differ' "$T/ctl" &&
  pass "14. RED CONTROL: a binary that resolves one hop wrongly fails case 5" ||
  fail "14. RED CONTROL: the wrong-hop binary was not caught: $(head -3 "$T/ctl")"

echo "run-path-bin: $fails failure(s)"
(( fails == 0 ))
