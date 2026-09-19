# Acceptance record — M3 end to end on prd (014, 005 SC-001, 006 T011c prd part)

**Lane**: M3-E2E-PRD (CLE-3396) · **Runs**: 2026-09-19 13:49:58Z (run 1, creates the tenant) and
13:51:50Z (run 2, re-uses it) · **n**: 2 full runs, every step PASS in both
**Hub under test**: prd `0.1.6` = `4dc854e` (`curl -s https://e2e.spool-hub.ai/version`,
built 2026-09-19T13:36:08Z)
**Harness**: `do_spl_m3_e2e` ENV=prd mode (`csi-spl-orc/src/bash/run/spl-m3-e2e.func.sh` +
`src/bash/scripts/m3-e2e.py`), trunk `f0d98ba`. Same steps as the dev record
(`./acceptance-dev.md`). Offline test: `bash csi-spl-orc/src/bash/tests/m3-e2e-prd.tst.sh`.
**Tenant**: the dedicated test tenant `e2e`. The owner's tenant `t1` was not touched: no box,
invite or human went into it. `box-orc-probe` (CLE-3384) is still pinned in t1 and was left there.

## 1. Why prd is not dev's run copied as is

| dev | prd (this mode) |
|---|---|
| tenant `t1` | only a test tenant, `^e2e(-[a-z0-9]+)?$` (default `e2e`). The harness refuses t1 and any other name before it makes a single call |
| the hub's debug token verifies the human | prd refuses debug tokens, and that stays. The verify mail goes to a real mailbox. The harness reads it over IMAP (csi-rel's `verify_relay_e2e.py` pattern) and posts its token to the hub's verify API |
| `m3-e2e-*@example.com` | plus-addresses of the relay mailbox (cnf `mail.env.SPOOL_HUB_MAIL_SMTP_USER`): `<local>+spl-e2e-<utc>@<domain>` (member) and `<local>+spl-e2e-out-<utc>@<domain>` (outsider). They are fixed per state dir, so a re-run signs in with the stored passwords and sends no mail |
| invite role `member` | invite role `owner` (the test tenant has no other member; prd has no bootstrap owner) |

IMAP login: the relay password, read from this project's own slot (cnf
`mail.secret_env.SPOOL_HUB_MAIL_SMTP_PASSWORD` = `csi-spl-hub-mail-smtp-password`, the owner's
copy of csi-rel's app password). It is read as the prd project SA
(`csi-spl-prd@csi-spl-prd.iam.gserviceaccount.com`, key `~/.gcp/.csi/key-csi-spl-prd.json`) in a
throwaway `CLOUDSDK_CONFIG`, written to a 0600 file in the state dir, and removed when the run ends.
The owner account was not used. No secret (root key, passwords, cookies, verify tokens) reached
the log or `results.json`. Check: `grep -cE '[0-9a-f]{64}'` on both run logs → 0.

## 2. How to re-run

From `csi-spl-orc`, as the box user:

```bash
ENV=prd ./run -a do_spl_m3_e2e
```

The first run only, on a box that has no key JSON for the tenant, adds `M3_CREATE_TENANT=1`.
Output: `PASS|FAIL|OBS <step> <evidence json>`. Results file:
`$HOME/.local/share/csi-spl/cloud/prd/m3-e2e/e2e/results.json`.

## 3. Hosts used (measured before the runs, 2026-09-19 13:4xZ)

`spool-hub.ai`, `api.spool-hub.ai`, `t1.spool-hub.ai`, `e2e.spool-hub.ai` and `www.spool-hub.ai` all
resolved to `34.54.10.95`, and each answered `/version` with the same hub (`0.1.6`). The harness used:

- hub / tenant API: `https://e2e.spool-hub.ai` (`/v1/ws`, `/v1/wui/ws`, `/v1/view/*`, `/v1/pins`)
- auth: `https://spool-hub.ai/api/v1/auth/*` (register, email/verify, login, session). The apex serves
  the hub API directly, and the session cookie is `Domain=spool-hub.ai`.

