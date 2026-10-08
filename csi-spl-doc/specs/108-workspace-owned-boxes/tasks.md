# 108 workspace-owned boxes: tasks

Authority for what is built (`spec.md` holds the behaviour; this file follows
its section 5). Each task names its layer, its dependency, the files it owns
and a Done line with its test pair from `spec.md` section 4 and that pair's n
as section 4 states it. Status vocabulary: `../README.md` item 3 (`[x]`
Implemented, `[~]` Partial / in progress in a live lane, `[ ]` Planned).

Owner questions 1-3 (`spec.md` section 7) are not answered yet. These tasks
build the spec's current text: Q1 one machine = one workspace (3.5), Q2 the
multi-workspace desk (`spl-desk-up-tenants.func.sh`) stays operator-only, Q3
queued deliveries at revoke are held for the admin. A later answer changes
only the tasks that name that question.

"workspace" in prose; `tenant_id` only where the code says so. Go paths are
under `csi-spl-api/src/go/spool-hub-api/`. Files marked *new* do not exist
yet; a migration takes the next free prefix at commit time.

## 1. First need: enrol ONE new box that no other box or workspace can see

Owner HUM-10, topic 65f75266 (msg e6d677d4). T001..T009 are that path; T009
is the milestone that proves it.

- [x] T001 **doc** (c-549): this file. Doc only; `spec.md` is not edited here.
- [~] T002 **hub**, = 073 T003, wave 1 IN PROGRESS (after 073 T002, done):
      join-token store methods, the five routes of 073 spec 4.3,
      `wire.JoinPayload`, `config.Hub.JoinTokenTTL` and the cnf key. Files:
      `internal/hub`, `internal/store`, `internal/wire`, `internal/config`,
      `csi-spl-cnf/csi-spl/all.env.yaml`. Done: as 073 T003 (073 AC1-AC7,
      AC10, AC12 on postgres).
- [ ] T003 **CLI**, = 073 T004 (after T002): `spool join`; the box generates
      its own key and the hub pins the public half, never minting a private
      key (spec 3.1). Files: `cmd/spool`, `internal/action`. Done: as 073
      T004 (a CLI test against a test hub seats a box with no root key).
- [ ] T004 **orc**, = 073 T005 (after T003): `do_spl_desk_pin` join mode.
      Files: `csi-spl-orc/src/bash/run/spl-desk-pin.func.sh`,
      `csi-spl-orc/src/bash/tests/desk-pin.tst.sh`. Done: as 073 T005
      (hermetic suite seats via a stub `spool join`).
- [~] T005 **orc**, 108 box-side isolation, wave 1 IN PROGRESS (no
      dependency): spec 3.5. One box = one workspace, refused in
      `do_spl_desk_up`; per-workspace OS user, spool root and state dir (Q1).
      Files: the `csi-spl-orc` desk/box runtime that lane holds
      (`spl-desk-up.func.sh` and its tests). Done: pair (d) EACCES, n=4:
      the per-workspace OS user cannot read another workspace's spool root;
      control: its own root stays readable.
- [x] T006 **rdb** (no dependency): unique index on live `pins(pubkey)` (19342d073)
      (`revoked_at IS NULL`), exempting `box-wui` (spec 3.2). Files:
      `csi-spl-rdb/src/sql/postgres/spool-hub/<next>_pins_pubkey_unique.sql`
      *new*. Done: migration lint and postgres store tests green; pair (c)
      is proven in T007.
- [ ] T007 **hub** (after T006 and T002): pin and join seat answer
      `pin_conflict` for a key already live in another workspace, never
      naming that workspace; a box pinned in one workspace is refused a pin
      in a second (spec 3.5 "at pin"). Files: `internal/store/postgres.go`,
      `internal/store/memory.go`, the pin route in `internal/hub/rest.go`,
      `internal/hub/pin_conflict_test.go` *new*. Done: pair (c) same key
      pinned, n=3: the same key cannot be pinned into a second workspace;
      control: a unique key pins. Postgres
      (`PRE_PUSH_TIER=full ./run -a do_check_pre_push`).
