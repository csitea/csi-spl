# Box owner lock: a box whose agents only its owner may reach (025 section 11)

**Feature**: `specs/025-spool-tenant-rbac`, box owner lock · **Created**: 2026-10-22 · **Lane**: c-630 ·
**Issue**: SPL-2917 (epic SPL-2400) · **Status**: v1.0, signed by the mistral reviewer m-797@sat at `201f2e3a8` (section 11); rows B1-B8 built, B6 including its help page `csi-spl-doc/doc/help/box-owner-lock.md` (SPL-3073); see each row's As built note.
**Builds on**: 025 (roles, permissions), 054 (act-as clone), 108 (workspace-owned boxes, pins, revoke),
017 FR-SEC-031 (desk owners), 023 (human keys), the signed directive feature
(`csi-spl-orc/src/bash/features/directive/`).
**Code facts read on**: `8a3d12797` (origin/master, 2026-10-22T18:44:50Z), re-read on `10e12f038` for v0.2. Paths under `internal/` are in
`csi-spl-api/src/go/spool-hub-api/internal/`; rdb paths are in `csi-spl-rdb/src/sql/postgres/spool-hub/`.

Public repository: no box or person is named here. `<OWNER_BOX>` is the box the owner locks, `<SHARED_BOX>`
every other box, `<OWNER_HUM>` the owner's `HUM-*`. The concrete mapping goes into cnf at build time
(row B6), never into this file.

## 1. Owner orders (verbatim, workspace owner topic e41cba27, 2026-10-22)

Box names in the quotes are replaced by the placeholders above.

> "we should create the rule than only me the logged in user now can access agents running on the
> `<OWNER_BOX>` box , an no other admins can overrule that" (msg ac26ff07)

> "basically all ofthe others should be able to access only `<SHARED_BOX>` box resources" (msg 3eb6222a)

> "this could be enforced somehow by me having to restart the whole spool service on the `<OWNER_BOX>` box by
> providing my own token, and nobody else. This should be somehow encrypted, and then nobody else, even if he
> is able to somehow get to my machine, would be able to overrule that (because he would have to know the
> token which I use to start the service on my `<OWNER_BOX>` laptop)." (msg 955cfb8c)

> "yeah , we will have to assume that nobody has hacked me yet" (msg 49914aea)

> "and this is a known limitation" (msg 005bacba, on the root-on-a-running-box limit, section 8.1)

## 2. The rule

1. A box can be **locked** to a list of named human owners (`HUM-*`), in one workspace.
2. Only an owner of a locked box can reach its agents or its resources: post or DM to them, mention them,
   command them, read what they write, see them in the roster, read their files, change their settings.
   Every other human is refused, whatever their role: member, admin, biz_owner, devops, operator, a platform
   operator (`OperatorEmails`), an act-as clone, or the holder of the workspace root key.
3. **No admin can lift or bypass a lock.** A lock is created, changed or lifted only by a request signed with
   the owner's **lock key** (section 4), which only the owner can unseal. No role, permission, operator route or
   root-key signature does it.
4. **Every refusal is audited** (section 6.3).
5. The lock is enforced by the hub, on the server, at the points where a message is queued to a box and where
   a view is filtered (section 5). It is not a desk label: today's `DESK_OWNERS` (017 FR-SEC-031) only frames a
   line as "not an order" and refuses nothing.
6. Other boxes (`<SHARED_BOX>`) are open as today: the lock changes nothing for an unlocked box.

## 3. Trust assumption

The owner's machine and account are not compromised at the moment the owner types the lock secret (owner,
msg 49914aea). Everything below holds only under it. Section 8 lists what the design does not protect against.

## 4. The owner's secret, the lock key and the box key

### 4.1 Keys

| key | what | where the private half lives |
|---|---|---|
| **lock key** `K_lock` | Ed25519, new, one per locked box | only encrypted, `<state>/lock/lock.key.enc` on `<OWNER_BOX>`, plus one recovery copy (4.5) |
| **box key** `K_box` | the box's existing pin key (`box-<id>.key`, read by `boxKey`, `internal/action/join.go:165`) | today a 0600 file in the clear; after the lock, only encrypted: `box-<id>.key.enc` |
| **unlock ticket** | hub-signed, short-lived (4.4) | in the sidecar's memory only |

The hub keeps only public halves: `K_lock`'s in `box_locks.lock_pubkey`, `K_box`'s in `pins` as today.
`K_lock` is not the owner's 023 identity key (`human_keys`, rdb `0018_human_keys.sql`): that key is generated in
a browser and may sit unencrypted; the lock key never leaves the owner box in the clear.

### 4.2 Sealing (key derivation, what is encrypted at rest)

`spool lock seal` (row B4), run by the owner on `<OWNER_BOX>`, refuses without a terminal (like
`directive-sign.sh --keygen`) and refuses an empty secret:

1. The owner types the lock secret twice (no echo). Minimum 16 characters; a passphrase of several words is
   the recommendation.
2. `KEK = argon2id(secret, salt, t=3, m=256 MiB, p=4, 32 bytes)`, salt 16 random bytes.
   `golang.org/x/crypto` is already a dependency (`go.mod` line 22; argon2 is used in `internal/auth/password.go`).
3. Two sub-keys by HKDF-SHA256 over `KEK`: `info="spool-lock-key"` and `info="spool-box-key"`.
4. `K_lock`'s seed and `K_box`'s seed are each sealed with XChaCha20-Poly1305 under their sub-key, a random
   24-byte nonce, and the associated data `tenant|box|key-kind|format-version`, so a file moved to another box
   or swapped between kinds fails to open.
5. The file header (version, KDF parameters, salt, nonce) is in the clear; nothing else is.
6. The clear `box-<id>.key` is overwritten and removed. The secret and `KEK` are never written anywhere.

### 4.3 Start and reboot: locked until the owner types it

- The sidecar of a locked box starts **sealed**: it holds no usable key and does not connect to the hub.
  It reads the secret only from `spool lock unlock` (row B4), which requires a terminal and passes the secret
  over a 0600 unix socket owned by the box OS user.
- After a reboot, or any sidecar restart, the box stays offline (its agents may run, but no message reaches or
  leaves them through the hub) until the owner types the secret again. Nobody else can bring it online: the
  box key exists on disk only sealed.
- A wrong secret fails the AEAD open; the sidecar logs the failure (never the secret) and stays sealed. After
  5 failures it waits 60 s per try.

### 4.4 How the hub verifies the unlock

The box hello already carries a hub-issued nonce (`helloRefusal`, `internal/hub/ws.go:286`, the check
`f.Nonce != nonce`). For a locked box, the hello adds an **unlock proof**:

1. The sidecar signs `"spool-unlock-v1" | tenant | box | hub_nonce | boot_id | K_box public key | ts` with
   `K_lock`.
2. The hub verifies it against `box_locks.lock_pubkey` for that `(tenant, box)`, checks `ts` within 120 s and
   that the nonce is the one it issued for this socket. On success it answers with an **unlock ticket**:
   `{tenant, box, box_pubkey, boot_id, expires_at}` signed by the hub's key, TTL from cnf (OQ-3, default 7 days).
