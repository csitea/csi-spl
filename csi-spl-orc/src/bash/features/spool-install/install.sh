#!/usr/bin/env bash
# install.sh — install the spool agent harness for THIS user (specs/037).
#
#   install.sh [options]
#
# Run it from a git clone of this repo, as the user who will run the agents.
# It needs bash and git, plus a few base tools every Linux / macOS box has
# (curl or wget, tar, python3, perl, flock, setsid; tmux to seat an agent) -
# a missing one is NAMED with the package line to install it, never installed
# with sudo. Everything else goes under your home, no sudo anywhere:
#   1. the agent CLIs you pick, each through its vendor's own documented
#      installer, which installs or updates to the LATEST release (qwen:
#      `npm install -g` into <prefix>, which needs Node 20+ and npm)
#   2. the toolchain the harness runs on: yq (v4) and Go, when not present,
#      into <data>/tools, and the `spool` binary built from this checkout
#   3. the `spool-agent` command in <prefix>/bin, a shim that runs this
#      checkout's spool-agent.sh with your env / tenant / box
#   4. the terminal mirror hooks in ~/.claude/settings.json (claude and grok
#      both read it; the hook does nothing in a session that has no agent id)
#   4b. the agent harness (specs/048): the slash commands and skills of
#      spawn-agents/assets rendered into ~/.claude/commands, ~/.claude/skills
#      and (with qwen) ~/.qwen/skills; the tmux window-access snippet copied
#      to <data>. A rendered file carries a sha256 marker: a re-run rewrites
#      it only while it is untouched; a hand-edited one is left alone and
#      named, a same-named file we did not write is never touched
#   5. your box on a tenant: its key, and its pin at the hub. The hub pins a
#      box only with the tenant root key: with ROOT_KEY_JSON you pin it
#      yourself; without, the seat is PENDING - this prints the one line your
#      tenant admin runs, and exits 0; re-running install.sh picks the pin up
# Re-running it is safe: every step checks before it changes anything.
#
# Options:
#   --cli <list>      comma list of claude,grok,agy,qwen, or none (default claude)
#   --env dev|prd|self  the hub environment (default $SPOOL_ENV, else dev);
#                     self = your own hub at SPOOL_HUB_URL, any host - e.g. the
#                     docker compose stack of this repo (specs/047 W4)
#   --tenant <slug>   the tenant (default $SPOOL_TENANT)
#   --box <box>       your box id (default $SPOOL_BOX, else box-<user>-<host>)
#   --no-seat         skip step 5 (no hub needed)
#   --no-hooks        skip step 4 (spool-agent then passes the hooks per session)
#   --no-skills       skip step 4b
#   --force-skills    step 4b also overwrites a hand-edited rendered file
#                     (the old one is kept as <file>.bak-spool-install)
#   --update          `git pull --ff-only` this checkout first (clean checkouts only)
#   --dry-run         print the plan; change nothing
#
# Env: SPOOL_HUB_URL - required unless --no-seat; the hub URL, no default.
#      With --env dev|prd it must be that env's hub; with --env self it is
#      any hub (http://localhost:8080 for the compose stack on this machine).
#      A re-run takes env / tenant / box / hub from ~/.config/spool-agent/env
#      ROOT_KEY_JSON - the tenant's 0600 create JSON, or a 0600 file with the
#      bare root key (the compose stack's tenant-root.key): pin the box yourself
#      SPOOL_INSTALL_PREFIX - default $HOME/.local (bin/ and share/ under it)
#      SPOOL_INSTALL_URL_CLAUDE / _GROK / _AGY / _GO / _YQ - a download mirror
#      SPOOL_INSTALL_NPM_QWEN - the qwen npm package (default @qwen-code/qwen-code@latest)
#      SPOOL_INSTALL_NPM - the npm command (default npm)
#      SPOOL_ROOT / SPOOL_AGENT_CEILING / SPOOL_ORCHESTRATOR_ID - rendered into
#      the skills (defaults /var/spool-hub, 40 and CLE-00)
#      SPOOL_INSTALL_BUILD / SPOOL_INSTALL_RUN - the spool build and ./run (tests)
#
# Exit codes: 0 done (a PENDING seat included), 2 usage, 3 a base tool is
# missing, 4 an agent CLI did not install (every other step still ran), 5 the seat failed, 6 the toolchain
# or the spool build failed, 7 a file in the way is not ours.
set -uo pipefail

