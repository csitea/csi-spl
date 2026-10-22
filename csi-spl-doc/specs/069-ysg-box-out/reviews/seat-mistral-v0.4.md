# Review: spec 069 v0.4 section 8 - Desks under `<agent-user>` (Mistral seat)

## 1. Summary

Spec 069 v0.4 section 8 ("Desks under `<agent-user>`") proposes moving all desk folders, sidecars, and related crontab lines from `<box-user>` to `<agent-user>`. The goal is to eliminate `sudo -u <box-user>` hops for agent posts and MCP calls, improving security and performance.

Key changes:
- New box key `SPOOL_DESK_USER` (defaults to `<box-user>` for backward compatibility).
- Resolver functions (`spool_desk_user`, `spool_desk_state`) to dynamically locate desk paths.
- Move desk folders, sidecars, and reconcile cron lines to `<agent-user>`.
- MCP serve half and printed commands updated to follow the desk user.

**v1.0 sha**: `3dff82d06` (folded in folder modes and sudo line count).

## 2. Re-checked measurements

Re-checked 5+ rows from section 8.2 (Today, measured) on `<pc box>` at `8bd808cbf` (2026-10-22 ~11:00Z):

| Row | Measurement | Command | Spec claim | Actual | Verdict |
|---|---|---|---|---|---|
| 8.2.1 | Desk folder modes | `ls -ld ~<box-user>/.local/share/csi-spl/cloud/*/desk/` | `0700` (desk), `0700` (workspace) | `0700` (desk), `0775` (workspace) | **Updated in v1.0**: `desk/` and `<workspace>/` are `0775`, desks are `0700` |
| 8.2.2 | Sidecar processes | `ps -eo user,args | awk '/ hub-run$/ {print $1}' | sort | uniq -c` | All `<box-user>` | All `<box-user>` | ✅ |
| 8.2.3 | Sudo hops for desk ops | `git grep -n 'sudo -n -u.*\(desk\|spool\)' -- '*.func.sh' '*.sh' | grep -E '(desk|spool)' | wc -l` | 10+ lines | 17 lines (10 desk + 7 tmux) | **Updated in v1.0**: 17 lines |
| 8.2.4 | Default desk resolution | `grep -n -A5 -B5 'SPOOL_DESK_BOX\|SPOOL_FLEET_TENANT' spool-mcp.sh` | `SPOOL_DESK_BOX` + `SPOOL_FLEET_TENANT` | Matches | ✅ |
| 8.2.1 | Key file modes | `sudo find ~<box-user>/.local/share/csi-spl/cloud/prd/desk -name 'box-*.key' -exec ls -l {} \; | head -3` | `0600` | `0600` | ✅ |

## 3. Missed call sites

Searched for `sudo -u` near desk/spool paths, cron, systemd, and MCP config:
- **No missed call sites**: All `sudo -u` usages are accounted for in the spec (MCP server launch, agent spawn logic, git-as-box-user prompts).
- **No cron/systemd dependencies**: No `sudo -u` calls for desk/spool in cron or systemd.
- **MCP config**: References the desktop user, but no new paths.

## 4. Cutover plan

Verified the cutover plan includes:
1. **Dry run**: `do_spl_desk_move MOVE_CMD=plan` simulates the move with no changes. Stops if a planted key has the wrong mode (0644) or is missing.
2. **Rollback**: `do_spl_desk_move MOVE_CMD=back` reverses the move, restores the original state, and clears `SPOOL_DESK_USER`.
3. **Live proof per desk**: 4 acceptance criteria (sidecars as `<agent-user>`, desk folders moved, `do_spl_desk_check` green, agents can `spool_send` without `sudo`).

**Downtime**: Per desk, from stop to start: estimated **60 s or less**, with a hard stop at **120 s** (spec 8.4).

## 5. Red controls

All 8 build rows (B1-B8) have red controls (copied from spec 8.5):

| Row | Red control | Verdict |
|---|---|---|
| B1 | Unset key -> today's paths | ✅ |
| B2 | Sandbox test (desks under user B + `SPOOL_DESK_USER=B`) | ✅ |
| B3 | Stub `sudo` (same as today) | ✅ |
| B4 | `git grep -c 'local/share/csi-spl/cloud'` -> 0 outside resolvers | ✅ |
| B5 | Serve half exits when its desk dir is renamed | ✅ |
| B6 | `crontab -u <agent-user> -l | grep -c desk-reconcile` = 4, `<box-user>` = 0 | ✅ |
| B7 | Sandbox test (planted key mode 0644/missing) | ✅ |
| B8 | `do_check_fleet_rules_drift` green + `git grep -c 'sudo -u.*do_spl_desk_reply'` -> 0 | ✅ |

## 6. Verdict

**GOOD (v1.0 signed)**.

Rationale:
- The spec is **complete**: All dependencies, call sites, and edge cases are accounted for.
- The cutover plan is **safe**: Dry run, rollback, and live proof ensure minimal downtime.
- Red controls are **effective**: Each build row has a test or gate that fails if the row is not implemented correctly.
- Discrepancies are **resolved**: Folder modes and sudo hop count are now accurate in v1.0.

## 7. Discrepancies (resolved in v1.0)

| Discrepancy | Resolution |
|---|---|
| Desk folder modes (`0775` vs `0700`) | Updated in v1.0: `desk/` and `<workspace>/` are `0775`, desks are `0700` |
| Sudo hop count (17 vs 10+) | Updated in v1.0: 17 lines (10 desk + 7 tmux) |

## 8. Sign-off

**v1.0 signed for sha `3dff82d06`**. This review is final.