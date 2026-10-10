# Review s-mistral: Workspace vendor keys (bring your own keys)

Review of spec v1.0 at `64b24b396` (2026-10-11), the editor c-928's fold of s-claude-2's review.

## 1. Measured facts (re-checked, cite the command)

| fact | the command that shows it | result |
|---|---|---|
| no per-workspace vendor key storage exists | `git -C /opt/csi/csi-spl-wt/m-934 grep -liE 'vendor_key|api_key' -- csi-spl-rdb` | no file |
| seats authenticate per box: each CLI's own login in the agent user's home; the launcher passes no key | `sed -n 8,12p /opt/csi/csi-spl-wt/m-934/csi-spl-orc/src/bash/features/spawn-agents/scripts/spawn-mistral.sh` | "Authentication is NOT the launcher's business" |
| the mistral launch drops an exported key so the box's `.vibe/.env` wins | `grep -n 'env -u MISTRAL_API_KEY' /opt/csi/csi-spl-wt/m-934/csi-spl-orc/src/bash/features/spawn-agents/scripts/spawn-mistral.sh` | line 63 |
| one OS user runs every seat of a box (`SPOOL_AGENT_USER`) | `grep -n 'SPOOL_AGENT_USER=' /opt/csi/csi-spl-wt/m-934/csi-spl-orc/src/bash/features/spawn-agents/lib/spool-env.inc.sh` | 273 |
| the fleet lease tick captures every seat's pane | `grep -n capture-pane /opt/csi/csi-spl-wt/m-934/csi-spl-orc/src/bash/run/spl-dispatch-lease.func.sh` | 560 |
| every launcher installs the terminal mirror (spec 036), which sends the seat's turns to the hub | `sed -n 6,20p /opt/csi/csi-spl-wt/m-934/csi-spl-orc/src/bash/features/spawn-agents/lib/spool-mirror-hooks.inc.sh` | terminal mirror installed |
| no seat limits core dumps, hides `/proc` or sets ptrace scope | `git -C /opt/csi/csi-spl-wt/m-934 grep -nE 'ulimit -c|LimitCORE|hidepid|ptrace_scope|PR_SET_DUMPABLE' -- csi-spl-orc csi-spl-iac` | nothing |
| the hub never stores private key material of spool keys (006 FR-014, amended by 017 SEC-03) | `grep -n FR-014 /opt/csi/csi-spl-wt/m-934/csi-spl-doc/specs/006-spool-hub-rental/spec.md` | 214 |
| the vendor split per task kind is a Workspace setting, `tenant_agent_split_kind` (rdb 0163), `PATCH /v1/agent-split` under `rbac.TenantSettings` | `sed -n 165,168p /opt/csi/csi-spl-wt/m-934/csi-spl-api/src/go/spool-hub-api/internal/hub/agent_split.go` | PATCH at 167 |
| the `secret` kind admits only claude and mistral, in the table | `grep -n secret_vendors /opt/csi/csi-spl-wt/m-934/csi-spl-rdb/src/sql/postgres/spool-hub/0163_tenant_agent_split_kind.sql` | 20, 49 |
| `box_mode` is the box's OWN declaration, signed by its own key, not a property the hub verifies; NULL on every root-key pin, read as shared | `sed -n 16,20p /opt/csi/csi-spl-wt/m-934/csi-spl-rdb/src/sql/postgres/spool-hub/0170_box_join_switch.sql`; `sed -n 384,389p /opt/csi/csi-spl-wt/m-934/csi-spl-api/src/go/spool-hub-api/internal/hub/join_tokens.go` | NULL on root-key pin, read as shared |
| FORCE RLS with `tenant_scope` + `operator_scope` on every tenant table; the operator scope reads every row | rdb 0163 tail; spec 108 section 3.6 (cross-reference) |
| one precedent for a table with NO operator policy: `personal.profile` (rdb 0168), pinned by a catalogue test with red controls | `grep -n "policies are exactly" /opt/csi/csi-spl-wt/m-934/csi-spl-api/src/go/spool-hub-api/internal/store/personal_catalogue_test.go` | 171 |
| the operator service account invites anyone into any workspace with any role | `sed -n 111,113p /opt/csi/csi-spl-wt/m-934/csi-spl-api/src/go/spool-hub-api/internal/hub/operator.go` | `POST /v1/operator/invites {tenant, email, role?, ..., no_mail?}` |
| an act-as session never holds an admin-only permission: the target is in the admin's own tenant and below the admin | `sed -n 33,39p /opt/csi/csi-spl-wt/m-934/csi-spl-api/src/go/spool-hub-api/internal/auth/actas.go` | act-as session never holds admin-only permission |
| the metering ledger exists: `usage_events`, `model_prices`, `token_budgets` (rdb 0171, spec 121 T301) | `sed -n 1,40p /opt/csi/csi-spl-wt/m-934/csi-spl-rdb/src/sql/postgres/spool-hub/0171_usage_events.sql` | exists |
| the per-env SAs cannot read GCP billing; spec 123 reads the BigQuery billing export with its own SA | spec 123 section 3 (cross-reference) |
| roles: `admin` and `biz_owner` hold `tenant.settings`; `agents.join` is the admin's alone | `sed -n 133,140p /opt/csi/csi-spl-wt/m-934/csi-spl-api/src/go/spool-hub-api/internal/rbac/rbac.go` | roles confirmed |

**Checked paths**: 18/18 exist on `origin/master` at `64b24b396`.

## 2. Review by section

| section | verdict | change (if any) |
|---|---|---|
| 1. The owner's words | agree | none |
| 2. Today, measured | agree | none |
| 3. Kinds and how many keys | agree | none |
| 4. Storage | agree | none |
| 5. Who, and spawning on the key | agree | none |
| 6. Leak paths, guards and tests | agree | none |
| 7. Workspace as a service (K4) | agree | none |
| 8. The WUI | agree | none |
| 9. Owner questions | agree | none (A on Q-1, Q-2, Q-3, Q-4) |
| 10. Lane plan | agree | none |
| 11. Panel and consensus | agree | none |

## 3. Isolation design

- **Operator path**: Closed by 5.1 (key-box approval + unconfirmed operator-made admins). The operator cannot read a key through the hub (no route, no `operator_scope` on the key table, key-box approval, operator-made admins unconfirmed).
- **Argv leak path**: Closed by 5.2 (`spool-key-exec` wrapper, no `exec env`, `SO_PEERCRED`). The key is never in an argv or a command string.
- **Core dumps**: Closed by 5.3 (hard `RLIMIT_CORE=0`, `suid_dumpable=0`, core_pattern checked).
- **Transcripts/desk mirror**: Closed by L9 (redaction by fingerprint and candidate shapes, before write and fan-out).

## 4. Owner questions

| question | answer | why |
|---|---|---|
| Q-1 Missing key | A | refuse that kind; the picker takes the backup with a key; none -> the task waits with "no key for <kind>" |
| Q-2 Hosted dedicated boxes | A | accept, stated in the plan's terms; root access to such boxes is by named action only and audited |
| Q-3 Margin | A | 50% exactly |
| Q-4 Operator-made admins | A | gets no `vendor_keys.manage` and cannot approve a box for keys until a confirmed admin confirms it |

## 5. Verdict

`SIGN 64b24b396`