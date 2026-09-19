# Tasks: Spool WUI dispatch (014)

**Feature**: `specs/014-spool-wui-dispatch` · **Milestone**: M3 · **Created**: 2026-09-19

`[x]` Implemented (cited) · `[~]` Partial (missing part named) · `[ ]` Planned
(`../README.md` §2.3). Tasks owned by another lane are written here, not done
here (§2.4); the owner is named.

## Phase 1 — Spec (DISPATCH, CLE-3349)

- [ ] T001 Planned — `spec.md` (OQ-014-1..4, the 002 trust-modes amendment), `plan.md`, `contracts/wui-dispatch.md`.
- [ ] T002 Planned — 003 `contracts/wui-live-ws.md`: replace only the "not delivered to boxes" rule with a pointer to 014.

## Phase 2 — Hub + box code (DISPATCH, CLE-3349)

- [ ] T010 Planned — config: `SPOOL_HUB_WUI_DISPATCH`, `SPOOL_HUB_WUI_KEY`, `SPOOL_HUB_WUI_KEY_EPHEMERAL` with fail-fast (contract §1); `spool serve` decodes / generates the key and logs only the pubkey.
- [ ] T011 Planned — `GET /v1/wui/pubkey`; `POST /v1/pins` accepts `box-wui` only for the hub key (`wui_key_mismatch`); hello as `box-wui` refused.
- [ ] T012 Planned — dispatch: session identity, recipient resolve (to / leading mention), roster -> box, pins, admit, sign, self-verify, shared commit; `wui.go` comment no longer says "never delivered to boxes".
- [ ] T013 Planned — box side: `hubclient` receive refuses a `box-wui` envelope unless `kind ∈ {task, note}`.
- [ ] T014 Planned — tests: positive (deliveries row verifies with `wire.Envelope.Verify` against the `box-wui` pin; live box writes the inbox) + controls (tampered envelope, wrong key, unpinned `box-wui`, no session, unknown / ambiguous agent, flag off, pin mismatch, hello refused, box-side kind refusal).

## Phase 3 — Handoffs (other lanes)

- [ ] T020 Planned (HOSTING / DEPLOY, iac 029 + 030) — Secret Manager slot `csi-spl-hub-wui-key` per env + accessor for the hub runtime SA, rendered as `SPOOL_HUB_WUI_KEY` into the hub service's secret env; no version resource.
- [ ] T021 Planned (DEPLOY, cnf) — `SPOOL_HUB_WUI_DISPATCH: "true"` in dev, `"false"` in prd; dev `SPOOL_HUB_WUI_KEY_EPHEMERAL: "true"` until T020 has a version.
- [ ] T022 Planned (owner) — mint the key, add the secret versions (contract §2.1); per tenant `spool pin --box box-wui` with the root key (§2.2).
- [ ] T023 Planned (HUMANS, 010 T012/T013) — store-backed Registrar + Membership: without them no socket carries a member session, so dispatch answers `dispatch_unauthenticated` everywhere (OQ-014-2). Durable v:1 human id (OQ-014-3).

<!-- version: 0.1.0 · updated: 2026-09-19 · last-edit: 2026-09-19T06:10:00Z -->
