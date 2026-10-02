#!/usr/bin/env bash
# tmp-scratch-sweep.sh — remove the Claude Code scratch dirs of DEAD sessions
# from the shared /tmp tmpfs, so agent leftovers cannot fill it under the CI
# runners that share it (workflow 10 run 37031322430: "no space left on
# device"; /tmp/claude-<uid> held 15 GB of 24 GB used, 2026-10-02).
#
# Claude Code keeps one dir per session: <root>/<project-slug>/<session-uuid>/
# (scratchpad, tasks). A session dir is removed only when ALL hold:
#   - its name is a session uuid, it is a real dir (no symlink) owned by us;
#   - no live session claims it: a pid in <sessions>/*.json that still runs
#     with that sessionId, or a running process of ours whose command line
#     names the uuid (a --resume);
#   - nothing under it changed in the last SCRATCH_SWEEP_AGE_H hours.
# A sessions dir that cannot be read decides nothing (exit 2). A project dir
# left empty by the sweep is removed too. Nothing else under the root, and
# nothing outside it, is ever touched.
#
# Installed by do_tmp_scratch_sweep_install_cron as ONE line tagged
# `# csi-spl:tmp-scratch-sweep`; one PLAN|REMOVE / KEEP line per session dir.
#
#   DRY_RUN=1 (default) | 0
#   SCRATCH_ROOT        default /tmp/claude-$(id -u)
#   SCRATCH_SESSIONS    default $HOME/.claude/sessions
#   SCRATCH_SWEEP_AGE_H default 24
#
# Exit: 0 done; 2 usage or a refusal (nothing removed).
set -uo pipefail
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}"

dry="${DRY_RUN:-1}"
root="${SCRATCH_ROOT:-/tmp/claude-$(id -u)}"
sessions="${SCRATCH_SESSIONS:-$HOME/.claude/sessions}"
age_h="${SCRATCH_SWEEP_AGE_H:-24}"
uuid_ere='[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'

say() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
refuse() { say "REFUSE $*: nothing removed"; exit 2; }
used() { df -P "$root" | awk 'NR==2{print $5}'; }

[[ "$dry" == 0 || "$dry" == 1 ]] || refuse "DRY_RUN must be 0 or 1, got '$dry'"
[[ "$age_h" =~ ^[0-9]+$ ]] && (( age_h >= 1 )) || refuse "SCRATCH_SWEEP_AGE_H must be a whole number >= 1, got '$age_h'"
[[ -d "$root" && ! -L "$root" ]] || { say "OK no scratch root $root: nothing to sweep"; exit 0; }
[[ -O "$root" ]] || refuse "$root is not owned by $(id -un)"
[[ -d "$sessions" && -r "$sessions" && -x "$sessions" ]] || refuse "cannot read the live sessions in $sessions"

# The live session ids: a registry entry whose pid still runs, plus any uuid
# on the command line of a running process of ours.
declare -A live=()
for f in "$sessions"/*.json; do
  [[ -f "$f" ]] || continue
  read -r pid sid < <(python3 -c 'import json,sys
try:
    d = json.load(open(sys.argv[1])); print(int(d["pid"]), d["sessionId"])
except Exception:
    print(0, "-")' "$f")
  [[ "$pid" != 0 && -d "/proc/$pid" ]] && live["$sid"]=1
done
for c in /proc/[0-9]*/cmdline; do
  [[ -O "$c" ]] || continue
  while IFS= read -r sid; do
    [[ -n "$sid" ]] && live["$sid"]=1
  done < <(tr '\0' '\n' <"$c" 2>/dev/null | grep -oE "$uuid_ere")
done

say "START root=$root dry_run=$dry age_h=$age_h live_sessions=${#live[@]} used=$(used)"
n_rm=0 kb_rm=0 n_keep=0
while IFS= read -r -d '' d; do
  sid="${d##*/}"
  [[ "$sid" =~ ^${uuid_ere}$ ]] || continue
  [[ -O "$d" ]] || { say "KEEP not-ours $d"; n_keep=$((n_keep + 1)); continue; }
  if [[ -n "${live[$sid]:-}" ]]; then say "KEEP live $d"; n_keep=$((n_keep + 1)); continue; fi
  if [[ -n "$(find "$d" -newermt "-${age_h} hours" -print -quit 2>/dev/null)" ]]; then
    say "KEEP recent $d"; n_keep=$((n_keep + 1)); continue
  fi
  kb="$(du -sk -- "$d" 2>/dev/null | cut -f1)"; kb="${kb:-0}"
  if [[ "$dry" == 1 ]]; then
    say "PLAN remove ${kb}KB $d"
  else
    rm -rf -- "$d" && say "REMOVE ${kb}KB $d" || { say "WARN could not remove $d"; continue; }
    rmdir -- "${d%/*}" 2>/dev/null && say "REMOVE empty ${d%/*}"
  fi
  n_rm=$((n_rm + 1)); kb_rm=$((kb_rm + kb))
done < <(find "$root" -mindepth 2 -maxdepth 2 -type d -print0)
say "DONE $([[ "$dry" == 1 ]] && echo would-remove || echo removed)=$n_rm ($((kb_rm / 1024)) MB) kept=$n_keep used=$(used)"