3. The sidecar then **drops `K_lock` from memory** and keeps `K_box` (it signs every envelope) and the ticket.
   A reconnect within the TTL presents the ticket instead of a new proof; after the TTL the box goes offline
   until the owner types the secret again.
4. A locked box whose hello carries neither a valid proof nor a valid ticket is refused `locked_box_sealed`
   and audited. So a stolen sealed key file, or a key pinned by someone else (5.1 path 8), never brings the box
   online.

Go does not guarantee that a dropped key is wiped from memory (the collector may keep copies). The design
narrows the window; it does not claim the lock key is unrecoverable from a running process (8.1).

### 4.5 Recovery if the owner loses the secret

- `spool lock seal` prints a **recovery code** once: 256 random bits as 24 groups of 4 base32 characters.
  It seals a second copy of `K_lock` (`lock.key.recovery.enc`, same scheme, argon2id over the code). The owner
  writes it down off the machine; it is never stored on a box or in the hub.
- With the recovery code, `spool lock reseal` sets a new secret (both files are re-sealed; the recovery code
  stays valid until the owner rotates it with `spool lock rotate-recovery`).
- Secret **and** recovery code lost: the lock cannot be lifted through the product by anyone. The only way out
  is the break-glass of section 8.3, which is the same power the known limitations name, made visible.
- A lost `<OWNER_BOX>` (stolen, disk dead) with the recovery code: seal a new box with `spool lock rebind`,
  which signs a change of `box_pubkey` with `K_lock` (6.2).

### 4.6 As built: the box side (row B4, SPL-2956)

Code: `internal/lockkey/` (seal, open, recovery code, unlock proof payload, lock body, the sealed holder),
`cmd/spool/lock.go` (`spool lock seal | unlock | serve | status | reseal | rotate-recovery | rebind | sign |
create`), and `boxKey` in `internal/action/join.go`. Tests: `go test ./internal/lockkey/ ./cmd/spool/ -run 'Lock'`
and `TestJoinSealedBox` in `internal/action/`.

- Files (4.1): `box-<id>.key.enc`, `lock/lock.key.enc`, `lock/lock.key.recovery.enc` and the public
  `lock/lock.json` under the box's keys dir, each 0600 JSON with a clear header (`v`, `kdf`, `t`, `m_kib`,
  `p`, `salt`, `nonce`, `kind`) and the sealed `ct`. The associated data is `tenant|box|kind|1`.
- The sealed holder is `spool lock serve`, started by `spool lock unlock` when none runs. It takes the secret
  over `lock/lockd.sock` (0600, peer uid must be its own), holds `K_box`, signs the unlock proof with `K_lock`
  until `drop-lock`, and waits 60 s per try after 5 wrong secrets. A restart leaves it sealed.
- `boxKey` (join) takes the key from the unlocked holder for a sealed box, and refuses a sealed box that is
  not unlocked; it never makes a clear key next to a sealed one.
- `spool keygen` refuses a sealed box, `--force` included: it exits 1, names `spool lock reseal / rebind`
  and writes no clear `box-<id>.key` (bug round 4 row 01, SPL-2974; test `TestKeygenSealedBox` in `cmd/spool/`).
- `spool lock sign` signs a file (stdin is the terminal the secret is typed on) and refuses a
  `spool-unlock-v1` payload. `create` and `rebind` print `signed_body` in B1's canonical form with
  `signature` (K_lock), and `create` adds `box_signature` (K_box), for the B2 routes.

Where it differs from 4.2 to 4.5, and what is left for later rows:

- The recovery code is 256 bits as 13 groups of 4 base32 characters (the last group may be shorter). "24
  groups of 4" would be 480 bits.
- Only `K_lock` has a recovery copy, so `reseal --recovery` cannot open the old `K_box`: it makes a new one,
  prints its public key, and the hub accepts that only after `spool lock rebind`.
- `rebind` on a new box needs the `lock/` files copied from a backup of the old box: the recovery copy of
  `K_lock` is a file on the box, not something derived from the code.
- Not wired yet (row B2, which owns `ws.go` and the hello): the proof in the hello frame, the ticket and the
  `drop-lock` call after it. The hub client still reads the clear `box-<id>.key`, so a sealed box stays
  offline even after `unlock` until B2 makes the client take its key from the holder.

## 5. Every access path and how it is refused

### 5.1 The paths (measured on `8a3d12797`)

The hub decides by workspace role, channel membership and a per-agent sender list; **no path checks the box
today**. `allowed` (`internal/hub/rbac.go:63`) takes no box. The only per-box human binding, `box_operators`
(rdb `0040_messages_typed_by_box_operators.sql`), is read only in `typedByRefusal` (`internal/hub/ws.go:794`)
and has no hub route that grants it.

