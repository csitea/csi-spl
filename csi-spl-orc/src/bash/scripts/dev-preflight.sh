#!/usr/bin/env bash
#------------------------------------------------------------------------------
# dev-preflight.sh - the prerequisite check of local dev mode (spec 148 4.2,
# row B1): seven checks in strict order, run before any docker command or
# build. The first one that fails stops the run with ONE plain error line and
# the exact command that fixes it on this machine's OS; a stranger who knows
# nothing of the system reads what is missing and how to get it.
#
#   1 os      uname -s in (Linux, Darwin), uname -m in (x86_64, aarch64, arm64)
#   2 git     git on PATH, version >= 2.30
#   3 docker  docker on PATH and `docker info` answers (daemon up, permission)
#   4 compose `docker compose version` is v2, >= 2.20.0
#   5 disk    >= 5 GB free where the stack runs
#   6 ram     >= 2048 MB available
#   7 ports   published host ports of docker-compose.yml not bound on 127.0.0.1
#             (8080 8443 1025 8025 when the file cannot be read)
#
# Output: one "OK <n>/7 <check>: <what>" line per passed check, then
# "OK dev preflight: all 7 checks passed". On a failure: "ERROR: ..." and
# "Fix (<os>): <command>" lines. The fix is the one for the detected OS
# (debian, macos, fedora); an OS it cannot place prints every one.
#
# Exit: 0 all passed; <n> (1..7) the number of the check that failed.
#
# Every probe can be replaced, so a test needs no particular machine:
#   DEV_PREFLIGHT_UNAME_S / _UNAME_M   instead of uname -s / -m
#   DEV_PREFLIGHT_OS_RELEASE           os-release file (default /etc/os-release)
#   DEV_PREFLIGHT_DIR                  where free disk is measured (default .)
#   DEV_PREFLIGHT_DISK_GB              free GB instead of df
#   DEV_PREFLIGHT_MEM_MB               available MB instead of meminfo/sysctl
#   DEV_PREFLIGHT_PORTS                ports to check (default: the compose file)
#   DEV_PREFLIGHT_COMPOSE              compose file those ports are read from
#   DEV_PREFLIGHT_PRINT_PORTS=1        print the resolved port list and exit 0
#   DEV_PREFLIGHT_MIN_DISK_GB (5)  DEV_PREFLIGHT_MIN_MEM_MB (2048)
# git and docker are found on PATH, so a stub on PATH stands in for them.
#------------------------------------------------------------------------------
set -uo pipefail

MIN_GIT=2.30
MIN_COMPOSE=2.20.0
MIN_DISK_GB="${DEV_PREFLIGHT_MIN_DISK_GB:-5}"
MIN_MEM_MB="${DEV_PREFLIGHT_MIN_MEM_MB:-2048}"

# dp_compose_host_ports <file> - host ports published by that compose file,
# in file order. A mapping is `${NAME:-HOST}:CONTAINER"` at the end of a
# line. Other `:-NUMBER` lines (smtp 587, a URL) do not match.
dp_compose_host_ports() {
  local f="$1" p
  [ -r "$f" ] || return 0
  p=$(sed -n 's/.*:-\([0-9][0-9]*\)}:\([0-9][0-9]*\)"$/\1/p' "$f" \
    | tr '\n' ' ' | sed 's/ *$//')
  printf '%s' "$p"
}

# dp_default_ports - published host ports of the repo compose file.
# DEV_PREFLIGHT_COMPOSE names another file (a test fixture). A missing file,
# or one with no published host port, falls back to the four the dev stack
# publishes: http, https, smtp, ui.
dp_default_ports() {
  local f="${DEV_PREFLIGHT_COMPOSE:-}" root="" p=""
  if [ -z "$f" ]; then
    root=$(CDPATH='' cd -P "$(dirname "$0")/../../../.." && pwd) || root=""
    [ -n "$root" ] && f="$root/docker-compose.yml"
  fi
  [ -n "$f" ] && p=$(dp_compose_host_ports "$f")
  if [ -z "$p" ]; then
    printf '%s' "8080 8443 1025 8025"
  else
    printf '%s' "$p"
  fi
}

# unset or empty -> the compose default. A single space is a real list of
# no ports (do_dev_mode_up passes that when a stack is already running).
PORTS="${DEV_PREFLIGHT_PORTS:-$(dp_default_ports)}"
if [ "${DEV_PREFLIGHT_PRINT_PORTS:-}" = 1 ]; then
  printf '%s\n' "$PORTS"
  exit 0
fi
UNAME_S="${DEV_PREFLIGHT_UNAME_S:-$(uname -s)}"
UNAME_M="${DEV_PREFLIGHT_UNAME_M:-$(uname -m)}"

# dp_os_family - debian | fedora | macos | unknown
dp_os_family() {
  local rel="${DEV_PREFLIGHT_OS_RELEASE:-/etc/os-release}" ids=""
  [ "$UNAME_S" = Darwin ] && { echo macos; return; }
  [ -r "$rel" ] && ids=$(sed -n 's/^\(ID\|ID_LIKE\)=//p' "$rel" | tr -d '"' | tr '\n' ' ')
  case " $ids " in
    *" debian "*|*" ubuntu "*) echo debian ;;
    *" fedora "*|*" rhel "*|*" centos "*) echo fedora ;;
    *) echo unknown ;;
  esac
}
OS_FAMILY=$(dp_os_family)

