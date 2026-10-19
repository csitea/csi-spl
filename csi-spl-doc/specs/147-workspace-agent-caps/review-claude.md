# 147 review (claude): per-workspace agent caps by kind

Reviewer: c-864 (claude, R7 reviewer seat), independent of the author
(a-799). Reviewed `spec.md` v1.0.0 (8d439404c + af7f6b039) against the code
on `origin/master` @ `683348fd9`. Read-only: no hub, dev or prd was touched;
nothing ran but `grep`, `sed`, `ls` and `git` on that tree. n below is the
number of lines, files or call sites the command printed.

## 1. Verdict

The idea is right and the hub gate is the right place: every roster write in
the hub goes through ONE store method, so a cap there cannot be bypassed from
a box. But the spec as written would not build cleanly: the migration number
is taken, about half of the section 2 file:line citations are wrong, the
"live" count has two definitions that disagree, two host gates target the
wrong code, and the build rows leave the hub WebSocket file with no owner.

| section | verdict |
|---|---|
| 0 Owner request, P1-P7 | agree with changes (P7 "immediately" is not what the code does, 3.1) |
| 1 Glossary | agree with changes (the live definition, 2.4) |
| 2 Audit of seating paths | agree with changes (wrong refs, 2.1; the hub side is right) |
| 3 Migration sketch | agree with changes (0209 is taken, 2.2) |
| 4 Live count | disagree as written (2.4) |
| 5 Enforcement | agree with changes for 5.1-5.2, disagree with 5.3-5.4 (2.5) |
| 6 API routes | agree with changes (2.6) |
| 7 WUI | agree with changes (a file that does not exist, 2.7) |
| 8 Acceptance case | agree with changes (2.8) |
| 9 FR matrix | agree |
| 10 Tests and controls | agree with changes (2.9) |
| 11 Build rows | disagree (2.10) |

Totals over 12 sections: **1 agree, 9 agree with changes, 2 disagree**
(section 5 counted as agree with changes; its 5.3 and 5.4 parts are a
disagreement inside it).

## 2. Per section, with the check

### 2.1 Section 2: the audit

**The hub side is right and complete.** Every roster write is `SetRoster`:

- `grep -rn "INTO roster\|UPDATE roster" csi-spl-api csi-spl-rdb --include=*.go --include=*.sql | grep -v _test`
  -> n=2: `store/postgres.go:356` (the insert in `SetRoster`) and
  `store/agent_run.go:95` (`UPDATE roster ... SET running`, no new rows).
- `grep -rn "SetRoster(" csi-spl-api/src/go --include=*.go | grep -v _test | grep -v internal/store/`
  -> n=3, all in `hub/ws.go`: 485 (`onAnnounce`), 518 and 538 (`seatRoster`).
- `SetRoster` is `store/postgres.go:335` with `botSeatGate` called at 337;
  `botSeatGate` is `store/seats_postgres.go:27`; `seatSession` is `ws.go:322`
  with `seatRoster` at 333 and `SetSubscriptions` at 339; `onAnnounce` 475;
  `seatRoster` 517; `operatorActor` `operator_workspaces.go:83`. All as the
  spec says (`grep -n` on each).

So a gate in `SetRoster` covers the WebSocket hello and the announce, the
only ways an agent id reaches a workspace's roster. Everything on the host
(spec 2.1, 2.3) only decides what a box *asks* to announce.

**Wrong citations** (each is the command output on 683348fd9):

