#!/usr/bin/env bash
# spec 184 row L4 (owner Q5 "fb"): a model the CLI refuses starts once more on
# the CLI's own default, with one WARN in the spawn log (stderr) and the lane
# journal (<id>/lifetime/journal.log), and lifetime/model.txt = cli-default.
#   1. live list: a model the CLI's list does not hold goes without it at
#      once (dry run, a stub CLI whose --help names the aliases);
#   2. start check: a stub launcher on a PRIVATE tmux server that quits when
#      a model resolves is respawned once without it; one that always quits
#      is a failed start after exactly two launches; CONTROL: one that does
#      not quit is never relaunched and logs no WARN.
# The stub launcher resolves the model with the real spool_agent_model from
# the env spawn-window hands the pane, as spawn-core does.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.inc.sh"
t_sandbox
SW="$T_SCRIPTS/spawn-window.sh"
WD="$T_TMP/plain"; mkdir -p "$WD" "$T_TMP/bin"
R="$SPOOL_ROOT"
export RETIRE_LANE=0 SPOOL_ID_REAP_H=6 SPOOL_BIN=/opt/x/spool
unset DRY_RUN SPAWN_MODEL SPAWN_MODEL_MAP SPAWN_TASK_KIND

# A claude CLI stub: --help names the aliases as claude 2.1.323 does.
cat >"$T_TMP/bin/claude" <<'EOS'
#!/usr/bin/env bash
case "${1:-}" in
  --help) printf '%s\n' "  --model <model>   Model for the current session. Provide an alias for" \
            "                    the latest model (e.g. 'opus' or 'sonnet') or a full name" ;;
  --version) echo "2.1.323 (Claude Code)" ;;
esac
EOS
chmod +x "$T_TMP/bin/claude"
export CLAUDE_BIN="$T_TMP/bin/claude"
cnf() { printf 'env:\n  box:\n    agent_model:\n      default: { claude: "%s" }\n      by_kind: {}\n' "$1" >"$T_TMP/model.yaml"; }
export SPOOL_AGENT_MODEL_CNF="$T_TMP/model.yaml"
# The dry runs plan on a private tmux server, against a stub lane map and a
# throwaway git checkout with an origin (as test-spawn-window-dry-run.sh).
t_tmux
ORC="$T_TMP/orc"; mkdir -p "$ORC"
printf '#!/usr/bin/env bash\nexit 0\n' >"$ORC/run"; chmod +x "$ORC/run"
export LANE_MAP_ORC="$ORC"
echo brief >"$T_TMP/brief.md"
git init -q --bare "$T_TMP/origin.git"
git init -q -b master "$T_TMP/repo"
git -C "$T_TMP/repo" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m init
git -C "$T_TMP/repo" remote add origin "$T_TMP/origin.git"
git -C "$T_TMP/repo" push -q origin master 2>/dev/null
dry() { SPAWN_DRY_RUN=1 timeout 60 bash "$SW" claude "$1" "$T_TMP/repo" "$T_TMP/brief.md" x 2>&1; }
WARN_RE='WARN model [^ ]+ refused by claude, started on the CLI default'

# --- 1. the live list ------------------------------------------------------------
cnf retired-x
out="$(dry CLE-4801)"; rc=$?
eq "1. a model outside the live list: the dry spawn still starts (exit 0)" 0 "$rc"
hasnt "...its launch goes without --model, at once" "--model" "$(grep '^PLAN launch' <<<"$out")"
has "...the plan says model=cli-default" "model=cli-default" "$(grep '^PLAN adapter' <<<"$out")"
eq "...one WARN, naming the model and why" 1 "$(grep -cE "WARN model retired-x refused by claude, started on the CLI default \(not in its live list\)" <<<"$out")"
cnf sonnet
out="$(dry CLE-4802)"
has "1. CONTROL: a model the list holds is passed" "--model 'sonnet'" "$(grep '^PLAN launch' <<<"$out")"
eq "...and logs no WARN" 0 "$(grep -cE "$WARN_RE" <<<"$out")"
cnf claude-full-name-1
out="$(dry CLE-4803)"
has "1. a full claude-* name passes on syntax alone (G8)" "--model 'claude-full-name-1'" "$(grep '^PLAN launch' <<<"$out")"
eq "...no WARN" 0 "$(grep -cE "$WARN_RE" <<<"$out")"
mv "$T_TMP/bin/claude" "$T_TMP/bin/claude.off"; printf '#!/usr/bin/env bash\nexit 1\n' >"$T_TMP/bin/claude"; chmod +x "$T_TMP/bin/claude"
cnf retired-x
out="$(dry CLE-4804)"
has "1. a CLI whose list cannot be read skips the check: the model is passed" "--model 'retired-x'" "$(grep '^PLAN launch' <<<"$out")"
eq "...no WARN" 0 "$(grep -cE "$WARN_RE" <<<"$out")"
mv "$T_TMP/bin/claude.off" "$T_TMP/bin/claude"

