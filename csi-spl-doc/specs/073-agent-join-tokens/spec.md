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
| `keys.manage` already exists for this | `internal/rbac/rbac.go:75` `{KeysManage, "tenant-level keys (box pins, the box-wui pin)"}`, held by `biz_owner` and `admin` |

## 2. The owner's ask and the decisions behind this spec

- **072 D3 = yes** ("Build agent join tokens (037 T005)?", answered in msg
  `97f2df08`, recorded in 072 section 8 v0.3), with the contributor persona
  P3+: their own machine, their own AI-vendor tokens, no GCP.
- 072 rule **R2**: "No guest needs GCP access, a cloud key, the tenant root key
  or a CI secret. Agents join with a per-seat token (A5)."
- 072 **A5**: "a tenant admin mints a short-lived, **per-seat** token (valid 1
  hour, single use, shown once, like the GitHub runner token; research 19) in
  Tenant settings -> Agents; `spool join <url> <token>` seats the box; each seat
  is revocable on its own; the root key never leaves the owner."

Prior art copied (072 `research/19-prior-art.md` rows 6 and 7): the GitHub
self-hosted runner token (minted in the UI, expires after one hour) and k3s
(the same install line, plus a URL and a token, also seats the node).

## 3. User scenarios

**US1, a contributor seats their laptop (072 user story 1, step 3).** A tenant
admin opens Tenant settings -> Agents, presses **New join token**, optionally
names the box, and copies the one line shown once. The contributor pastes it on
their own machine. Within a minute the box shows as seated in the Agents list.
The contributor never sees the root key, GCP or a CI secret.

**US2, a used or expired token.** The contributor pastes the line a second
time, or after an hour. The CLI exits non-zero and says why and what to do:
"this join token was already used (or: expired at <time>); ask a tenant admin
for a new one in Tenant settings -> Agents".

**US3, one seat revoked.** The admin presses **Revoke seat** on one box in the
Agents list. That box's live session closes and it cannot reconnect; every
other seated box stays connected.

**US4, the root-key path still works.** A tenant admin with the root key keeps
using `spool hub-pin` / `do_spl_desk_pin` exactly as today (037 modes 1 and 2).

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
- **Lifetime**: 1 hour from minting (`JoinTokenTTL`, a hub option; cnf may
  lower it, never raise it above 24 hours).
- **Use count**: one. Redeeming is one conditional `UPDATE ... SET consumed_at
  = now() WHERE consumed_at IS NULL AND revoked_at IS NULL AND expires_at >
  now() RETURNING`, so two racing redeems seat at most one box. The update and
  the pin write share one transaction: a refused pin leaves the token unused.
