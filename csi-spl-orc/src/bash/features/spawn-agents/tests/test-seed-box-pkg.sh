#!/usr/bin/env bash
# Spec 142 row B8 (owner t1 06871e35: agents keep the right to install
# packages, through one named action): every vendor's seed carries the
# package line once. Renders the seed each of the five launchers writes
# (SPAWN_DRY_RUN=1, SPAWN_PLAN_DIR/prompt.txt), in a git repo and in a plain
# dir. Control: the line's one home (SEED_BOX_PKG in spawn-core.inc.sh)
# rendered for claude only -> the four other kinds miss it -> FAIL.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.inc.sh"
t_sandbox
export SPAWN_DRY_RUN=1 SPOOL_BIN=/opt/x/spool MISTRAL_BIN=/opt/x/vibe SPOOL_MISTRAL_MAX_PRICE=1
export SPAWN_GIT_IDENTITY='FirstName LastName <dev@example.com>'
# The env-first form: run.sh drops unknown trailing args, so
# './run -a do_box_pkg_install BOX_PKG=x' would run with BOX_PKG unset.
ACTION="/csi-spl-iac && BOX_PKG=<pkg> BOX_PKG_REASON=\"<why>\" AGENT_ID=<ID> ./run -a do_box_pkg_install'; you keep sudo, the action records it."
echo brief > "$T_TMP/brief.md"
mkdir -p "$T_TMP/plain"
git init -q --bare "$T_TMP/origin.git"
git init -q "$T_TMP/repo" && git -C "$T_TMP/repo" -c user.name=FirstName\ LastName -c user.email=dev@example.com commit -q --allow-empty -m init
git -C "$T_TMP/repo" branch -M master
git -C "$T_TMP/repo" remote add origin "$T_TMP/origin.git"
git -C "$T_TMP/repo" push -q origin master 2>/dev/null

# The control tree: this feature's scripts and lib, the line kept for claude only.
CTL="$T_TMP/ctl/spawn-agents"; mkdir -p "$CTL"
cp -r "$T_FEAT/scripts" "$T_FEAT/lib" "$CTL/"
sed -i '/^SEED_BOX_PKG=/a [ "$SPAWN_KIND" = claude ] || SEED_BOX_PKG=""' "$CTL/scripts/spawn-core.inc.sh"
check "control: the claude-only gate is in the control source" grep -q 'SPAWN_KIND" = claude ] || SEED_BOX_PKG=""' "$CTL/scripts/spawn-core.inc.sh"

seed() {  # SCRIPTS_DIR KIND ID WORKDIR PLAN -> prints the rendered seed
  mkdir -p "$5"
  SPAWN_PLAN_DIR="$5" bash "$1/spawn-$2.sh" "$3" "$4" "$T_TMP/brief.md" "box pkg" >"$5/out" 2>&1
  cat "$5/prompt.txt" 2>/dev/null
}
count() { printf '%s' "$2" | grep -o -- "$1" | wc -l; }

ctl_miss=0
for k in claude grok agy qwen mistral; do
  id=CLE-79; [ "$k" = grok ] && id=GRK-79; [ "$k" = agy ] && id=AGY-79
  [ "$k" = qwen ] && id=QWN-79; [ "$k" = mistral ] && id=m-079
  for w in repo plain; do
    s="$(seed "$T_SCRIPTS" "$k" "$id" "$T_TMP/$w" "$T_TMP/plan-$k-$w")"
    has "$k/$w: the seed carries the package line" "PACKAGES: install one with 'cd " "$s"
    has "$k/$w: ... env-first, with the lane's own id" "${ACTION//<ID>/$id}" "$s"
    eq "$k/$w: ... once" 1 "$(count do_box_pkg_install "$s")"
    c="$(seed "$CTL/scripts" "$k" "$id" "$T_TMP/$w" "$T_TMP/ctl-$k-$w")"
    has "$k/$w: control renders a seed" "Your spool agent id is ${id}" "$c"
    case "$c" in *"${ACTION//<ID>/$id}"*) ;; *) ctl_miss=$((ctl_miss + 1)) ;; esac
  done
done
# Claude-only line: 4 kinds x 2 dirs miss it, which the checks above refuse.
eq "control (claude-only source): 8 seeds miss the line -> FAIL" 8 "$ctl_miss"
t_done
