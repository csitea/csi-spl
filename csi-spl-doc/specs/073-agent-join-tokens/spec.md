# 073: agent join tokens (seat a box without the tenant root key)

**Feature ID**: `073-agent-join-tokens` · **Milestone**: M3 · **Status**: Planned
**Created**: 2026-10-04 · **Lane**: c-179 (spec 072 T012, row L17)
**Authority**: this file for the behaviour and its rules; `tasks.md` for what is
built, with the sha and the check for each item. Status vocabulary:
`../README.md` §2.3. Docs only: this spec builds nothing (`../README.md` §2.4).

This is the spec that 072 action **A5** asks for ("its own spec first") and
that closes **037 T005** once built. It builds on, and does not repeat:
[037 agent install](../037-spool-agent-install/spec.md) (the installer and its
two seat modes), [072 rapid deployability](../072-rapid-deployability/spec.md)
(A5, the guest rules R1-R3 in 3.2, user story 1 step 3),
[047 deployability](../047-spool-deployability/deployability-analysis.md) (B2)
and `../../doc/md/SPEC-spool-identity-routing.md` (box ids and pins).

`<hub-url>`, `<tenant>` and `<box_id>` are placeholders.

## 1. Why

Seating an agent box means pinning its Ed25519 public key at the hub. Today the
hub pins a box **only** through `POST /v1/pins` signed by the tenant root key
(`csi-spl-api/src/go/spool-hub-api/internal/hub/rest.go` `handlePin`; revoke is
`DELETE /v1/pins/{box_id}`, same signature). So a person who is not the tenant
admin either receives the root key (rule R2 of 072 3.2 forbids it) or waits for
the admin to run the one `spool hub-pin` line the installer prints (037,
"PENDING" seat). Measured on tree `e5b2af64` (n = 1 per command):

| fact | command -> result |
|---|---|
| no join token exists in the hub | `grep -rliE 'join.?token' csi-spl-api/src/go --include=*.go \| grep -vc _test` -> 0 |
| 037 T005 is open | `grep -n 'T005' csi-spl-doc/specs/037-spool-agent-install/tasks.md` -> line 32, `- [ ] T005 OPEN` |
| the WUI guide hands out the root key | `grep -n 'root.key' csi-spl-wui/src/components/ConnectAgentGuide.vue` -> lines 3, 8, 65 (65: the key file default `~/Downloads/<tenant>.root.key`) |
| a human session cannot revoke a box | `grep -c '/v1/pins' csi-spl-api/src/go/spool-hub-api/internal/hub/server.go` -> 3 routes: the list needs a box token, pin and revoke the root signature |
| `keys.manage` cannot be the mint gate | `internal/rbac/rbac.go:75` `{KeysManage, "tenant-level keys (box pins, the box-wui pin)"}`; `Defaults` grants it to `biz_owner` (line 86) and `admin` (line 89). Re-read on `b2ef08e33` (n = 1): the same two grants. The owner said admin only (section 8, Q1) |

## 2. The owner's ask and the decisions behind this spec

- **072 D3 = yes** ("Build agent join tokens (037 T005)?", answered in msg
  `97f2df08`, recorded in 072 section 8 v0.3), with the contributor persona
  P3+: their own machine, their own AI-vendor tokens, no GCP.
- 072 rule **R2**: "No guest needs GCP access, a cloud key, the tenant root key
  or a CI secret. Agents join with a per-seat token (A5)."
- 072 **A5**: "a tenant admin mints a short-lived, **per-seat** token (valid 1
  hour, single use, shown once, like the GitHub runner token; research 19) in
  Tenant settings -> Agents; `spool join <url> <token>` seats the box; each seat
  is revocable on its own; the root key never leaves the owner." The "1 hour"
  in that quote is the default of Q2 (section 8), not a fixed lifetime.

Prior art copied (072 `research/19-prior-art.md` rows 6 and 7): the GitHub
self-hosted runner token (minted in the UI, expires after one hour) and k3s
(the same install line, plus a URL and a token, also seats the node).

