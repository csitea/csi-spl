# Refactor round 6 - claude seat proposal (c-709, sat)

A proposal, not the plan. The editor (this seat) merges the three seats into `../refactor-round-6-plan.md`. The agy and mistral seats write `seat-agy.md` and `seat-mistral.md` beside this file, measured on the same sha, then sign.

Every count was measured on ONE trunk sha, **`da36dad94`**, n=1 per count unless stated otherwise. The command for each is in the plan, section 2. Round 5 is closed and held: `refactor-round-5-retro.md` section 1 (10 of 10 actions).

## 1. The 10 actions

| # | slug | source | sites | n | kind | box |
|---|---|---|---|---|---|---|
| 01 | `r6-01-wui-fetch-signal-hours` | r5 D3 | 4 WUI utils, 6 calls | 6 | simple_coding | PC |
| 02 | `r6-02-wui-fetch-signal-calendar` | r5 D3 | 3 WUI utils, 4 calls | 4 | simple_coding | PC |
| 03 | `r6-03-bash-return-not-exit` | r5 D4 | `gcp-import-to-cloudsql.func.sh:168`, `gcp-export-dns-settings.func.sh:39` | 2 | secret | sat |
| 04 | `ci(r6-04-shellcheck-api-wui)` | r5 section 8 | the 22 api/wui `.sh` into the scanner; 6 findings fixed first | 6 | complex_coding | sat |
| 05 | `ci(r6-05-prepush-stale-tree)` | r5 retro 6.1 | a pre-push part refusing a commit that restores >= 3 paths | 2 of 300 | complex_coding | sat |
| 06 | `test(r6-06-go-coverage-raise)` | r5-10 + retro 6.7 | `internal/edge`, `internal/files`, `internal/action` (30-38%) | 3 | tests | PC |
| 07 | `r6-07-bash-cron-drop-helper` | DRY | 5 install-cron copies | 5 | simple_coding | sat |
| 08 | `r6-08-bash-probe-scaffold` | DRY | 5 reply-probe preambles | 5 | secret | sat |
| 09 | `r6-09-wui-small-functions` | small functions | 4 LONG entries at 89-110 lines | 4 | simple_coding | PC |
| 10 | `r6-10-bash-small-functions` | small functions | 2 LONG iac actions at 117, 130 | 2 | secret | sat |

## 2. Rules proposed (from the r5 retro, section 6)

- R2 gains cross-package callers of a moved or deleted export (retro 4.2).
- R7 names the reviewer per row from another vendor's panel seat, with a backup, and adds C7 "the pushed sha is the reviewed sha" (retro 4.1, 4.3).
- R9: a gate lane runs its own test under `PRE_PUSH_TIER=full` and with no inherited `PRE_PUSH_*` (retro 4.4).
- A row brief carries the plan row verbatim (retro 4.5); the spawner reads the new pane 2 minutes after spawn (retro section 2).

## 3. Left out

The plan's section 8, each with the command that measured it.
