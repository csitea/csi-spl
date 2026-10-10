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
#      `npm install -g` into <prefix>, which needs Node 20+ and npm).
#      mistral is the exception (spec 110 2.2): EXACTLY the cnf pin
#      env.box.mistral_vibe.version of the PyPI package mistral-vibe, through
#      `uv tool install` (pipx when there is no uv), never `curl | bash`;
#      a vibe already at the pin is not reinstalled. Then the flag contract
#      (vibe --help names --auto-approve, --resume, --continue and -p, else
#      the pin is refused), the dependency list, active_model in
#      ~/.vibe/config.toml (written when absent; one set by hand is kept and
#      named), ask_user_question in its top-level disabled_tools (a TUI
#      dialog no seat answers; other entries kept, never duplicated), and the
#      login file's mode and owner (never its content)
#   2. the toolchain the harness runs on: yq (v4) into <data>/tools, and the
#      `spool` binary, linked as <prefix>/bin/spool (a real file there is left
#      alone). spool is DOWNLOADED (spec 072 A4b): spool-<os>-<arch> of the
#      newest stable-* release of this clone's GitHub origin, checked against
#      the release's spool-SHA256SUMS - no Go needed. Only when that is
#      impossible (no release, no asset for this OS/arch, no SHA256SUMS,
#      offline) is it built from this checkout, with Go downloaded into
#      <data>/tools when not present; one line says which path ran and why.
#      A checksum mismatch is refused (exit 6), never built around. A --fleet
#      box and a shared copy (SPOOL_INSTALL_SHARED) always build: their binary
#      carries this checkout's commit
#   3. the `spool-agent` command in <prefix>/bin, a shim that runs this
#      checkout's spool-agent.sh with your env / tenant / box
#   4. the terminal mirror hooks in ~/.claude/settings.json (claude and grok
#      both read it; the hook does nothing in a session that has no agent id)
#   4b. the agent harness (specs/048): the slash commands and skills of
#      spawn-agents/assets rendered into ~/.claude/commands, ~/.claude/skills
#      and (with qwen) ~/.qwen/skills, (with agy) ~/.gemini/config/skills;
#      the tmux window-access snippet copied
#      to <data>. A rendered file carries a sha256 marker: a re-run rewrites
#      it only while it is untouched; a hand-edited one is left alone and
#      named, a same-named file we did not write is never touched
#   5. your box on a tenant: its key, and its pin at the hub. The hub pins a
#      box only with the tenant root key: with ROOT_KEY_JSON you pin it
#      yourself; without, the seat is PENDING - this prints the one line your
#      tenant admin runs, and exits 0; re-running install.sh picks the pin up.
#      The hub is checked first (GET <hub>/version): one that does not answer,
#      fails TLS or returns an error is exit 5 naming the URL, before anything
#      is installed
#   6. only with --fleet: the fleet's ~/.claude/CLAUDE.md block, its settings
#      (skipDangerousModePermissionPrompt among them) and the browser MCP
#      entrypoints, and the same fleet rules into ~/.vibe/AGENTS.md (vibe
#      loads AGENTS.md, never CLAUDE.md: spec 110), and the lane rule into
#      agy's ~/.gemini/config/rules and qwen's ~/.qwen/QWEN.md. Without it your own
#      Claude Code and vibe setup is left as it is
#   6b. only with --fleet, and only as the agent user (SPOOL_AGENT_USER, else
#      the box config's): `pkill` and `killall` guards in <prefix>/bin that
#      refuse `pkill -f` and every `killall` (steps/y11-kill-guard.sh)
#   6c. when ~/.vibe exists: the Mistral Vibe push guard, a strict pre_tool
#      hook that refuses force pushes to master (steps/y12-vibe-push-guard.sh;
#      both users of a box: ./run -a do_spl_vibe_push_guard_install)
#   6d. only with --fleet: the force-push block - a pre-tool hook on the
#      shared matcher plus deny rules - in claude, grok, agy and qwen
#      (steps/y13-force-push-guard.sh; both homes: do_install_force_push_guard)
# Re-running it is safe: every step checks before it changes anything.
#
# Options:
#   --cli <list>      comma list of claude,grok,agy,qwen,mistral, or none (default claude)
#   --cli-only        ONLY step 2, the CLIs of --cli: no toolchain, config,
#                     shim, hooks, skills or seat (do_install_mistral_vibe)
#   --env dev|prd|self  the hub environment (default $SPOOL_ENV, else self when
#                     SPOOL_HUB_URL is set, else dev);
#                     self = your own hub at SPOOL_HUB_URL, any host - e.g. the
#                     docker compose stack of this repo (specs/047 W4)
#   --tenant <slug>   the tenant (default $SPOOL_TENANT)
#   --box <box>       your box id (default $SPOOL_BOX, else box-<user>-<host>)
#   --no-seat         skip step 5 (no hub needed)
#   --fleet           also step 6: the fleet's CLAUDE.md, settings and browser
#                     MCP (the fleet's own boxes pass it). Remembered: a re-run
#                     keeps it, as it does on a home that already has the
#                     fleet block; SPOOL_INSTALL_FLEET=0 turns it off
#   --no-hooks        skip step 4 (spool-agent then passes the hooks per session)
#   --no-skills       skip step 4b
#   --force-skills    step 4b also overwrites a hand-edited rendered file
#                     (the old one is kept as <file>.bak-spool-install)
#   --update          `git pull --ff-only` this checkout first (clean checkouts only)
#   --binary-only     ONLY rebuild the spool binary in <data>/tools/bin (and its
#                     <prefix>/bin link): no CLI, no config, no shim, no hooks,
#                     no skills, no .bashrc, no CLAUDE.md, no mcp-bot, no seat.
#                     The old binary is kept as spool.bak; the new one must run
#                     `spool version` and carry this checkout's HEAD (or
#                     SPOOL_INSTALL_EXPECT_REV) as its commit, else the old
#                     one is put back and it exits 6
#   --dry-run         print the plan; change nothing
#
# Env: SPOOL_HUB_URL - required unless --no-seat; the hub URL, no default.
#      With --env dev|prd it must be that env's hub; with --env self it is
#      any hub (http://localhost:8080 for the compose stack on this machine).
#      A re-run takes env / tenant / box / hub from ~/.config/spool-agent/env
#      ROOT_KEY_JSON - the tenant's 0600 create JSON, or a 0600 file with the
#      bare root key (the compose stack's tenant-root.key): pin the box yourself
#      SPOOL_INSTALL_PREFIX - default $HOME/.local (bin/ and share/ under it)
#      SPOOL_INSTALL_SHARED - the ONE spool binary of this machine (a file
#      path every user can read, e.g. /var/<org>/<org>-<app>/spool/bin/spool):
#      the build goes there and <data>/tools/bin/spool becomes a link to it (a
#      real file there is kept as spool.bak), so one refresh reaches every
#      user linked to it. Default: where <data>/tools/bin/spool already links.
#      SPOOL_INSTALL_SHARED_GROUP - chgrp a newly made shared dir (mode 2775)
#      SPOOL_INSTALL_NO_BUILD=1 - with SPOOL_INSTALL_SHARED, --binary-only only
#      LINKS to the shared copy another user built and verified: no Go, no
#      build; a missing shared copy fails (exit 6)
#      SPOOL_INSTALL_CLI - auto (default: download, build as the fallback),
#      download (no build: a download that is impossible is exit 6) or build
#      SPOOL_INSTALL_REPO - <owner>/<repo> whose releases carry the CLI
#      (default: this clone's origin, when it is on GitHub)
#      SPOOL_INSTALL_URL_RELEASES - the releases list (default the GitHub API
#      for SPOOL_INSTALL_REPO); SPOOL_INSTALL_URL_CLI - the download base,
#      <base>/<tag>/<asset> (default that repo's releases/download)
#      SPOOL_INSTALL_URL_CLAUDE / _GROK / _AGY / _GO / _YQ - a download mirror
#      SPOOL_INSTALL_NPM_QWEN - the qwen npm package (default @qwen-code/qwen-code@latest)
#      SPOOL_INSTALL_NPM - the npm command (default npm)
#      SPOOL_INSTALL_MISTRAL_VERSION - the mistral-vibe pin, X.Y.Z (default
#      the cnf env.box.mistral_vibe.version of this checkout; latest or an
#      empty pin is exit 2); SPOOL_INSTALL_MISTRAL_MODEL - active_model
#      (default the cnf env.box.mistral_vibe.model, else mistral-vibe-cli-latest)
#      SPOOL_INSTALL_UV / SPOOL_INSTALL_PIPX / SPOOL_INSTALL_PYTHON - the uv,
#      pipx and python3 commands (mistral needs python 3.12+, else exit 2)
#      SPOOL_ROOT / SPOOL_AGENT_CEILING / SPOOL_ORCHESTRATOR_ID - rendered into
#      the skills (defaults $XDG_STATE_HOME/spool-hub - ~/.local/state/spool-hub
#      without it, /var/spool-hub with --fleet -, 40 and the role orchestrator)
#      SPOOL_INSTALL_BUILD / SPOOL_INSTALL_RUN - the spool build and ./run (tests)
#      SPOOL_INSTALL_BINREV - prints a binary's commit (tests; default go version -m)
#
# Exit codes: 0 done (a PENDING seat included), 2 usage, 3 a base tool is
# missing, 4 an agent CLI did not install (every other step still ran), 5 the
# hub did not answer or the seat failed (the URL is named), 6 the toolchain
# or the spool build failed, or the downloaded spool failed its checksum,
# 7 a file in the way is not ours.
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
FLEET="${SPOOL_INSTALL_FLEET:-$(cfg_get SPOOL_INSTALL_FLEET)}"
[ -n "${SPOOL_HUB_URL:-}" ] || SPOOL_HUB_URL="$(cfg_get SPOOL_HUB_URL)"
[ -n "$SPOOL_HUB_URL" ] || unset SPOOL_HUB_URL
SEAT=1 HOOKS=1 SKILLS=1 FORCE_SKILLS=0 UPDATE=0 DRY=0 BINONLY=0 CLIONLY=0
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
    --fleet)    FLEET=1; shift ;;
    --no-hooks) HOOKS=0; shift ;;
    --no-skills) SKILLS=0; shift ;;
    --force-skills) FORCE_SKILLS=1; shift ;;
    --update)   UPDATE=1; shift ;;
    --dry-run)  DRY=1; shift ;;
    --binary-only) BINONLY=1; shift ;;
    --cli-only) CLIONLY=1; shift ;;
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