_here="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ORC="$(cd "$_here/../../../.." && pwd)"
ROOT="$(cd "$ORC/.." && pwd)"
RUN="${SPOOL_INSTALL_RUN:-$ORC/run}"
AGENT_SH="$ORC/src/bash/features/spawn-agents/scripts/spool-agent.sh"
MOD="$ROOT/$(basename "$ORC" | sed 's/-orc$//')-api/src/go/spool-hub-api"
BUILD_SH="${SPOOL_INSTALL_BUILD:-$MOD/../../bash/build.sh}"
MARK="# spool-agent shim, written by spool-install (specs/037)"

# A re-run needs no arguments: what the last run saved in the config is the
# default (an option, then the environment, win over it) - so "re-run
# install.sh" after the admin pinned the box is literally that.
CFG_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/spool-agent/env"
cfg_get() { [ -r "$CFG_FILE" ] && ( . "$CFG_FILE" >/dev/null 2>&1; eval "printf '%s' \"\${$1:-}\"" ); }
CLIS="claude" ENVN="${SPOOL_ENV:-$(cfg_get SPOOL_ENV)}" TENANT="${SPOOL_TENANT:-$(cfg_get SPOOL_TENANT)}" BOX="${SPOOL_BOX:-$(cfg_get SPOOL_BOX)}"
ENVN="${ENVN:-dev}"
[ -n "${SPOOL_HUB_URL:-}" ] || SPOOL_HUB_URL="$(cfg_get SPOOL_HUB_URL)"
[ -n "$SPOOL_HUB_URL" ] || unset SPOOL_HUB_URL
SEAT=1 HOOKS=1 SKILLS=1 FORCE_SKILLS=0 UPDATE=0 DRY=0
say()  { echo "spool-install: $*" >&2; }
die()  { local rc="$1"; shift; say "FATAL $*"; exit "$rc"; }
usage() { sed -n '/^#   install.sh/,/^# Exit codes/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; exit 2; }
ORIG_ARGS=("$@")
while [ "$#" -gt 0 ]; do
  case "$1" in
    --cli)      [ "$#" -ge 2 ] || usage; CLIS="$2"; shift 2 ;;
    --env)      [ "$#" -ge 2 ] || usage; ENVN="$2"; shift 2 ;;
    --tenant)   [ "$#" -ge 2 ] || usage; TENANT="$2"; shift 2 ;;
    --box)      [ "$#" -ge 2 ] || usage; BOX="$2"; shift 2 ;;
    --no-seat)  SEAT=0; shift ;;
    --no-hooks) HOOKS=0; shift ;;
    --no-skills) SKILLS=0; shift ;;
    --force-skills) FORCE_SKILLS=1; shift ;;
    --update)   UPDATE=1; shift ;;
    --dry-run)  DRY=1; shift ;;
    -h|--help)  usage ;;
    *) say "unknown option $1"; usage ;;
  esac
done

# --update goes FIRST, before any check: the file bash is running is the old
# one, so after the pull the updated installer is exec-ed (without --update,
# so it runs once) and it does every other step.
if [ "$UPDATE" = 1 ] && [ "$DRY" = 0 ]; then
  if [ -n "$(git -C "$ROOT" status --porcelain 2>/dev/null)" ]; then say "WARN $ROOT has local changes: not updated"
  else
    git -C "$ROOT" pull -q --ff-only || die 6 "git pull --ff-only failed in $ROOT"
    say "updated $ROOT to $(git -C "$ROOT" rev-parse --short HEAD); running the updated installer"
    rest=(); for a in "${ORIG_ARGS[@]}"; do [ "$a" = --update ] || rest+=("$a"); done
    exec bash "${BASH_SOURCE[0]}" ${rest[@]+"${rest[@]}"}
  fi
fi

