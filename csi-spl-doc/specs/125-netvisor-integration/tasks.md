# Spec 125 tasks: Netvisor integration, in the owner's order

Issue SPL-4812 (this list), epic SPL-2380 ([plan.md](plan.md) header); [spec.md](spec.md) v0.4,
[plan.md](plan.md). Each row is one lane and one commit series, tests red
first, proven on the Netvisor test company. Rows in `csitea/csi-spl` land on
`master` and are done when served on dev AND prd; store rows run
`PRE_PUSH_TIER=full`. Data rule: every row is `claude`, `grok` or `mistral`
(spec header); a row that reads the keys runs on the main box.

## 1. Report 1: month-end cash forecast (D4: first)

| row | spec row | what | repo | test |
|---|---|---|---|---|
| T1 | B1 | XML parsers + sequential test-company probes for the forecast resources | `csi-int-nvs` | C-NVS-1 |
| T2 | B2 | `do_nvs_cash_forecast --env test`, route C, due date assumed (D7) | `csi-int-nvs` | C-NVS-2 |
| T3 | B6 | `do_nvs_sync --env test`, nightly cron + "Refresh now" poller (D6) | `csi-int-nvs` | C-NVS-6 |
| T3a | B4, B5, B7 | already on `master` ([plan.md](plan.md) section 1); this row is the end-to-end proof: a person of `csitea` reads the test-company forecast on dev, an agent seat reads 403 | `csi-spl` | C-NVS-5b, C-NVS-7 |

## 2. Report 2: card costs (D4: second)

| row | spec row | what | repo | test |
|---|---|---|---|---|
| T4 | B3 | `do_nvs_card_costs --env test`: debit lines, credit-card e-invoice rows, settlement-only cards as one line, settlement bill of a per-line card left out by its card liability account, a setting (main-box file or a `netvisor_settings` column; spec 4.3, accountant Q4) | `csi-int-nvs` | C-NVS-3 |
| T5 | B3b | the spec-123 check in both workspaces (spec 4.2 item 3, [plan.md](plan.md) 3.1) | `csi-spl` | C-NVS-12 |

## 3. Reports 3 and 4: P&L, then balance sheet (Qto)

| row | spec row | what | repo | test |
|---|---|---|---|---|
| T6 | B11 | Qto `persons` mode ([plan.md](plan.md) 3.2) | `csi-spl` | C-NVS-11 |
| T7 | B9 | monthly P&L into a `persons` Qto document | `csi-int-nvs` + `csi-spl` | C-NVS-9 |
| T8 | B9 | balance sheet into a `persons` Qto document | `csi-int-nvs` + `csi-spl` | C-NVS-9 |

## 4. Report 5: open invoice lists

| row | spec row | what | repo | test |
|---|---|---|---|---|
| T9 | B10 | open sales and purchase invoices with the overdue split; the five reports in D4's order on the Finance screen | both | B10 order check |

## 5. Production (after the owner's steps, spec section 10)

| row | spec row | what | who |
|---|---|---|---|
| T10 | P1..P5 | the owner's steps 1..5 | owner |
| T11 | P6 | first `--env prd` run on the main box, compared with Netvisor's own screen; then the nightly prd schedule | main-box lane, owner's go |

## 6. Dependencies

T1 -> T2 -> T3 -> T3a; T1 -> T4 -> T5; T6 -> T7 -> T8; T3 + T8 -> T9;
every T row before T11. T4, T5 and T6 may start in parallel with T2.

## 7. The monthly personnel cost (spec section 11, `SPL-6409`, `csitea` `CSI-102`)

Private repo, kind `secret`: `claude` main, `grok` backup.

| row | spec row | what | repo | test |
|---|---|---|---|---|
| T12 | N1 (B12) | parsers for payroll batches and the personnel ledger accounts, test company | `csi-int-nvs` | spec 11.5 N1 |
| T13 | N2 (B13) | `do_nvs_payroll_month --env test`: ledger split by payroll, posted to F3 on dev, idempotent | `csi-int-nvs` | spec 11.5 N2 |
| T14 | N3 (B14) | nightly days 1 to 5 + the no-figure notice to `ba50f507` | `csi-int-nvs` | spec 11.5 N3 |
| T15 | N4 (P7) | the last closed month in production, after `CSI-63` and the owner's go | main-box lane | spec 11.4 acceptance |

## 8. The generic finance connector in csi-spl (spec section 11.8, owner answer B `8ab39b9d`)

`claude` main, `grok` backup (finance schema; never `mistral`).

| row | spec row | what | repo | test |
|---|---|---|---|---|
| T16 | F1 | provider-neutral `finance_*` tables, no bookkeeping account column | `csi-spl` | F1 |
| T17 | F2 | store, wire, hub and routes on them; cnf `SPOOL_HUB_FINANCE_WORKSPACE` | `csi-spl` | F2 |
| T18 | F3 | the payroll door into spec 123 `hr` lines | `csi-spl` | F3 |
| T19 | F4 | Reporting -> Finance without the provider name, the account form removed | `csi-spl` | F4 |
| T20 | F5 | drop the old tables and routes, the docs moved, the name in the hygiene sweep | `csi-spl` | F5 |

T12 may start now. T16 -> T17 -> T18 -> T13 -> T14 -> T15; T17 -> T19 ->
T20; T20 after the private sync posts to the new routes.