- [x] T008 (4a243524b) **hub**, tests only (no dependency; `inTenant` runs are built,
      spec 5 step 2): the session-pinning pairs. Files, all *new*, beside
      the existing `internal/hub/crosstenant_test.go` (not edited here):
      `internal/hub/tenant_header_pin_test.go`,
      `internal/store/isolation_pair_test.go`,
      `internal/hub/crosstenant_send_pair_test.go`. Done on postgres:
      pair (a) isolation, n=1 (B's `tenant_id` reads 0 rows of A's message;
      control: A reads it); pair (b) header/pin mismatch, n=2 (valid pin
      with another `X-Spool-Tenant` refused; control: matching header
      accepted); pair (e) cross-workspace send, n=5 (send to another
      workspace's recipient refused; control: same workspace delivered).
- [ ] T009 **orc + doc**, MILESTONE (after T004, T005, T007, T008): enrol
      ONE new box with a join token into a fresh workspace on dev, then prd
      (prd with the owner's go). Files: a runbook under
      `csi-spl-doc/doc/md/` *new*; no code. Done: the box is seated; pairs
      (a) and (d) pass on that box; no other box's `spool recv` and no
      other workspace's WUI shows a row, box or agent of it (n=1 per env).

## 2. After the first box

- [~] T010 **WUI**, = 073 T006 (after T002): New join token, optional
      `for_human`, open tokens list, Revoke seat, shown only with
      `agents.join`. Files: as 073 T006. Done: as 073 T006.
      **Built** db323e02b (c-563), WUI v3.6.6 on dev + prd; AC8 open
      (needs T003 `spool join` and an admin test session). Detail: 073
      tasks.md T006.
- [ ] T011 **hub + iac** (after T002): relay signed URLs (spec 3.4). The
      hub mints per-object signed URLs under a hub-chosen `<tenant_id>/`
      prefix; the relay SA key never reaches a box. Read the git-rel sources
      (`csi-spl-doc/doc/md/csi-spl.feature.md` section 4) before changing
      bucket semantics. Files: `internal/hub/relay_url.go` *new* and its
      test, a `wire` type, the iac step granting the hub SA the sign
      permission (an IAM change: owner's go). Done: pair (f) relay prefix,
      n=6: a box cannot get a URL for another workspace's prefix; control:
      its own prefix works.
- [ ] T012 **hub** (after T007): revoke path (spec 3.7). Set
      `pins.revoked_at`, close the box's session sockets, refuse reconnect,
      void its join tokens, refuse URL minting, drop upload tokens; other
      instances see it within the 5 s pin cache. Q3: queued deliveries are
      held for the admin, not purged. Files: the revoke route in
      `internal/hub/rest.go`, `internal/store/hotcache.go`,
      `internal/hub/box_revoke_test.go` *new*. Done: pair (g) revoke, n=7:
      a revoked box cannot mint tokens or connect; control: an active box
      can. Postgres.
- [ ] T013 **orc** (after T005): local leave removes the per-workspace OS
      user, spool root and state dir (the hub sends no wipe, spec 3.7).
      Files: `csi-spl-orc/src/bash/run/spl-box-leave.func.sh` and its test.
      Done: after leave the box's root is gone; control: the operator
      desk's other roots on that machine (Q2) are untouched.
- [ ] T014 **WUI** (after T010, T012): Workspace Settings -> Fleet: the
      workspace's boxes and agents, Revoke box. Files:
      `csi-spl-wui/src/pages/tenant-settings/fleet.vue` *new*,
      `csi-spl-wui/src/utils/tenant-settings-nav.mjs`. Done: typecheck +
      e2e for list and revoke; a session without `agents.join` does not see
      Revoke; pair (g) green behind it.
- [ ] T015 **doc** (after T009, T011..T014): spec status, the help page for
      enrolling a box, close the section 4 pairs in this file.

## 3. Parallel without a shared file

| wave | tasks | why they do not collide |
|---|---|---|
| now | T002 (073 T003), T005, T006, T008 | join routes / orc desk runtime / one new migration / new test files only |
| after T002 | T003, T010, T011 | CLI / WUI join-token UI / new `relay_url.go` + iac |
| after T003, T006 | T004, T007 | `spl-desk-pin.func.sh` / pin route + store |
| after T005, T007 | T012, T013 | hub revoke / `spl-box-leave.func.sh` |

Not parallel: T007 and T012 both edit `internal/hub/rest.go`, so one after
the other. T002 holds `internal/store` and `internal/hub` while it runs,
so T007 waits for it (already its dependency).

<!-- version: 0.1.0 · updated: 2026-10-08 · last-edit: 2026-10-08T13:02:54Z -->