- **Per seat**: one token pins one `box_id`. The admin may bind the token to a
  box id at mint time; unbound, the box id comes from the redeemer (the
  installer's default `box-<user>-<host>`, 037).

### 4.2 Store (one migration, the next free prefix at build time)

```sql
CREATE TABLE agent_join_tokens (
    token_hash   text        PRIMARY KEY CHECK (token_hash ~ '^[0-9a-f]{64}$'),
    tenant_id    text        NOT NULL REFERENCES tenants (tenant_id) ON DELETE CASCADE,
    created_by   text        NOT NULL,
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
`pins_history.reason` gains `'join'` and `'wui-revoke'` so the pin history
says which path seated or removed a box. Rows past `expires_at + 7 days` are
pruned by the hub's existing sweeper.

### 4.3 Hub API

| route | auth | does |
|---|---|---|
| `POST /v1/tenant/agents/join-tokens` | member session, `keys.manage` | mint; body `{label?, box_id?}`; answers `{token, expires_at, box_id, join_line}` once; per-human write window as `keys.go` (30/hour) |
| `GET /v1/tenant/agents/join-tokens` | member session, `keys.manage` | the tenant's unexpired tokens: `{id (first 8 hex of the hash), label, box_id, created_by, expires_at, state: open\|used\|revoked}`; never the token |
| `DELETE /v1/tenant/agents/join-tokens/{id}` | member session, `keys.manage` | revoke an unused token |
| `POST /v1/pins/join` | the token itself + proof of the box key | redeem: body `{token, box_id, pubkey, ts, sig}`, `sig` = the box key's signature over `wire.JoinPayload(token_hash, box_id, pubkey, ts)`; pins the key |
| `DELETE /v1/tenant/agents/pins/{box_id}` | member session, `keys.manage` | revoke one seat from the WUI; closes that box's live sessions as `handleRevoke` does |

`POST /v1/pins/join` keeps every rule `handlePin` keeps: `msg.ValidBoxID`, the
`box-wui` box is refused (`reserved_box`), `skewOK(ts)`, `billing.AllowsWrite`,
the pin quota, and `store.PutPin` **without force**: a box id already pinned to
a different key is refused (`pin_conflict`, "box_id is already seated with
another key; revoke it in Tenant settings -> Agents first"), and the same key
again is idempotent (200). The box signs its own request, proving it holds the
private half of the key it asks to pin. A stolen token can still seat the
thief's own key, once, inside the hour; that seat shows in the Agents list
(section 6).

Refusals, each naming the fix (072 ranking rule, measure 3):

| case | status, code | message ends with |
|---|---|---|
| unknown token | 401 `join_token_invalid` | "ask a tenant admin for a join token in Tenant settings -> Agents" |
| used | 410 `join_token_used` | same |
| expired | 410 `join_token_expired` | "(expired at <ts>)" + same |
| revoked | 410 `join_token_revoked` | same |
| bound to another box id | 409 `join_token_box_mismatch` | "this token seats <box_id> only" |
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

- **New join token** (shown to `keys.manage` only): a label and an optional box
  id; the answer shows the token once, with a copy button and the pasteable
  line `SPOOL_JOIN_TOKEN=<token> spool join <hub-url>`, and a countdown to
  expiry. Closing the dialog drops the token from memory.
- The open tokens list (state, expiry, who minted, Revoke).
- Per seated box: **Revoke seat**, with a confirm naming the box.
- `ConnectAgentGuide.vue` replaces its root-key step with the join line; the
  root-key path moves under "Advanced: I hold the tenant root key".

## 5. Requirements

- **FR-001** A member with `keys.manage` mints a join token from the WUI or the
  API; it is shown once and stored only as its sha256. *Planned.*
- **FR-002** A token seats exactly one box, once, within its lifetime (default
  1 hour); a second redeem, a redeem after expiry and a redeem of a revoked
  token are refused with the codes in 4.3, each naming where to get a new one.
  *Planned.*
- **FR-003** Redeeming never overrides an existing pin of another key, never
  pins `box-wui`, and respects billing and the pin quota exactly as `handlePin`.
  *Planned.*
- **FR-004** A member with `keys.manage` revokes one seat from the WUI; that
  box's sessions close; every other seat is unaffected. *Planned.*
- **FR-005** `spool join <hub-url> <token>` seats a box with no root key on the
  machine; the token is accepted from the environment or stdin. *Planned.*
- **FR-006** No plain token in a log, in the database or in an argv the
  project's own scripts build. *Planned.*
- **FR-007** The root-key paths (`POST /v1/pins`, `spool hub-pin`,
  `do_spl_desk_pin` self / admin / revoke) are unchanged. *Implemented* today;
  kept by a regression test in the hub task.

## 6. Security

- The root key never leaves its holder (072 R2; research a3 boundary 1).
- A join token grants exactly one thing: one pin, once, within an hour. It
  cannot mint tokens, revoke pins or read anything (a test proves each).
- Theft window: a leaked token is worth one seat for at most one hour, shows in
  the open-tokens list as `used` with the box id it seated, and that seat is
  revoked in one click (FR-004). The admin may also bind the token to a box id.
- Brute force: 256-bit secret, plus the per-address redeem window.
- A seat does not outlive a revoked membership on its own: see question Q3.

## 7. Acceptance (072 A5's check, made concrete)

| # | check | proves |
|---|---|---|
| AC1 | hub postgres test: mint -> redeem -> `GET /v1/pins` lists the box | FR-001, FR-002 |
| AC2 | hub test with a fake clock: redeem at 61 min -> 410 `join_token_expired`; a second redeem -> 410 `join_token_used`; both messages contain `Tenant settings -> Agents` | FR-002 (research 19, item 6) |
| AC3 | hub test: two concurrent redeems of one token -> one 200, one 410 | FR-002 |
| AC4 | hub test: redeem onto a box id pinned to another key -> 409 `pin_conflict`, token still unused; `box-wui` -> refused | FR-003 |
| AC5 | hub test: revoke one of two seats from a member session -> that box's socket closes `unpinned_box`, the other stays open | FR-004 |
| AC6 | hub test: a token on `POST /v1/pins`, `DELETE /v1/pins/{id}` or the mint route -> refused | 6 |
| AC7 | `grep -c 'spj1\.' <hub log of the AC1 run>` -> 0 | FR-006 |
| AC8 | live, dev then prd e2e tenant (n = 1 each): from the WUI alone, mint, paste on a fresh HOME with `ROOT_KEY_JSON` unset, box seated in **< 1 min** wall clock | 072 A5 |
| AC9 | `grep -rliE 'join.?token' csi-spl-api/src/go --include=*.go \| grep -vc _test` -> >= 1 (today 0) | built |

## 8. Questions for the owner (each built behind its recommendation)

| id | question | recommended default |
|---|---|---|
| Q1 | Who may mint a join token? | **`keys.manage` only** (biz_owner, admin). A contributor with the `developer` role asks the admin, who sends the line. Keeps R2: the owner decides who seats. |
| Q2 | Token lifetime? | **1 hour**, cnf may lower it, hard cap 24 hours (the GitHub runner token). |
| Q3 | When a contributor's membership ends (072 A27), do the seats minted for them go too? | **Yes**: a token may name the member it is for (`for_human`); ending that membership revokes the seats it created. Built as a second step after FR-001..FR-006. |
| Q4 | Retire the root-key line from the WUI guide? | **Move it under "Advanced"**, keep it working (US4). |

072 D3 itself is answered (yes, msg `97f2df08`); this spec does not reopen it.

## 9. Not in scope

- Prebuilt `spool` binaries (072 A4) and the one-line bootstrap (072 A20): the
  join line works with whatever `spool` the box has.
- Per-agent (rather than per-box) credentials: the box key stays the unit of
  trust (`002-box-agent-messaging/contracts/trust-modes.md`).
- A human's own sign-in (spec 023) and member invites (`do_spl_hub_invite`).

## 10. Version log

| version | change | by |
|---|---|---|
| v0.1 | first draft from 072 A5 / 037 T005: token shape, store, API, CLI, WUI, requirements, acceptance, Q1-Q4 | c-179 |

<!-- version: 0.1.0 · updated: 2026-10-04 · last-edit: 2026-10-04T11:35:00Z -->
