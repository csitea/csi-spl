#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the local dev mode prerequisite check (spec 148 4.2, row B1,
#          SPL-2842) runs its 7 checks in order and stops at the first failure
#          with one plain ERROR line, the exact fix for the detected OS and the
#          check's number as exit code. Hermetic: git and docker are stubs on
#          PATH, uname / disk / memory are injected, the ports are free ones
#          this test picks (one of them it binds itself).
#   1. all checks pass -> exit 0, seven OK lines in order, the final line
#   2. each check fails on its own -> exit <n>, its ERROR text, no later OK
#      line: unsupported OS, no git, old git, no docker, docker daemon down,
#      no compose, old compose, low disk, low RAM, a bound port
#   3. the fix fits the OS: debian -> apt-get, fedora -> dnf, macOS -> brew,
#      an unknown Linux prints all three
#   4. a failure stops the run: a missing git with a down docker reports git
#      only (exit 2)
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0
SCRIPT="$PROJ_ROOT/src/bash/scripts/dev-preflight.sh"
[ -f "$SCRIPT" ] || { echo "FAIL: $SCRIPT is missing"; exit 1; }
command -v python3 >/dev/null || { echo "FAIL: python3 is required"; exit 1; }

# a free port: bind 0, read it, close
free_port() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()'; }
P1=$(free_port); P2=$(free_port)

mkdir -p "$T/bin" "$T/nogit" "$T/nodocker"
printf 'ID=debian\n' > "$T/os-debian"
printf 'ID="fedora"\n' > "$T/os-fedora"
printf 'ID=rocky\nID_LIKE="rhel centos fedora"\n' > "$T/os-rocky"
printf 'ID=alpine\n' > "$T/os-alpine"

# mk_git <version> - stub git in $1
mk_git() { printf '#!/bin/sh\necho "git version %s"\n' "$2" > "$1/git"; chmod +x "$1/git"; }
# mk_docker <dir> <info rc> <compose version or empty>
mk_docker() {
  cat > "$1/docker" <<EOF
#!/bin/sh
case "\$1" in
  info) exit $2 ;;
  compose) [ -n "$3" ] || { echo "docker: 'compose' is not a docker command." >&2; exit 1; }
           if [ "\$3" = "--short" ]; then echo "$3"; else echo "Docker Compose version v$3"; fi ;;
esac
EOF
  chmod +x "$1/docker"
}
# tools on PATH besides git/docker: only the basics the script needs
BASE="$T/base"; mkdir -p "$BASE"
for b in sh bash sed tr sort head grep awk df uname cat; do
  p=$(command -v "$b") && ln -sf "$p" "$BASE/$b"
done

# run_pf <bin dir> [VAR=value]... - run the script; sets OUT and RC
run_pf() {
  local bin="$1"; shift
  OUT=$(env -i HOME="$T" PATH="$bin:$BASE" DEV_PREFLIGHT_UNAME_S=Linux DEV_PREFLIGHT_UNAME_M=x86_64 \
    DEV_PREFLIGHT_OS_RELEASE="$T/os-debian" DEV_PREFLIGHT_DISK_GB=50 DEV_PREFLIGHT_MEM_MB=8000 \
    DEV_PREFLIGHT_PORTS="$P1 $P2" "$@" bash "$SCRIPT" 2>&1); RC=$?
}
# expect <label> <rc> <regex> [<regex absent>]
expect() {
  local label="$1" rc="$2" re="$3" absent="${4:-}"
  if [ "$RC" -ne "$rc" ]; then fail "$label: exit $RC, want $rc :: $OUT"; return; fi
  if ! grep -qE -- "$re" <<<"$OUT"; then fail "$label: no /$re/ :: $OUT"; return; fi
  if [ -n "$absent" ] && grep -qE -- "$absent" <<<"$OUT"; then fail "$label: /$absent/ present :: $OUT"; return; fi
  pass "$label"
}

GOOD="$T/good"; mkdir -p "$GOOD"; mk_git "$GOOD" 2.39.5; mk_docker "$GOOD" 0 2.29.1

# 1. all green
run_pf "$GOOD"
expect "1 all checks pass" 0 '^OK dev preflight: all 7 checks passed$' '^ERROR'
order=$(grep -oE '^OK [0-9]/7' <<<"$OUT" | tr '\n' ' ')
if [ "$order" = "OK 1/7 OK 2/7 OK 3/7 OK 4/7 OK 5/7 OK 6/7 OK 7/7 " ]; then pass "1 seven OK lines in order"; else fail "1 order: '$order'"; fi

# 2. each check fails on its own
run_pf "$GOOD" DEV_PREFLIGHT_UNAME_S=FreeBSD
expect "2.1 unsupported OS -> exit 1" 1 '^ERROR: Unsupported operating system or CPU architecture' '^OK 1/7'
run_pf "$GOOD" DEV_PREFLIGHT_UNAME_M=i686
expect "2.1b unsupported arch -> exit 1" 1 'requires Linux or macOS \(x86_64 or arm64\)'
run_pf "$GOOD" DEV_PREFLIGHT_UNAME_M=aarch64
expect "2.1c aarch64 passes" 0 '^OK 1/7 os: Linux aarch64'

B="$T/b-nogit"; mkdir -p "$B"; mk_docker "$B" 0 2.29.1
run_pf "$B"
expect "2.2 no git -> exit 2" 2 '^ERROR: Git is not installed or version is older than 2.30' '^OK 2/7'
B="$T/b-oldgit"; mkdir -p "$B"; mk_git "$B" 2.25.1; mk_docker "$B" 0 2.29.1
run_pf "$B"
expect "2.2b git 2.25.1 -> exit 2" 2 'found: 2.25.1'
B="$T/b-git230"; mkdir -p "$B"; mk_git "$B" 2.30.0; mk_docker "$B" 0 2.29.1
run_pf "$B"
expect "2.2c git 2.30.0 passes (boundary)" 0 '^OK 2/7 git: 2.30.0'

