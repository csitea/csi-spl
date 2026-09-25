#!/bin/bash
#------------------------------------------------------------------------------
# @description Show the terminal mirror (specs/036) of a desk: per seated agent
# @description whether it mirrors, the human and DM topic its posts land in,
# @description how many web UI lines wait to be recognised, and its last
# @description mirror log line. Also names the two box-level facts the mirror
# @description depends on and nothing else shows:
# @description   - the notifier the live sidecar runs. It records the web UI
# @description     lines the mirror must not echo; a sidecar started from a
# @description     worktree runs THAT tree's notifier, which disappears with
# @description     the worktree (WARN)
# @description   - whether the agent user's ~/.claude/settings.json carries the
# @description     mirror hooks (a CLI reads them when it starts)
# @description Reads local files only: no cloud call, no send. One JSON line per
# @description agent, then one summary line.
# @param ENV - required: dev or prd
# @param TENANT_ID - required: the tenant the desk is seated in
# @param DESK_BOX (optional) - default box-desk
# @param DESK_AGENT (optional) - one agent; default every seat on the desk
# @param SESSION_AGENT_USER (optional) - whose ~/.claude/settings.json to read,
# @param   default $SPOOL_AGENT_USER, else the current user
# @example ENV=dev TENANT_ID=t1 ./run -a do_spl_desk_mirror_check
#------------------------------------------------------------------------------
do_spl_desk_mirror_check() {
  do_require_bin python3 || return 1
  do_spl_cloud_cnf || return 1
  local tenant="${TENANT_ID:-}" box="${DESK_BOX:-box-desk}" agent="${DESK_AGENT:-}"
  local auser="${SESSION_AGENT_USER:-${SPOOL_AGENT_USER:-$(id -un)}}"
  spl_desk_validate "$tenant" "$box" "${agent:-CLE-0}" || return 1
  local d="$SPL_STATE_DIR/desk/$tenant/$box" ahome
  [[ -d "$d/spool" ]] || { do_log "FATAL no desk $box in $tenant ($d)"; return 1; }
  ahome="$(getent passwd "$auser" | cut -d: -f6)"
  python3 - "$d" "$agent" "${ahome:-/nonexistent}/.claude/settings.json" <<'EOF_PY'
import glob, json, os, re, sys, time
d, only, settings = sys.argv[1:]
spool = os.path.join(d, "spool")
notify, warn = None, []
try:
    pid = open(os.path.join(spool, ".hub", "hub-run.pid")).read().strip()
    env = dict(kv.split("=", 1) for kv in open(f"/proc/{pid}/environ", "rb").read().decode(errors="replace").split("\0") if "=" in kv)
    notify = env.get("SPOOL_NOTIFY_CMD")
except (OSError, ValueError):
    warn.append("no live sidecar: nothing reaches the terminal and nothing is flushed to the hub")
if notify and re.search(r"-wt/[^/]+/", notify):
    warn.append(f"the sidecar runs a WORKTREE's notifier ({notify}): it vanishes with that worktree; restart the desk from the main checkout")
if notify and os.path.isfile(notify) and "spool_notify_mark_typed" not in open(os.path.join(os.path.dirname(os.path.dirname(notify)), "lib", "spool-notify.inc.sh")).read():
    warn.append("the sidecar's notifier predates the mirror: web UI prompts would echo back into the DM until the desk restarts")
try:
    hooked = "spool-mirror.py" in open(settings).read()
except OSError:
    hooked = None
ids = [only] if only else sorted(os.path.basename(p) for p in glob.glob(os.path.join(spool, "*"))
                               if re.match(r"^[A-Z]{2,4}-[0-9]+$", os.path.basename(p)) and os.path.isdir(p))
def rd(p):
    try:
        return json.load(open(p))
    except (OSError, ValueError):
        return None
n_on = 0
for a in ids:
    ad = os.path.join(spool, a)
    m = os.path.join(ad, ".mirror")
    on = os.path.isdir(ad) and not os.path.exists(os.path.join(ad, ".no-mirror"))
    n_on += on
    last = None
    try:
        last = open(os.path.join(m, "mirror.log")).read().strip().splitlines()[-1]
    except (OSError, IndexError):
        pass
    print(json.dumps({"agent": a, "seated": os.path.isdir(ad), "mirror": on, "peer": rd(os.path.join(m, "peer")),
                      "topic": rd(os.path.join(m, "topic")), "typed_pending": len(glob.glob(os.path.join(m, "typed", "*"))),
                      "last": last}, sort_keys=True))
print(json.dumps({"desk": d, "agents": len(ids), "mirroring": n_on, "sidecar_notify": notify,
                  "hooks_in_settings": hooked, "warn": warn}, sort_keys=True))
EOF_PY
}