| spec says | origin/master |
|---|---|
| `do_spl_desk_up_all` `spl-desk-up.func.sh:317-360`, `_tenants` 372-405, `_boxes` 416-452 | own files: `spl-desk-up-all.func.sh:80`, `spl-desk-up-tenants.func.sh:27`, `spl-desk-up-boxes.func.sh:32` (`grep -rn "^do_spl_desk_up[a-z_]*()" csi-spl-orc/src/bash/run/` -> n=4) |
| `desk-reconcile-cron.sh:36-40` calls the three | one call, line 374, `do_spl_desk_up_all` |
| `spool-agent.sh:268` calls `do_spl_desk_up` | no call: `grep -n desk_up` prints comments at 12, 130, 239 only |
| `0001_initial.sql:40-48` roster | `0001_hub_core.sql:47`; its id CHECK was replaced in `0155_mistral_kind.sql:26-27` |
| `0119_agent_join_tokens.sql` creates `box_join_tokens` | it creates `agent_join_tokens` (line 29); `grep -n box_join_tokens` on the rdb dir -> n=0 |
| `0115_operator_audit.sql` | the table is in `0115_operator_workspaces.sql:37` |
| `do_spl_take` "queries lane mix, resolves vendor, calls spawn-window.sh" | it posts the take line (its header; 104 lines); `grep -n "spawn-window\|lane.mix"` -> n=0 |
| `agent-claims.tsv` (spec 4.1 item 3) | `grep -rn agent-claims csi-spl-orc csi-spl-api` -> n=0; a claim is the spool dir `$SPOOL_ROOT/<id>/` (`sw_release_claim`, `spawn-window.sh:389`) |
| `dedicated_agents` table (spec 2.4, 4.1 item 2) | `grep -rln dedicated_agents csi-spl-rdb csi-spl-api` -> n=0; spec 144 is `Planned (Spec Only)` |
| `TenantSettingsDialog.vue` (spec 7.2) | does not exist; the Agents tab is `csi-spl-wui/src/pages/tenant-settings/agents.vue` |

`spl-channel-agent-add-op.func.sh` is correctly not a seating path: its
header says "Each agent must be on the tenant roster ... (else FATAL
not_a_member)", so it never adds a live agent. Say that in section 2 instead
of listing it among the paths.

### 2.2 Section 3: the migration

- **0209 is taken**: `ls csi-spl-rdb/src/sql/postgres/spool-hub/ | sort | tail -1`
  -> `0209_human_rail_order_reporting.sql` (2835ff381, SPL-2587, landed the
  same day). Do not fix a number in the spec: write `<next>` and let R1 take
  it at its last rebase (the fleet lost a migration number to a race 3 times
  before).
- Use the house form of the newest migrations (`0208_spec_sync_map.sql`):
  `text` not `varchar`, `SET LOCAL lock_timeout = '5s'`, the `DEPLOY ORDER`
  note.
- `idx_tenant_agent_caps_lookup (tenant_id)` repeats the leading column of
  the primary key `(tenant_id, vendor)`. Drop it.
- The RLS shape is right for P2/P3: the tenant policy is `FOR SELECT` only
  and the operator policy `FOR ALL`, so a write inside `inTenant` fails
  closed. Keep it; it is stricter than `0208`, whose tenant policy has a
  `WITH CHECK`. Say in the spec that this is deliberate.
- P4 says "`max_live = NULL` / absent row"; the column is `NOT NULL`. Say
  "absent row only"; `0` then means "none allowed", which an admin may set.

### 2.3 Concurrency (agree, add one sentence)

Two boxes announcing at once cannot both take the last seat, but only
because `botSeatGate` runs first: it takes
`SELECT seats_bots FROM tenants WHERE tenant_id = $1 FOR NO KEY UPDATE`
(`seats_postgres.go:29`) before it returns, also when the cap is 0. A
`vendorCapGate` after it in the same transaction is serialised by that lock.
Write the dependency into 5.1, so nobody moves the new gate first or drops
the lock while M4 is off.

### 2.4 Section 4: the live count (disagree as written)

1. **Two definitions.** 4.1 counts roster rows of boxes with
   `last_hello_at` within 60 s, plus dedicated agents, plus spawn claims;
   5.1 steps 2-4 count the whole tenant roster with no freshness. They give
   different answers for a dead box. Pick one.
2. **Items 2 and 3 cannot be in a hub query today.** `dedicated_agents` does
   not exist (2.1) and a spawn claim is a directory on a box the hub never
   sees. Define live = the roster count; add spec 144's reservations when
   144 lands, as a named follow-up.
3. **Freshness**: if 4.1 is kept, use the hub's own TTL, not a literal 60 s:
   `presenceTTL()` = 2 x `presenceEvery` (`hub/presence.go:36`, default
   30 s). `botSeatGate` counts the roster with no freshness today
   (`seats_postgres.go:38`), so the two gates would disagree on a dead box;
   say which is intended.