| # | path | entry (file:line) | decides today | refusal under a lock |
|---|---|---|---|---|
| 1 | Channel post fanned out to member agents | WUI `send`, `wuiSend` `internal/hub/wui.go:560`; fan-out only with `agents.command` (`wui.go:758`); `routeChannel` `internal/hub/channels.go:261`, per-box loop at `:277` | channel membership + `agents.command` | the locked box is skipped in the loop unless the post's human (`typed_by` / sender) is an owner; the post still lands for everyone else; one audit row `channel_fanout` |
| 1b | Fallback responder picks an online agent on any box | `fallbackPick` `internal/hub/fallback.go:83`, called at `:256` and on the retry at `:382`, queued at `:335` | none | a locked box is never a fallback candidate for a non-owner's post |
| 1c | Add an agent to a channel (back-fills history to its box) | `handleAddChannelAgent` `internal/hub/channel_members.go:347`; `backfillBox` `internal/hub/backfill.go:65`, called at `channel_members.go:408`, at box connect `ws.go:238` and by the back-fill sweep `backfill.go:160` | `channels.edit` + `mayInviteChannel` | 403 `box_locked` when the agent is on a locked box and the caller is not an owner |
| 2 | DM or `@agent` command | `wuiRecipient` `wui.go:848`, `agents.command` at `wui.go:827`; `dispatchCheck` `internal/hub/dispatch.go:125` (box resolved from `:136`); queued at `internal/hub/ws.go:974` | `agents.command`, roster, pin, `senderAllowed` `internal/hub/sender_allow.go:229` (per agent, not per box) | `dispatchCheck` answers 403 `box_locked` for a non-owner; checked before `senderAllowed`, so no allow-list edit widens it |
| 2b | Reply in an agent's topic | `internal/hub/topic_reply.go:28`, `dispatchCheck` at `:39` | `agents.command` | goes through `dispatchCheck`: same refusal |
| 2c | Reply to a retired agent, re-routed to its box | `internal/hub/retired_reply.go:75` (`dispatchCheck`) | `agents.command` | goes through `dispatchCheck`: same refusal |
| 3 | Bare `@mention` | `internal/hub/dispatch.go:79-81`; `sendTargets` `sender_allow.go:208` | channel membership | a mention of a locked-box agent by a non-owner is not delivered (path 1 skip) and the WUI shows `box_locked` |
| 4 | Read agent topics, DMs, search, flow | `canReadTopic` / `topicVerdict` `internal/hub/privacy.go:129` / `:143`; `handleViewTopics` `view.go:602`, `handleViewTopic` `:1124`; `handleSearch` `search.go:111`; `handleViewFlow` `flow.go:113` | DM ends or channel membership | messages whose `from_box` or `to_box` is a locked box are hidden from non-owners (OQ-1); the same predicate in all four reads |
| 4b | Live tail and subscribe | `wuiSubscribeTask` `internal/hub/wui.go:388`, `wuiSubscribeChannel` `:422`, `wuiSubscribeFollow` `:462`; per-message `wants` `wui.go:505` | `canReadTopic`, `canReadChannel` | same predicate in `wants` |
| 5 | Roster and presence | `handleViewRoster` `internal/hub/view.go:266`; welcome presence `wui.go:343`; `broadcastRoster` `ws.go:573` | `topics.read` only: every member sees every box | rows of a locked box are dropped for non-owners |
| 5b | Box stats, agent lifecycle settings | `handleBoxStats` `internal/hub/box_stats.go:104`; `agent_lifecycle.go:104`, `:119` | `audit.read`; `tenant.settings` | locked box dropped from reads; writes 403 `box_locked` |
| 6 | Files carried by messages | `GET /v1/files/{id}`, `mayReadFile` `internal/hub/rest.go:282`; delete `handleDeleteFile` `wui.go:1303`, `mayDeleteFile` `:1339` | readable when a carrying message is readable | follows path 4: a file carried only by hidden messages is 404 for non-owners |
| 7 | Doctree, workspace docs | `docTreeWho` `internal/hub/wsdoc_tree.go:213`; `workspace_docs.go:124` | `docs.read` / `docs.write` | **not covered**: docs are workspace objects, not box objects (OQ-4) |
| 8 | Pin or revoke a box key with the workspace root key | `handlePin` `internal/hub/rest.go:434`, `handleRevoke` `rest.go:506` | root-key signature | 403 `box_locked` for a locked box id; a key change goes through `spool lock rebind` (6.2) only |
| 8b | List pins | `handleListPins` `internal/hub/rest.go:389` (any upload token; the browser gets one, `wui.go:333`) | any upload token | locked pins dropped unless the token's human is an owner |
| 8c | Join tokens, seat revoke | `internal/hub/join_tokens.go:182`, `:239`, `:270`; `handleSeatRevoke` `:305` | `agents.join` (admin) | revoke of a locked seat 403 `box_locked`; a join with a locked box id 403 |
| 8d | Sender allow-lists, channel AI-agents switch, agent split | `senderAllowActor` `internal/hub/sender_allow.go:68`; `handlePutChannelAIAgents` `internal/hub/channel_ai_agents.go:63`; `agent_split.go:79` | `tenant.settings` | writes naming a locked-box agent 403 `box_locked`; they can only narrow, but the lock owner decides |
| 9 | Act-as clone (054) | `StartActAs` `internal/hub/actas.go:177`; clone check `readerIsActAsClone` `actas.go:29`, used only on DM lists | `members.impersonate` + ceiling; the WS send path has no clone check | a clone is a new `HUM-*`, never an owner, so every check above refuses it by construction; the lock check needs no clone rule |
| 10 | Platform operator replay of unsigned posts | `internal/hub/replay_unsigned.go:54`, delivers via `routeChannel` at `:156` | `OperatorEmails` | path 1's check runs inside `routeChannel`, so the replay is refused per box too |
| 10b | Operator-workspace routes (workspaces, agent caps, fleet load, fleet tokens) | `operatorActor` `internal/hub/operator_workspaces.go:83`; `fleetLoadCaller` `fleet_load.go:120` | operator-workspace session role | writes naming a locked box 403 `box_locked`; reads drop it |
| 11 | Issue assigned to an agent | `checkAssignee` `internal/hub/issues.go:284` | agent in roster | a non-owner may not assign to a locked-box agent: 403 `box_locked` |
| 12 | Another box's agent sends to a locked-box agent (box to box) | `onSend` `internal/hub/ws.go:603`, `sendRouteRefusal` `ws.go:686`; queued `ws.go:974` | box pin + tenant | refused unless the sending box is in the lock's `peer_boxes` (OQ-2): otherwise any admin could command a `<SHARED_BOX>` agent to relay into `<OWNER_BOX>` |
| 12b | Another box's agent posts in a channel a locked agent is in | `routeChannel` called from the box send at `ws.go:985`; `agentPost` at `channels.go:274` | channel membership | same `peer_boxes` rule, in the same loop as path 1 |
| 13 | Terminal, tmux, send-keys, restart | none in the hub (no send-keys or tmux code under `internal/hub/`); the pane is touched only by box-side notify on delivery | box side only | nothing to refuse in the hub; on the box it is OS access (8.1) |

### 5.2 One check, called from every queue and view point

- `boxLock(ctx, tenant, box) *lock` reads `box_locks` through a 5 s cache like the pin cache (108 3.7), cleared
  on a lock change.
- `boxLockRefusal(ctx, tenant, box, hum, path) *frameRefusal` answers `nil` for an unlocked box or an owner;
  otherwise it writes the audit row (6.3) and answers 403 `box_locked`. The message does not name the owner.
- Queue points: `dispatchCheck`, the `routeChannel` loop, `fallbackPick`, `backfillBox`, `onSend`.
  The direct queue at `ws.go:974` is reached only after one of them.
- Every queue write in `internal/hub/` on `10e12f038`, and why it is covered
  (`git grep -nE 'Store\.Enqueue\(' -- csi-spl-api/src/go/spool-hub-api/internal/hub ':!*_test.go'` -> 8 lines):
  `channels.go:291` (the `routeChannel` loop), `fallback.go:335` (a box `fallbackPick` chose), `ws.go:974`
  (direct, after `onSend` / `dispatchCheck`); the other 5 queue to `box-wui`, the browser's own box, never to
  an agent's box: `blocker_issue.go:394`, `dm_ref.go:140`, `fleet_tokens.go:392`, `issue_backlog.go:80`,
  `public_notice.go:81`. Callers of the checked helpers: `dispatchCheck` `wui.go:730`, `topic_reply.go:39`,
  `retired_reply.go:75`; `routeChannel` `ws.go:985`, `replay_unsigned.go:156`; `backfillBox` `ws.go:238`,
  `channel_members.go:408`, `backfill.go:160`; `fallbackPick` `fallback.go:256`, `:382`. A new queue write
  outside these helpers is a new path: B3's test lists the 8 lines and fails on a ninth (red control: add one).
- View points: one predicate `hiddenByLock(tenant, hum, from_box, to_box)`, used by `canReadTopic`, `wants`,
  search, flow, roster, presence, pins list, box stats, files.
- Fail closed: a `box_locks` read error refuses, never allows.

