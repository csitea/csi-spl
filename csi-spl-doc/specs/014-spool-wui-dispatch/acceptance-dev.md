# Acceptance record — M3 end to end on dev (014, 005 SC-001, 006 T011c dev part)

**Lane**: M3-E2E-DEV (CLE-3372) · **Runs**: 2026-09-19 12:13Z, 12:15Z (door off) 12:43Z (door
`session`, after dev 030 `ec94b9b`) and 12:53Z (persistent Secret Manager `box-wui` key, dev 030
`56439ab`) · **n**: 4 full runs (run 1: 2 FAILs, both in the assertions, fixed before run 2;
runs 2, 3 and 4: every step PASS)
**Hub under test**: dev `0.1.4` = `b067cfd` (`curl -s https://dev.<domain>/version`)
**Harness**: `do_spl_m3_e2e` (`csi-spl-orc/src/bash/run/spl-m3-e2e.func.sh` +
`src/bash/scripts/m3-e2e.py`), trunk `260aec3`. Tenant `t1` (006 T011d).
**Gate for**: the prd WUI→box command rollout (owner decision 2026-09-19: prd command
only after this passes).

## 1. How to re-run

From `csi-spl-orc`, as the box user. The FIRST run of a fresh state dir needs the DB
invite, so it runs in a throwaway `CLOUDSDK_CONFIG` that holds the dev project key
(the 006 T011d pattern). Later runs need no GCP identity.

```bash
ENV=dev TENANT_ID=t1 ROOT_KEY_JSON=<0600 tenant json of do_spl_tenant_create> ./run -a do_spl_m3_e2e
```

It prints `PASS|FAIL|OBS <step> <evidence json>` and writes
`$SPL_STATE_DIR/m3-e2e/<tenant>/results.json`. The root key, the passwords and the
session cookies are kept in 0600 files next to it and never printed.

## 2. Results (run 2)