# ── 0. arguments and base tools ──────────────────────────────────────────────
[[ "$ENVN" =~ ^(dev|prd|self)$ ]] || die 2 "--env must be dev, prd or self (a self-hosted hub), got '$ENVN'"
[ "$CLIS" = none ] && CLIS=""
IFS=, read -r -a CLI_LIST <<<"$CLIS"
for c in "${CLI_LIST[@]}"; do
  case "$c" in claude|grok|agy|qwen) ;; *) die 2 "--cli takes claude,grok,agy,qwen or none, got '$c'" ;; esac
done
if [ -z "$BOX" ]; then
  BOX="$(printf 'box-%s-%s' "$(id -un)" "$(hostname -s 2>/dev/null || echo host)" | tr '[:upper:]_.' '[:lower:]--' |
    tr -cd 'a-z0-9-' | cut -c1-32 | sed 's/-*$//')"
fi
if [ "$SEAT" = 1 ]; then
  : "${SPOOL_HUB_URL:?SPOOL_HUB_URL must be set (no default) - e.g. https://api.example.com; or pass --no-seat}"
  [ -n "$TENANT" ] || die 2 "a seat needs the tenant: --tenant <slug> or SPOOL_TENANT (or pass --no-seat)"
  [[ "$TENANT" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || die 2 "bad tenant '$TENANT'"
  [[ "$BOX" =~ ^[a-z0-9][a-z0-9-]{0,31}$ && "$BOX" != box-wui ]] || die 2 "bad box '$BOX' (pass --box)"
fi
(( BASH_VERSINFO[0] >= 4 )) || die 3 "bash 4 or newer is needed (this is $BASH_VERSION)"

PREFIX="${SPOOL_INSTALL_PREFIX:-$HOME/.local}"
BIN="$PREFIX/bin"
DATA="$PREFIX/share/spool-agent"
TOOLS="$DATA/tools"
CFG_DIR="${CFG_FILE%/*}"
case "$(uname -m)" in
  x86_64|amd64) ARCH=amd64 ;; aarch64|arm64) ARCH=arm64 ;; *) ARCH="$(uname -m)" ;;
esac
OS="$(uname -s | tr '[:upper:]' '[:lower:]')"

missing=()
for b in git python3 tar perl flock setsid; do command -v "$b" >/dev/null 2>&1 || missing+=("$b"); done
command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 || missing+=(curl)
if [ "${#missing[@]}" -gt 0 ]; then
  pk="${missing[*]}"; pk="${pk//flock/util-linux}"; pk="${pk//setsid/util-linux}"
  die 3 "missing: ${missing[*]} - install them first (this needs root, so it is yours to run), e.g.: sudo apt-get install -y $pk"
fi
# ./run derives ORG from the clone's parent dir (<base>/<org>/<org>-<app>):
# a clone at ~/src/csi-spl reads ORG=src and its actions mis-resolve.
# A linked worktree counts as its main checkout, as resolve-oap reads it.
_main="$(cd "$ROOT" && cd "$(git rev-parse --git-common-dir 2>/dev/null || echo .git)/.." 2>/dev/null && pwd)"
_main="${_main:-$ROOT}" _app="$(basename "${_main:-$ROOT}")"
[ "$(basename "$(dirname "$_main")")" = "${_app%%-*}" ] ||
  say "WARN clone this repo as <dir>/${_app%%-*}/$_app (it is at $_main): ./run takes the org from the parent dir"
# qwen installs through npm (specs/048 §3.3): named up front, like a base tool.
NPM="${SPOOL_INSTALL_NPM:-npm}"
for c in "${CLI_LIST[@]}"; do
  [ "$c" = qwen ] || continue
  command -v "$NPM" >/dev/null 2>&1 || die 3 "--cli qwen needs npm (Node 20+) - install Node.js first (this needs root, so it is yours to run), e.g.: sudo apt-get install -y nodejs npm"
done
command -v tmux >/dev/null 2>&1 || say "WARN tmux is missing: spool-agent seats an agent only inside tmux (sudo apt-get install -y tmux)"