4. **`count(DISTINCT r.agent_id)` undercounts.** The roster key is
   `(tenant_id, box_id, agent_id)` (`0001_hub_core.sql:47`); role seats
   001-003 exist once per box (`agentid.IsRoleSeat`, `agentid.go:121`), so
   `c-001` on this box and `c-001` on PC are two agents counted as one.
   Count `(box_id, agent_id)` pairs.
5. **Use `agentid.Kind`, not the `LIKE` list.** `Kind` (`agentid.go:102`)
   maps both grammars from one table (`kinds`, `legacyKinds`, lines 63-64)
   and strips `@box`; a second list in SQL drifts from it. 5.1 step 4
   already says `Kind`; make 4.1 say the same.

### 2.5 Section 5: enforcement

- **5.1 agree with changes.** Name the memory store too:
  `store/memory.go:272` has its own `SetRoster`, and the hub tests run on
  it. Define `ErrVendorCapExceeded` next to `ErrSeatQuota` in the store
  package. The 409 in `onAnnounce` fails the whole frame, so a box that
  announces one over-cap agent and one legitimate new one seats neither;
  the bot seat cap works that way today (`ws.go:485-487`), so accept it, but
  say so.
- **Say the hub gate is the authority and the host checks are courtesy.** A
  box announces the directories in its desk spool (`hubclient/agent_drop.go:40`,
  `rosterAgents` -> `scanAgents`), so a `mkdir` there skips
  `do_spl_desk_up` and any check in it.