**As built (row B3, SPL-2970)**: `internal/hub/box_lock.go` (`boxLockRefusal`, `channelLockSkip`,
`fallbackLockSkip`, `boxSendLockRefusal`) and one call each in `dispatch.go`, `channels.go`, `fallback.go`,
`backfill.go` and `channel_members.go`. Tests: `TestBoxLockQueuePaths`, `TestBoxLockReplayUnsigned`
(`internal/hub/box_lock_test.go`), `TestBoxSendLockRefusal`, `TestBoxLockQueueWriteInventory`
(`box_lock_internal_test.go`).

- `dispatchCheck` refuses a non-owner with 403 `box_locked` once the box is resolved, before the pin and the
  allow-lists (paths 2, 2c). A reply in an agent's topic (2b) is not refused as a frame: `topicReplyAgent`
  keeps any reply whose `dispatchCheck` fails as a browser-only post. So the admin's reply is acked with
  no `to_box`, nothing is queued to the locked box, and one `dispatch` audit row is written.
- The `routeChannel` loop skips the locked box for a browser post whose `from` is not an owner (paths 1, 3,
  10) and for a box post whose `from_box` is neither the locked box nor a peer (12b). Audit paths
  `channel_fanout` and `box_channel`; the post still reaches every other box.
- `fallbackPick` takes the poster: a locked box is no candidate unless the poster is an owner (1b). No
  audit row, because nothing the poster asked for is refused. The members answer's preview passes no
  poster, so it never shows a locked box.
- `POST /v1/channels/{c}/agents` for an agent on a locked box is 403 `box_locked` for a non-owner (audit
  `channel_agent_add`), and a back-fill sends only the earlier posts the fan-out would have delivered (1c).
- A lock read error refuses: 503 `store_unavailable` on a request, a skipped box in a loop, a pending back-fill.
- **As built (path 12, batch 3, SPL-2993)**: a box's own send straight to a locked-box agent is refused in
  `onSend` (`internal/hub/ws.go`), right after `sendRouteRefusal` has checked `to_box`:
  `if rf == nil { rf = s.boxSendLockRefusal(ctx, x, env, m) }` (dispatcher, msg e63df138). A send from the
  locked box itself or a peer box passes; any other box gets 403 `box_locked`, nothing is queued, and one
  `box_send` audit row is written. Test: `TestBoxLockQueuePaths/12_box_send` (the peer box delivered,
  `box-sh` refused); remove the call and it goes red.

### 5.3 What the owner box does on its own (defence in depth)

The sidecar of `<OWNER_BOX>` keeps the lock's owners and `peer_boxes`, verified with `K_lock`'s public half,
and drops a delivery whose `from_box` is not itself, `box-wui` or a peer box, or whose `typed_by` human is not
an owner. This catches a hub that lost its check (a bad deploy); it does not catch a hub that lies about
`typed_by` (8.2).

**As built (row B7, SPL-2992)**: `internal/spool/lockfilter.go`, called once in `deliverTo`
(`internal/spool/spool.go`), the one function behind `Deliver`, `DeliverTo` and `DeliverQuiet`. The sidecar
names each frame's `from_box` with `Store.FromBox(e.FromBox)` at its three delivery calls
(`internal/hubclient/hubclient.go` `receive`, `backfill.go`, `fallback.go`). Tests: `TestBoxLockFilter`,
`TestBoxLockFilterQuiet` (`internal/spool/lockfilter_test.go`), `TestSyncBoxLockDrops`
(`internal/hubclient/box_lock_drop_test.go`).

- The lock the box keeps is the owner's signed statement, `spool lock create` (or `rebind`) output as
  printed, saved as `lock/lock.signed.json` under the box's keys dir. It is verified on every delivery
  against `lock/lock.json`: K_lock's signature over `signed_body`, the body in B1's canonical form, and the
  same tenant, box and `lock_pubkey`.
- A hub frame never carries `typed_by` (`wire.Frame.TypedBy`: "never on a frame to a box"), so the human
  the box checks is a browser post's `from`, the same rule as the hub's `lockAdmits` (B3): from `box-wui`
  only an owner's `HUM-*`; from any other box only the box itself or a peer box. A peer box's post is not
  checked for a human, as on the hub.
- A box with no `lock/lock.json` is not sealed: nothing is filtered. A sealed box whose signed lock is
  missing, malformed, signed by another key or for another box admits only its own box (fail closed, like
  a tampered row, 6.1).
- A dropped delivery is not written, rung or copied to the fleet inbox; the sidecar answers it as
  delivered (no redelivery loop) and logs one line with ids and boxes, never the body.
- Not in B7: `spool lock create` and `rebind` do not yet write `lock/lock.signed.json` themselves (B4's
  `cmd/spool/lock.go`); until a later row does, the owner saves the printed output there.

### 5.4 As built: the view and admin points (row B5, SPL-2991)

Code: `internal/hub/box_lock_view.go` (`lockView` and its one predicate `hiddenByLock(from_box, to_box)`,
`topicLockHidden`, `fileLockHidden`, `adminLockRefusal`, `seatLockRefusal`, `channelLockRefusal`, the live
snapshot `lockSnaps`); store `LockedBoxes` (`internal/store/box_locks_tenant.go`, the workspace's locked box
ids, 5 s cache that a lock write through the same store clears) and `TopicAccess.Boxes` (every non-empty
`from_box` / `to_box` of the topic). A workspace with no lock pays the one `LockedBoxes` read per request and
nothing else. Test: `TestBoxLockViewPaths` (`internal/hub/box_lock_view_test.go`), one pair per path: the owner
sees or changes it, the other admin is hidden, 404 or 403 `box_locked`, and the admin's control on the open box
passes. Path 10b: `TestBoxLockFleetLoadPaths`; the live snapshot: `TestLockSnapsFailClosed`.

