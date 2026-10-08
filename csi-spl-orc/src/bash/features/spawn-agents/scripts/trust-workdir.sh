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
#   mistral $VIBE_HOME (<home>/.vibe)/trusted_folders.toml  trusted = ["<dir>", …]
#           (specs/110 3.3; the dir also leaves `untrusted`, which vibe checks
#           literally before it asks)
#
# A store that does not exist is skipped (the CLI's first run onboards itself).
# Each edit is idempotent, under an flock, written via temp file + rename.
#
# --settle (a spawn, CLE-77829): a parallel batch lost the trust race (2 of 8
# spawns stopped on "Is this a project you trust?", 2026-10-01). The per-store
# flock cannot stop it: a STARTING claude rewrites the whole ~/.claude.json
# from the copy it read, unlocked, so a sibling's fresh trust entry is lost.
# With --settle the edit (1) waits for ONE box-wide spawn lock
# (<home>/.spool-spawn-trust.lock), (2) VERIFIES the entry reads back, exit 3
# if it never does, and (3) leaves a detached child holding that lock for
# TRUST_SETTLE_SECS (default 6) that re-asserts the entry every 0.2 s, so the
# claude launched next reads it and the next spawn's edit waits for this
# claude's startup write to be over.
#
# Usage: trust-workdir.sh [--settle] <DIR> [AGENT_USER] [AGENT …]   (AGENT: claude grok agy qwen mistral)
set -uo pipefail

_here="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=../lib/spool-env.inc.sh
. "$_here/../lib/spool-env.inc.sh"
spool_env_resolve

