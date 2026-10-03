#!/usr/bin/env bash

# REFUSALS COME FIRST, BEFORE THE BINARY IS RESOLVED. A refusal is a statement
# about policy, not about this box's installation: `graft init` is refused
# whether or not a launcher is present, and the operator gets the real reason
# rather than "no graft binary found". Resolving first made every refusal
# unreachable on a box with no graft.real -- including in the tests.

set -uo pipefail

GRAFT_REAL_HOME="${GRAFT_REAL_HOME:-}"
REFUSE=78
_die() { echo "graft-safe: $*" >&2; exit "$REFUSE"; }

for a in "$@"; do
  case "$a" in
    init)
      _die "'graft init' is refused: it writes .mcp.json (npx -y @nanonets/graft,
              which fetches from the public registry) and a repo .claude/settings.json,
              and it does so even with --no-mcp --no-hooks. The integration on this box
              is hand-installed -- see csi-spl-orc/src/bash/features/graft/README.md." ;;
    upgrade)
      _die "'graft upgrade' is refused: it installs from the public npm registry.
              This graft came in through the relay and is upgraded the same way.
              ('graft version' is allowed -- it only probes, and with no route out
              it says 'latest: unreachable' instead of reaching anything.)" ;;
    --deep|--deep=*)
      _die "'--deep' is refused: it sends source to a model API. This index is local." ;;
    -*deep*)
      _die "refusing '$a': anything matching 'deep' is treated as --deep. Use the
              long flag if you genuinely meant something else, and say so." ;;
  esac
done

# `telemetry status` and `telemetry disable` are fine; re-enabling is not. The
# env vars below are belt, but a config write survives them into any invocation
# that does not come through this wrapper.
case " $* " in
  *" telemetry "*)
    case " $* " in
      *" enable "*) _die "re-enabling telemetry is refused here." ;;
    esac ;;
esac

# graft-safe.sh -- the only graft on PATH. A wrapper, because the zero-egress
# rules are not the kind you can leave to whoever types the next command.
#
# Three things reach the network from a tool that is supposed to be local, and
# each is one forgotten flag away:
#
#   graft init     writes .mcp.json into the repo, spawning `npx -y
#                  @nanonets/graft mcp` -- npx fetches from the public registry
#                  every time it runs. It also writes a repo .claude/settings.json
#                  carrying hooks. It does this even with --no-mcp --no-hooks,
#                  so the flags are not a defence and --dry-run is not a preview
#                  of what it writes.
#   --deep         sends source to a model API.
#   telemetry      on by default.
#
# The telemetry point is not hypothetical and not covered by the network. On at
# least one box in this estate that endpoint ANSWERS 302 while the same gateway
# returns 503 for storage.googleapis.com and registry.npmjs.org. So the egress
# block everyone assumed covered it does not, and configuration was the only
# thing between graft and that endpoint. Do not assume a network control covers
# a host you have not measured against that host.
#
# So: init is refused, --deep is refused, DO_NOT_TRACK is forced, and the API
# key is cleared from the environment so that anything which slips past the
# --deep check fails loudly instead of succeeding quietly and off-box.
#
#   graft <args>...                 # normal use, through here
#   GRAFT_SAFE_BIN=/path/to/graft   # override the real binary
#   GRAFT_REAL_HOME=/home/<owner>   # where to find graft.real for a second user
#   GRAFT_SAFE_ALLOW_PROXY=1        # keep proxy env (default: cleared)
#   GRAFT_SAFE_IN_TREE=1            # do not add --dir: use graft's <repo>/graft
#
# Exit 78 (EX_CONFIG) for a refusal, so a refusal is never mistaken for a
# tool error or for an empty result.

# The wrapper installs AS `graft` on PATH, so the real launcher is renamed
# alongside it. Only `.real` names are searched: picking up a plain `graft`
# would eventually pick up this wrapper and exec itself forever.
# GRAFT_SAFE_SYSTEM_DIR names the system-wide candidate's directory; it exists
# so a test can search an empty one instead of whatever this box installed.
BIN="${GRAFT_SAFE_BIN:-}"
if [ -z "$BIN" ]; then
  for c in "$HOME/.local/bin/graft.real" "$GRAFT_REAL_HOME/.local/bin/graft.real" \
           "${GRAFT_SAFE_SYSTEM_DIR:-/usr/local/bin}/graft.real"; do
    [ -n "$c" ] && [ -x "$c" ] && { BIN="$c"; break; }
  done
fi
[ -n "$BIN" ] && [ -x "$BIN" ] || _die "no graft binary found. Expected a graft.real beside
              this wrapper on PATH; set GRAFT_SAFE_BIN to point at one."

# Exec'ing ourselves is the one failure that looks like a hang rather than an
# error, so it is checked rather than merely avoided by naming convention.
if [ "$(readlink -f "$BIN" 2>/dev/null)" = "$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null)" ]; then
  _die "GRAFT_SAFE_BIN resolves to this wrapper -- that would exec forever"
fi



# Telemetry off, belt and braces: the env var AND the config the CLI reads.
export DO_NOT_TRACK=1
export GRAFT_TELEMETRY_DISABLED=1
# Cleared, not merely unset by convention: if --deep ever slips past the loop
# above, this makes it fail on a missing key rather than succeed off-box.
unset GRAFT_API_KEY ANTHROPIC_API_KEY OPENAI_API_KEY

# Run with no route out. A local index needs no egress, so anything that tries
# fails loudly here instead of succeeding quietly in a month's time.
if [ "${GRAFT_SAFE_ALLOW_PROXY:-}" != 1 ]; then
  unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY all_proxy ALL_PROXY
  export NO_PROXY='*' no_proxy='*'
fi

# The index lives outside the repo (graft-index-dir.sh). Unless the caller names
# a --dir, point graft at this repo's out-of-tree index, so `graft ask` and
# friends read the same index the scheduled build writes, and a `graft build`
# by hand never creates <repo>/graft. Outside a git repo nothing is added.
_has_dir=0
for a in "$@"; do case "$a" in --dir|--dir=*) _has_dir=1 ;; esac; done
if [ "$_has_dir" = 0 ] && [ "${GRAFT_SAFE_IN_TREE:-}" != 1 ]; then
  _idx="$(bash "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/graft-index-dir.sh" 2>/dev/null)" \
    && [ -n "$_idx" ] && set -- --dir "$_idx" "$@"
fi

exec "$BIN" "$@"