R7 fixes (c-986 FAIL on `c8afc00d5`): a file hit now carries `to_box` and every search hit in a hidden topic is
dropped (D1: a file on a line TO a locked box stayed in another admin's search). The live snapshot `lockSnaps` is
known (read, with or without locks) or unknown (never read on this instance, or its last read failed); an unknown
workspace hides every frame with a box end from everyone until one read succeeds (D2: a store error at fan-out
used to keep, or find empty, the last snapshot and show the frame). A frame with no box end is never hidden.

| path | where | what a non-owner gets |
|---|---|---|
| 4 | `topicDoor` (`privacy.go`): `canReadTopic` and the fused page door (`view.go`); the topic list and its inline messages; the topic page; search (`search.go`: message, file, box and robot hits by their ends, and every hit with a `task_id` by its topic's `TopicAccess`, once per topic); flow (`flow.go`, the page and the live event) | a topic that touches a locked box reads 404 and leaves every list; a message or event from or to one is left out |
| 4b | `wants` (`wui.go`), so every live frame that asks it (new posts, edits, reactions, moves, merges, archive); subscribe goes through `canReadTopic` | no frame; subscribe answers `not_found` |
| 5 | `handleViewRoster` (`view.go`); the welcome presence snapshot (`wui.go`) | the box's row and its agents' presence are left out |
| 5b | `handleBoxStats` (`box_stats.go`); `handleAgentLifecycleEvents` (`agent_lifecycle.go`) | the box's rows, hours and lifecycle events are left out |
| 6 | `fileReadableBy` (`rest.go`), so download, delete and re-attach | 404, unless a carrier the reader may read is not hidden |
| 8 | `handlePin`, `handleRevoke` (`rest.go`), after the root signature | 403, audit `pin` / `revoke` |
| 8b | `handleListPins` (`rest.go`) | the locked pin is listed only to the box itself, a peer box of its lock, or an owner's browser token |
| 8c | join token mint and redeem, seat revoke (`join_tokens.go`) | 403, audit `join_token` / `seat_revoke` |
| 8d | sender list `PUT` / `DELETE` (`sender_allow.go`, bare id by the roster); the channel AI agents switch when the channel holds an agent of a locked box (`channel_ai_agents.go`) | 403, audit `sender_allow` / `channel_ai_agents` |
| 10b | `PATCH /v1/operator/fleet-load` (`fleet_load.go`) when `boxes` or `box_order`, stored or new, names a locked box; the `GET` drops it | 403, audit `operator_workspace` |
| 11 | issue create and update (`checkAssigneeBy`, `issues.go`) | 403, audit `issue_assign`; an agent of the locked box may still assign its own box |

Where it differs from 5.1 and 5.2:

- A topic is hidden whole when ANY of its messages touches a locked box, not message by message: its list row
  carries the first message's subject and its participants. The lobby is the exception: every member shares
  it, so only its hidden messages go.
- A hidden read writes no audit row (like `fallbackLockSkip`): it refuses nothing the reader asked to change,
  and a list read would write one row per hidden topic. Every 403 writes one.
- `hide_posts = false` is not honoured yet: every lock hides.
- The live fan-out runs under the hub mutex and reads the locks last read for the workspace (each view read,
  subscribe and stored message refreshes them). A lock made on another instance reaches its live frames after
  that instance's next read (the 5 s cache).

Not covered by this row:

- `agent_split.go` and `operator_workspaces.go` are unchanged: their routes name no box or agent (per-kind
  vendor weights; whole workspaces). The agent lifecycle `PATCH` is workspace-wide and names no box either.
- The live roster and presence broadcasts at a box's connect (`broadcastRoster` in `ws.go`, the path 12 lane's
  file; the presence frames in `channels.go`, B3's): an open socket of a non-owner still sees the locked box
  come online. The welcome snapshot and `GET /v1/view/roster` are filtered.
- The flow day fold (`flow_fold.go`) and the flow counts; the sender list `GET`; the lifecycle aggregates; the
  DM counts and pointers of a topic list.
- Box-session lane reads (`box_stats_list`, `lifecycle_*`, the fleet load lane): a box, not a human, asks.

## 6. Data, routes and audit

### 6.1 Tables (rdb `<next>_box_locks.sql`, row B1)

```sql
CREATE TABLE box_locks (
  tenant_id    text        NOT NULL,
  box_id       text        NOT NULL,
  lock_pubkey  text        NOT NULL,             -- base64 Ed25519, K_lock
  box_pubkey   text        NOT NULL,             -- the K_box this lock accepts
  owners       text[]      NOT NULL CHECK (cardinality(owners) >= 1),   -- HUM-*
  peer_boxes   text[]      NOT NULL DEFAULT '{}',
  hide_posts   boolean     NOT NULL DEFAULT true,  -- OQ-1
  version      bigint      NOT NULL,             -- +1 on every signed change
  signed_body  text        NOT NULL,             -- canonical JSON of every column above
  signature    text        NOT NULL,             -- K_lock over signed_body
  created_at   timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (tenant_id, box_id)
);
CREATE TABLE box_lock_audit (
  tenant_id text NOT NULL, box_id text NOT NULL, human_id text NULL, from_box text NULL,
  path text NOT NULL,
  verdict text NOT NULL CHECK (verdict IN ('refused','created','changed','lifted','sealed_hello','tampered')),
  first_at timestamptz NOT NULL, last_at timestamptz NOT NULL, count integer NOT NULL DEFAULT 1
);
-- FORCE ROW LEVEL SECURITY with the tenant policy of 0021; operator scope only for the break-glass (8.3).
```

The hub verifies `signature` over `signed_body` on every cache load, and that `signed_body` equals the row.
A row edited in the database without `K_lock` (owners widened, `peer_boxes` added) fails the check, and the
hub then treats the box as **locked to nobody**: every human refused, the box refused at hello, one
`tampered` audit row and a note in the owner's DM. A deleted row is caught by cnf (6.4).

**As built (row B1, SPL-2952)**: rdb `0213_box_locks.sql`; `internal/store/box_locks.go` (+ `_postgres.go`,
`_memory.go`), interface `BoxLockStore`. For the later rows:

- `BoxLock(ctx, tenant, box)` answers `nil` for an unlocked box, else the lock verified by `VerifyBoxLock`;
  a failed verify comes back with `Tampered` set and bumps one `tampered` audit row (path `load`). Read
  `IsOwner(hum)` / `IsPeer(box)`: both are false for every human and box on a tampered lock. An error means
  refuse (5.2). Postgres serves it through a 5 s cache that its own writes clear; no `box_locks` table yet
  (rdb 0213 not applied) reads as unlocked.
- `signed_body` is `BoxLockBody(l)`: `encoding/json` of `tenant_id, box_id, lock_pubkey, box_pubkey, owners,
  peer_boxes, hide_posts, version` in that order, an empty list as `[]`; keys and signature are standard
  base64. `spool lock sign` (B4) signs exactly those bytes.
- `CreateBoxLock` / `ChangeBoxLock` refuse a body that does not verify; a change must name the `lock_pubkey`
  on file and the stored `version + 1` (`ErrBoxLockKey`, `ErrBoxLockVersion`). `LiftBoxLock` deletes; the lift
  statement's signature is the route's check (B2). Each writes its `created` / `changed` / `lifted` row.
- `RecordBoxLockAudit` bumps the row of the same box, human, from_box, path and verdict first written within
  the last minute, else writes one. The audit table has an identity key `audit_id` (not in the sketch above).
- Not in B1: the DM note on a tamper finding and the cnf check (6.4) are B2 / B6.

### 6.2 Routes (row B2)

| route | who | body | does |
|---|---|---|---|
| `POST /v1/boxes/{box}/lock` | a box session of that box (the request is signed by `K_box`) **and** confirmed by an owner's WUI session | `signed_body` + `signature` by `K_lock` | creates the lock; refused if the confirming human is not in `owners` |
| `PUT /v1/boxes/{box}/lock` | an owner's session | new `signed_body` (version + 1) signed by `K_lock`, over a hub nonce no older than 300 s | changes owners, `peer_boxes`, `hide_posts`, or `box_pubkey` (`rebind`) |
| `DELETE /v1/boxes/{box}/lock` | an owner's session | a lift statement signed by `K_lock` over a hub nonce | lifts the lock |
| `GET /v1/boxes/{box}/lock` | an owner's session | — | the lock and its audit; any other caller gets 404 |

No other route, role, permission or operator scope writes `box_locks`. The `K_lock` signature is made on
`<OWNER_BOX>` by `spool lock sign` (terminal + secret); the WUI only carries it. A stolen owner session
cookie therefore cannot change a lock, and neither can `K_lock` alone without an owner session.

**As built (row B2, SPL-2964)**: `internal/hub/box_lock_routes.go`, the hello step in `helloRefusal`
(`internal/hub/ws.go`), the hello and welcome fields `boot_id`, `unlock_proof`, `unlock_ticket` on
`wire.Frame`, the four operations in `internal/hub/openapi.json`. Tests: `TestBoxLockRoutes`,
`TestLockedHello` (`internal/hub/box_lock_routes_test.go`).

- Every route needs a member's session; a visitor role (demo_user, channel_guest) is 403 before any
  lookup. No role or permission grants anything: only the lock's owners (a tampered lock has none).
- `POST` body: `spool lock create`'s output as is (`signed_body`, `signature`, `box_signature`).
  Version 1; the confirming member in `owners` (else 403 `not_owner`); `box_pubkey` the pinned key and
  `box_signature` that key's over `signed_body` (else 403 `bad_box_sig`); `signature` K_lock's (else 403
  `bad_sig`). 409 when already locked. A live session of the box is closed (going away), so its next
  hello needs the unlock.
- The hub nonce is `<unix seconds>.<signature>`, the hub's own key (box-wui's) over
  `spool-lock-nonce-v1|<tenant>|<box>|<seconds>`, good for 300 s; `GET` answers one to an owner. A hub
  with no box-wui key cannot issue one: `PUT` and `DELETE` then answer 501.
- `PUT` body: `signed_body`, `signature`, `nonce`, `nonce_signature` = K_lock over
  `spool-lock-change-v1|<tenant>|<box>|<nonce>|<sha256 hex of signed_body>`. A non-owner is 403
  `box_locked`; a statement or body under another key 403 `bad_sig`; a stale or foreign nonce 400
  `stale_nonce`; a version other than stored + 1 409 `stale_version`. A new `box_pubkey` (rebind) is
  pinned in the same call (force) and the box's live session closed.
- `DELETE` body: `nonce`, `signature` = K_lock over `spool-lock-lift-v1|<tenant>|<box>|<stored
  version>|<nonce>`; 204.
- `GET`: the row, its audit rows (newest first, at most 200) and a nonce; 404 to anyone else.
- Audit: each refusal bumps one `refused` row per human and path (`lock_create`, `lock_change`,
  `lock_lift`, `lock_get`): `not_owner`, `box_locked`, `bad_box_sig`, `bad_sig`, `stale_nonce` and
  `stale_version` all do (`TestBoxLockRefusalsAudited`). A malformed request (415, 400 `bad_json` /
  `bad_body`) writes none. The store writes `created` / `changed` / `lifted` (B1).
- Hello (4.4): for a locked box the pinned key must be the lock's `box_pubkey` (else 4401
  `locked_box_key`), and a `role=box` hello must carry a valid ticket for the same `boot_id`, or an
  `unlock_proof`: K_lock over `lockkey.ProofPayload(tenant, box, nonce, boot_id, box_pubkey, ts)` with the
  hello's own nonce and `ts` within 120 s. A proof earns a ticket on the welcome (`unlock_ticket`:
  base64url JSON `{v, tenant, box, box_pubkey, boot_id, expires_at}` + `.` + the hub key's signature over
  `spool-unlock-ticket-v1|<json part>`, 7 days). Anything else, and a tampered lock, is 4401
  `locked_box_sealed` with one `sealed_hello` audit row (path `hello`). A `role=cli` hello is not a
  delivery target and proves K_box, which exists only in the unlocked holder: it needs the key check only.
  A `box_locks` read error answers `store_unavailable` (fail closed; the box redials).