fetch() {  # URL OUT
  if command -v curl >/dev/null 2>&1; then curl -fsSL --retry 2 -o "$2" "$1"; else wget -q -O "$2" "$1"; fi
}
plan() { [ "$DRY" = 1 ] && echo "would: $*"; }

# ── 1. this checkout (a real --update ran and re-exec-ed above) ──────────────
[ "$UPDATE" = 1 ] && plan "git -C $ROOT pull --ff-only, then run the updated installer"

# ── 2. the agent CLIs ─────────────────────────────────────────────────────────
cli_url() {
  case "$1" in
    claude) echo "${SPOOL_INSTALL_URL_CLAUDE:-https://claude.ai/install.sh}" ;;
    grok)   echo "${SPOOL_INSTALL_URL_GROK:-https://x.ai/cli/install.sh}" ;;
    agy)    echo "${SPOOL_INSTALL_URL_AGY:-https://antigravity.google/cli/install.sh}" ;;
  esac
}
cli_path() {  # the installed binary, or nothing
  local p; p="$(command -v "$1" 2>/dev/null)"; [ -n "$p" ] && { echo "$p"; return; }
  for p in "$BIN/$1" "$HOME/.local/bin/$1" "$HOME/.grok/bin/$1"; do [ -x "$p" ] && { echo "$p"; return; }; done
}
QWEN_PKG="${SPOOL_INSTALL_NPM_QWEN:-@qwen-code/qwen-code@latest}"
# One vendor's bad day must not cost the user the other CLIs, the toolchain
# and the harness (measured 2026-09-28: a transient binary body from one
# vendor URL stopped a clean install before qwen and the skills). A failed
# CLI is named, the run goes on, and it exits 4 at the end.
CLI_FAILED=()
cli_fail() { say "FAIL $*"; CLI_FAILED+=("$1"); }
# qwen: npm into the user prefix (no sudo), then the vendored ripgrep gets its
# execute bit - the 0.24.6 tarball ships it without one and every session
# then warns "Ripgrep not available ... EACCES".
qwen_install() {
  local have="$1" rg
  if [ "$DRY" = 1 ]; then plan "npm install --prefix $PREFIX -g $QWEN_PKG${have:+ (have $have)}, then chmod +x its vendored rg"; return 0; fi
  say "installing the latest qwen (npm $QWEN_PKG into $PREFIX)"
  "$NPM" install --prefix "$PREFIX" -g "$QWEN_PKG" >&2 || { cli_fail qwen "npm install of $QWEN_PKG failed"; return 0; }
  for rg in "$PREFIX"/lib/node_modules/@qwen-code/qwen-code/vendor/ripgrep/*/rg; do
    [ -f "$rg" ] && [ ! -x "$rg" ] && chmod +x "$rg" && say "qwen: made $rg executable"
  done
  have="$(cli_path qwen)"; [ -n "$have" ] || { cli_fail qwen "npm installed $QWEN_PKG but no qwen binary is on PATH or in $BIN"; return 0; }
  say "qwen: $have ($("$have" --version 2>/dev/null | head -1))"
}
for c in "${CLI_LIST[@]}"; do
  url="$(cli_url "$c")"; have="$(cli_path "$c")"
  [ "$c" = qwen ] && { qwen_install "$have"; continue; }
  # agy's installer stops at "already installed"; its own `update` is the
  # documented way to the latest. claude's and grok's installers update in place.
  if [ "$c" = agy ] && [ -n "$have" ]; then
    if [ "$DRY" = 1 ]; then plan "$have update"; continue; fi
    "$have" update >&2 || say "WARN '$have update' failed; keeping $("$have" --version 2>/dev/null | head -1)"
    continue
  fi
  if [ "$DRY" = 1 ]; then plan "install the latest $c: bash <($url)${have:+ (have $have)}"; continue; fi
  tmp="$(mktemp)"
  fetch "$url" "$tmp" || { rm -f "$tmp"; cli_fail "$c" "cannot download the $c installer from $url"; continue; }
  # An installer is a script: a body that does not start with #! (an HTML
  # error page, a binary) is refused rather than handed to bash.
  [ "$(head -c 2 "$tmp")" = "#!" ] || { rm -f "$tmp"; cli_fail "$c" "$url did not return a script: retry later, or set SPOOL_INSTALL_URL_$(printf %s "$c" | tr "[:lower:]" "[:upper:]")"; continue; }
  say "installing the latest $c ($url)"
  if [ "$c" = grok ]; then mkdir -p "$BIN"; GROK_BIN_DIR="$BIN" bash "$tmp" >&2; rc=$?; else bash "$tmp" >&2; rc=$?; fi
  rm -f "$tmp"
  [ "$rc" -eq 0 ] || { cli_fail "$c" "the $c installer failed (rc $rc)"; continue; }
  have="$(cli_path "$c")"; [ -n "$have" ] || { cli_fail "$c" "the $c installer ran but no $c binary is on PATH or in $BIN"; continue; }
  say "$c: $have ($("$have" --version 2>/dev/null | head -1))"
done

# ── 3. toolchain: yq, Go, spool ───────────────────────────────────────────────
TPATH="$TOOLS/bin:$TOOLS/go/bin"
export PATH="$TPATH:$PATH"
yq_ok() { yq --version 2>/dev/null | grep -qE 'mikefarah|version v?4\.'; }
if ! yq_ok; then
  url="${SPOOL_INSTALL_URL_YQ:-https://github.com/mikefarah/yq/releases/latest/download}/yq_${OS}_${ARCH}"
  if [ "$DRY" = 1 ]; then plan "download yq v4 into $TOOLS/bin/yq ($url)"
  else
    mkdir -p "$TOOLS/bin" && fetch "$url" "$TOOLS/bin/yq.tmp" && chmod 755 "$TOOLS/bin/yq.tmp" &&
      mv -f "$TOOLS/bin/yq.tmp" "$TOOLS/bin/yq" || die 6 "cannot download yq from $url"
    yq_ok || die 6 "$TOOLS/bin/yq is not yq v4"
  fi
fi
GO_NEED="$(sed -n 's/^go \([0-9.]*\).*/\1/p' "$MOD/go.mod" 2>/dev/null)"
go_ok() {  # the first go on PATH (or in an override root) that is new enough
  local g v
  local -a cands=()
  if [ -n "${SPOOL_INSTALL_GO_ROOTS+x}" ]; then
    # SPOOL_INSTALL_GO_ROOTS is the override. Empty means PATH only.
    # shellcheck disable=SC2206
    cands=("$(command -v go 2>/dev/null)" ${SPOOL_INSTALL_GO_ROOTS})
  else
    # shellcheck source=../../../../../csi-spl-api/src/bash/use-go-toolchain.sh
    source "$ROOT/csi-spl-api/src/bash/use-go-toolchain.sh"
    spl_export_go_path || true
    cands=("$(command -v go 2>/dev/null)")
  fi
  for g in "${cands[@]}"; do
    [ -d "$g" ] && g="$g/go"; [ -x "$g" ] || continue
    v="$("$g" version 2>/dev/null | sed -n 's/.* go\([0-9.]*\).*/\1/p')"
    [ -n "$v" ] && [ "$(printf '%s\n%s\n' "$GO_NEED" "$v" | sort -V | head -1)" = "$GO_NEED" ] && { GO_BIN="$g"; return 0; }
  done
  return 1
}
GO_BIN=""
if ! go_ok; then
  base="${SPOOL_INSTALL_URL_GO:-https://go.dev}"
  if [ "$DRY" = 1 ]; then plan "download the latest Go (>= $GO_NEED) into $TOOLS/go ($base/dl/)"; GO_BIN="$TOOLS/go/bin/go"
  else
    tmp="$(mktemp -d)"
    fetch "$base/VERSION?m=text" "$tmp/v" || die 6 "cannot read the latest Go version from $base"
    ver="$(head -1 "$tmp/v")"; [[ "$ver" =~ ^go[0-9.]+$ ]] || die 6 "unexpected Go version '$ver' from $base"
    say "installing $ver into $TOOLS/go"
    fetch "$base/dl/$ver.$OS-$ARCH.tar.gz" "$tmp/go.tgz" || die 6 "cannot download $ver"
    rm -rf "$TOOLS/go.new" && mkdir -p "$TOOLS/go.new" && tar -xzf "$tmp/go.tgz" -C "$TOOLS/go.new" --strip-components=1 ||
      die 6 "cannot unpack $ver"
    rm -rf "$TOOLS/go" "$tmp" && mv "$TOOLS/go.new" "$TOOLS/go"
    go_ok || die 6 "$TOOLS/go/bin/go does not run or is older than $GO_NEED"
  fi
fi
[ -n "$GO_BIN" ] && TPATH="$TPATH:$(dirname "$GO_BIN")" && export PATH="$(dirname "$GO_BIN"):$PATH"
SPOOL="$TOOLS/bin/spool"
if [ "$DRY" = 1 ]; then plan "build spool from $MOD into $SPOOL"
else
  mkdir -p "$TOOLS/bin"
  # build.sh is offline (GOPROXY=off): a fresh machine fetches the modules
  # once, through Go's own default proxy, then builds offline ever after -
  # which is what every later do_spl_desk_up rebuild relies on.
  if ! bash "$BUILD_SH" "$SPOOL" >/dev/null 2>&1; then
    say "fetching the Go modules of $MOD (first build on this machine)"
    ( cd "$MOD" && GOFLAGS=-mod=mod "${GO_BIN:-go}" mod download ) >&2 || die 6 "go mod download failed in $MOD"
    bash "$BUILD_SH" "$SPOOL" >&2 || die 6 "the spool build failed ($BUILD_SH)"
  fi
  say "spool: $SPOOL ($("$SPOOL" version 2>/dev/null | head -1))"
fi

# ── 4. the spool-agent command and its config ────────────────────────────────
SHIM="$BIN/spool-agent" CFG="$CFG_FILE"
if [ -e "$SHIM" ] && ! grep -qF "$MARK" "$SHIM" 2>/dev/null; then
  die 7 "$SHIM exists and is not a spool-install shim: move it away and re-run"
fi
if [ "$DRY" = 1 ]; then plan "write $SHIM -> $AGENT_SH, and $CFG (SPOOL_ENV=$ENVN SPOOL_TENANT=$TENANT SPOOL_BOX=$BOX)"
else
  mkdir -p "$BIN" "$CFG_DIR" && chmod 700 "$CFG_DIR" || die 7 "cannot create $BIN / $CFG_DIR"
  ( umask 077
    { echo "# spool-agent defaults, written by spool-install; edit freely"
      printf 'SPOOL_ENV=%q\nSPOOL_TENANT=%q\nSPOOL_BOX=%q\n' "$ENVN" "$TENANT" "$BOX"
      if [ -n "${SPOOL_HUB_URL:-}" ]; then printf 'SPOOL_HUB_URL=%q\n' "$SPOOL_HUB_URL"; fi
    } >"$CFG.tmp" && mv -f "$CFG.tmp" "$CFG" ) || die 7 "cannot write $CFG"
  cat >"$SHIM.tmp" <<EOF
#!/usr/bin/env bash
$MARK
# Runs spool-agent.sh of $ROOT with the defaults in $CFG;
# an option given here wins over them. Re-run install.sh to rewrite this file.
export PATH="$TPATH:\$PATH"
[ -r "$CFG" ] && . "$CFG"
pre=()
[ -n "\${SPOOL_ENV:-}" ] && pre+=(--env "\$SPOOL_ENV")
[ -n "\${SPOOL_TENANT:-}" ] && pre+=(--tenant "\$SPOOL_TENANT")
[ -n "\${SPOOL_BOX:-}" ] && pre+=(--box "\$SPOOL_BOX")
exec bash "$AGENT_SH" "\${pre[@]}" "\$@"
EOF
  chmod 755 "$SHIM.tmp" && mv -f "$SHIM.tmp" "$SHIM" || die 7 "cannot write $SHIM"
  say "spool-agent: $SHIM"
  case ":$PATH:" in *":$BIN:"*) ;; *) say "WARN $BIN is not on your PATH: add  export PATH=\"$BIN:\$PATH\"  to your shell rc" ;; esac
