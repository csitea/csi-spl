# Contract: `v:1` → `v:2` migration (readers first, writers last)

Feature: `020-spool-message-v2`. Goal: **no running box breaks at any step**,
and no message is ever lost silently.

## 1. Why the order is forced (measured)

- **A `v:1`-only reader refuses a `v:2` object.** Control on trunk `dabd2d4`
  (n=1): one `v:1` and one `v:2` file in one inbox, `spool recv --as CLE-7`
  → the `v:1` message is returned; stderr `spool: 1 malformed message file(s)
  left in …/inbox`. `msg.Validate`: `unsupported version 2 (want 1)`.
- **Through the hub, that refusal is SILENT loss.** `internal/hub/ws.go`
  `push` marks the row `sent` as soon as the `recv` frame is written;
  `internal/hubclient/hubclient.go` handles a refused frame with a log line only
  (`"recv frame refused"`). The hub never learns, the sender reads
  `delivery: sent`, the recipient never sees it.
- **An old hub refuses a `v:2` send** (`ws.go` `onSend` → `env.Inner()` →
  `Validate`), so a box that writes `v:2` before its hub reads it gets an
  error back rather than losing mail. That is loud, but it is still an outage
  for that box.

Hence: every reader first, then the writers, plus a hub guard (§3) so a
straggler box can never lose mail silently.

## 2. Phases

| phase | what changes | who | gate to enter |
|---|---|---|---|
| **P1 readers** | `msg.Validate` accepts `v ∈ {1,2}`; boxes advertise `msg_versions:[1,2]` in `hello`; the hub holds `v:2` rows for a box that did not advertise `2` (§3). Writers unchanged: `v:1` | code on trunk (020 T004–T010) | — |
| **P1-deploy hub** | hub image with P1 rolled to **dev**, then **prd** | deploy lane (CLE-3355: bump `hub.image.tag`, apply step 030 via make) | P1 on trunk, CI green |
| **P1-deploy boxes** | every box running `spool` rebuilt from a trunk ≥ P1 (list: §4) | box owners / ORC | P1 on trunk |
| **P1-deploy WUI** | `SpoolMessage.v: 1 \| 2` (type only; the WUI reads no `v`) | UI lane (CLE-55) | P1 on trunk |
| **P2 writers (canary)** | hub: cnf `SPOOL_HUB_MSG_VERSION=2` on **dev**; one box: `SPOOL_MSG_VERSION=2` | owner go | every row of §4 upgraded, both hubs report the P1 commit (`GET /` `commit`) |
| **P2 writers (all)** | hub prd `SPOOL_HUB_MSG_VERSION=2`; boxes `SPOOL_MSG_VERSION=2` | owner go | dev canary clean for 24 h: `do_spl_db_message_show` shows `v:2` rows delivered, 0 rows stuck `queued` behind the §3 guard |
| **P3 default** | code default of both knobs flips to `2` (one commit) | API lane | P2 all, 7 days (the queue TTL) |

`v:1` reading is never removed: stored `v:1` rows, archives and pending
envelopes stay readable forever.

## 3. Hub guard: capability in `hello` (additive, 003 `http-v1 §2.2`)

- A box `hello` frame MAY carry `"msg_versions":[1,2]`, the inner versions its
  reader accepts. Absent → `[1]` (every pre-020 box).
- The field is **not** in the hello signature payload
  (`{box_id,nonce,ts}` unchanged), so a pre-020 hub ignores it (WS frames are
  decoded non-strictly) and a pre-020 box's hello verifies unchanged.
- The hub never pushes a `recv` frame whose inner `v` the session did not
  advertise. The row stays `queued`, a later `hello` from an upgraded binary
  drains it, and the queue TTL (`SPOOL_HUB_QUEUE_TTL`, 168 h) is the bound.
  Loud (visible as `queued` in the send result and in the store), never silent.
- Same guard on a channel fan-out (`routeChannel` → `push`).

## 4. What must upgrade (this box, 2026-09-19)

`find / -xdev -type f -name spool -perm -u+x` → 3 binaries; no `spool`
process was running (`ps aux | grep '[s]pool'` found none):

| binary | role | action |
|---|---|---|
| `/opt/csi/csi-spl/csi-spl-api/src/go/spool-hub-api/bin/spool` | the box CLI + MCP server built from the shared checkout | rebuild after the shared checkout fast-forwards to ≥ P1 |
| `/var/tmp/spool-test-3333/bin/spool` | a lane's test copy | rebuild or delete; not a live box |
| `/var/tmp/claude/msgs/CLE-3374/proof/spool` | a lane's proof copy | rebuild or delete; not a live box |

Plus, out of this box: the **hub** in dev and prd (`csi-spl-hub-<env>`,
Cloud Run), `box-wui` (inside the hub process, so it moves with the hub
image), `cicdlogs` (inside the hub). **Any customer or tenant box** that runs
its own `spool` must upgrade before P2 reaches its tenant's hub; until then
the §3 guard holds its `v:2` mail rather than losing it.

## 5. Knobs

| env | where | values | default |
|---|---|---|---|
| `SPOOL_MSG_VERSION` | box (`spool send`, MCP `spool_send`, hub-mode send) | `1` \| `2` | `1` until P3 |
| `SPOOL_HUB_MSG_VERSION` | hub (WUI posts, dispatch, CI-logs notes) | `1` \| `2` | `1` until P3 |

Both fail fast on any other value. The legacy `.md` bridge always synthesises
`v:1` (it never leaves the box and its contract says `v:1`).

## 6. Rollback

- P2 → flip the knob back to `1`. Rows already written as `v:2` stay
  readable by every P1 reader; the §3 guard keeps them from old boxes.
- P1 → re-rolling an older hub image leaves `v:2` rows it cannot parse. Only
  roll back past P1 while no `v:2` row exists
  (`do_spl_db_message_show` / `msg->>'v'`).

<!-- version: 0.1.0 · updated: 2026-09-19 · last-edit: 2026-09-19T14:28:00Z -->