B="$T/b-nodocker"; mkdir -p "$B"; mk_git "$B" 2.39.5
run_pf "$B"
expect "2.3 no docker -> exit 3" 3 '^ERROR: Docker is not installed' '^OK 3/7'
B="$T/b-dockerdown"; mkdir -p "$B"; mk_git "$B" 2.39.5; mk_docker "$B" 1 2.29.1
run_pf "$B"
expect "2.3b daemon down -> exit 3" 3 '^ERROR: Docker engine is not running or current user lacks docker permissions' '^OK 3/7'
# shellcheck disable=SC2016 # the literal $USER the fix prints
if grep -qF 'sudo systemctl start docker && sudo usermod -aG docker $USER' <<<"$OUT"; then pass "2.3c fix names systemctl + usermod"; else fail "2.3c fix :: $OUT"; fi

B="$T/b-nocompose"; mkdir -p "$B"; mk_git "$B" 2.39.5; mk_docker "$B" 0 ""
run_pf "$B"
expect "2.4 no compose -> exit 4" 4 '^ERROR: Docker Compose v2 plugin is missing or older than v2.20.0' '^OK 4/7'
B="$T/b-oldcompose"; mkdir -p "$B"; mk_git "$B" 2.39.5; mk_docker "$B" 0 2.17.2
run_pf "$B"
expect "2.4b compose 2.17.2 -> exit 4" 4 'found: 2.17.2'

run_pf "$GOOD" DEV_PREFLIGHT_DISK_GB=4
expect "2.5 4 GB free -> exit 5" 5 '^ERROR: Insufficient disk space. Spool local dev requires at least 5 GB' '^OK 5/7'
run_pf "$GOOD" DEV_PREFLIGHT_DISK_GB= DEV_PREFLIGHT_DIR="$T"
expect "2.5b df measures the dir (this box has >= 5 GB or reports exit 5)" "$( [ "$(df -Pk "$T" | awk 'NR==2{print int($4/1048576)}')" -ge 5 ] && echo 0 || echo 5)" '(^OK 5/7 disk: [0-9]+ GB free|^ERROR: Insufficient disk)'

run_pf "$GOOD" DEV_PREFLIGHT_MEM_MB=1024
expect "2.6 1024 MB -> exit 6" 6 '^ERROR: Insufficient system memory. Spool local dev requires at least 2048 MB' '^OK 6/7'

python3 -c 'import socket,sys,time; s=socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind(("127.0.0.1",int(sys.argv[1]))); s.listen(5); time.sleep(30)' "$P2" &
LPID=$!
for _ in $(seq 1 50); do (exec 3<>"/dev/tcp/127.0.0.1/$P2") 2>/dev/null && break; sleep 0.1; done
run_pf "$GOOD"
kill "$LPID" 2>/dev/null; wait "$LPID" 2>/dev/null
expect "2.7 bound port -> exit 7" 7 "^ERROR: Port $P2 is already bound by another service on this machine\\.\$" '^OK 7/7'
if grep -qF "sudo lsof -i :$P2 -sTCP:LISTEN" <<<"$OUT"; then pass "2.7b fix names lsof on that port"; else fail "2.7b :: $OUT"; fi

# 3. the fix fits the OS
run_pf "$T/b-nogit"
expect "3.1 debian -> apt-get" 2 '^Fix \(debian/ubuntu\): sudo apt-get update && sudo apt-get install -y git$' '^Fix \((macos|fedora)'
run_pf "$T/b-nogit" DEV_PREFLIGHT_OS_RELEASE="$T/os-fedora"
expect "3.2 fedora -> dnf" 2 '^Fix \(fedora/rhel\): sudo dnf install -y git$' '^Fix \((macos|debian)'
run_pf "$T/b-nogit" DEV_PREFLIGHT_OS_RELEASE="$T/os-rocky"
expect "3.3 ID_LIKE rhel -> dnf" 2 '^Fix \(fedora/rhel\): sudo dnf install -y git$'
run_pf "$T/b-nogit" DEV_PREFLIGHT_UNAME_S=Darwin DEV_PREFLIGHT_UNAME_M=arm64
expect "3.4 macOS -> brew" 2 '^Fix \(macos\): brew install git$' '^Fix \((debian|fedora)'
run_pf "$T/b-nogit" DEV_PREFLIGHT_OS_RELEASE="$T/os-alpine"
n=$(grep -c '^Fix (' <<<"$OUT")
if [ "$RC" -eq 2 ] && [ "$n" -eq 3 ]; then pass "3.5 unknown Linux prints all three fixes"; else fail "3.5 rc=$RC fixes=$n :: $OUT"; fi

# 4. the first failure stops the run
B="$T/b-nogit-down"; mkdir -p "$B"; mk_docker "$B" 1 2.29.1
run_pf "$B"
expect "4 git missing + docker down -> git only" 2 '^ERROR: Git' 'Docker engine'
n=$(grep -c '^ERROR' <<<"$OUT")
if [ "$n" -eq 1 ]; then pass "4b exactly one ERROR line"; else fail "4b $n ERROR lines"; fi

echo
[ "$fails" -eq 0 ] && { echo "ALL PASS: test-dev-preflight"; exit 0; }
echo "FAILED: $fails"; exit 1
