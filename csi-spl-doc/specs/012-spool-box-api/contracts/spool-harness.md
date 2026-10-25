# Contract: `spool-harness` (012)

Source: `csi-spl-orc/src/bash/features/spawn-agents/scripts/spool-harness.sh`.
Binding narrative: `../../../doc/md/SPEC-spool-box-api.md` §2.1.

## 1. Invocation

```text
spool-harness --as <agent_id> [--to-box <box_id>] [--] <agent-cli-command...>
```

- `--as` (required): `^[A-Z]{2,4}-[0-9]+$`, not `BOX-` (identity-routing §2).
- `--to-box`: the box this session is attached to; sets `SPOOL_BOX_ID`,
  wins over an inherited value. `^[a-z0-9][a-z0-9-]{0,31}$`.
- `--` is optional; the first non-option word starts the command.

## 2. Sequence (in order; a refusal stops before the next step)

| # | Step | Local mode | Hub mode (`SPOOL_HUB_URL` set) |
|---|---|---|---|
| 1 | `$SPOOL_ROOT/<id>/{inbox,outbox,archive}`, `$SPOOL_ROOT/{files,pins}` 0775; `umask 0002` | yes | yes |
| 2 | box id + `${SPOOL_KEYS_DIR:-$HOME/.spool/keys}/box-<box_id>.key` 0600 | optional; a wrong mode warns | required, else 78 |
| 3 | one `spool hub-run` per root; wait for `<id>` under `<box>` in `$SPOOL_ROOT/.hub/roster.json` | skipped | yes |
| 4 | export `SPOOL_ROOT`, `SPOOL_BOX_ID` (if set), `SPOOL_AGENT_ID` | yes | yes |
| 4b | seed + brief token budget (SPL-2177): an argv with the seed pointer `Read and follow your seed: <file>` estimates `<file>` + the `brief.md` beside it (`brief-token-estimate.sh`, bytes / 4, rounded up) and refuses over `SPOOL_BRIEF_TOKEN_BUDGET` with one `FATAL` line naming both numbers, exit 65; nothing is truncated; no pointer (a resume) = skipped | yes | yes |
| 5 | `exec <command>` | yes | yes |

## 3. Env

| var | default | meaning |
|---|---|---|
| `SPOOL_ROOT` | `/var/spool-hub` | message root |
| `SPOOL_BOX_ID` | — | box id |
| `SPOOL_KEYS_DIR` | `$HOME/.spool/keys` | box private key dir (same as `spool`) |
| `SPOOL_HUB_URL` | — | set = hub mode |
| `SPOOL_BIN` | repo build, else `spool` on `PATH` | binary for the sidecar |
| `SPOOL_HARNESS_SIDECAR` | `auto` | `auto` start when absent · `external` only wait · `off` skip |
| `SPOOL_HARNESS_WAIT_SECS` | `25` | roster wait |
| `SPOOL_HARNESS_STRICT` | `0` | `1` = unconfirmed sidecar/roster exits 69 |
| `SPOOL_BRIEF_TOKEN_BUDGET` | `16000` | step 4b budget in tokens; measured 2026-10-25: the largest live seed + brief was 18212 B (~4553 tokens) |

Sidecar files, all under `$SPOOL_ROOT/.hub/` (hidden from the agent scan):
`hub-run.pid`, `hub-run.log`, `hub-run.lock`, and the `roster.json` that
`spool hub-run` writes.

## 4. Exit codes (before the exec)

| code | meaning |
|---|---|
| 2 | usage |
| 65 | the seed + brief token estimate is over `SPOOL_BRIEF_TOKEN_BUDGET` (step 4b) |
| 69 | hub mode: no spool binary to start the sidecar; strict: sidecar down or agent not announced |
| 73 | a spool dir cannot be created or is not writable |
| 78 | verify/refuse: bad agent/box id; hub mode without box id, key, or key mode 0600 |
| 127 | agent command not found |

After the exec the exit code is the agent's.

<!-- version: 1.1.0 · updated: 2026-10-25 · last-edit: 2026-10-25T21:30:00Z -->