fi

# ── 5. the mirror hooks ───────────────────────────────────────────────────────
SETTINGS="$HOME/.claude/settings.json"
if [ "$HOOKS" = 1 ]; then
  if [ "$DRY" = 1 ]; then plan "merge the mirror hooks (./run -a do_spl_desk_mirror_settings) into $SETTINGS"
  else
    hooks="$("$RUN" -a do_spl_desk_mirror_settings 2>/dev/null | sed -n '/^{/,/^}/p')"
    [ -n "$hooks" ] || die 6 "do_spl_desk_mirror_settings printed no hooks"
    mkdir -p "${SETTINGS%/*}"
    # Every older spool-mirror entry (a moved checkout, a second clone) is
    # replaced, never added to: two copies post every prompt twice.
    printf '%s' "$hooks" | python3 -c '
import json, os, sys
path = sys.argv[1]
new = json.load(sys.stdin)["hooks"]
cur = {}
if os.path.exists(path) and os.path.getsize(path) > 0:
    with open(path) as f: cur = json.load(f)
    bak = path + ".bak-spool-install"
    if not os.path.exists(bak):
        with open(bak, "w") as f: json.dump(cur, f, indent=2)
hk = cur.setdefault("hooks", {})
for ev, entries in new.items():
    keep = [e for e in hk.get(ev, []) if "spool-mirror.py" not in json.dumps(e)]
    hk[ev] = keep + entries
