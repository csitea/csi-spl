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
# The age is 2 h, not 24 (sat, 2026-10-31 23:07Z: /tmp had 3658 inodes free
# of 1048576 at 54% bytes used; every lane rotates about hourly and leaves a
# dead dir of up to 100k inodes, and a day of them filled the tmpfs).
#
# Inode guard: when the root's free inodes are below SCRATCH_INODE_MIN_FREE_PCT
# percent after the age pass, the dead dirs (same claim check) idle at least
# SCRATCH_PRESSURE_AGE_M minutes go too, oldest first, until the free inodes
# (projected: those freed by each dir, du --inodes) reach the threshold.
#
# Installed by do_tmp_scratch_sweep_install_cron as ONE line tagged
# `# csi-spl:tmp-scratch-sweep`; one PLAN|REMOVE / KEEP line per session dir.
#
#   DRY_RUN=1 (default) | 0
#   SCRATCH_ROOT                default /tmp/claude-$(id -u)
#   SCRATCH_SESSIONS            default $HOME/.claude/sessions
#   SCRATCH_SWEEP_AGE_H         default 2
#   SCRATCH_INODE_MIN_FREE_PCT  default 10 (0 = no inode guard)
#   SCRATCH_PRESSURE_AGE_M      default 30
#   SCRATCH_DF                  default df (tests pass a fake)
#
# Exit: 0 done; 2 usage or a refusal (nothing removed).
set -uo pipefail
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}"

dry="${DRY_RUN:-1}"
root="${SCRATCH_ROOT:-/tmp/claude-$(id -u)}"
sessions="${SCRATCH_SESSIONS:-$HOME/.claude/sessions}"
age_h="${SCRATCH_SWEEP_AGE_H:-2}"
min_pct="${SCRATCH_INODE_MIN_FREE_PCT:-10}"
p_age_m="${SCRATCH_PRESSURE_AGE_M:-30}"
df_cmd="${SCRATCH_DF:-df}"
uuid_ere='[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'

say() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
refuse() { say "REFUSE $*: nothing removed"; exit 2; }
used() { "$df_cmd" -P "$root" | awk 'NR==2{print $5}'; }
# "<inodes> <free>" of the root's filesystem; "0 0" when it reports none.
inodes() { "$df_cmd" -iP "$root" 2>/dev/null | awk 'NR==2{print $2+0, $4+0; f=1} END{if(!f) print 0, 0}'; }

[[ "$dry" == 0 || "$dry" == 1 ]] || refuse "DRY_RUN must be 0 or 1, got '$dry'"
[[ "$age_h" =~ ^[0-9]+$ ]] && (( age_h >= 1 )) || refuse "SCRATCH_SWEEP_AGE_H must be a whole number >= 1, got '$age_h'"
[[ "$min_pct" =~ ^[0-9]+$ ]] && (( min_pct <= 50 )) || refuse "SCRATCH_INODE_MIN_FREE_PCT must be 0..50, got '$min_pct'"
[[ "$p_age_m" =~ ^[0-9]+$ ]] && (( p_age_m >= 10 )) || refuse "SCRATCH_PRESSURE_AGE_M must be a whole number >= 10, got '$p_age_m'"
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

# remove_dir <dir> <why>: PLAN in a dry run, else REMOVE (and an emptied
# project dir); counts it. Returns 1 when the removal failed.
n_rm=0 kb_rm=0 n_keep=0 in_rm=0
remove_dir() {
  local d="$1" why="$2" kb in
  kb="$(du -sk -- "$d" 2>/dev/null | cut -f1)"; kb="${kb:-0}"
  in="$(du -s --inodes -- "$d" 2>/dev/null | cut -f1)"; in="${in:-0}"
  if [[ "$dry" == 1 ]]; then
    say "PLAN remove ${kb}KB $d${why}"
  else
    rm -rf -- "$d" && say "REMOVE ${kb}KB $d${why}" || { say "WARN could not remove $d"; return 1; }
    rmdir -- "${d%/*}" 2>/dev/null && say "REMOVE empty ${d%/*}"
  fi
  n_rm=$((n_rm + 1)); kb_rm=$((kb_rm + kb)); in_rm=$((in_rm + in))
}

read -r i_total i_free < <(inodes)  # before the sweep: freed inodes are added
say "START root=$root dry_run=$dry age_h=$age_h live_sessions=${#live[@]} used=$(used)"
recent=()  # dead dirs kept for age only: the inode guard's candidates
while IFS= read -r -d '' d; do
  sid="${d##*/}"
  [[ "$sid" =~ ^${uuid_ere}$ ]] || continue
  [[ -O "$d" ]] || { say "KEEP not-ours $d"; n_keep=$((n_keep + 1)); continue; }
  if [[ -n "${live[$sid]:-}" ]]; then say "KEEP live $d"; n_keep=$((n_keep + 1)); continue; fi
  if [[ -n "$(find "$d" -newermt "-${age_h} hours" -print -quit 2>/dev/null)" ]]; then
    say "KEEP recent $d"; n_keep=$((n_keep + 1)); recent+=("$d"); continue
  fi
  remove_dir "$d" "" || continue
done < <(find "$root" -mindepth 2 -maxdepth 2 -type d -print0)

want=$(( i_total * min_pct / 100 ))
if (( min_pct > 0 && i_total > 0 && i_free + in_rm < want )); then
  say "PRESSURE ifree=$((i_free + in_rm)) of $i_total want=$want: dead dirs idle >= ${p_age_m}m go, oldest first"
  # "<newest mtime> <dir>" of each candidate idle long enough, oldest first.
  while IFS= read -r line; do
    d="${line#* }"
    (( i_free + in_rm >= want )) && break
    remove_dir "$d" " (inode pressure)" && n_keep=$((n_keep - 1))
  done < <(for d in "${recent[@]}"; do
      [[ -n "$(find "$d" -newermt "-${p_age_m} minutes" -print -quit 2>/dev/null)" ]] && continue
      printf '%s %s\n' "$(find "$d" -printf '%T@\n' 2>/dev/null | sort -n | tail -1)" "$d"
    done | sort -n)
  if (( i_free + in_rm >= want )); then say "PRESSURE OK ifree=$((i_free + in_rm)) >= $want"
  else say "PRESSURE WARN ifree=$((i_free + in_rm)) < $want: no more dead dirs idle >= ${p_age_m}m"; fi
fi
say "DONE $([[ "$dry" == 1 ]] && echo would-remove || echo removed)=$n_rm ($((kb_rm / 1024)) MB, $in_rm inodes) kept=$n_keep used=$(used) ifree~$(( i_free + in_rm ))/$i_total"
