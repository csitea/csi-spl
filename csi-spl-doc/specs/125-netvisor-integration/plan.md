# Plan: Netvisor integration (125)

**Spec**: [spec.md](spec.md) v0.3 · **Issue**: SPL-4812 (this plan), build
rows under epic SPL-2380 · **Base**: `origin/master` `504cafd15`
(2026-11-04)

Plan only: nothing here is built by this lane.

---

## 1. Where it stands (read 2026-11-04)

What `csitea/csi-spl` already holds, by `git log origin/master --grep=SPL-<n>`:

| row | what | commit | status |
|---|---|---|---|
| B4 | hub tables, `FORCE ROW LEVEL SECURITY` (rdb `0255`) | `7dd357744` (SPL-4721) | on `master` |
| B5 | hub routes; the `csitea` workspace from cnf (`SPOOL_HUB_NETVISOR_WORKSPACE`) | `ea47ad1e4` (SPL-4732), `3ae72a734` (SPL-4742) | on `master` |
| B7 | Reporting -> Finance screen | `c94bbc7ae` (SPL-4741) | on `master` |
| B8 | one-person Qto lock (rdb `0256`) | `0d0c3e5f3` (SPL-4723) | on `master` |
| D2 | every person of `csitea` reads; agents never (rdb `0260`) | `b335ce3db`, `1842893c6` (SPL-4792) | on `master` |

Not checked by this lane: the private `csitea/csi-int-nvs` rows (B1, B2,
B3, B6, B9's fetch part); the spec records their baseline `837fe08`
(section 2.1). Whether each `master` commit above is served on dev and prd
was not checked either.

## 2. Phases, in the owner's order (D4)

| phase | report the owner gets | rows | repo | gate |
|---|---|---|---|---|
| 1 | month-end cash forecast | B1, B2, B6 (+ B4, B5, B7 on `master`) | `csi-int-nvs` | C-NVS-1, -2, -6 against the test company; the figure equals Netvisor's own cash-flow screen (section 3.2) |
| 2 | card costs by vendor and type, every card | B3, B3b | `csi-int-nvs`, `csi-spl` | C-NVS-3, C-NVS-12 |
| 3 | monthly P&L (Qto document) | B11, B9 (P&L part) | `csi-spl`, `csi-int-nvs` | C-NVS-11, C-NVS-9 |
| 4 | balance sheet (Qto document) | B9 (balance-sheet part) | `csi-int-nvs`, `csi-spl` | C-NVS-9 |
| 5 | open invoice lists | B10 | both | the B10 order check |
| 6 | production | P1..P6 (spec section 9), after the owner's steps (spec section 10) | main box | P6: the prd figure equals Netvisor's own screen |

Every phase is proven on the Netvisor test company before the next phase's
production use (owner order, spec 1.1). Phases 2..5 may be BUILT in
parallel with phase 1; they SHIP to the owner in this order.

## 3. Design per new row

### 3.1 B3b, the spec-123 check (D12, spec 4.2 item 3)

1. rdb `<next>_netvisor_cost_dedup.sql`: `netvisor_card_cost_lines.recorded_in
   text NULL CHECK (recorded_in IN ('csitea', 'spool-hub'))`;
   `netvisor_settings.vendor_map jsonb` and `dedup_tolerance numeric NOT
   NULL DEFAULT 0`.
2. `netvisor_cost_recorded_in(tenant, vendor_key, month, amount, currency)
   RETURNS text`, `SECURITY DEFINER`, owner the migration role, `search_path`
   pinned; reads `cost_lines` (`csitea`, `t1`, estate), `cost_entries` and
   `fleet_token_paid_items`; returns only the label.
3. Hub ingest (`internal/hub/netvisor.go`): calls it per line, sets
   `excluded` and `recorded_in`; the forecast is not touched (a payment is
   still a payment).
4. WUI: the "already in Costs (`<workspace>`)" and "check: vendor also in
   Costs" marks; i18n keys reviewed by `agy`.

### 3.2 B11, Qto `persons` mode (D3, spec 5.3)

1. rdb `<next>_workspace_doc_persons.sql`: `workspace_doc.restricted_to`
   `text NULL CHECK (restricted_to IN ('persons'))`; RESTRICTIVE policies on
   `workspace_doc`, `_item`, `_node`, `_rev_log` passing a `persons` row only
   when the statement carries a person (the `0260` `netvisor_person_seat()`
   test, generalised to a doc function so the doc read never opens finance
   rows, as `0256` keeps `app.doc_human_id` apart from `app.human_id`).
2. Store and hub: every read, tree, search (`0227`) and export path; the
   create route lets a person set the mode.
3. Tests: C-NVS-11, plus `TestRLSCoversEveryTenantTable` stays green.

## 4. Risks

- The vendor map is data the owner (or a person of `csitea`) keeps; an
  unmapped vendor is never matched, so a missing entry double-counts. The
  screen lists unmapped vendors that share a month and amount with a
  spec-123 row as "check".
- A credit card booked only as a monthly settlement gives one line per card
  (spec 4.3); the per-vendor slice is empty for it until the accountants
  book per line.
- B9 before B11 would put the figures where agent seats read: B9's gate
  refuses any document not in `persons` mode.