## 3. User scenarios

**US1, a contributor seats their laptop (072 user story 1, step 3).** A tenant
admin opens Tenant settings -> Agents, presses **New join token**, optionally
names the box and the member the seat is for, and copies the one line shown
once. The contributor pastes it on their own machine. Within a minute the box
shows as seated in the Agents list. The contributor never sees the root key,
GCP or a CI secret.

**US2, a used or expired token.** The contributor pastes the line a second
time, or after the token's expiry (default 1 hour, section 4.1). The CLI
exits non-zero and says why and what to do: "this join token was already used
(or: expired at <time>); ask a tenant admin for a new one in Tenant settings
-> Agents".

**US3, one seat revoked.** The admin presses **Revoke seat** on one box in the
Agents list. That box's live session closes and it cannot reconnect; every
other seated box stays connected.

**US4, the root-key path still works.** A tenant admin with the root key keeps
using `spool hub-pin` / `do_spl_desk_pin` exactly as today (037 modes 1 and 2).
The WUI shows that path only under Advanced (Q4).

## 4. Design

### 4.1 The token

- **Shape**: `spj1.<tenant>.<secret>`, where `<secret>` is 32 bytes from
  `crypto/rand`, base64url without padding. The tenant is in the token so that
  `spool join <hub-url> <token>` needs nothing else; it is not secret. The
  `spj1.` prefix makes a leaked token greppable by secret scanners (a gitleaks
  rule ships with the hub task).
- **Stored hashed**: the hub keeps `sha256(secret)` hex only, as
  `password_reset_tokens` already does (rdb `0009_native_credentials.sql`,
  `token_hash ... CHECK (token_hash ~ '^[0-9a-f]{64}$')`). The plain token is
  in exactly one response, the mint, and in no log.
- **Lifetime**: from minting, `config.Hub.JoinTokenTTL`. The handler, the
  route and the WUI countdown do not carry a duration literal: the countdown
  reads `expires_at` from the mint response. The value is cnf, read the same
  way as `UploadTokenTTL` (`internal/config/config.go:317`,
  `(*Hub).checkLimits` at line 506).
  - **Cnf key**: `env.hub.env.SPOOL_HUB_JOIN_TOKEN_TTL` in
    `csi-spl-cnf/csi-spl/all.env.yaml` (a `hub.env` key is the env var the hub
    binary reads; 030 renders it onto Cloud Run, `do_gen_docker_env` onto
    lde). Go `time.ParseDuration` string. Default `"1h"`. An env file may
    override it inside the bounds. No second name.
  - **Bounds**, inclusive, enforced by `checkLimits` before the process
    serves: minimum `5m`, maximum `24h`. Below `5m`, above `24h`, or not a
    positive Go duration: the process refuses to start. `5m` is the shortest
    capability the hub already issues to a person
    (`SPOOL_HUB_UPLOAD_TOKEN_TTL`). `24h` is the cap so a leaked token is not
    valid for days. The struct tag `envDefault` is `1h` so a test process
    with the variable unset matches the cnf default; served environments take
    the cnf value.
- **Use count**: one. Redeeming is one conditional `UPDATE ... SET consumed_at
  = now() WHERE consumed_at IS NULL AND revoked_at IS NULL AND expires_at >
  now() RETURNING`, so two racing redeems seat at most one box. The update and
  the pin write share one transaction: a refused pin leaves the token unused.