tmp = path + ".tmp"
with open(tmp, "w") as f: json.dump(cur, f, indent=2); f.write("\n")
os.replace(tmp, path)
' "$SETTINGS" || die 6 "cannot merge the hooks into $SETTINGS (is it valid JSON?)"
    say "mirror hooks: $SETTINGS"
  fi
fi

# ── 5b. the agent harness: skills, slash commands, tmux snippet (specs/048) ──
HARNESS_DIR="$ORC/src/bash/features/spawn-agents"
if [ "$SKILLS" = 1 ]; then
  QWEN_SKILLS=0
  for c in "${CLI_LIST[@]}"; do [ "$c" = qwen ] && QWEN_SKILLS=1; done
  [ -d "$HOME/.qwen" ] && QWEN_SKILLS=1
  if [ "$DRY" = 1 ]; then
    plan "render $HARNESS_DIR/assets commands + skills into $HOME/.claude$([ "$QWEN_SKILLS" = 1 ] && echo " and $HOME/.qwen/skills") (hand-edited files kept)"
    plan "copy the tmux snippet to $DATA/tmux-agent-status.conf"
  else
    python3 - "$HARNESS_DIR/assets" "$HOME" "$QWEN_SKILLS" "$FORCE_SKILLS" \
      "$HARNESS_DIR" "${SPOOL_ROOT:-/var/spool-hub}" "${SPOOL_AGENT_CEILING:-40}" "${SPOOL_ORCHESTRATOR_ID:-CLE-00}" <<'EOF_PY' || die 6 "cannot render the harness skills"