# --- 2. the start check ----------------------------------------------------------
# The stub launcher: records the model like spawn-core's _spawn_model_record,
# counts its launches, then per $T_TMP/mode: on-model = quits (the session
# ended banner, the pane kept) when a model resolved; die-on-model = its
# process ends (the pane dead) when a model resolved; always = quits anyway;
# never = draws an input box and stays.
cat >"$T_TMP/stub-launch.sh" <<EOS
#!/usr/bin/env bash
. "$T_FEAT/lib/spool-env.inc.sh"
m="\$(spool_agent_model claude 2>/dev/null)"
mkdir -p "\$SPOOL_ROOT/\$1/lifetime"; printf '%s\n' "\${m:-cli-default}" >"\$SPOOL_ROOT/\$1/lifetime/model.txt"
printf '%s %s\n' "\${m:-cli-default}" "\${SPAWN_REUSE_ID:-0}" >>"$T_TMP/launches"
case "\$(cat "$T_TMP/mode")" in
  on-model) [ -z "\$m" ] || { echo " claude session '\$1' ended. Pane kept open so the window stays"; exec sleep 600; } ;;
  die-on-model) [ -z "\$m" ] || exit 1 ;;
  always) echo " claude session '\$1' ended. Pane kept open so the window stays"; exec sleep 600 ;;
esac
printf '%s\n' '────────' '❯ ' '────────'; exec sleep 600
EOS
L="$(readlink -f "$T_SCRIPTS")/spawn-claude.sh"
REAL_TMUX="$(command -v tmux)"
# tmux shim: new-window and respawn-pane run the stub in place of the launcher.
cat >"$T_TMP/bin/tmux" <<EOS
#!/usr/bin/env bash
case " \$* " in
  *" new-window "*|*" respawn-pane "*) c="\${@: -1}"; p='$L' r='$T_TMP/stub-launch.sh'; set -- "\${@:1:\$#-1}" "\${c//"\$p"/"\$r"}" ;;
esac
exec "$REAL_TMUX" "\$@"
EOS
chmod +x "$T_TMP/bin/tmux"
sw() { : >"$T_TMP/launches"; PATH="$T_TMP/bin:$PATH" SPAWN_START_CHECK=1 SPAWN_START_CHECK_WAIT=10 START_CHECK_POLL=0.2 bash "$SW" claude "$1" "$WD" 2>&1; }
echo on-model >"$T_TMP/mode"; cnf sonnet
out="$(sw CLE-4811)"; rc=$?
eq "2. a CLI that quits on --model: the spawn starts (exit 0)" 0 "$rc"
eq "...after exactly two launches, the second without the model, as a respawn" "sonnet 0|cli-default 1" "$(paste -sd'|' "$T_TMP/launches")"
eq "...one WARN in the spawn log" 1 "$(grep -cE "WARN model sonnet refused by claude, started on the CLI default \(the CLI quit at start\)" <<<"$out")"
eq "...one line in the lane journal" 1 "$(grep -cE "$WARN_RE" "$R/CLE-4811/lifetime/journal.log" 2>/dev/null)"
eq "...lifetime/model.txt reads cli-default" cli-default "$(cat "$R/CLE-4811/lifetime/model.txt" 2>/dev/null)"
check "...the '<ID> <PANE>' line goes out" grep -qE '^CLE-4811 %[0-9]+$' <<<"$out"

echo die-on-model >"$T_TMP/mode"
out="$(sw CLE-4815)"; rc=$?
eq "2. a pane that ends on --model (start check rc 5): respawned, exit 0" 0 "$rc"
eq "...two launches" "sonnet 0|cli-default 1" "$(paste -sd'|' "$T_TMP/launches")"
eq "...one WARN" 1 "$(grep -cE "$WARN_RE" <<<"$out")"

echo always >"$T_TMP/mode"
out="$(sw CLE-4812)"; rc=$?
eq "2. a CLI that quits again on the default: a failed start (exit 11)" 11 "$rc"
eq "...no third launch" "sonnet 0|cli-default 1" "$(paste -sd'|' "$T_TMP/launches")"
has "...named as an ordinary failed start" "START FAIL CLE-4812" "$out"
eq "...the WARN still once" 1 "$(grep -cE "$WARN_RE" <<<"$out")"

cnf ""
out="$(sw CLE-4813)"; rc=$?
eq "2. no model set and the CLI quits: no relaunch" "cli-default 0" "$(paste -sd'|' "$T_TMP/launches")"
eq "...a failed start (exit 11)" 11 "$rc"
eq "...no WARN" 0 "$(grep -cE "$WARN_RE" <<<"$out")"

echo never >"$T_TMP/mode"; cnf sonnet
out="$(sw CLE-4814)"; rc=$?
eq "2. CONTROL: a CLI that does not quit starts at once (exit 0)" 0 "$rc"
eq "...no relaunch: one launch, on the model" "sonnet 0" "$(paste -sd'|' "$T_TMP/launches")"
eq "...no WARN in the spawn log" 0 "$(grep -cE "$WARN_RE" <<<"$out")"
check "...no lane journal line" test ! -e "$R/CLE-4814/lifetime/journal.log"
eq "...lifetime/model.txt keeps the model" sonnet "$(cat "$R/CLE-4814/lifetime/model.txt" 2>/dev/null)"

t_done