Neither CLE-3382 (Cloud Run domain mappings) nor CLE-3354 (apex to Firebase) had moved these hosts
when the runs happened. After either move, measure the hosts again before the next run.

## 4. Results

The ids are from run 1. Run 2 gave the same verdict on every step, with fresh ids.

| step | what | result | evidence (run 1) |
|---|---|---|---|
| T | test tenant `e2e` created (`do_spl_tenant_create`, DRY_RUN=0, as the prd SA through the Cloud SQL proxy) | PASS | `created tenant e2e url=https://e2e.spool-hub.ai`; before this, `e2e.spool-hub.ai/v1/view/threads` → `404 unknown_tenant`, and afterwards `401 view_door` |
| 0 | two boxes on this machine (`box-e2e-a` hosts `EZA-1`, `box-e2e-b` hosts `EZB-1`), pinned by the e2e root key; the hub's `box-wui` key pinned in e2e | PASS | roster `{box-e2e-a:[EZA-1], box-e2e-b:[EZB-1]}`; `/v1/wui/pubkey` `dispatch:true`, pubkey `7ginIASz…ZV0=` (the Secret Manager key, 014 T022); box-b's local `box-wui` pin == hub |
| a | box-a → box-b `spool send` (005 SC-001) | PASS | msg `88d16784…` task `341732f6…` `delivery:queued` → box-b `hub-sync` `delivered:1`; `/v1/view/threads` lists it, 1 message, delivery `sent` |
| h0 | native sign-up through a REAL mailbox (015 on prd) | PASS | `register` 202 (no debug token). After 2.4 s the mail was in the relay mailbox, From `"SPOOL-HUB.AI NO-REPLY" <sys@csitea.net>`, subject "Confirm your email for spool", Message-ID `<6aae9332.5714e0c1.24e621.5523@mx.google.com>`. The hub's `POST /api/v1/auth/email/verify` with its token → `204` |
| h0-wui | the mail's link page `https://spool-hub.ai/verify-email` | **PENDING** (recorded, not gated) | `GET` → `404 text/plain`: the apex serves the hub, not the WUI. The token was consumed through the hub API instead. This step passes once CLE-3354 moves the apex to Firebase |
| h | member human signs in to e2e | PASS | invite `role:owner status:invited` (prd SA, `spool hub-invite`) before any tenant sign-in; login → session `200` `p:password` `t:e2e` `hum:HUM-1`; `/v1/wui/ws` `welcome.as` = `HUM-1` |
| b1 | #lobby ambient note reaches no box | PASS | msg `eed78436…`: the only `deliveries` row is `box-wui`, not in EZB-1's inbox |
| b2 | #lobby leading `@EZB-1` mention reaches the box | PASS | msg `ff9c3c96…` ack `to_box:box-e2e-b delivery:sent`, in EZB-1's inbox `from:HUM-1` |
| c1 | `kind=task` to `EZB-1` is box-wui SIGNED and verified by the box | PASS | msg `07d11a8d…` task `9c25562e…`: stored env `from_box:box-wui to_box:box-e2e-b`, sig 88 chars; box-b's `spool hub-run` wrote it (it writes only after `Envelope.Verify` against its local `box-wui` pin). Cloud SQL row (`ENV=prd TENANT_ID=e2e MSG_ID=07d11a8d-… ./run -a do_spl_db_message_show`): `from_box:box-wui from_id:HUM-1 to_box:box-e2e-b to_id:EZB-1 kind:task channel:lobby`, delivery `sent` 13:51:09.28Z |
| c2 | the agent's `kind=result` reaches the WUI thread | PASS | msg `56e59942…` `delivery:sent`; the browser socket got the `message` frame; thread kinds `[task, result]` |
| d1 | DM (no channel) human ↔ agent | PASS | task `c6144704…`: human → EZB-1 `sent`, reply EZB-1 → HUM-1 on the socket; `/v1/view/threads?dm=true&peer=EZB-1` row `channel:null`, 2 messages, participants `EZB-1@box-e2e-b`, `HUM-1@box-wui` |
| d2 | presence follows the box session | PASS | `EZB-1@box-e2e-b` `online` when `hub-run` connected, `offline` after SIGTERM |
| e1 | CONTROL: forged / unsigned envelopes are refused by the box | PASS | local fake hub → clone of box-b running the real `spool hub-sync`: tampered body, `sig:""`, new msg_id → each **exit 78** "signature verification failed", nothing written; the genuine copy → exit 0, 1 written (the control's control) |
| e2 | CONTROL: a non-member human is refused | PASS | outsider (native, verified through its own mail `<6aae9357.46be2493.25bdf7.680e@mx.google.com>`, verify `204`): login with `tenant=e2e` → `403 not_allowed`; tenant-less login `200`; its session's `/v1/wui/ws` upgrade → `401 view_door` |
| e3 | CONTROL: anonymous read → the view door | PASS | anonymous `GET /v1/view/threads` → `401 view_door`; the non-member's session → `401 view_door` (prd door `session`) |

Run 2 (13:51:50Z) PASSed every step, with sc001 task `12db8d5f…`, task thread `fcf4eae8…` and DM
thread `ffc408e7…`. It re-pinned the two box keys (`--force`), signed in with the stored password,
and sent no new mail.

## 5. Observations

- **OBS-1 (same as dev)**: a mid-body `@EZB-1` from a human is not routed (msg `1b472404…`). FR-006
  dispatches only on a leading mention. Whether that should change is a product question for the owner.
- **OBS-2 WUI verify link pending**: see h0-wui above. The mail points at
  `https://spool-hub.ai/verify-email`, and that host serves the hub (404). This is closed by
  CLE-3354 (apex → Firebase). No browser leg ran on prd: the human legs used the scripted
  browser client, as on dev (OBS-3 there).
- **OBS-3 accounts left in the auth store**: the two plus-address credentials (member `HUM-1` of
  e2e, owner; outsider with no membership) stay, so re-runs can sign in. They are Csitea's own
  relay aliases.

## 6. The test tenant stays (documented)

- tenant id `e2e`, URL `https://e2e.spool-hub.ai`, `billing_status=manual`, created 2026-09-19T13:50:17Z
- root key record: `/var/csi/csi-spl/tenants/prd/e2e.20260919T134958Z.json` (0600, dir 0700, box
  user). Its fields are `tenant`, `url`, `root_pubkey`, `root_private_key` and `billing_status`
- state (box keys, passwords, cookie, results): `$HOME/.local/share/csi-spl/cloud/prd/m3-e2e/e2e/`
  (dir 0700, secret files 0600)
- **how to delete**: no named action removes a tenant today (the checked trees and cmd/spool have
  none). Every direct foreign key to `tenants` cascades: `grep -h "REFERENCES tenants"
  csi-spl-rdb/src/sql/postgres/spool-hub/*.sql | grep -c CASCADE` → 7 (boxes, pins, messages,
  channels, payment_checkouts, tenant_memberships, tenant_invites), and the same grep with
  `grep -vc CASCADE` → 0. So the core of a removal is `DELETE FROM tenants WHERE tenant_id = 'e2e'`.
  I have not checked that the second-level tables (roster, deliveries, pins_history,
  channel_subscriptions) follow through their own foreign keys; the action has to prove that. Under
  the no-ad-hoc rule the delete first becomes a named action (for example `do_spl_tenant_delete`,
  refusing `t1`) and needs the owner's go. Then remove the key JSON and the state dir. The two plus-address credentials are not tenant-scoped and
  would stay.

<!-- last-edit: 2026-09-19T14:05:00Z -->