- **5.2 agree with changes**: the host check needs a read the box can make;
  name the call (the 6.2 route with the desk's own credentials) and its file.
- **5.3 disagree.** `LANE_TENANT` is not the workspace a lane works for: it
  is the tenant that holds the lane map (`spl-lane-map.func.sh:84`,
  `LANE_TENANT="${LANE_TENANT:-${LEASE_TENANT:-}}"`). Gating on it would cap
  the fleet's own tenant. A spawn does not seat into a customer workspace; a
  desk does. Drop 5.3, or give the spawn an explicit target-workspace
  variable. `spool hub-caps` does not exist and no row builds it. Exit 14 is
  free in `spawn-window.sh` (`grep -n "exit 14"` -> n=0; it uses 4, 10-13).
- **5.4 disagree**: `do_spl_take` picks no vendor (2.1). The vendor pick is
  `do_spl_lane_mix` and the box pick `do_spl_box_pick` (`pick=hold`,
  `spl-box-pick.func.sh:194`). Move the fail-over there, or drop it until a
  customer workspace spawns lanes.

### 2.6 Section 6: API (agree with changes)

- The operator routes fit the house set (`operator_workspaces.go:541-547`:
  `GET/POST/PATCH/DELETE /v1/operator/workspaces[/{id}]` plus `OPTIONS`
  preflights). Add the `OPTIONS` route for the new path, and register it in
  `hub/operator.go:272`, where `routeOperatorWorkspaces` is wired; no build
  row owns that file.
- The 403 body `operator.workspaces` matches `permOperatorAdmin`
  (`operator_workspaces.go:42`).
- 6.2 "405 or 403": pick one. Registering only `GET` makes the mux answer
  405, the cheaper and testable choice.
- 6.2 says administrators of the workspace read it; state whether a plain
  member may too (live counts are not secret, the caps may be commercial).

### 2.7 Section 7: WUI (agree with changes)

`OperatorPane.vue`, `stores/operator-pane.ts` and `utils/spool-client-lazy.mjs`
exist (`ls` -> n=3). `TenantSettingsDialog.vue` does not; use
`pages/tenant-settings/agents.vue`. `ls csi-spl-wui/i18n/locales | wc -l`
-> 19, so "en.json (and all 19 locales)" is 19 files, en included. The
strings in 7.1-7.2 ship as keys (developer guide 2.4) and get the agy
language review before they ship.

### 2.8 Section 8: acceptance (agree with changes)

- The commands are written `do_spl_desk_up TENANT_ID=example-ws ...`; the
  action takes env first:
  `TENANT_ID=example-ws DESK_AGENT=c-005 DRY_RUN=0 ./run -a do_spl_desk_up`.
- Step 11 "drops to 0" on `/exit-clean` is not immediate, see 3.1.

### 2.9 Section 10: tests (agree with changes)

C1-C3 are real red controls. Add two:
- **C4, stale box**: cap 1, an agent on a box whose last hello is older than
  the TTL; a new agent on a live box seats (if freshness is kept), and is
  refused when the freshness filter is removed.
- **C5, the race**: two `SetRoster` calls in parallel transactions for the
  last seat, from two boxes; exactly one succeeds. Red control: the gate
  placed before `botSeatGate` (no lock) lets both through. Runs on Postgres
  (`PRE_PUSH_TIER=full`).

### 2.10 Section 11: build rows (disagree)

The six listed file sets are disjoint from each other, but they do not cover
the change, so the real rows would collide or leave work unowned:

| file the change needs | row |
|---|---|
| `internal/store/postgres.go` (`SetRoster` calls the gate) | none |
| `internal/store/memory.go` (`SetRoster`, line 272) | none |
| `internal/hub/ws.go` (`onAnnounce` 409, `seatRoster` trim) | none: FR-004/FR-005 have no row |
| `internal/hub/operator.go` (route registration, line 272) | none |
| the `spool hub-caps` subcommand under `cmd/spool/` | none |
| `pages/tenant-settings/agents.vue` | none (R5 names a file that does not exist) |
| `spl-take.func.sh` | R4, but the wrong file (2.5) |

Also: R6 adds a new e2e file; a new file under `csi-spl-wui/tests/e2e/`
changes the shard spread and reds its control, so extend an existing e2e
file. `csi-spl-api/src/bash/tests/` names tests `*.tst.sh`
(`ls ... | grep -c "^test-"` -> 0), not `test-*.sh`. Put `ws.go` and both
store files in R1 (one lane owns the gate end to end) and the registration
in R2.

## 3. What the spec missed (2)

### 3.1 Release on exit is up to an hour late on a customer desk

P7 and AC-06 say a retired agent's seat is released "immediately". A box
announces every directory in its desk spool (`rosterAgents`), and a customer
desk keeps its directories: `do_spl_desk_up_tenants` runs with
`DESK_RETIRE=0 (a customer desk keeps its dirs)` (its header). An exited
agent then leaves the roster only through `dropDead`
(`hubclient/agent_drop.go:70`), after `SPOOL_AGENT_DROP_AFTER`, which is cnf
`env.box.agent_drop_after_minutes: 60` (`csi-spl-cnf/csi-spl/all.env.yaml:1003`);
empty or 0 means never (`ParseDropAfter`, same file). And `dropDead` does
nothing without the fleet tick's run report (`if c.DropAfter <= 0 || run == nil`),
which a workspace-owned box (spec 108) may not have; I believe, unchecked,
that such a box has none. So with a cap of 1 the workspace waits up to 60
minutes, or for ever, for the seat of an agent that already exited. The
spec needs an explicit release (the retire path removes that one agent's
desk dir, or the box stops announcing it), and AC-06 must measure the time
to release.

### 3.2 Whose agents count against the workspace's cap

The spec counts every non-human roster row of the workspace. The fleet seats
its own agents there too: `do_spl_desk_up_all` seats "a DO seat
c-001..c-003, an orchestrator or dispatcher id of lease.conf, an id in
DESK_SEAT" (its header), and `do_spl_desk_up_tenants` runs it for every
tenant dir on the box. If a fleet dispatcher holds a desk in `example-ws`, it
takes the workspace's one claude seat. The spec must say whether role seats
(`agentid.IsRoleSeat`) and the operator's own agents count, and test it.
Related, unchecked: `seatSession` passes `f.Agents`, the full announced list,
to `SetSubscriptions` (`ws.go:339`), not the trimmed `agents`, so an agent
refused a roster seat still gets channel subscriptions. Check whether
anything routes to a subscribed agent that is not on the roster before
relying on the trim alone.