# dp_fail <n> <error> <debian fix> <macos fix> <fedora fix> - print the error
# and the fix for this OS (every fix when the OS is unknown), exit <n>.
dp_fail() {
  local n="$1" err="$2" deb="$3" mac="$4" fed="$5"
  echo "ERROR: $err"
  case "$OS_FAMILY" in
    debian) echo "Fix (debian/ubuntu): $deb" ;;
    macos)  echo "Fix (macos): $mac" ;;
    fedora) echo "Fix (fedora/rhel): $fed" ;;
    *) echo "Fix (debian/ubuntu): $deb"
       echo "Fix (macos): $mac"
       echo "Fix (fedora/rhel): $fed" ;;
  esac
  exit "$n"
}

# dp_ver_ge <have> <want> - true when version <have> >= <want>
dp_ver_ge() {
  [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | sed -n 1p)" = "$2" ]
}

dp_ok() { echo "OK $1/7 $2"; }

# 1. OS and CPU architecture
case "$UNAME_S:$UNAME_M" in
  Linux:x86_64|Linux:aarch64|Linux:arm64|Darwin:x86_64|Darwin:arm64|Darwin:aarch64) ;;
  *) dp_fail 1 "Unsupported operating system or CPU architecture ($UNAME_S $UNAME_M). Spool local dev requires Linux or macOS (x86_64 or arm64)." \
       "run on a supported Linux (x86_64 or arm64) machine or VM" \
       "run on macOS with an Intel or Apple silicon CPU" \
       "run on a supported Linux (x86_64 or arm64) machine or VM" ;;
esac
dp_ok 1 "os: $UNAME_S $UNAME_M ($OS_FAMILY)"

# 2. git >= 2.30
git_ver=""
command -v git >/dev/null 2>&1 && git_ver=$(git --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | sed -n 1p)
if [ -z "$git_ver" ] || ! dp_ver_ge "$git_ver" "$MIN_GIT"; then
  dp_fail 2 "Git is not installed or version is older than $MIN_GIT (found: ${git_ver:-none})." \
    "sudo apt-get update && sudo apt-get install -y git" \
    "brew install git" \
    "sudo dnf install -y git"
fi
dp_ok 2 "git: $git_ver"

# 3. docker engine up and usable by this user
if ! command -v docker >/dev/null 2>&1; then
  dp_fail 3 "Docker is not installed." \
    "sudo apt-get update && sudo apt-get install -y docker.io && sudo usermod -aG docker \$USER" \
    "brew install --cask docker && open -a Docker" \
    "sudo dnf install -y moby-engine && sudo systemctl start docker && sudo usermod -aG docker \$USER"
fi
if ! docker info >/dev/null 2>&1; then
  dp_fail 3 "Docker engine is not running or current user lacks docker permissions." \
    "sudo systemctl start docker && sudo usermod -aG docker \$USER (then log out and in again)" \
    "open -a Docker (start Docker Desktop)" \
    "sudo systemctl start docker && sudo usermod -aG docker \$USER (then log out and in again)"
fi
dp_ok 3 "docker: engine answers"

# 4. docker compose v2 >= 2.20.0
compose_ver=$(docker compose version --short 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | sed -n 1p)
[ -n "$compose_ver" ] || compose_ver=$(docker compose version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | sed -n 1p)
if [ -z "$compose_ver" ] || ! dp_ver_ge "$compose_ver" "$MIN_COMPOSE"; then
  dp_fail 4 "Docker Compose v2 plugin is missing or older than v$MIN_COMPOSE (found: ${compose_ver:-none})." \
    "sudo apt-get update && sudo apt-get install -y docker-compose-plugin" \
    "brew install docker-compose" \
    "sudo dnf install -y docker-compose-plugin"
fi
dp_ok 4 "compose: v$compose_ver"

# 5. free disk
disk_gb="${DEV_PREFLIGHT_DISK_GB:-}"
if [ -z "$disk_gb" ]; then
  disk_kb=$(df -Pk "${DEV_PREFLIGHT_DIR:-.}" 2>/dev/null | awk 'NR==2 {print $4}')
  disk_gb=$(( ${disk_kb:-0} / 1024 / 1024 ))
fi
if [ "$disk_gb" -lt "$MIN_DISK_GB" ]; then
  dp_fail 5 "Insufficient disk space. Spool local dev requires at least $MIN_DISK_GB GB of free disk space (found: $disk_gb GB)." \
    "docker system prune -f (free up disk space)" \
    "docker system prune -f (free up disk space)" \
    "docker system prune -f (free up disk space)"
fi
dp_ok 5 "disk: $disk_gb GB free"

# 6. available memory
mem_mb="${DEV_PREFLIGHT_MEM_MB:-}"
if [ -z "$mem_mb" ]; then
  if [ "$UNAME_S" = Darwin ]; then
    mem_mb=$(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1024 / 1024 ))
  else
    mem_mb=$(awk '/^MemAvailable:/ {print int($2/1024)}' /proc/meminfo 2>/dev/null)
  fi
fi
if [ "${mem_mb:-0}" -lt "$MIN_MEM_MB" ]; then
  dp_fail 6 "Insufficient system memory. Spool local dev requires at least $MIN_MEM_MB MB of available RAM (found: ${mem_mb:-0} MB)." \
    "close unused applications" \
    "increase the Docker Desktop memory allocation (Settings > Resources)" \
    "close unused applications"
fi
dp_ok 6 "ram: $mem_mb MB available"

# 7. free ports: a port is bound when a TCP connect to 127.0.0.1 succeeds
for port in $PORTS; do
  if (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; then
    dp_fail 7 "Port $port is already bound by another service on this machine." \
      "sudo lsof -i :$port -sTCP:LISTEN (inspect and stop the conflicting service)" \
      "lsof -i :$port -sTCP:LISTEN (inspect and stop the conflicting service)" \
      "sudo ss -tulpn | grep :$port (inspect and stop the conflicting service)"
  fi
done
dp_ok 7 "ports: $PORTS free"

echo "OK dev preflight: all 7 checks passed"