Not in B2, left for a later row: the box client (`internal/hubclient`) does not yet send the proof,
keep the ticket or call `drop-lock`, and still reads the clear key, so a sealed box stays offline (4.6);
the ticket TTL is a constant until cnf (B6); the owner's DM note on a tamper finding (6.1) and the daily
audit digest (6.3).

### 6.3 Audit

- Every refusal writes or bumps one `box_lock_audit` row per `(box, human or from_box, path)` per minute
  (`count`, `last_at`), so a refusal loop does not flood the database (db-f1-micro).
- Every create, change, lift, sealed hello and tamper finding writes one row.
- Readable by the owners (`GET /v1/boxes/{box}/lock`), and sent to the owner's DM as a daily digest when the
  count is not zero.

### 6.4 cnf: the expected locks (row B6)

`hub.box_locks_expected: [{tenant: <workspace>, box: <OWNER_BOX>, lock_pubkey: <base64>}]` in
`csi-spl-cnf/csi-spl/<env>.env.yaml`, rendered to the hub's env. At start and on every cache load the hub
refuses to serve a listed box without a verified lock row with that `lock_pubkey`. So removing a lock by
deleting its row needs a cnf commit on trunk too, which is visible in git history.

**As built (row B6, SPL-3014)**: cnf `hub.box_locks_expected: []` in `csi-spl-cnf/csi-spl/{dev,prd}.env.yaml`
(empty in both: no box is locked), rendered by 030's template to `SPOOL_HUB_BOX_LOCKS_EXPECTED`, entries
`<tenant>:<box>:<lock_pubkey>` joined with commas; `config.Hub.BoxLocksExpected` reads it. Code:
`internal/store/box_locks_expected.go` (`ParseExpectedBoxLocks`, `ExpectBoxLocks`, `CheckExpectedBoxLocks`),
one call each in `BoxLock` (Memory, Postgres) and `LockedBoxes`, and `expectBoxLocks` in `cmd/spool/hub.go`
at start. Tests: `TestBoxLockExpected`, `TestParseExpectedBoxLocks` (`internal/store/`, memory and
Postgres), `TestHubStartRefusesExpectedBoxWithoutLock`, `TestExpectBoxLocksRefusesBadList` (`cmd/spool/`),
`csi-spl-iac/src/bash/tests/hub-box-locks-expected-030.tst.sh` (the render).

- A listed box with no row, or with a row under another `lock_pubkey`, loads as `Tampered`: locked to
  nobody, so every check of B2, B3 and B5 refuses it (hello `locked_box_sealed`, 403 `box_locked`, hidden),
  with one `tampered` audit row (path `expected`) per load. `LockedBoxes` lists it even with no row. The
  check is in the store, not in `internal/hub/`, so no queue or view point needs its own call.
- A row created later under the listed key verifies again: the owner creates the lock (7.1 step 2) with
  the box listed or not.
- At start the hub logs `box_lock.expected_missing` per refused box and `box_lock.expected` with the counts.
  A malformed list (not three parts, a key that is not 32 bytes of base64, a box listed twice) stops the
  start: a typo never leaves a box unchecked.
