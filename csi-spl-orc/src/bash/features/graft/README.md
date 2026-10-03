# graft — a local, zero-egress code index for the agents

The spool agents' `graft` command and skill (spec 069 Y6, moved here from the
box engine). graft is a third-party tree-sitter code index; this feature keeps
it local and keeps its index current. graft itself is installed separately
(npm or an offline pack); nothing here downloads anything.

| path | what |
|---|---|
| `scripts/graft-safe.sh` | the policy wrapper: refuses `init`, `upgrade`, `--deep`, re-enabling telemetry (exit 78); forces `DO_NOT_TRACK`, clears API keys and the proxy; adds `--dir <out-of-tree index>` inside a git repo |
| `scripts/graft-wrap.sh` | writes the ONE stub shape that is `graft` on PATH (`GRAFT_SAFE_BIN=<raw launcher>`, exec `graft-safe.sh`) |
| `scripts/graft-index-dir.sh` | where a repo's index lives: `${GRAFT_INDEX_ROOT:-$GRAFT_VAR_ROOT/index}/<slug>` |
| `scripts/graft-index-update.sh` | re-index the box repo list; re-asserts the wrapper and the language layer; skips unchanged repos |
| `scripts/graft-cron.sh` | the scheduled entry (spec 069 C3, C4): `flock -n`, log, then `graft-index-update.sh` |
| `scripts/graft-register-lang.sh` | register a breadth-tier grammar (bash, sql) in the installed graft |
| `assets/skills/graft/` | the agents' `graft` skill (`~/.claude/skills/graft` links here) |
| `assets/agy-rules/graft.md` | the agy rule (`~/.gemini/config/rules/graft.md` links here) |
| `assets/tags/`, `assets/wasm/` | tags queries and grammars graft's vendor bundle lacks |

## Box state

`GRAFT_VAR_ROOT` (default `/var/csi/csi-spl/graft`) is box-wide, because one OS
user builds the index and every agent user reads it:

| file | what |
|---|---|
| `repos.list` | the repos this box indexes, one absolute path per line, `#` comments (`GRAFT_REGISTRY` overrides). Box-specific, never tracked. |
| `index/<slug>/` | each repo's index |
| `graft-cron.log`, `graft-cron.lock` | the scheduled run (`GRAFT_CRON_LOG`, `GRAFT_CRON_LOCK` override) |

## Install

`install.sh` (spool-install) runs `steps/y6-graft.sh` for the user it runs as:
the `graft` stub on `<prefix>/bin` is pointed at this checkout's `graft-safe.sh`
(the raw launcher it named is kept), and the skill and agy-rule links are
pointed here. `install.sh --dry-run` prints the plan. The cron lines are
written by the box cron action, running `scripts/graft-cron.sh`.

## Tests

`bash csi-spl-orc/src/bash/features/graft/tests/run-all.sh` (hermetic: sandbox
`HOME`, stub graft, no network).