import hashlib, os, re, sys
assets, home, qwen, force, harness, root, ceiling, orc = sys.argv[1:]
MARK = re.compile(r"\n<!-- spool-install: sha256=([0-9a-f]{64}) -->\n?")
subst = {"HARNESS_DIR": harness, "SPOOL_ROOT": root, "AGENT_CEILING": ceiling, "ORCHESTRATOR_ID": orc}
def render(src):
    t = open(src).read()
    t = re.sub(r"\{\{([A-Z_]+)\}\}", lambda m: subst[m.group(1)], t)
    return t + "\n<!-- spool-install: sha256=%s -->\n" % hashlib.sha256(t.encode()).hexdigest()
jobs = []
for f in sorted(os.listdir(os.path.join(assets, "commands"))):
    n = f[:-3]
    src = os.path.join(assets, "commands", f)
    jobs.append((src, os.path.join(home, ".claude", "commands", f)))
    if qwen == "1":
        jobs.append((src, os.path.join(home, ".qwen", "skills", n, "SKILL.md")))
for n in sorted(os.listdir(os.path.join(assets, "skills"))):
    src = os.path.join(assets, "skills", n, "SKILL.md")
    jobs.append((src, os.path.join(home, ".claude", "skills", n, "SKILL.md")))
    if qwen == "1":
        jobs.append((src, os.path.join(home, ".qwen", "skills", n, "SKILL.md")))