- On a database without rdb 0213 a listed box is refused too (no audit row: there is no table).

### 6.5 As built: the WUI (row B8, SPL-3015)

Code: `csi-spl-wui/src/components/BoxLockPane.vue` (lazy, last on the box's Monitoring
card `/monitoring/boxes/<box>`, below the resources and the seats: above them it pushed the resource rows
under the phone's docked composer), `csi-spl-wui/src/utils/box-lock.mjs` (the pasted-output check, the lock route
refusal map, the mock), `sendFailureKey` in `csi-spl-wui/src/utils/send-failure.mjs` (the refusal map), the
client methods `getBoxLock` / `createBoxLock` (`spool-client-lazy.mjs`), and the keys `box_lock.*` and
`composer.send_failed_box_locked` in every `i18n/locales/*.json`. Tests: `tests/unit/box-lock.test.mjs`, the
box lock cases in `tests/e2e/agent-senders.test.mjs`.

- A send the hub refuses with `box_locked` (path 2) reads "Not sent — this agent's box is locked to its
  owners, and only they can message its agents. Your text is still here." next to the composer, with the
  text kept. The line names no owner (5.2).
- The pane: an owner sees the owners, the peer boxes, the version and the audit rows `GET` answers. Anyone
  else, and an unlocked box, reads "This box has no lock you own." (the hub answers both 404, so the WUI
  cannot tell them apart). A hub with no lock store (501) shows no pane.
- The confirm dialog takes `spool lock create`'s printed output as is, refuses text that is not that output
  or names another box before anything is sent, shows the owners it names, and `POST`s it. Each refusal of
  6.2 (`not_owner`, `bad_box_sig`, `bad_sig`, `box_locked` 409, `bad_body`, `not_found`) has its own line.
  The WUI holds no key and signs nothing.
- Mock bundle: the hook `spool.mock.box-lock` = `{box, owners, peer_boxes}` stands in for a hub with that
  lock (the send refusal and `GET`); with no hook every box is open.
- Not in B8: `PUT` (change) and `DELETE` (lift) in the WUI: both need `K_lock`'s signature over a hub nonce
  that `GET` hands out, so the owner signs on the box; a later row can carry them the same way.

## 7. Migration and the owner's proof

### 7.1 Migration

1. B1 to B5 land and deploy to dev and prd with no lock row: nothing changes (every box unlocked).
2. On `<OWNER_BOX>` the owner runs `spool lock seal` (sets the secret, gets the recovery code), then
   `spool lock create --owners <OWNER_HUM>` and confirms in the WUI. Dev first, then prd.
3. B6 adds the cnf entry for that box in both envs.
4. `<SHARED_BOX>` and every other box stay open, as today. No other workspace member is moved or changed.
5. `DESK_OWNERS` (017 FR-SEC-031) stays as it is: it labels lines, the lock refuses them.

### 7.2 How the owner proves it works (red controls)

Run by the owner, or by a lane with a second test account, on dev then prd, n=1 per case:

| case | as | expect | red control |
|---|---|---|---|
| DM a `<OWNER_BOX>` agent | another admin | 403 `box_locked`, audit row, nothing in the agent's inbox | the same DM as the owner: delivered |
| post in a channel the agent is in | another admin | post visible to the channel, nothing queued to `<OWNER_BOX>` | the same post as the owner: queued |
| read the agent's topic, roster row, file | another admin | hidden / 404 | as the owner: shown |
| act-as a member, then DM the agent | admin via a 054 clone | 403 `box_locked` | the same member, signed in as themself, on an unlocked box: delivered |
| pin a new key for `<OWNER_BOX>` with the workspace root key | root-key holder | 403 `box_locked` | an unlocked box: pinned |
| a `<SHARED_BOX>` agent DMs a `<OWNER_BOX>` agent | box session | refused (peer not listed) | after the owner adds it to `peer_boxes`: delivered |
| restart the sidecar, do not unlock | — | box offline, `sealed_hello` audit row | type the secret: online |
| edit `owners` in the database by hand (dev only) | env SA | `tampered`, everyone refused | restore the row: the owner works again |

## 8. Known limitations (accepted by the owner, msgs 49914aea, 005bacba)

### 8.1 Root on a running box

