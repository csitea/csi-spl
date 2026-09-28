#!/usr/bin/env bash
# trust-workdir.sh — pre-accept the "do you trust this folder?" dialog for a
# directory, on behalf of the OS user an agent runs as. Forked verbatim in
# behaviour from the box engine's helper; only the run-as hop is the spool's.
#
# A spawned worker lands in a directory it has never seen; each CLI then asks
# whether the folder is trusted, in a pane nobody watches, and the worker looks
# idle while it is blocked. The stores:
#
#   claude  <home>/.claude.json                projects["<dir>"].hasTrustDialogAccepted
#   grok    <home>/.grok/trusted_folders.toml  [folders."<dir>"] trusted = true
#   agy     <home>/.gemini/antigravity-cli/settings.json  trustedWorkspaces[]
#   qwen    <home>/.qwen/trustedFolders.json   {"<dir>": "TRUST_FOLDER"}
#
# A store that does not exist is skipped (the CLI's first run onboards itself).
# Each edit is idempotent, under an flock, written via temp file + rename.
#
# Usage: trust-workdir.sh <DIR> [AGENT_USER] [AGENT …]   (AGENT: claude grok agy qwen)
set -uo pipefail

_here="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=../lib/spool-env.inc.sh
. "$_here/../lib/spool-env.inc.sh"
spool_env_resolve

DIR="${1:-}"
[ -n "$DIR" ] || { echo "usage: trust-workdir.sh <DIR> [AGENT_USER] [AGENT ...]" >&2; exit 2; }
shift
AGENT_USER="${1:-$(id -un)}"
[ $# -gt 0 ] && shift
AGENTS=("$@")
[ ${#AGENTS[@]} -eq 0 ] && AGENTS=(claude grok agy qwen)

if [ -d "$DIR" ]; then DIR_ABS="$(cd "$DIR" && pwd -P)"; else DIR_ABS="$(readlink -m -- "$DIR")"; fi

read -r -d '' TRUST_PY <<'PY'
import fcntl, json, os, re, sys, time

target = sys.argv[1]
agents = sys.argv[2:]
home = os.path.expanduser("~")
stamp = int(time.time())
changed, skipped = [], []


def edit(path, mutate, default=None):
    """Read-modify-write `path` under an flock, atomically. Returns True if the
    file changed, False if it was already correct, None if there is no store to
    edit (parent directory missing, or file absent and no default given)."""
    parent = os.path.dirname(path)
    if not os.path.isdir(parent):
        return None
    if not os.path.exists(path) and default is None:
        return None
    lock = open(path + ".trust-lock", "a+")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX)
        try:
            with open(path, encoding="utf-8") as fh:
                before = fh.read()
        except FileNotFoundError:
            before = default
        after = mutate(before)
        if after == before:
            return False
        mode = os.stat(path).st_mode & 0o777 if os.path.exists(path) else 0o600
        tmp = "%s.trust-tmp.%d" % (path, os.getpid())
        with open(tmp, "w", encoding="utf-8") as fh:
            fh.write(after)
        os.chmod(tmp, mode)
        os.replace(tmp, path)
        return True
    finally:
        fcntl.flock(lock, fcntl.LOCK_UN)
        lock.close()


def claude(before):
    doc = json.loads(before)
    proj = doc.setdefault("projects", {}).setdefault(target, {})
    proj["hasTrustDialogAccepted"] = True
    return json.dumps(doc, indent=2) + "\n"


def agy(before):
    doc = json.loads(before)
    ws = doc.setdefault("trustedWorkspaces", [])
    if target not in ws:
        ws.append(target)
    return json.dumps(doc, indent=2) + "\n"


def qwen(before):
    doc = json.loads(before)
    doc[target] = "TRUST_FOLDER"
    return json.dumps(doc, indent=2) + "\n"


def grok(before):
    # No stdlib TOML writer, and the file is a flat list of one-table-per-folder
    # blocks, so append a block rather than round-tripping the document.
    header = '[folders."%s"]' % target
    if re.search(r"^%s\s*$" % re.escape(header), before, re.M):
        return before
    if before == "" or before.endswith("\n\n"):
        sep = ""
    elif before.endswith("\n"):
        sep = "\n"
    else:
        sep = "\n\n"
    return "%s%s%s\ntrusted = true\ndecided_at = %d\n" % (
        before, sep, header, stamp)


STORES = {
    "claude": (os.path.join(home, ".claude.json"), claude, None),
    "agy": (os.path.join(home, ".gemini", "antigravity-cli", "settings.json"),
            agy, "{}\n"),
    "grok": (os.path.join(home, ".grok", "trusted_folders.toml"), grok, ""),
    "qwen": (os.path.join(home, ".qwen", "trustedFolders.json"), qwen, "{}\n"),
}

rc = 0
for name in agents:
    if name not in STORES:
        print("trust-workdir: unknown agent '%s'" % name, file=sys.stderr)
        rc = 2
        continue
    path, mutate, default = STORES[name]
    try:
        result = edit(path, mutate, default)
    except Exception as exc:                       # best-effort: never fatal
        print("trust-workdir: %s: %s" % (name, exc), file=sys.stderr)
        rc = 1
        continue
    if result is None:
        skipped.append("%s (no store)" % name)
    elif result:
        changed.append(name)
    else:
        skipped.append("%s (already trusted)" % name)

if changed:
    print("trust-workdir: trusted %s for %s" % (target, ", ".join(changed)))
if skipped:
    print("trust-workdir: skipped %s" % ", ".join(skipped))
sys.exit(rc)
PY

if [ "$AGENT_USER" = "$(id -un)" ]; then
  printf '%s' "$TRUST_PY" | python3 - "$DIR_ABS" "${AGENTS[@]}"
else
  # Hop the way the launcher starts the agent, so HOME is the agent's own.
  SPOOL_AGENT_USER="$AGENT_USER"
  spool_agent_argv || exit 2
  printf '%s' "$TRUST_PY" | "${SPOOL_AGENT_ARGV[@]}" -c "python3 - '${DIR_ABS}' ${AGENTS[*]}"
fi