wrote = same = 0
for src, dst in jobs:
    new = render(src)
    if os.path.exists(dst):
        cur = open(dst).read()
        if cur == new:
            same += 1
            continue
        m = MARK.search(cur)
        if not m:
            print("spool-install: skills: %s is not ours (no spool-install marker): left alone" % dst, file=sys.stderr)
            continue
        body = cur[:m.start()] + cur[m.end():]
        if hashlib.sha256(body.encode()).hexdigest() != m.group(1):
            if force != "1":
                print("spool-install: skills: %s was edited by hand: left alone (--force-skills overwrites it)" % dst, file=sys.stderr)
                continue
            open(dst + ".bak-spool-install", "w").write(cur)
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    tmp = dst + ".tmp.%d" % os.getpid()
    open(tmp, "w").write(new)
    os.replace(tmp, dst)
    wrote += 1
print("spool-install: skills: %d written, %d already current" % (wrote, same), file=sys.stderr)
EOF_PY
    mkdir -p "$DATA" && sed "s#{{HARNESS_DIR}}#$HARNESS_DIR#g" "$HARNESS_DIR/assets/tmux-agent-status.conf" >"$DATA/tmux-agent-status.conf" ||
      die 6 "cannot copy the tmux snippet to $DATA"
    say "tmux: add this line to ~/.tmux.conf for the window-access keys:  source-file $DATA/tmux-agent-status.conf"
  fi
fi

# ── 6. the seat ───────────────────────────────────────────────────────────────
if [ "$SEAT" = 1 ]; then
  if [ "$DRY" = 1 ]; then plan "key + pin $BOX in $TENANT at $SPOOL_HUB_URL ($ENVN; ./run -a do_spl_desk_pin${ROOT_KEY_JSON:+, with ROOT_KEY_JSON})"
  else
    out="$(PATH="$TPATH:$PATH" env ENV="$ENVN" TENANT_ID="$TENANT" DESK_BOX="$BOX" SPOOL_HUB_URL="$SPOOL_HUB_URL" \
      ROOT_KEY_JSON="${ROOT_KEY_JSON:-}" DRY_RUN=0 "$RUN" -a do_spl_desk_pin 2>&1)"; rc=$?
    json="$(printf '%s\n' "$out" | grep -m1 '^{')"
    if [ "$rc" -eq 0 ] && printf '%s' "$json" | grep -q '"pinned": true'; then
      say "seated: $BOX is pinned in $TENANT ($ENVN) - start an agent with:  spool-agent claude"
    elif printf '%s' "$json" | grep -q '"pinned": false'; then
      admin="$(printf '%s' "$json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["admin_cmd"])')"
      pub="$(printf '%s' "$json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["box_pubkey"])')"
      say "seat PENDING: $BOX is not pinned in $TENANT yet. Send your tenant admin this ONE line:"
      echo "SPOOL_HUB_URL=$SPOOL_HUB_URL SPOOL_TENANT=$TENANT spool hub-pin --box $BOX --pubkey $pub --root-key <root private key: a file, the key text, or - for stdin>"
      say "(or, from their clone of this repo: $admin)"
      say "then re-run install.sh: it picks the pin up."
    else
      printf '%s\n' "$out" | grep -E 'FATAL|FAIL|WARN' | tail -3 >&2
      die 5 "the seat failed (rc $rc)"
    fi
  fi
fi
[ "$DRY" = 1 ] && say "DRY RUN - nothing changed"
[ "${#CLI_FAILED[@]}" -eq 0 ] || die 4 "not installed: ${CLI_FAILED[*]} (every other step ran; re-run install.sh --cli ${CLI_FAILED[*]// /,} to retry)"
exit 0