# --binary-only touches nothing but the binary: no CLI, no seat (step 6), and
# it stops after the link, before the config, shim, hooks and harness steps.
[ "$BINONLY" = 1 ] && { CLIS=none SEAT=0; }
# --cli-only stops after step 2: no seat, so no hub is needed.
[ "$CLIONLY" = 1 ] && SEAT=0
# ── 0. arguments and base tools ──────────────────────────────────────────────
# A hub URL and no env is someone's own hub (spec 072 A50), never our dev.
[ -n "$ENVN" ] || { [ -n "${SPOOL_HUB_URL:-}" ] && ENVN=self || ENVN=dev; }
# The fleet config is opt-in (spec 072 A49); a home that already carries the
# fleet's CLAUDE.md block is a fleet box that predates the option.
if [ -z "$FLEET" ]; then
  grep -qF '<!-- spool-install: begin claude-md' "$HOME/.claude/CLAUDE.md" 2>/dev/null && FLEET=1 || FLEET=0
fi
[[ "$FLEET" =~ ^[01]$ ]] || die 2 "SPOOL_INSTALL_FLEET must be 0 or 1, got '$FLEET'"
CLI_MODE="${SPOOL_INSTALL_CLI:-auto}"
[[ "$CLI_MODE" =~ ^(auto|download|build)$ ]] || die 2 "SPOOL_INSTALL_CLI must be auto, download or build, got '$CLI_MODE'"
[[ "$ENVN" =~ ^(dev|prd|self)$ ]] || die 2 "--env must be dev, prd or self (a self-hosted hub), got '$ENVN'"
[ "$CLIS" = none ] && CLIS=""
IFS=, read -r -a CLI_LIST <<<"$CLIS"
for c in "${CLI_LIST[@]}"; do
  case "$c" in claude|grok|agy|qwen|mistral) ;; *) die 2 "--cli takes claude,grok,agy,qwen,mistral or none, got '$c'" ;; esac
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
# mistral (spec 110 2.2): the pin, a python 3.12+ and uv or pipx, up front.
UV="${SPOOL_INSTALL_UV:-uv}" PIPX="${SPOOL_INSTALL_PIPX:-pipx}" PY="${SPOOL_INSTALL_PYTHON:-python3}"
# cnf_mistral <key>: env.box.mistral_vibe.<key> of this checkout's cnf, read
# without yq (step 3 installs yq; this runs before it).
cnf_mistral() {
  local app; app="$(basename "$ORC" | sed 's/-orc$//')"
  awk -v k="$1" '
    /^[[:space:]]*mistral_vibe:[[:space:]]*$/ { match($0, /^[[:space:]]*/); ind = RLENGTH; on = 1; next }
    on { match($0, /^[[:space:]]*/); if ($0 !~ /^[[:space:]]*(#|$)/ && RLENGTH <= ind) on = 0 }
    on && $1 == k ":" { v = $2; gsub(/["\047]/, "", v); print v; exit }
  ' "$ROOT/$app-cnf/$app/all.env.yaml" 2>/dev/null
}
# a bare uv / pipx off PATH: the user-local one (their installers' default
# dir, which a `sudo -u <agent>` PATH lacks)
command -v "$UV" >/dev/null 2>&1 || [ ! -x "$HOME/.local/bin/$UV" ] || UV="$HOME/.local/bin/$UV"
command -v "$PIPX" >/dev/null 2>&1 || [ ! -x "$HOME/.local/bin/$PIPX" ] || PIPX="$HOME/.local/bin/$PIPX"
for c in "${CLI_LIST[@]}"; do
  [ "$c" = mistral ] || continue
  MISTRAL_PIN="${SPOOL_INSTALL_MISTRAL_VERSION-$(cnf_mistral version)}"
  MISTRAL_MODEL="${SPOOL_INSTALL_MISTRAL_MODEL:-$(cnf_mistral model)}"
  MISTRAL_MODEL="${MISTRAL_MODEL:-mistral-vibe-cli-latest}"
  [[ "$MISTRAL_PIN" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
    die 2 "--cli mistral installs one pinned version X.Y.Z (cnf env.box.mistral_vibe.version or SPOOL_INSTALL_MISTRAL_VERSION), got '${MISTRAL_PIN}': never latest"
  [[ "$MISTRAL_MODEL" =~ ^[A-Za-z0-9._:-]+$ ]] || die 2 "bad mistral model '$MISTRAL_MODEL'"
  pyv="$("$PY" -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null)"
  [ -n "$pyv" ] && [ "${pyv%%.*}" -eq 3 ] && [ "${pyv#*.}" -ge 12 ] ||
    die 2 "--cli mistral needs python 3.12 or newer (mistral-vibe requires_python >=3.12), $PY is ${pyv:-missing} - install python3.12+ (this needs root, so it is yours to run), or set SPOOL_INSTALL_PYTHON"
  command -v "$UV" >/dev/null 2>&1 || command -v "$PIPX" >/dev/null 2>&1 ||
    die 3 "--cli mistral needs uv or pipx - install one first (this needs root, so it is yours to run), e.g.: sudo apt-get install -y pipx"
done
command -v tmux >/dev/null 2>&1 || say "WARN tmux is missing: spool-agent seats an agent only inside tmux (sudo apt-get install -y tmux)"

fetch() {  # URL OUT
  if command -v curl >/dev/null 2>&1; then curl -fsSL --connect-timeout 30 --max-time 1800 --speed-limit 1024 --speed-time 60 --retry 2 -o "$2" "$1"; else wget -q -O "$2" "$1"; fi
}
plan() { [ "$DRY" = 1 ] && echo "would: $*"; }
# The hub answers before anything is installed: a wrong URL, bad TLS or a 404
# is exit 5 naming the URL, never a PENDING seat (spec 072 A50).
if [ "$SEAT" = 1 ]; then
  probe="${SPOOL_HUB_URL%/}/version"
  if [ "$DRY" = 1 ]; then plan "check that the hub answers $probe"
  else
    if command -v curl >/dev/null 2>&1; then err="$(curl -fsS --max-time 15 -o /dev/null "$probe" 2>&1)"
    else err="$(wget -nv -T 15 -O /dev/null "$probe" 2>&1)"; fi ||
      die 5 "the hub at $SPOOL_HUB_URL does not answer $probe (${err:-no detail}): check SPOOL_HUB_URL and --env ($ENVN), or pass --no-seat, then re-run install.sh"
  fi
fi

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
  say "qwen: $have ($("$have" --version 2>/dev/null | sed -n 1p))"
}
# mistral (spec 110 2.2): the cnf pin of mistral-vibe, through uv, else pipx.
# Every vibe call runs with MISTRAL_API_KEY unset: an exported one beats
# ~/.vibe/.env, and nothing here needs a key.
vibe_version() { env -u MISTRAL_API_KEY "$1" --version 2>/dev/null | sed -n '1s/^vibe[[:space:]]*//p'; }
# vibe_disable_tool <cfg> <tool>: <tool> in the top-level disabled_tools of
# vibe's config.toml, idempotently. An existing list (one line or several)
# keeps its entries and gets <tool> first; with none, a one-entry list goes
# before the first table, where a top-level key must live in TOML.
vibe_disable_tool() {
  local cfg="$1" tool="$2" tmp act
  tmp="$(mktemp "$(dirname "$cfg")/.config.toml.XXXXXX")" || { cli_fail mistral "no temp file for $cfg"; return 1; }
  act="$(awk -v t="$tool" -v q="'" '
    function add() { print "disabled_tools = [\"" t "\"]"; done = 1; act = "added" }
    BEGIN { top = 1 }
    top && /^[[:space:]]*\[/ { if (!done) add(); top = 0 }
    top && !done && !arr && /^[[:space:]]*disabled_tools[[:space:]]*=/ { arr = 1; buf = "" }
    arr { buf = buf $0 "\n"; if (index($0, "]") == 0) next
          arr = 0; done = 1
          if (index(buf, "\"" t "\"") || index(buf, q t q)) { act = "kept"; printf "%s", buf; next }
          if (!sub(/=[[:space:]]*\[[[:space:]]*\]/, "= [\"" t "\"]", buf)) sub(/=[[:space:]]*\[/, "= [\"" t "\", ", buf)
          act = "added"; printf "%s", buf; next }
    { print }
    END { if (!done) add(); print act > "/dev/stderr" }' "$cfg" 2>&1 >"$tmp")" && [ -s "$tmp" ] ||
    { rm -f "$tmp"; cli_fail mistral "cannot read $cfg"; return 1; }
  if [ "$act" = kept ]; then rm -f "$tmp"; say "mistral: disabled_tools has $tool in $cfg"; return 0; fi
  chmod 600 "$tmp" && mv -f "$tmp" "$cfg" || { rm -f "$tmp"; cli_fail mistral "cannot write $cfg"; return 1; }
  say "mistral: $tool added to disabled_tools in $cfg (a TUI dialog no seat answers)"
}
mistral_install() {
  local have="$1" cur="" cmd miss="" f help d cfg tmp m n
  [ -n "$have" ] && cur="$(vibe_version "$have")"
  if command -v "$UV" >/dev/null 2>&1; then cmd=("$UV" tool install --force "mistral-vibe==$MISTRAL_PIN")
  else cmd=("$PIPX" install --force "mistral-vibe==$MISTRAL_PIN"); fi
  if [ -n "$cur" ] && [ "$cur" = "$MISTRAL_PIN" ]; then say "mistral: $have is at the pin $MISTRAL_PIN: not reinstalled"
  elif [ "$DRY" = 1 ]; then plan "${cmd[*]}${cur:+ (have $cur)}"
  else
    say "installing mistral-vibe $MISTRAL_PIN (${cmd[*]})${cur:+, replacing $cur}"
    env -u MISTRAL_API_KEY "${cmd[@]}" >&2 || { cli_fail mistral "${cmd[*]} failed"; return 0; }
  fi
  say "mistral: launch line: env -u MISTRAL_API_KEY vibe --auto-approve (the launcher never inherits a key from the env)"
  [ -n "${MISTRAL_API_KEY+x}" ] && say "WARN mistral: MISTRAL_API_KEY is set in this environment; it would beat ~/.vibe/.env, so every vibe call here runs without it"
  if [ "$DRY" = 1 ]; then
    plan "check vibe --version = $MISTRAL_PIN and the flag contract (--auto-approve --resume --continue -p), list the dependencies, set active_model = \"$MISTRAL_MODEL\" in $HOME/.vibe/config.toml when it has none, add ask_user_question to its disabled_tools"
    return 0
  fi
  have="$(cli_path vibe)"; [ -n "$have" ] || { cli_fail mistral "no vibe binary on PATH or in $BIN after the install"; return 0; }
  cur="$(vibe_version "$have")"
  [ "$cur" = "$MISTRAL_PIN" ] || { cli_fail mistral "$have is ${cur:-unknown}, the pin is $MISTRAL_PIN"; return 0; }
  help="$(env -u MISTRAL_API_KEY "$have" --help 2>&1)"
  for f in --auto-approve --resume --continue -p; do
    grep -qE -- "(^|[[:space:],[])$f([],[:space:]]|\$)" <<<"$help" || miss="$miss $f"
  done
  [ -z "$miss" ] || { cli_fail mistral "vibe $cur lacks the flag contract:$miss - the pin $MISTRAL_PIN is refused (spec 110 2.2)"; return 0; }
  say "mistral: flag contract ok (--auto-approve --resume --continue -p)"
  # the transitive dependencies float under ==<pin>: name what this box got
  if [ "${cmd[0]}" = "$UV" ]; then d="$("$UV" pip freeze --python "$(dirname "$(readlink -f "$have")")/python" 2>/dev/null)"
  else d="$("$PIPX" runpip mistral-vibe freeze 2>/dev/null)"; fi
  n="$(grep -c . <<<"$d")"
  say "mistral: $n dependencies of mistral-vibe $cur:"; [ -n "$d" ] && sed 's/^/spool-install:   dep /' <<<"$d" >&2
  # active_model: an unset one lets the vendor route the session elsewhere.
  d="$HOME/.vibe" cfg="$HOME/.vibe/config.toml"
  mkdir -p "$d" && chmod 700 "$d" || { cli_fail mistral "cannot create $d"; return 0; }
  m="$(sed -n 's/^[[:space:]]*active_model[[:space:]]*=[[:space:]]*"\{0,1\}\([^"]*\)"\{0,1\}[[:space:]]*$/\1/p' "$cfg" 2>/dev/null)"; m="${m%%$'\n'*}"
  if [ -z "$m" ]; then
    tmp="$(mktemp "$d/.config.toml.XXXXXX")" || { cli_fail mistral "no temp file in $d"; return 0; }
    { printf 'active_model = "%s"\n' "$MISTRAL_MODEL"; if [ -f "$cfg" ]; then cat "$cfg"; fi; } >"$tmp" && chmod 600 "$tmp" && mv -f "$tmp" "$cfg" ||
      { rm -f "$tmp"; cli_fail mistral "cannot write $cfg"; return 0; }
    say "mistral: active_model = \"$MISTRAL_MODEL\" written to $cfg"
  elif [ "$m" = "$MISTRAL_MODEL" ]; then say "mistral: active_model = \"$m\" in $cfg (the cnf model)"
  else say "WARN mistral: $cfg keeps active_model = \"$m\", set by hand; the cnf model is $MISTRAL_MODEL"
  fi
  # ask_user_question opens a TUI dialog nobody answers: the seat waits for
  # the watchdog's 15-min cap (m-682, m-740). vibe -p disables it itself.
  vibe_disable_tool "$cfg" ask_user_question || return 0
  say "mistral: telemetry off switch: none written yet (spec 110 T005 measures the egress first)"
  # the login: its mode and owner only, never its content
  if [ -f "$d/.env" ]; then
    m="$(stat -c '%a %U' "$d/.env" 2>/dev/null)"
    [ "${m%% *}" = 600 ] && say "mistral: login $d/.env mode ${m% *} owner ${m#* }" ||
      say "WARN mistral: login $d/.env is mode ${m% *} (owner ${m#* }), want 600: chmod 600 it"
  else say "mistral: no login yet ($d/.env): run do_set_mistral_key; until then lane-mix skips mistral on this box"
  fi
  say "mistral: $have (vibe $cur)"
}
for c in "${CLI_LIST[@]}"; do
  [ "$c" = mistral ] && { mistral_install "$(cli_path vibe)"; continue; }
  url="$(cli_url "$c")"; have="$(cli_path "$c")"
  [ "$c" = qwen ] && { qwen_install "$have"; continue; }
  # agy's installer stops at "already installed"; its own `update` is the
  # documented way to the latest. claude's and grok's installers update in place.
  if [ "$c" = agy ] && [ -n "$have" ]; then
    if [ "$DRY" = 1 ]; then plan "$have update"; continue; fi
    "$have" update >&2 || say "WARN '$have update' failed; keeping $("$have" --version 2>/dev/null | sed -n 1p)"
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
  say "$c: $have ($("$have" --version 2>/dev/null | sed -n 1p))"
done

if [ "$CLIONLY" = 1 ]; then
  [ "$DRY" = 1 ] && say "DRY RUN - nothing changed"
  [ "${#CLI_FAILED[@]}" -eq 0 ] || die 4 "not installed: ${CLI_FAILED[*]} (re-run install.sh --cli-only --cli ${CLI_FAILED[*]// /,} to retry)"
  exit 0
fi

# ── 3. toolchain: yq, Go, spool ───────────────────────────────────────────────
TPATH="$TOOLS/bin:$TOOLS/go/bin"
export PATH="$TPATH:$PATH"
yq_ok() { yq --version 2>/dev/null | grep -E 'mikefarah|version v?4\.' >/dev/null; }
if [ "$BINONLY" = 0 ] && ! yq_ok; then
  url="${SPOOL_INSTALL_URL_YQ:-https://github.com/mikefarah/yq/releases/latest/download}/yq_${OS}_${ARCH}"
  if [ "$DRY" = 1 ]; then plan "download yq v4 into $TOOLS/bin/yq ($url)"
  else
    mkdir -p "$TOOLS/bin" && fetch "$url" "$TOOLS/bin/yq.tmp" && chmod 755 "$TOOLS/bin/yq.tmp" &&
      mv -f "$TOOLS/bin/yq.tmp" "$TOOLS/bin/yq" || die 6 "cannot download yq from $url"
    yq_ok || die 6 "$TOOLS/bin/yq is not yq v4"
  fi
fi
TOOLS_SPOOL="$TOOLS/bin/spool"
# One installed copy per machine: SPOOL_INSTALL_SHARED, else the file the
# tools path already links to (so a full install by any linked user rebuilds
# the shared copy instead of splitting it again).
SHARED="${SPOOL_INSTALL_SHARED:-}"
[ -z "$SHARED" ] && [ -L "$TOOLS_SPOOL" ] && SHARED="$(readlink -f "$TOOLS_SPOOL")"
SPOOL="${SHARED:-$TOOLS_SPOOL}"

# spool from the newest stable-* release (spec 072 A4b): wf 55 attaches
# spool-<os>-<arch> and spool-SHA256SUMS (sha256sum -c format) to each one.
sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
  else return 1; fi
}
CLI_ASSET="spool-$OS-$ARCH"
CLI_REPO="${SPOOL_INSTALL_REPO:-$(git -C "$ROOT" remote get-url origin 2>/dev/null |
  sed -nE 's#^(https://|ssh://git@|git@)github\.com[:/]([^/]+/[^/]+)$#\2#p' | sed 's/\.git$//')}"
CLI_RELEASES="${SPOOL_INSTALL_URL_RELEASES:-https://api.github.com/repos/$CLI_REPO/releases?per_page=30}"
CLI_BASE="${SPOOL_INSTALL_URL_CLI:-https://github.com/$CLI_REPO/releases/download}"
# cli_download: 0 = $SPOOL is the release asset (downloaded, or already that
# file); 1 = a download is impossible, the reason in CLI_WHY (the caller
# builds). A checksum mismatch is exit 6 here: never installed, never built
# around, since a tampered or truncated asset is not "no release".
cli_download() {
  local tmp="" tag="" has_asset="" has_sums="" want="" got="" ver=""
  [ -n "$CLI_REPO" ] || { CLI_WHY="the origin of $ROOT is not a GitHub repo, so there is no release to read (set SPOOL_INSTALL_REPO=<owner>/<repo>)"; return 1; }
  sha256_of /dev/null >/dev/null || { CLI_WHY="neither sha256sum nor shasum is here to check a download"; return 1; }
  tmp="$(mktemp -d)"
  fetch "$CLI_RELEASES" "$tmp/rel.json" || { rm -rf "$tmp"; CLI_WHY="cannot read the releases at $CLI_RELEASES (offline, or the API rate limit)"; return 1; }
  read -r tag has_asset has_sums < <(python3 - "$tmp/rel.json" "$CLI_ASSET" <<'PY'
import json, sys
try:
    rels = json.load(open(sys.argv[1]))
except ValueError:
    rels = []
for r in rels if isinstance(rels, list) else []:
    if not str(r.get("tag_name", "")).startswith("stable-") or r.get("draft") or r.get("prerelease"):
        continue
    names = {a.get("name") for a in r.get("assets", [])}
    print(r["tag_name"], int(sys.argv[2] in names), int("spool-SHA256SUMS" in names))
    break
PY
)
  [ -n "$tag" ] || { rm -rf "$tmp"; CLI_WHY="no stable-* release at $CLI_RELEASES"; return 1; }
  [ "$has_asset" = 1 ] || { rm -rf "$tmp"; CLI_WHY="$tag has no $CLI_ASSET (this OS/arch)"; return 1; }
  [ "$has_sums" = 1 ] || { rm -rf "$tmp"; CLI_WHY="$tag publishes no spool-SHA256SUMS, so $CLI_ASSET cannot be checked"; return 1; }
  fetch "$CLI_BASE/$tag/spool-SHA256SUMS" "$tmp/sums" || { rm -rf "$tmp"; CLI_WHY="cannot download $CLI_BASE/$tag/spool-SHA256SUMS"; return 1; }
  want="$(awk -v f="$CLI_ASSET" '$2 == f || $2 == "*" f {print $1; exit}' "$tmp/sums")"
  [[ "$want" =~ ^[0-9a-f]{64}$ ]] || { rm -rf "$tmp"; CLI_WHY="$CLI_BASE/$tag/spool-SHA256SUMS lists no sha256 for $CLI_ASSET"; return 1; }
  if [ -x "$SPOOL" ] && [ ! -L "$SPOOL" ] && [ "$(sha256_of "$SPOOL")" = "$want" ]; then
    rm -rf "$tmp"; say "spool CLI: $SPOOL is already $CLI_ASSET of $tag (sha256 matches) - not downloaded again"; return 0
  fi
  fetch "$CLI_BASE/$tag/$CLI_ASSET" "$tmp/$CLI_ASSET" || { rm -rf "$tmp"; CLI_WHY="cannot download $CLI_BASE/$tag/$CLI_ASSET"; return 1; }
  got="$(sha256_of "$tmp/$CLI_ASSET")"
  [ "$got" = "$want" ] || { rm -rf "$tmp"; die 6 "the sha256 of $CLI_BASE/$tag/$CLI_ASSET is ${got:-unreadable}, its spool-SHA256SUMS says $want: refused, $SPOOL untouched. Re-run install.sh; if it repeats, report it and build from this checkout with SPOOL_INSTALL_CLI=build"; }
  chmod 755 "$tmp/$CLI_ASSET"
  ver="$("$tmp/$CLI_ASSET" version 2>/dev/null | sed -n 1p)"
  [ -n "$ver" ] || { rm -rf "$tmp"; CLI_WHY="$CLI_ASSET of $tag does not run here ('spool version' printed nothing)"; return 1; }
  mkdir -p "${SPOOL%/*}" && cp "$tmp/$CLI_ASSET" "$SPOOL.new.$$" && chmod 755 "$SPOOL.new.$$" ||
    { rm -rf "$tmp" "$SPOOL.new.$$"; die 6 "cannot write $SPOOL: check that ${SPOOL%/*} is yours, then re-run install.sh"; }
  rm -rf "$tmp"
  spool_swap "$SPOOL.new.$$"
  say "spool CLI: downloaded $CLI_ASSET of $tag ($CLI_BASE/$tag/$CLI_ASSET, sha256 checked against spool-SHA256SUMS) -> $SPOOL ($ver)"
}
# file_ugm <path>: "<uid> <gid> <octal mode>" (GNU stat, else BSD stat)
file_ugm() { stat -c '%u %g %a' "$1" 2>/dev/null || stat -f '%u %g %Lp' "$1" 2>/dev/null; }
# spool_swap <new>: rename <new> over $SPOOL - the ONE way every path (the
# download, the build, --binary-only) replaces the binary. A real file there
# is first kept as spool.bak (a temp copy renamed in, so spool.bak is always
# one whole binary), and its owner, group and mode go onto <new> before the
# rename. The right owner is the old file's: the box user, who owns the
# shared dir and runs its refreshes, so a refresh by an agent user must not
# hand the machine's one binary to that agent. A non-root user cannot give a
# file away: then the group and mode are kept (all a linked user needs to
# refresh it; the shared dir is 2775) and one WARN line names the new owner.
# The same bytes: nothing renamed, spool.bak keeps the build before it.
spool_swap() {
  local new="$1" bak="$SPOOL.bak" u g m nu ng
  if [ -f "$SPOOL" ] && [ ! -L "$SPOOL" ]; then
    if cmp -s "$new" "$SPOOL"; then rm -f "$new"; say "spool: $SPOOL is unchanged (the same bytes) - $bak kept as it was"; return 0; fi
    { cp -p "$SPOOL" "$bak.tmp.$$" && mv -f "$bak.tmp.$$" "$bak"; } ||
      { rm -f "$bak.tmp.$$" "$new"; die 6 "cannot back up $SPOOL to $bak; $SPOOL untouched"; }
    read -r u g m < <(file_ugm "$SPOOL")
    read -r nu ng _ < <(file_ugm "$new")
    if [ -n "$u" ] && [ "$nu" != "$u" ] && ! chown "$u:$g" "$new" 2>/dev/null; then
      say "WARN $SPOOL was owned by uid $u; this user ($(id -un)) cannot give a file away, so the new one is owned by uid $nu (group and mode kept)"
    fi
    read -r nu ng _ < <(file_ugm "$new")
    if [ -n "$g" ] && [ "$ng" != "$g" ] && ! chgrp "$g" "$new" 2>/dev/null; then
      say "WARN $SPOOL had group $g; this user is not in it, so the new one has group $ng"
    fi
    [ -z "$m" ] || chmod "$m" "$new" || { rm -f "$new"; die 6 "cannot set mode $m on the new $SPOOL; $SPOOL untouched"; }
    say "spool: the old $SPOOL kept as $bak"
  fi
  mv -f "$new" "$SPOOL" || { rm -f "$new"; die 6 "cannot rename the new binary into $SPOOL"; }
}
CLI_FROM=build CLI_WHY=""
if [ "$BINONLY" = 1 ]; then :  # --binary-only verifies this checkout's HEAD: always a build
elif [ "$CLI_MODE" = build ]; then CLI_WHY="SPOOL_INSTALL_CLI=build"
elif [ "$CLI_MODE" = auto ] && [ "$FLEET" = 1 ]; then CLI_WHY="a fleet box (--fleet) runs this checkout's own build"
elif [ "$CLI_MODE" = auto ] && [ -n "$SHARED" ]; then CLI_WHY="the shared copy $SHARED carries this checkout's commit"
elif [ "$DRY" = 1 ]; then
  CLI_FROM=plan
  plan "download $CLI_ASSET of the newest stable-* release (${CLI_REPO:-no GitHub origin}: $CLI_RELEASES), check it against spool-SHA256SUMS, install it as $SPOOL"
elif cli_download; then CLI_FROM=download
elif [ "$CLI_MODE" = download ]; then
  die 6 "SPOOL_INSTALL_CLI=download, but $CLI_WHY: unset SPOOL_INSTALL_CLI to build from this checkout instead, then re-run install.sh"
fi
[ "$BINONLY" = 1 ] || [ "$CLI_FROM" != build ] || say "spool CLI: building from this checkout - $CLI_WHY"

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
    [ -n "$v" ] && [ "$(printf '%s\n%s\n' "$GO_NEED" "$v" | sort -V | sed -n 1p)" = "$GO_NEED" ] && { GO_BIN="$g"; return 0; }
  done
  return 1
}
GO_BIN=""
FALLBACK=""; [ "$CLI_FROM" = plan ] && FALLBACK=" (only when the download is impossible)"
if [ "${SPOOL_INSTALL_NO_BUILD:-0}" = 1 ] || [ "$CLI_FROM" = download ]; then :
elif ! go_ok; then
  base="${SPOOL_INSTALL_URL_GO:-https://go.dev}"
  if [ "$DRY" = 1 ]; then plan "download the latest Go (>= $GO_NEED) into $TOOLS/go ($base/dl/)$FALLBACK"; GO_BIN="$TOOLS/go/bin/go"
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
if [ -n "$GO_BIN" ]; then
  go_dir="$(dirname "$GO_BIN")"

  # TPATH is copied into the spool-agent shim; PATH is this process, so the build below can run go.
  TPATH="$TPATH:$go_dir"
  PATH="$go_dir:$PATH"
  export PATH
fi
# bin_rev <bin>: the commit a spool binary was built from - build.sh's
# -X main.commit in the recorded -ldflags, else Go's vcs.revision.
bin_rev() {
  if [ -n "${SPOOL_INSTALL_BINREV:-}" ]; then "$SPOOL_INSTALL_BINREV" "$1"; return; fi
  "${GO_BIN:-go}" version -m "$1" 2>/dev/null | awk '
    $1 == "build" && match($0, /main\.commit=[0-9a-f]+/) { c = substr($0, RSTART + 12, RLENGTH - 12) }
    $2 ~ /^vcs\.revision=/ { sub(/^vcs\.revision=/, "", $2); r = $2 }
    END { if (c == "") c = r; print c }'
}
# bin_ok <bin> <want>: it runs `spool version` and carries commit <want>
bin_ok() {
  local v r
  v="$("$1" version 2>/dev/null | sed -n 1p)"
  [ -n "$v" ] || { say "FAIL $1: 'spool version' printed nothing"; return 1; }
  r="$(bin_rev "$1")"
  [ "$r" = "$2" ] || { say "FAIL $1 carries commit '${r:-none}', want $2"; return 1; }
  say "verified $1: version $v, commit $r"
}
# --binary-only: build to a temp file and verify it, keep the old binary as
# spool.bak, rename the new one in and verify again. A failure before the
# rename leaves the old binary untouched; after it, the old one is put back
# (or the new one removed when there was none). Either way: exit 6.
binary_only() {
  local want new="$SPOOL.new.$$" bak="$SPOOL.bak"
  want="${SPOOL_INSTALL_EXPECT_REV:-$(git -C "$ROOT" rev-parse HEAD 2>/dev/null)}"
  [ -n "$want" ] || die 6 "cannot read HEAD of $ROOT (set SPOOL_INSTALL_EXPECT_REV)"
  if [ "${SPOOL_INSTALL_NO_BUILD:-0}" = 1 ]; then
    [ -n "$SHARED" ] || die 2 "SPOOL_INSTALL_NO_BUILD=1 needs SPOOL_INSTALL_SHARED"
    if [ -x "$SPOOL" ]; then say "spool: link only, to $SPOOL (built and verified by the refresh)"; return 0; fi
    [ "$DRY" = 1 ] && { plan "link only: $SPOOL is not built yet (the refresh builds it first)"; return 0; }
    die 6 "$SPOOL is missing and SPOOL_INSTALL_NO_BUILD=1: nothing linked"
  fi
  if [ -x "$SPOOL" ] && bin_ok "$SPOOL" "$want" >/dev/null 2>&1; then
    say "spool: $SPOOL is already at $want - not rebuilt"; return 0
  fi
  if [ "$DRY" = 1 ]; then plan "build spool from $MOD into $new, verify commit $want, keep $bak, rename into $SPOOL"; return 0; fi
  shared_dir || die 6 "cannot create ${SPOOL%/*}"
  if ! bash "$BUILD_SH" "$new" >/dev/null 2>&1; then
    say "fetching the Go modules of $MOD (first build on this machine)"
    { ( cd "$MOD" && GOFLAGS=-mod=mod "${GO_BIN:-go}" mod download ) >&2 && bash "$BUILD_SH" "$new" >&2; } ||
      { rm -f "$new"; die 6 "the spool build failed ($BUILD_SH); $SPOOL untouched"; }
  fi
  bin_ok "$new" "$want" || { rm -f "$new"; die 6 "the new binary failed verification; $SPOOL untouched"; }
  [ -e "$SPOOL" ] && say "old spool: commit $(bin_rev "$SPOOL"), version $("$SPOOL" version 2>/dev/null | sed -n 1p)"
  spool_swap "$new"
  if ! bin_ok "$SPOOL" "$want"; then
    if [ -e "$bak" ]; then cp -p "$bak" "$SPOOL"; else rm -f "$SPOOL"; fi
    die 6 "$SPOOL failed verification after the rename; the old binary is restored"
  fi
  say "spool: $SPOOL refreshed to $want"
}
# shared_dir: the dir of $SPOOL; a newly made shared one is 2775 (every
# linked user may refresh it), group SPOOL_INSTALL_SHARED_GROUP when set
shared_dir() {
  local d="${SPOOL%/*}"
  [ -d "$d" ] && return 0
  mkdir -p "$d" || return 1
  [ -n "$SHARED" ] || return 0
  if [ -n "${SPOOL_INSTALL_SHARED_GROUP:-}" ]; then
    chgrp "$SPOOL_INSTALL_SHARED_GROUP" "$d" || say "WARN cannot chgrp $d to $SPOOL_INSTALL_SHARED_GROUP"
  fi
  chmod 2775 "$d"
}
# link_tools: <data>/tools/bin/spool -> the shared copy. A real file there is
# kept as spool.bak first; a link elsewhere is repointed. Atomic: a temp link
# renamed over the path, so a failure leaves the old file in place.
link_tools() {
  [ -n "$SHARED" ] || return 0
  local cur="" tmp="$TOOLS_SPOOL.lnk.$$" real=0
  [ -L "$TOOLS_SPOOL" ] && cur="$(readlink "$TOOLS_SPOOL")"
  [ "$cur" = "$SHARED" ] && return 0
  [ -f "$TOOLS_SPOOL" ] && [ ! -L "$TOOLS_SPOOL" ] && real=1
  if [ "$DRY" = 1 ]; then
    plan "link $TOOLS_SPOOL -> $SHARED${cur:+ (was -> $cur)}$([ "$real" = 1 ] && echo ', the real file kept as spool.bak')"
    return 0
  fi
  mkdir -p "$TOOLS/bin" || die 6 "cannot create $TOOLS/bin"
  if [ "$real" = 1 ]; then cp -p "$TOOLS_SPOOL" "$TOOLS_SPOOL.bak" || die 6 "cannot back up $TOOLS_SPOOL; nothing linked"; fi
  if ! { ln -sfn "$SHARED" "$tmp" && mv -fT "$tmp" "$TOOLS_SPOOL"; }; then
    rm -f "$tmp"; die 6 "cannot link $TOOLS_SPOOL -> $SHARED (the old file is untouched)"
  fi
  say "spool: $TOOLS_SPOOL -> $SHARED (the one installed copy)"
}
if [ "$BINONLY" = 1 ]; then binary_only
elif [ "$CLI_FROM" = download ]; then :
elif [ "$DRY" = 1 ]; then plan "build spool from $MOD into $SPOOL$FALLBACK"
else
  shared_dir
  # build.sh is offline (GOPROXY=off): a fresh machine fetches the modules
  # once, through Go's own default proxy, then builds offline ever after -
  # which is what every later do_spl_desk_up rebuild relies on.
  # Built beside $SPOOL, then swapped in (spool.bak, owner/group/mode kept).
  new="$SPOOL.new.$$"
  if ! bash "$BUILD_SH" "$new" >/dev/null 2>&1; then
    say "fetching the Go modules of $MOD (first build on this machine)"
    ( cd "$MOD" && GOFLAGS=-mod=mod "${GO_BIN:-go}" mod download ) >&2 || { rm -f "$new"; die 6 "go mod download failed in $MOD"; }
    bash "$BUILD_SH" "$new" >&2 || { rm -f "$new"; die 6 "the spool build failed ($BUILD_SH); $SPOOL untouched"; }
  fi
  spool_swap "$new"
  say "spool: $SPOOL ($("$SPOOL" version 2>/dev/null | sed -n 1p))"
fi
link_tools
# The harness scripts (spool-send.sh, ...) call a bare `spool`: a binary only
# in tools is not on PATH, and they fail rc 127. A symlink in <prefix>/bin
# follows every rebuild; a <prefix>/bin/spool that is a real file is left
# alone and named, never replaced.
SPOOL_LINK="$BIN/spool"
if [ -L "$SPOOL_LINK" ] && [ "$(readlink "$SPOOL_LINK")" = "$TOOLS_SPOOL" ]; then :
elif [ "$DRY" = 1 ]; then plan "link $SPOOL_LINK -> $TOOLS_SPOOL"
elif [ -e "$SPOOL_LINK" ] && [ ! -L "$SPOOL_LINK" ]; then
  say "WARN $SPOOL_LINK exists and is not a link: left alone (spool is at $SPOOL)"
else
  mkdir -p "$BIN" && ln -sfn "$TOOLS_SPOOL" "$SPOOL_LINK" || die 7 "cannot link $SPOOL_LINK"
  say "spool on PATH: $SPOOL_LINK -> $TOOLS_SPOOL"
fi
if [ "$BINONLY" = 1 ]; then
  [ "$DRY" = 1 ] && say "DRY RUN - nothing changed"
  exit 0
fi

# ── 4. the spool-agent command and its config ────────────────────────────────
SHIM="$BIN/spool-agent" CFG="$CFG_FILE"
if [ -e "$SHIM" ] && ! grep -qF "$MARK" "$SHIM" 2>/dev/null; then
  die 7 "$SHIM exists and is not a spool-install shim: move it away and re-run"
fi
# A kept SPOOL_ORCHESTRATOR_ID that spool-env refuses as retired (CLE-001
# after the specs/061 cutoff) fails every responder run on the box: dropped,
# with one line. The retired check is spool-env's own, run in a subshell.
ORCH_RETIRED=""
if [ -r "$CFG" ]; then
  orch="$(sed -nE 's/^(export +)?SPOOL_ORCHESTRATOR_ID=//p' "$CFG" | tail -1 | tr -d "\"'")"
  if [ -n "$orch" ] && ! ( . "$ORC/src/bash/features/spawn-agents/lib/spool-env.inc.sh" && _spl_id_write_ok "$orch" ) 2>/dev/null; then
    ORCH_RETIRED="$orch"
  fi
fi
if [ "$DRY" = 1 ]; then plan "write $SHIM -> $AGENT_SH, and $CFG (SPOOL_ENV=$ENVN SPOOL_TENANT=$TENANT SPOOL_BOX=$BOX SPOOL_INSTALL_FLEET=$FLEET)"
  [ -z "$ORCH_RETIRED" ] || plan "drop SPOOL_ORCHESTRATOR_ID=$ORCH_RETIRED from $CFG (a retired id)"
else
  mkdir -p "$BIN" "$CFG_DIR" && chmod 700 "$CFG_DIR" || die 7 "cannot create $BIN / $CFG_DIR"
  ( umask 077
    { echo "# spool-agent defaults, written by spool-install; edit freely"
      printf 'SPOOL_ENV=%q\nSPOOL_TENANT=%q\nSPOOL_BOX=%q\nSPOOL_INSTALL_FLEET=%q\n' "$ENVN" "$TENANT" "$BOX" "$FLEET"
      if [ -n "${SPOOL_HUB_URL:-}" ]; then printf 'SPOOL_HUB_URL=%q\n' "$SPOOL_HUB_URL"; fi
      # Lines this installer does not own (agent-top's SPOOL_BOX_TAG,
      # SPOOL_ORCHESTRATOR_ID, ...) survive a re-run.
      if [ -r "$CFG" ]; then grep -vE '^(# spool-agent defaults|SPOOL_ENV=|SPOOL_TENANT=|SPOOL_BOX=|SPOOL_INSTALL_FLEET=|SPOOL_HUB_URL=)' "$CFG" |
        if [ -n "$ORCH_RETIRED" ]; then grep -vE '^(export +)?SPOOL_ORCHESTRATOR_ID='; else cat; fi || true; fi
    } >"$CFG.tmp" && mv -f "$CFG.tmp" "$CFG" ) || die 7 "cannot write $CFG"
  [ -z "$ORCH_RETIRED" ] || say "dropped SPOOL_ORCHESTRATOR_ID=$ORCH_RETIRED from $CFG: a retired id (specs/061); the default applies"
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

[ "$SKILLS" = 1 ] && { . "$_here/steps/y5-adopt-skills.sh" && y5_adopt_skills "$HOME" || die 7 "cannot hand the engine-rendered skills over (specs/069 Y5)"; }
# ── 5b. the agent harness: skills, slash commands, tmux snippet (specs/048) ──
HARNESS_DIR="$ORC/src/bash/features/spawn-agents"
# A stranger's spool lives under their own state dir and talks to whoever holds
# the orchestrator role; /var/spool-hub is the fleet's (spec 072 A50).
if [ "$FLEET" = 1 ]; then ROOT_DEFAULT=/var/spool-hub; else ROOT_DEFAULT="${XDG_STATE_HOME:-$HOME/.local/state}/spool-hub"; fi
if [ "$SKILLS" = 1 ]; then
  QWEN_SKILLS=0
  for c in "${CLI_LIST[@]}"; do [ "$c" = qwen ] && QWEN_SKILLS=1; done
  [ -d "$HOME/.qwen" ] && QWEN_SKILLS=1
  # agy reads ~/.gemini/config/skills: without them it kept the frozen
  # engine's /exit-clean (no --retire, a path that no longer exists).
  AGY_SKILLS=0
  for c in "${CLI_LIST[@]}"; do [ "$c" = agy ] && AGY_SKILLS=1; done
  [ -d "$HOME/.gemini" ] && AGY_SKILLS=1
  [ "$AGY_SKILLS" = 1 ] && { y5_adopt_agy_skills "$HOME" "$HARNESS_DIR/assets" || die 7 "cannot hand the engine's agy skills over"; }
  # mistral's vibe reads ~/.vibe/skills (2.26.0): without them an m- lane had
  # no /exit-clean at all and every one was closed by an orchestrator.
  VIBE_SKILLS=0
  for c in "${CLI_LIST[@]}"; do [ "$c" = mistral ] && VIBE_SKILLS=1; done
  [ -d "$HOME/.vibe" ] && VIBE_SKILLS=1
  if [ "$DRY" = 1 ]; then
    plan "render $HARNESS_DIR/assets commands + skills into $HOME/.claude$([ "$QWEN_SKILLS" = 1 ] && echo " and $HOME/.qwen/skills")$([ "$AGY_SKILLS" = 1 ] && echo " and $HOME/.gemini/config/skills")$([ "$VIBE_SKILLS" = 1 ] && echo " and $HOME/.vibe/skills") (hand-edited files kept)"
    plan "copy the tmux snippet to $DATA/tmux-agent-status.conf"
  else
    python3 - "$HARNESS_DIR/assets" "$HOME" "$QWEN_SKILLS" "$FORCE_SKILLS" \
      "$HARNESS_DIR" "${SPOOL_ROOT:-$ROOT_DEFAULT}" "${SPOOL_AGENT_CEILING:-40}" "${SPOOL_ORCHESTRATOR_ID:-orchestrator}" "$AGY_SKILLS" "$VIBE_SKILLS" <<'EOF_PY' || die 6 "cannot render the harness skills"
import hashlib, os, re, sys
assets, home, qwen, force, harness, root, ceiling, orc = sys.argv[1:9]
agy = sys.argv[9] if len(sys.argv) > 9 else "0"
vibe = sys.argv[10] if len(sys.argv) > 10 else "0"
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
    if agy == "1":
        jobs.append((src, os.path.join(home, ".gemini", "config", "skills", n, "SKILL.md")))
    if vibe == "1":
        jobs.append((src, os.path.join(home, ".vibe", "skills", n, "SKILL.md")))
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
. "$_here/steps/y7-tmux-links.sh" && { spool_install_y7_tmux_links "$HOME" "$DATA/tmux-agent-status.conf" "$DRY" || die 6 "cannot repoint ~/.tmux.conf"; }

. "$_here/steps/y10-run-completion.sh" && spl_install_run_completion "$ORC" "$HOME/.bashrc" "$DRY" || die 7 "run completion: cannot update $HOME/.bashrc"
# ── 5c. the fleet config, only with --fleet (spec 072 A49) ────────────────────
if [ "$FLEET" != 1 ]; then
  # shellcheck disable=SC2034  # read by the sourced y1, y4, y8 and y9 steps
  SPOOL_INSTALL_MCP_BOT=0 SPOOL_INSTALL_CLAUDE_CONFIG=0 SPOOL_INSTALL_VIBE_AGENTS=0 SPOOL_INSTALL_VENDOR_RULES=0
  say "fleet config: not written - your ~/.claude/CLAUDE.md, settings and browser MCP are yours (--fleet writes the fleet's)"
fi
. "$_here/steps/y1-mcp-bot.sh" && y1_mcp_bot "$ORC/src/bash/features/mcp-bot" || die $? "mcp-bot: cannot link the browser MCP entrypoints (spec 069 Y1)"

source "$_here/steps/y4-claude-config.sh" && spool_install_claude_config || die 6 "cannot render the fleet CLAUDE.md / settings.json (spec 069 Y4)"
source "$_here/steps/y8-vibe-agents.sh" && spool_install_vibe_agents || die 6 "cannot render the fleet ~/.vibe/AGENTS.md (spec 110)"
source "$_here/steps/y9-vendor-lane-rule.sh" && spool_install_vendor_lane_rule || die 6 "cannot render the lane rule into the agy / qwen rules files"
. "$_here/steps/y11-kill-guard.sh" && spool_install_kill_guard "$BIN" "$DRY" "$FLEET" || die 7 "kill-guard: cannot install pkill / killall into $BIN"
. "$_here/steps/y12-vibe-push-guard.sh" && spool_install_vibe_push_guard "${VIBE_HOME:-$HOME/.vibe}" "$DRY" || die 7 "vibe push guard: cannot install into ${VIBE_HOME:-$HOME/.vibe}"
. "$_here/steps/y13-force-push-guard.sh" && spool_install_force_push_guard "$HOME" "$DATA" "$DRY" "$FLEET" || die 7 "force-push-guard: cannot wire the force-push block into the harness settings"
[ "$SKILLS" = 1 ] && { . "$_here/steps/y6-graft.sh" && y6_graft_install "$ORC" "$BIN" "$DRY" || die 6 "the graft step (spec 069 Y6) failed"; }

# ── 6. the seat ───────────────────────────────────────────────────────────────
if [ "$SEAT" = 1 ]; then
  if [ "$DRY" = 1 ]; then plan "key + pin $BOX in $TENANT at $SPOOL_HUB_URL ($ENVN; ./run -a do_spl_desk_pin${ROOT_KEY_JSON:+, with ROOT_KEY_JSON})"
  else
    out="$(PATH="$TPATH:$PATH" env ENV="$ENVN" TENANT_ID="$TENANT" DESK_BOX="$BOX" SPOOL_HUB_URL="$SPOOL_HUB_URL" \
      ROOT_KEY_JSON="${ROOT_KEY_JSON:-}" DRY_RUN=0 "$RUN" -a do_spl_desk_pin 2>&1)"; rc=$?
    json="$(grep -m1 '^{' <<<"$out")"
    if [ "$rc" -eq 0 ] && printf '%s' "$json" | grep '"pinned": true' >/dev/null; then
      say "seated: $BOX is pinned in $TENANT ($ENVN) - start an agent with:  spool-agent claude"
    elif printf '%s' "$json" | grep '"pinned": false' >/dev/null; then
      admin="$(printf '%s' "$json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["admin_cmd"])')"
      pub="$(printf '%s' "$json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["box_pubkey"])')"
      say "seat PENDING: $BOX is not pinned in $TENANT yet. Send your tenant admin this ONE line:"
      echo "SPOOL_HUB_URL=$SPOOL_HUB_URL SPOOL_TENANT=$TENANT spool hub-pin --box $BOX --pubkey $pub --root-key <root private key: a file, the key text, or - for stdin>"
      say "(or, from their clone of this repo: $admin)"
      say "then re-run install.sh: it picks the pin up."
    else
      printf '%s\n' "$out" | grep -E 'FATAL|FAIL|WARN' | tail -3 >&2
      die 5 "the seat failed (rc $rc) at $SPOOL_HUB_URL: fix the line above, then re-run install.sh"
    fi
  fi
fi
[ "$DRY" = 1 ] && say "DRY RUN - nothing changed"
[ "${#CLI_FAILED[@]}" -eq 0 ] || die 4 "not installed: ${CLI_FAILED[*]} (every other step ran; re-run install.sh --cli ${CLI_FAILED[*]// /,} to retry)"
exit 0