- **Per seat**: one token pins one `box_id`. The admin may bind the token to a
  box id at mint time; unbound, the box id comes from the redeemer (the
  installer's default `box-<user>-<host>`, 037).
- **For one member**: the admin may set `for_human` (a `HUM-<n>` who is a
  current member). Membership end for that human revokes the token and the
  seat it created (section 4.8). Omitted, membership end does not touch it.

### 4.2 Store (one migration, the next free prefix at build time)

```sql
CREATE TABLE agent_join_tokens (
    token_hash   text        PRIMARY KEY CHECK (token_hash ~ '^[0-9a-f]{64}$'),
    tenant_id    text        NOT NULL REFERENCES tenants (tenant_id) ON DELETE CASCADE,
    created_by   text        NOT NULL,
    for_human    text        NULL CHECK (for_human IS NULL OR for_human ~ '^HUM-[0-9]+$'),
    label        text        NOT NULL DEFAULT '' CHECK (length(label) <= 80),
    box_id       text        NULL CHECK (box_id ~ '^[a-z0-9][a-z0-9-]{0,31}$'),
    created_at   timestamptz NOT NULL DEFAULT now(),
    expires_at   timestamptz NOT NULL,
    consumed_at  timestamptz NULL,
    consumed_box text        NULL,
    revoked_at   timestamptz NULL
);
```

Tenant row-level security as every tenant table (rdb `0014_tenant_rls.sql`).
`pins_history.reason` gains `'join'`, `'wui-revoke'` and `'membership-end'`
so the pin history says which path seated or removed a box. `for_human` is
the member the token is for (Q3, section 4.8); null means membership end
does not touch that token. Rows past `expires_at + 7 days` are pruned by the
join-token sweeper (section 4.8), which on the same pass revokes seats whose
membership has passed `access_until`.

The same migration (or the next free one in that commit) seeds the permission
in section 4.7: one `rbac_permissions` row and one `rbac_role_permissions`
row, matching `rbac.Permissions` and `rbac.Defaults`
(`TestRBACSeedMatchesDefaults`). Shape: rdb `0088_member_clones.sql`.

### 4.3 Hub API

| route | auth | does |
|---|---|---|
| `POST /v1/tenant/agents/join-tokens` | member session, `agents.join` | mint; body `{label?, box_id?, for_human?}`; answers `{token, expires_at, box_id, for_human, join_line}` once; per-human write window as `keys.go` (30/hour) |
| `GET /v1/tenant/agents/join-tokens` | member session, `agents.join` | the tenant's unexpired tokens: `{id (first 8 hex of the hash), label, box_id, for_human, created_by, expires_at, state: open\|used\|revoked}`; never the token |
| `DELETE /v1/tenant/agents/join-tokens/{id}` | member session, `agents.join` | revoke an unused token |
| `POST /v1/pins/join` | the token itself + proof of the box key | redeem: body `{token, box_id, pubkey, ts, sig}`, `sig` = the box key's signature over `wire.JoinPayload(token_hash, box_id, pubkey, ts)`; pins the key |
| `DELETE /v1/tenant/agents/pins/{box_id}` | member session, `agents.join` | revoke one seat from the WUI; closes that box's live sessions as `handleRevoke` does; `pins_history.reason = 'wui-revoke'` |

`agents.join` is admin only (section 4.7). `keys.manage` does not gate any
row of this table.

`for_human`, when set, is a current member of the tenant: the membership row
exists and `access_until` is null or still in the future
(`internal/store/access_until.go`). Anything else is 400 `join_token_member`,
and the message names Tenant settings -> Members.

`POST /v1/pins/join` keeps every rule `handlePin` keeps: `msg.ValidBoxID`, the
`box-wui` box is refused (`reserved_box`), `skewOK(ts)`, `billing.AllowsWrite`,
the pin quota, and `store.PutPin` **without force**: a box id already pinned to
a different key is refused (`pin_conflict`, "box_id is already seated with
another key; revoke it in Tenant settings -> Agents first"), and the same key
again is idempotent (200). The box signs its own request, proving it holds the
private half of the key it asks to pin. A stolen token can still seat the
thief's own key, once, inside its lifetime; that seat shows in the Agents list
(section 6).

Refusals, each naming the fix (072 ranking rule, measure 3):

| case | status, code | message ends with |
|---|---|---|
| unknown token | 401 `join_token_invalid` | "ask a tenant admin for a join token in Tenant settings -> Agents" |
| used | 410 `join_token_used` | same |
| expired | 410 `join_token_expired` | "(expired at <ts>)" + same |
| revoked | 410 `join_token_revoked` | same |
| bound to another box id | 409 `join_token_box_mismatch` | "this token seats <box_id> only" |
| `for_human` is not a current member | 400 `join_token_member` | "pick a current member in Tenant settings -> Members" |
| session lacks `agents.join` | 403 | the permission name |
| redeem flood | 429 `rate_limited` | per source address, `edge.NewWindow`, 20/hour |

### 4.4 CLI

- `spool join <hub-url> <token> [--box <box_id>]`: generates the box key if
  none (as `keygen`), redeems, writes the hub config the box needs, prints
  `seated <box_id> on <tenant>`. The token may come from `SPOOL_JOIN_TOKEN` or
  `-` (stdin) instead of argv, so it need not appear in `ps` or shell history;
  the WUI's copied line uses the environment form.
- `spool` usage names the verb (`TestUsageNamesEveryVerb`).

### 4.5 Box actions and installer

- `do_spl_desk_pin` gains a fourth mode, **join**: with `SPOOL_JOIN_TOKEN` set
  and no `ROOT_KEY_JSON`, it runs `spool join` and the seat is done, not
  PENDING. The token goes through the environment, never an argv of `./run`.
- `install.sh --join <token>` (or `SPOOL_JOIN_TOKEN`) passes it through. The
  installer is held by another lane today; this is a task for whoever holds it
  then, not an edit made by this spec's lane.
- 072 A52 (`do_spl_box_enrol`) uses the join mode once it lands.

### 4.6 WUI (Tenant settings -> Agents)

- **New join token** (shown only when the session holds `agents.join`): a
  label, an optional box id and an optional member (`for_human`); the answer
  shows the token once, with a copy button and the pasteable line
  `SPOOL_JOIN_TOKEN=<token> spool join <hub-url>`, and a countdown to
  `expires_at`. Closing the dialog drops the token from memory.
- The open tokens list (state, expiry, who minted, who it is for, Revoke),
  same permission.
- Per seated box: **Revoke seat**, with a confirm naming the box, same
  permission.
- The connect guide's default steps are the join line. The root-key path is
  not on that path: it sits in a closed Advanced disclosure only (Q4,
  section 4.9).

### 4.7 Who may mint, list and revoke (`agents.join`)

Decided (section 8, Q1): **admin only**. Enforced by a new permission, not by
a role-name check.

The hub asks for a permission at each entry point and never for a role name
(`internal/rbac/rbac.go` lines 1-4; `Authorizer.Can`). A check of
`role == "admin"` would bypass that, and the role table is data
(`TestRBACSeedMatchesDefaults`), so the door is a permission.

`keys.manage` is the wrong permission. `rbac.Defaults` grants it to
`biz_owner` and to `admin` (lines 85-89, re-read on `b2ef08e33`). Gating on
it would let `biz_owner` mint, which the owner refused.

`agents.join` ("mint, list and revoke agent join tokens, and revoke one seat
from the WUI") is granted to **`admin` only**. `biz_owner` does not receive
it. That is an exception to the line at `rbac.go:81` ("biz_owner holds every
permission"), which rdb `0074` restored for `members.invite`. This exception
stays. No other role receives it: `product_owner`, `developer`, `tester`,
`pure_agent`, `biz_customer`, `regular_user`.

The permission covers every member-session route in section 4.3:

| endpoint | covered |
|---|---|
| mint `POST /v1/tenant/agents/join-tokens` | yes |
| list `GET /v1/tenant/agents/join-tokens` | yes |
| revoke an unused token `DELETE /v1/tenant/agents/join-tokens/{id}` | yes |
| revoke a seat `DELETE /v1/tenant/agents/pins/{box_id}` | yes |
| redeem `POST /v1/pins/join` | no (the token itself) |
| root-key pin and revoke `POST /v1/pins`, `DELETE /v1/pins/{box_id}` | no (FR-007, US4) |

Revoke-a-pin from the WUI is included so a `biz_owner`, who cannot mint, also
cannot drop a seat from the session. The root-key holder still revokes with
`DELETE /v1/pins/{box_id}`.

The seed is the migration in section 4.2 plus the same two slices in
`rbac.Permissions` and `rbac.Defaults`, one commit. Spec 025's matrix is
another lane's file; this spec is the record of the grant.

### 4.8 When a membership ends

Decided (section 8, Q3): **yes**. Ending the membership of `for_human`
revokes that human's still-open tokens and the seats those tokens created.
A token with `for_human` null is left alone; the admin revokes that seat by
hand (FR-004).

Membership end is two triggers, and no others. Disable (`disabled_at`, rdb
`0074`) is not membership end: the seat stays until removal, until
`access_until`, or until an explicit revoke.

1. **Removal.** `DELETE /v1/members/{human_id}`
   (`internal/hub/rbac.go` `handleMemberRemove`) calls
   `(*Postgres).RemoveMember` (`internal/store/humans_rbac_postgres.go:144`),
   which deletes the `tenant_memberships` row inside `inTenant`. That same
   transaction revokes every `agent_join_tokens` row of the tenant with this
   `for_human`, `revoked_at` null and `consumed_at` null (set `revoked_at`),
   and revokes every pin whose consumed token has this `for_human`
   (`pins_history.reason = 'membership-end'`). A failure aborts the removal.
   Live sessions of those boxes close after the commit, the same way
   `handleRevoke` closes them once the pin is gone (`unpinned_box`).
2. **`access_until` expiry.** `tenant_memberships.access_until` (rdb
   `0113_membership_access_until.sql`). At or past that instant
   `internal/store/access_until.go` already reads the membership as absent.
   The seat revoke does not wait for the next sign-in. The same revoke as
   removal runs at two moments:
   - the request that writes `access_until` to a time at or before now
     (`PATCH /v1/members/{human_id}`, `internal/hub/tenant_settings.go`). A
     future `access_until` does not revoke yet.
   - the join-token sweeper, on the pass that prunes rows past
     `expires_at + 7 days`. It selects memberships with
     `access_until <= now()` that still have an open token or a live pin
     from a `for_human` token, and revokes those. That is the path that
     fires when the clock passes a future `access_until` with nobody
     writing. Same shape as `SweepClones` (`internal/hub/actas.go`): a
     sweeper the hub process already runs, not a new cron.

Clearing `access_until`, extending it, or inviting the human again does not
restore a revoked token or a revoked seat. A new token is required.

### 4.9 Connect guide (Advanced only)

Decided (section 8, Q4): **yes**. The root-key line is Advanced only.

Today the default paste is the root key. Re-read on `b2ef08e33` (n = 1):
`grep -n 'root.key' csi-spl-wui/src/components/ConnectAgentGuide.vue` -> lines
3, 8 and 65, and line 65 sets the key file to `~/Downloads/<tenant>.root.key`.
The paste text is `csi-spl-wui/src/utils/connect-agent.mjs`. The walk-through
the component links (`/help/connect-an-agent`) is
`csi-spl-doc/doc/help/connect-an-agent.md`, copied to
`csi-spl-wui/src/public/help-md/` (`tests/unit/help-sync.test.mjs`).

After this change:

- The open steps are the join line:
  `SPOOL_JOIN_TOKEN=<token> spool join <hub-url>`. The guide does not embed
  a live token; the admin copies it from the mint dialog (section 4.6). The
  key-file field is not required for the block to be valid.
- The root-key file field and the `spool hub-pin --root-key` line sit in one
  closed disclosure whose summary is "Advanced: I hold the tenant root key".
  They are absent from the open steps. The path still works (US4).
- The help walk-through uses the same split: the join line on the default
  path, the root-key lines under an Advanced heading. It keeps the rules
  `csi-spl-iac/src/bash/tests/help-connect-agent.tst.sh` already enforces
  (no hosted domain, `{{api}}` / `{{site}}`, both the installer and
  `spool mcp --as`, no legacy agent id). The README's "On another machine"
  paragraph is not this guide and is not edited.

## 5. Requirements

- **FR-001** A member with `agents.join` (the `admin` role only, section 4.7)
  mints a join token from the WUI or the API; it is shown once and stored
  only as its sha256. A session without that permission, including
  `biz_owner`, is refused. *Planned.*
- **FR-002** A token seats exactly one box, once, within its configured
  lifetime (default 1 hour, bounds `5m`..`24h`, section 4.1). A second redeem,
  a redeem after expiry and a redeem of a revoked token are refused with the
  codes in 4.3, each naming where to get a new one. *Planned.*
- **FR-003** Redeeming never overrides an existing pin of another key, never
  pins `box-wui`, and respects billing and the pin quota exactly as `handlePin`.
  *Planned.*
- **FR-004** A member with `agents.join` revokes one seat from the WUI; that
  box's sessions close; every other seat is unaffected. The root-key revoke
  is unchanged (FR-007). *Planned.*
- **FR-005** `spool join <hub-url> <token>` seats a box with no root key on the
  machine; the token is accepted from the environment or stdin. *Planned.*
- **FR-006** No plain token in a log, in the database or in an argv the
  project's own scripts build. *Planned.*
- **FR-007** The root-key paths (`POST /v1/pins`, `spool hub-pin`,
  `do_spl_desk_pin` self / admin / revoke) are unchanged. *Implemented* today;
  kept by a regression test in the hub task.
- **FR-008** Ending the `for_human` membership (removal, or `access_until` at
  or before now, section 4.8) revokes that human's open tokens and the seats
  they created. A null `for_human` is not revoked by membership end. *Planned.*
- **FR-009** The connect guide's open steps are the join line. The root-key
  line is only inside Advanced (section 4.9). *Planned.*

## 6. Security

- The root key never leaves its holder (072 R2; research a3 boundary 1).
- A join token grants exactly one thing: one pin, once, within its lifetime.
  It cannot mint tokens, revoke pins or read anything (a test proves each).
- Theft window: a leaked token is worth one seat for at most its configured
  lifetime (default 1 hour, never above 24 hours), shows in the open-tokens
  list as `used` with the box id it seated, and that seat is revoked in one
  click (FR-004). The admin may also bind the token to a box id.
- Brute force: 256-bit secret, plus the per-address redeem window.
- Who mints is admin only (section 4.7). `biz_owner` holds `keys.manage` and
  still cannot mint, list or revoke join tokens, and cannot revoke a seat
  from the WUI.
- A seat tied to `for_human` does not outlive that membership (section 4.8).

## 7. Acceptance (072 A5's check, made concrete)

| # | check | proves |
|---|---|---|
| AC1 | hub postgres test: mint -> redeem -> `GET /v1/pins` lists the box | FR-001, FR-002 |
| AC2 | hub test with a fake clock and the default TTL: redeem at 61 min -> 410 `join_token_expired`; a second redeem -> 410 `join_token_used`; both messages contain `Tenant settings -> Agents`. A second case sets `JoinTokenTTL` to `5m` and expires at 5 min | FR-002 (research 19, item 6) |
| AC3 | hub test: two concurrent redeems of one token -> one 200, one 410 | FR-002 |
| AC4 | hub test: redeem onto a box id pinned to another key -> 409 `pin_conflict`, token still unused; `box-wui` -> refused | FR-003 |
| AC5 | hub test: revoke one of two seats from an admin session -> that box's socket closes `unpinned_box`, the other stays open | FR-004 |
| AC6 | hub test: a token on `POST /v1/pins`, `DELETE /v1/pins/{id}` or the mint route -> refused | 6 |
| AC7 | `grep -c 'spj1\.' <hub log of the AC1 run>` -> 0 | FR-006 |
| AC8 | live, dev then prd e2e tenant (n = 1 each): from the WUI alone, mint, paste on a fresh HOME with `ROOT_KEY_JSON` unset, box seated in **< 1 min** wall clock | 072 A5 |
| AC9 | `grep -rliE 'join.?token' csi-spl-api/src/go --include=*.go \| grep -vc _test` -> >= 1 (today 0) | built |
| AC10 | hub test: a `biz_owner` session (holds `keys.manage`, lacks `agents.join`) gets 403 on mint, list, revoke-token and `DELETE /v1/tenant/agents/pins/{box_id}`; an `admin` session is allowed; root-key `DELETE /v1/pins/{box_id}` still succeeds | FR-001, FR-004, 4.7 |
| AC11 | hub postgres test: `RemoveMember` of `for_human` revokes the open token and the seated pin (`reason = membership-end`) and closes that box; a `PATCH` that sets `access_until` in the past does the same; the sweeper does it when `access_until` passes with no further write; a token with `for_human` null is untouched; another member's seat stays. Extending `access_until` afterwards does not restore the seat | FR-008 |
| AC12 | `checkLimits`: `5m` and `24h` pass; `4m59s` and `24h1s` and a non-duration refuse startup. Unset variable loads `1h` | FR-002, 4.1 |
| AC13 | WUI: the open connect-guide steps contain `spool join` and do not contain `root.key`; the Advanced disclosure contains the root-key line and is closed. Help walk-through matches, and `help-sync` plus `help-connect-agent.tst.sh` stay green | FR-009 |

## 8. Owner decisions

Decided by the owner on t1 topic `e3310f01`, msg `b30cc1ef` (2026-10-04).
Q1-Q4 are closed. The recommended default is what the spec said before that
message; the decision is what is built.

| id | question | was recommended | decision |
|---|---|---|---|
| Q1 | Who may mint a join token? | `keys.manage` only (`biz_owner` and `admin`) | **admin only**, enforced by `agents.join` held by `admin` alone (section 4.7). Covers mint, list, revoke-token and WUI revoke-seat. Does not cover redeem or the root-key pin routes |
| Q2 | Token lifetime? | 1 hour; cnf may lower it; hard cap 24 hours | **configurable, default 1 hour**. Cnf key `env.hub.env.SPOOL_HUB_JOIN_TOKEN_TTL`, bounds `5m`..`24h` inclusive, read by `config.Hub.JoinTokenTTL` (section 4.1). No duration literal in the handler |
| Q3 | When a contributor's membership ends, do the seats minted for them go too? | yes, via `for_human`, as a second step | **yes**. Triggers: removal (`RemoveMember`) and `access_until` at or before now (section 4.8). Task T008 |
| Q4 | Retire the root-key line from the WUI guide? | move it under "Advanced", keep it working | **yes, Advanced only** (section 4.9). Task T009 |

072 D3 itself is answered (yes, msg `97f2df08`); this spec does not reopen it.

## 9. Not in scope

- Prebuilt `spool` binaries (072 A4) and the one-line bootstrap (072 A20): the
  join line works with whatever `spool` the box has.
- Per-agent (rather than per-box) credentials: the box key stays the unit of
  trust (`002-box-agent-messaging/contracts/trust-modes.md`).
- A human's own sign-in (spec 023) and member invites (`do_spl_hub_invite`).
- Editing spec 025's permission matrix (another lane's file). The grant is
  recorded here and seeded by T002.
- Disable (`disabled_at`) as a seat-revoke trigger. Section 4.8 names the two
  triggers that are membership end.

## 10. Version log

| version | change | by |
|---|---|---|
| v0.1 | first draft from 072 A5 / 037 T005: token shape, store, API, CLI, WUI, requirements, acceptance, Q1-Q4 | c-179 |
| v0.2 | Q1-Q4 decided (msg `b30cc1ef`): `agents.join` admin only; cnf TTL `5m`..`24h` default `1h`; membership-end revoke; connect guide Advanced only | g-242 |

<!-- version: 0.2.0 · updated: 2026-10-04 · last-edit: 2026-10-04T18:16:38Z -->