| step | what | result | evidence (ids from run 2) |
|---|---|---|---|
| 0 | two boxes on this machine (`box-e2e-a` hosts `EZA-1`, `box-e2e-b` hosts `EZB-1`), own key + `SPOOL_ROOT` each, pinned by the t1 root key; the hub's `box-wui` key pinned (`--force`) | PASS | roster agents `{box-e2e-a:[EZA-1], box-e2e-b:[EZB-1]}`; `/v1/wui/pubkey` `dispatch:true`; box-b's local `pins/box-box-wui.pub` == the hub pubkey |
| a | box-a → box-b `spool send` (005 SC-001, T012) | PASS | msg `311dc080…` task `0db91b6e…` `delivery:queued` → box-b `hub-sync` `delivered:1`; `/v1/view/threads` lists it; the dev WUI (`csi-spl-dev-site.web.app`, Chrome) lists it and opens `/t/<id>` "newest first" |
| h | member human: native (015) sign-in to t1 | PASS | session `200` `p:password` `t:t1` `hum:HUM-4`; `/v1/wui/ws` `welcome.as` = `HUM-4` (the session wins over `hello.as`) |
| b1 | #lobby ambient note reaches no box | PASS | msg `a0d7f8f0…`: the only `deliveries` row is `box-wui`, not in EZB-1's inbox |
| b2 | #lobby leading `@EZB-1` mention reaches the box | PASS | msg `fea36565…` ack `to_box:box-e2e-b delivery:sent`, in EZB-1's inbox `from:HUM-4` |
| c1 | `kind=task` to `EZB-1` is box-wui SIGNED and verified by the box | PASS | msg `9d624e28…` task `3e570b53…`: stored env `from_box:box-wui to_box:box-e2e-b`, sig 88 chars; box-b's `spool hub-run` wrote it to the inbox, and it writes only after `Envelope.Verify` against its local `box-wui` pin (`hubclient.receive`) |
| c2 | the agent's `kind=result` reaches the WUI thread | PASS | `spool send --to HUM-4 --to-box box-wui --kind result` msg `40f38035…` `delivery:sent`; the browser socket got the `message` frame; thread kinds `[task, result]`; the dev WUI shows both on `/t/3e570b53…` |
| d1 | DM (no channel) human ↔ agent | PASS | task `a0cae73a…`: human → EZB-1 `sent`, reply `EZB-1 → HUM-4` reached the socket; `/v1/view/threads?dm=true&peer=EZB-1` row has `channel:null`, 2 messages |
| d2 | presence follows the box session | PASS | `{"peer":"EZB-1@box-e2e-b","status":"online"}` when `hub-run` connected, `offline` after SIGTERM |
| e1 | CONTROL: forged / unsigned envelopes are refused by the box | PASS | a local fake hub replays copies of the c1 envelope to a clone of box-b (same id, keys, pins) running the real `spool hub-sync`: tampered body, `sig:""`, new msg_id → each **exit 78**, nothing written; the genuine copy → exit 0, 1 written (the control's control) |
| e2 | CONTROL: a non-member human is refused | PASS | never-invited account: login with `tenant=t1` → `403 not_allowed`. Door off (run 2): its tenant-less session on t1's `/v1/wui/ws` sends a task to EZB-1 → `401 dispatch_unauthenticated`. Door `session` (run 3): the socket upgrade itself → `401 view_door` |
| e3 | CONTROL: the view door (run 3, door `session`) | PASS | anonymous `GET /v1/view/threads` → `401 view_door`; the non-member's session → `401 view_door`; the member's session reads every view above (the harness sends its cookie) |

## 3. Observations (recorded, not gated)

- **OBS-1 mid-body mention from a human is not routed.** `"… @EZB-1 …"` (not
  leading) stays in the browser: FR-006 dispatches on a leading mention only,
  and channels-v1 §4.6 never routes an unsigned browser envelope. Box-sent
  channel messages DO route mid-body mentions (§4.2). Whether humans should get
  the same is a product question (owner).
- **OBS-2 (closed on dev by run 3)** — the dev door was off, so an asserted id was taken. The non-member's
  socket said `hello.as:"HUM-4"` and was welcomed as `HUM-4`. It could not
  dispatch (e2), but on door-off dev it can post browser-only notes under a
  member's id. This is documented (003 `wui-live-ws.md` §3.1, "door off only"),
  and the fix is 010 T019 (`SPOOL_HUB_VIEW_DOOR=session` on dev, owner +
  DEPLOY). The door went to `session` on dev with 030 `ec94b9b` (12:4xZ), and
  run 3 then measured the refusals (e2, e3). prd keeps its default `token` door.
- **OBS-3 no browser human can sign in on the dev WUI site today.**
  `https://csi-spl-dev-site.web.app/api/v1/auth/session` → `404` (n=2; the
  `/api/v1/auth/**` → hub rewrite is not live, and the hub cookie is
  `Domain=dev.<domain>` anyway). So the human legs above ran with a scripted
  browser client (`m3-e2e.py` `WS`, the same frames the WUI sends). Handed to
  HOSTING (CLE-3354; the dev site-2 / sub-zone move is in flight) and CLE-55.
  The WUI read path (viewer, threads) was checked in Chrome.
- **OBS-4 (closed on dev by run 4)** — ephemeral dev key vs box pins. Every dev hub restart mints a new
  `box-wui` key. The harness re-pins with `--force`, but a long-lived box keeps
  its old local `pins/box-box-wui.pub`, and `SyncPins` then refuses the new key
  (`pin_conflict`, exit 78, 004 T007/T008). That box's next hello fails until
  someone deletes the stale file. This harness starts from fresh box dirs each
  run, so it never meets the problem. T020 (a real secret slot) removes it for dev.
- **Seat (mistake, run 1).** t1 had zero members and dev has bootstrap-owner
  on, so the harness's first tenant sign-in made the test account (`HUM-4`)
  t1's bootstrap **owner**. The harness now invites BEFORE any tenant sign-in.
  The owner is seated with `spool hub-invite --tenant t1 --email <owner> --role
  owner` (ORC informed).

## 4. Not covered here

- Two **real** machines (006 T011c): this run is two box clients on one
  machine. Owner step: on a second machine, build `spool`, then
  `SPOOL_HUB_URL=https://t1.dev.<domain> SPOOL_BOX_ID=<box> spool keygen`, then
  pin it with the t1 root key (`spool hub-pin --box <box> --pubkey <b64>
  --root-key <root.key>`), `mkdir $SPOOL_ROOT/<AGENT-ID>`, `spool hub-run`.
  Then re-run steps a/c against that agent id.
- prd: no tenant exists (`t1.<domain>` → `unknown_tenant`), and dispatch is off (OQ-014-1).

Run 3 also ran on a new ephemeral `box-wui` key (the 030 revision minted
`j7ps8eu9…`, was `+xOuUyLW…`). The harness re-pinned it with `--force` and
dispatch verified on it (OBS-4 in practice).

Run 4 (12:53Z) ran after dev 030 `56439ab`, which replaced the ephemeral key with the
Secret Manager key (`csi-spl-hub-wui-key`, pubkey `6ElVCSaK…`, stable across
restarts). Every step PASSed; box-b's local `box-wui` pin matched it, and the
dispatched task verified on it. This is the key the per-tenant pin keeps from now on.

<!-- last-edit: 2026-09-19T12:56:00Z -->