Root (or anyone who can run code as the box's OS user) on `<OWNER_BOX>` **while the sidecar is unlocked** can
read the sidecar's memory: `K_box` and the unlock ticket, possibly a stale copy of `K_lock` (4.4). With those
they can send as that box's agents until the ticket expires, and with a `K_lock` copy also change the lock.
They can also capture the secret the next time the owner types it (a keylogger), as the directive runbook
says of its passphrase (`csi-spl-orc/src/bash/features/directive/doc/runbook.md` section 7). The design does
not protect a running box from its own root. It does protect: a sealed box after a reboot, the key files at
rest, and every path through the hub.

### 8.2 The hub, its database and its code

The lock is enforced by hub code, and the hub is trusted:

- Whoever holds a per-env service-account key can write the database. A tampered row is detected (6.1); a row
  deleted together with a cnf change is not prevented, only made visible in git.
- Whoever can land code on trunk and get it deployed can remove the check. The box-side check (5.3) catches
  a removed check, not a hub that forges `typed_by`.
- A stolen owner session cookie reads what the owner reads; it cannot change the lock without `K_lock`.

### 8.3 Break-glass

Secret and recovery code both lost: `do_spl_box_lock_break` (row B6, per-env SA, `DRY_RUN=0`, refuses without
a cnf commit that removes the box from `box_locks_expected`) deletes the row under the operator scope, writes
an audit row and posts to the owner's DM. It is the power named in 8.2, given a name and a trail rather than
left unnamed. It never runs without the owner's go for that call.

**As built (row B6, SPL-3014)**: `csi-spl-orc/src/bash/run/spl-box-lock-break.func.sh`
(`do_spl_box_lock_break`) and `spl-box-lock.func.sh` (`do_spl_box_lock`: `BOX_LOCK_CMD=create`, run on the
sealed box, saves `spool lock create`'s statement as `<keys>/lock/lock.signed.json` 0600 and prints the
cnf entry; `BOX_LOCK_CMD=show`, read only: the cnf entry, the row, the audit summary and whether the hub
refuses the box). They live in `csi-spl-orc`, not `csi-spl-iac` as row B6 names: the proxy and cloud-cnf
helpers they use (`spl_via_proxy`, `do_spl_cloud_cnf`) are orc's. Test:
`csi-spl-orc/src/bash/tests/spl-box-lock.tst.sh` (stubs, then a real Postgres with the rdb migrations as
the runtime login).

- The break is a dry run unless `DRY_RUN=0`, which needs `BOX_LOCK_GO` (the owner's message id). It refuses
  while the box is listed in `hub.box_locks_expected` of the working cnf OR of `origin/master`'s cnf (fetched
  first), before any database call. It deletes the row and writes one `break` / `lifted` audit row in one
  transaction; a box with no row is refused and nothing is written.
- Not built: the post to the owner's DM; the action prints that the owner must be told on the go's topic.

### 8.4 Other limits

- Docs and Qto trees are not covered (OQ-4).
- A bare agent id announced by a second box is ambiguous and refused (`locateAgent`,
  `internal/hub/agent_box.go:44`): another box cannot take the locked agent's traffic this way, but it can make
  a bare-id send fail. Owners address `<ID>@<OWNER_BOX>`.

## 9. Open questions (default recommended, built unless the owner changes it)

| # | question | recommendation |
|---|---|---|
| OQ-1 | Do non-owners see what `<OWNER_BOX>` agents post in shared channels? | no (`hide_posts = true`): "all of the others should be able to access only `<SHARED_BOX>` box resources" |
| OQ-2 | May `<SHARED_BOX>` agents message `<OWNER_BOX>` agents (today's cross-box relays)? | no by default (`peer_boxes` empty): a peer box reopens the path for anyone who can command it; the owner adds one by a signed change if wanted |
| OQ-3 | Unlock ticket lifetime (how often the secret is typed while the box stays up) | 7 days, cnf |
| OQ-4 | Do docs written by `<OWNER_BOX>` agents get a per-box reader list? | not in this spec: docs are workspace objects; a separate row if wanted |

## 10. Build rows (rounds rulebook R1-R16; disjoint files per batch)

| row | batch | what | files | red control | measure after | vendor |
|---|---|---|---|---|---|---|
| **B1** data | 1 | `box_locks`, `box_lock_audit`, RLS, store methods + 5 s cache, signature verify on load | rdb `<next>_box_locks.sql`; `internal/store/box_locks.go`, `box_locks_postgres.go`, `box_locks_memory.go` (new) | a row with a widened `owners` and the old signature loads as `tampered`; drop the verify → red | `PRE_PUSH_TIER=full` green; `TestBoxLockTamper` POSTGRES | claude |
| **B4** box side | 1 | `spool lock seal / unlock / reseal / rotate-recovery / rebind / sign / create`; sealed sidecar; unlock proof in hello; drop `K_lock` after the ticket | `cmd/spool/lock.go` (new), `internal/lockkey/` (new: argon2id, HKDF, XChaCha20), `internal/action/join.go` (`boxKey` reads `.enc`) | open with a wrong secret, or a file sealed for another box id → refused; drop the associated-data binding → the swapped file opens → red | `go test ./internal/lockkey/... ./cmd/spool/...`; seal and unlock on a dev box, n=1 | claude |
| **B2** routes + hello | 2 | the four lock routes (6.2), hello proof and ticket in `helloRefusal`, `sealed_hello` audit | `internal/hub/box_lock_routes.go` (new), `internal/hub/ws.go` (`helloRefusal` only) | a hello with no proof for a locked box is refused; accept it unchecked → red; a `PUT` signed by another key → 403 | `TestBoxLockRoutes`, `TestLockedHello` | claude |
| **B3** queue points | 2 | `boxLockRefusal` and its calls: paths 1, 1b, 1c, 2, 2b, 3, 10, 12, 12b | `internal/hub/box_lock.go` (new), `dispatch.go`, `channels.go`, `fallback.go`, `backfill.go`, `channel_members.go` | another admin's DM → 403 and audit; act-as clone → 403; remove the call in `dispatchCheck` → red | `TestBoxLockQueuePaths` (each path a pair: owner delivered, other refused) | claude |
| **B5** view and admin points | 3 | `hiddenByLock` and the write refusals: paths 4, 4b, 5, 5b, 6, 8, 8b, 8c, 8d, 10b, 11 | `privacy.go`, `wui.go`, `view.go`, `search.go`, `flow.go`, `rest.go`, `box_stats.go`, `agent_lifecycle.go`, `join_tokens.go`, `sender_allow.go`, `channel_ai_agents.go`, `agent_split.go`, `operator_workspaces.go`, `fleet_load.go`, `issues.go` (all `internal/hub/`) | another admin reads the topic, roster, file of a locked box → hidden / 404 / 403; drop the predicate in `canReadTopic` → red | `TestBoxLockViewPaths` POSTGRES | claude |
| **B7** box-side drop | 3 | the owner-box sidecar drops deliveries from a non-peer box or a non-owner `typed_by` (5.3) | `internal/spool/lockfilter.go` (new) and its call in `Deliver` (`internal/spool/spool.go:262`) | a delivery with a non-owner `typed_by` is dropped; skip the filter → red | unit test | claude |
| **B6** cnf, actions, docs | 4 | `hub.box_locks_expected` in cnf and its render, hub start check; `do_spl_box_lock` (create, show) and `do_spl_box_lock_break`; this spec's status and the help page | `csi-spl-cnf/csi-spl/{dev,prd}.env.yaml`, its tpl-gen template, `csi-spl-iac/src/bash/run/spl-box-lock*.func.sh` + tests, `internal/config/config.go` (one key) | a hub started with a listed box and no row refuses that box; delete the check → red; the break action without the cnf removal refuses | `ENV=<env> ./run -a do_tpl_gen` + `git diff --exit-code`; iac tests | claude |
| **B8** WUI | 4 | lock confirm dialog, `box_locked` refusal text, lock pane for owners; strings in every locale | `csi-spl-wui/src/components/BoxLockPane.vue` (new), the refusal map, `i18n/locales/*.json` | another admin's DM shows the `box_locked` text; mock the hub refusal off → red | `pnpm run typecheck`, unit + e2e on the mock bundle; agy review of the strings LAST | claude, then agy (i18n) |

Batches: 1 (B1, B4) → 2 (B2, B3) → 3 (B5, B7) → 4 (B6, B8). No file is in two rows of one batch: `ws.go` is
in B2 only (B3 adds no line there; `onSend` reaches `boxLockRefusal` through `dispatch.go`'s helper, else B3
moves to batch 3), `wui.go` is in B5 only (path 1's fan-out check sits in `channels.go`, B3). Rows are built
after the panel signs this plan, without a further owner go (rounds rulebook 1.4); the prd lock creation
(7.1 step 2) is the owner's own act.

## 11. Review

| seat | vendor | verdict | at |
|---|---|---|---|
| reviewer (docs review) | mistral, m-797@sat | CHANGES 5.1, 10 (msg 71c78d32) on v0.1 `5e019c763`; folded in v0.2: `fleet_load.go:119` was a comment line (now `:120`, `fleetLoadCaller`); the queue sites `retired_reply.go:75`, `ws.go:238`, `ws.go:985`, `fallback.go:256/:335/:382`, `backfill.go:160` added to 5.1 and the queue-write inventory to 5.2. Its other 9 "file not found / no function" items arrived with the paths stripped; every 5.1 reference re-read on `10e12f038`: 0 more wrong | 2026-10-22 |
| reviewer (docs review) | mistral, m-797@sat | **SIGNED at `201f2e3a8`** (msg 7e792038) | 2026-10-22 |

<!-- version: 1.0.0 · updated: 2026-10-23 · last-edit: 2026-10-23T05:28:17Z -->