SETTLE=0
[ "${1:-}" = --settle ] && { SETTLE="${TRUST_SETTLE_SECS:-6}"; shift; }
case "$SETTLE" in ''|*[!0-9.]*) echo "trust-workdir: TRUST_SETTLE_SECS must be a number" >&2; exit 2 ;; esac
DIR="${1:-}"
[ -n "$DIR" ] || { echo "usage: trust-workdir.sh [--settle] <DIR> [AGENT_USER] [AGENT ...]" >&2; exit 2; }
shift
AGENT_USER="${1:-$(id -un)}"
[ $# -gt 0 ] && shift
AGENTS=("$@")
[ ${#AGENTS[@]} -eq 0 ] && AGENTS=(claude grok agy qwen mistral)

if [ -d "$DIR" ]; then DIR_ABS="$(cd "$DIR" && pwd -P)"; else DIR_ABS="$(readlink -m -- "$DIR")"; fi

read -r -d '' TRUST_PY <<'PY'
import fcntl, json, os, re, sys, time

target = sys.argv[1]
settle = float(sys.argv[2])
agents = sys.argv[3:]
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


def vibe_lists(text):
    """(trusted, untrusted) of a vibe trusted_folders.toml (tomllib: 3.11+,
    and vibe itself needs 3.12)."""
    import tomllib
    doc = tomllib.loads(text)
    return list(doc.get("trusted", [])), list(doc.get("untrusted", []))


def mistral(before):
    # vibe writes the file with tomli_w as two string lists; there is no
    # stdlib TOML writer, and a list of JSON strings is valid TOML.
    trusted_l, untrusted_l = vibe_lists(before)
    if target in trusted_l and target not in untrusted_l:
        return before
    if target not in trusted_l:
        trusted_l.append(target)
    untrusted_l = [d for d in untrusted_l if d != target]
    fmt = lambda xs: "[%s%s]" % ("".join("\n    %s," % json.dumps(x) for x in xs), "\n" if xs else "")
    return "trusted = %s\nuntrusted = %s\n" % (fmt(trusted_l), fmt(untrusted_l))


STORES = {
    "claude": (os.path.join(home, ".claude.json"), claude, None),
    "agy": (os.path.join(home, ".gemini", "antigravity-cli", "settings.json"),
            agy, "{}\n"),
    "grok": (os.path.join(home, ".grok", "trusted_folders.toml"), grok, ""),
    "qwen": (os.path.join(home, ".qwen", "trustedFolders.json"), qwen, "{}\n"),
    "mistral": (os.path.join(os.environ.get("VIBE_HOME") or os.path.join(home, ".vibe"),
                             "trusted_folders.toml"), mistral, ""),
}

def trusted(name):
    """Does the store read back with `target` trusted? None = no store."""
    path = STORES[name][0]
    try:
        with open(path, encoding="utf-8") as fh:
            text = fh.read()
    except FileNotFoundError:
        return None
    try:
        if name == "claude":
            return bool(json.loads(text).get("projects", {}).get(target, {}).get("hasTrustDialogAccepted"))
        if name == "agy":
            return target in json.loads(text).get("trustedWorkspaces", [])
        if name == "qwen":
            return json.loads(text).get(target) == "TRUST_FOLDER"
        if name == "mistral":
            trusted_l, untrusted_l = vibe_lists(text)
            return target in trusted_l and target not in untrusted_l
        return re.search(r"^%s\s*$" % re.escape('[folders."%s"]' % target), text, re.M) is not None
    except ValueError:
        return False   # a half-written file reads as not-yet-trusted


spawn_lock = None
if settle > 0:
    # ONE lock for every spawn on this box: the next spawn edits only after
    # this one's CLI has started (and done its own write of the store).
    try:
        spawn_lock = open(os.path.join(home, ".spool-spawn-trust.lock"), "a+")
    except OSError as exc:
        print("trust-workdir: no spawn lock (%s), going on without it" % exc, file=sys.stderr)
    deadline = time.time() + 120
    while spawn_lock is not None:
        try:
            fcntl.flock(spawn_lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            break
        except OSError:
            if time.time() > deadline:
                print("trust-workdir: spawn lock busy for 120 s, going on without it", file=sys.stderr)
                spawn_lock.close(); spawn_lock = None
                break
            time.sleep(0.1)

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

if settle > 0:
    known = [a for a in agents if a in STORES]
    # VERIFY before the CLI starts: re-assert until every existing store reads
    # back trusted (a concurrent unlocked writer can undo the first edit).
    for _ in range(25):
        missing = [a for a in known if trusted(a) is False]
        if not missing:
            break
        for a in missing:
            try:
                edit(STORES[a][0], STORES[a][1], STORES[a][2])
            except Exception:
                pass
        time.sleep(0.2)
    missing = [a for a in known if trusted(a) is False]
    if missing:
        print("trust-workdir: NOT VERIFIED for %s in %s -- the CLI would stop on its trust prompt"
              % (", ".join(missing), target), file=sys.stderr)
        sys.exit(3)
    print("trust-workdir: verified %s for %s (settle %ss)" % (target, ", ".join(known) or "-", settle))
    sys.stdout.flush()
    if os.fork() == 0:
        # Detached settler: holds the spawn lock (inherited) while the CLI
        # starts, re-asserting the entry against an unlocked whole-file write.
        os.setsid()
        devnull = os.open(os.devnull, os.O_RDWR)
        for fd in (0, 1, 2):
            os.dup2(devnull, fd)
        end = time.time() + settle
        while time.time() < end:
            for a in known:
                try:
                    if trusted(a) is False:
                        edit(STORES[a][0], STORES[a][1], STORES[a][2])
                except Exception:
                    pass
            time.sleep(0.2)
        os._exit(0)
    # the parent's copy of the lock fd closes on exit; the child keeps it held
sys.exit(rc)
PY

if [ "$AGENT_USER" = "$(id -un)" ]; then
  printf '%s' "$TRUST_PY" | python3 - "$DIR_ABS" "$SETTLE" "${AGENTS[@]}"
else
  # Hop the way the launcher starts the agent, so HOME is the agent's own.
  # The script travels in the command line (base64, inert in any shell), never
  # on stdin, and this hop takes no pty: with su --pty (su-dash, from a
  # terminal) stdin is the pty, so `python3 -` read the TTY instead of the
  # pipe and sat in the REPL at '>>>' - claude was never started (CLE-77907,
  # 3 lanes stuck 2026-10-01). The CLI launch itself keeps --pty (SIGWINCH).
  SPOOL_AGENT_USER="$AGENT_USER" SPOOL_AGENT_PTY=0
  b64="$(printf '%s' "$TRUST_PY" | base64 | tr -d '\n')"
  printf -v args ' %q' "$DIR_ABS" "$SETTLE" "${AGENTS[@]}"
  spool_agent_exec "python3 -c 'import base64; exec(compile(base64.b64decode(\"${b64}\"), \"trust-workdir\", \"exec\"))'${args}" </dev/null
fi
