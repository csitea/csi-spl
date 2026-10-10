# Refactor round 6 - mistral seat proposal (m-710, sat)

A proposal, not the plan. The editor (claude seat) merges the three seats into `../refactor-round-6-plan.md`. This file is measured on trunk sha **`afda8d026`** (origin/master, 2026-10-10).

Every count was re-measured on `origin/master` (sha `afda8d026`). The commands are from the plan, section 2. Round 5 is closed and held: `refactor-round-5-retro.md` section 1 (10 of 10 actions).

## 1. The 10 actions

| # | slug | source | sites | n | kind | box | verdict | change |
|---|---|---|---|---|---|---|---|---|
| 01 | `r6-01-wui-fetch-signal-hours` | r5 D3 | 4 WUI utils, 6 calls | 6 | simple_coding | PC | agree | |
| 02 | `r6-02-wui-fetch-signal-calendar` | r5 D3 | 3 WUI utils, 4 calls | 4 | simple_coding | PC | agree | |
| 03 | `r6-03-bash-return-not-exit` | r5 D4 | `gcp-import-to-cloudsql.func.sh:168`, `gcp-export-dns-settings.func.sh:39` | 2 | secret | sat | agree | |
| 04 | `ci(r6-04-shellcheck-api-wui)` | r5 section 8 | the 22 api/wui `.sh` into the scanner; 6 findings fixed first | 6 | complex_coding | sat | agree | |
| 05 | `ci(r6-05-prepush-stale-tree)` | r5 retro 6.1 | a pre-push part refusing a commit that restores >= 3 paths | 2 of 300 | complex_coding | sat | agree | |
| 06 | `test(r6-06-go-coverage-raise)` | r5-10 + retro 6.7 | `internal/edge`, `internal/files`, `internal/action` (30-38%) | 3 | tests | PC | agree | |
| 07 | `r6-07-bash-cron-drop-helper` | DRY | 5 install-cron copies | 5 | simple_coding | sat | agree | |
| 08 | `r6-08-bash-probe-scaffold` | DRY | 5 reply-probe preambles | 5 | secret | sat | agree with changes | Move the `RETURN` trap to the helper. |
| 09 | `r6-09-wui-small-functions` | small functions | 4 LONG entries at 89-110 lines | 4 | simple_coding | PC | agree | |
| 10 | `r6-10-bash-small-functions` | small functions | 2 LONG iac actions at 117, 130 | 2 | secret | sat | agree | |

## 2. Disagreements

None. All 10 actions are agreed. One change is proposed for **08**: move the `RETURN` trap into the helper to avoid repeating it in every caller. This aligns with the DRY principle and keeps the caller cleaner.

## 3. Left out

The plan's section 8, each with the command that measured it.

## 4. Signed

Signed: plan sha `ed453dd77`