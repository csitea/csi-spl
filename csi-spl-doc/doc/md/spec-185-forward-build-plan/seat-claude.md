# Spec 185 forward build plan: panel seat claude (c-715)

Seat: **c-715** (claude), the cross-vendor panel seat of rulebook section
3.2 for the agy-written plan. Placement `c002-s185-fwd-build-claude-panel-seat`.
Issue: SPL-6653 (the plan's). Doc review only: no code, no edit of the plan.

## 0. Verdict

**FAIL on `c2633a2c8e5ba3e31131ad16c0380f9b9b5357fe`** (plan v0.1, branch
`review/c002-s185-fwd-build-planner`; `git ls-remote origin
refs/heads/review/c002-s185-fwd-build-planner` -> `c2633a2c8e5b...` at
2026-11-27T06:36Z). The rows, batches, vendors and the open decision are sound.
The FAIL is for five fixable defects (W1-W5): two cited lines that are not what
the plan says, a ruling id that the tree attributes to something else, a red
control with no test behind it, and two incomplete R2 test columns. Fold
W1-W5 into v1.0 and this seat expects to sign it.

The plan's base: `84f86ab8c` (its section 0). Origin/master at this read:
`31a52634691d456792fa292f537052115733fd91`. `git diff --stat origin/master...c2633a2c8`
-> 1 file, `csi-spl-doc/doc/md/spec-185-forward-build-plan.md`, 337 insertions.

## 1. The checks, each with its command and output

### 1.1 Check 1: every row of spec 185 section 6 is in the plan

Source: `git show 36d707972:csi-spl-doc/specs/185-message-forward/spec.md`,
section 6 (lines 254-262), against plan sections 2.1 and 3.

| row | in plan | spec done test | spec red control | verdict |
|---|---|---|---|---|
| F1 | 2.1 :95, 3 :111-118, 6.1 | :117 (applies twice, `\d messages`) | :118 (migration test RED before the file) | OK |
| F2 | :98, :120-137, 6.2 | :132-136 (all of the spec's cases, plus `mc_id` and `noteToSelf`) | :137 (both of the spec's, plus the `@c-001` one) | OK |
| F3 | :96, :139-155, 6.3 | :154 | :155 (the spec's two, plus widening) | OK |
| F4 | :101, :157-165, 6.4 | :164 | :165 (both of the spec's) | OK |
| F5 | :99, :167-173, 6.5 | :172, GCT in place of agy, with a stated reason (N1 of the plan, :239) | :173 (`i18n-untranslated`, as the spec) | OK |
| F6 | :100, :175-182, 6.6 | :181 (the spec's two, plus phone absence) | :182 | OK |
| F7 | :97, :184-192, 6.7 | :191 | :192, **no test behind it: W4** | W4 |

### 1.2 Check 2: every site file:line, on the base and on origin/master

**No drift to master.** For the 49 files the plan cites, `git diff --numstat
84f86ab8c 31a526346 -- <file>` printed nothing for every one, so every line
valid on the base is valid on master. One path,
`csi-spl-wui/public/help-md/...`, is MISSING. That is not a defect: the plan's
`wui:` prefix is `csi-spl-wui/src/`, and
`csi-spl-wui/src/public/help-md/message-actions-and-formatting.md` is OK.

**Lines on the base.** I checked 98 cited lines on `84f86ab8c`, each with
`git show 84f86ab8c:<file> | sed -n <N>p` against the token the plan names at
that line. Script: the `sites.tsv` loop of this session.

- 90 matched on the first pass.
- 6 of the 8 misses were my own token choices. On a second read the line holds
  what the plan says:
  - `wui_multicast.go:381` is `type mcIDKey struct{}`, and `withMcID` / `mcIDOf` follow at :384 and :392.
  - `ws.go:1140` is `McID:       mcIDOf(ctx),` (spacing).
  - `postgres.go:470`: `$26::timestamptz` is at :469, inside the cited range `:467-470`.
  - `attachment_remove.go:99` is the `s.o.Log.Info()` line.
  - `msg-menu.test.mjs:213` is `assert.deepEqual(Object.keys(en).sort(), ['add_to_note', ...`.
- The 2 real misses:
  - `help-sync.test.mjs:86-88`: **W1**.
  - `topic_loop_fire.go:217,:227`: **W2**.

Other base facts checked:

- `git show 84f86ab8c:.../spool-client.mjs | grep -n 'PUBLIC_CHANNELS ='` -> `:296 new Set(['lobby', 'alerts', 'feedback', 'public', 'issues'])` (N2).
- `git grep -c forward 84f86ab8c -- csi-spl-wui/src/utils/uiIcons.ts` -> rc 1, 0 lines: the plan's "no `forward` icon" holds.
- `msg-menu.test.mjs:51` -> `assert.deepEqual(msgMenuItems().map((i) => i.id), ['open', 'copy'])`: the plan's N4 opt-in reason holds.
- `openapi.json`, `grep -c -E '"forward_of"|"mc_id"'` -> 0: F2's "no openapi edit" holds.
- `qto-docs.tsv:57` -> `bf244c37-39b0-40c1-9567-b8ec5fd94913	csi-spl-doc/doc/help/message-actions-and-formatting.md`: OK.
- `005-spool-wui/spec.md:363-364` -> `FR-022 ... FR-021 is reserved for spec 185 F7`: OK.
- `perf-budgets.json` -> `:4 "ci_initial_gzip_kb": 155.0`, `:27 "ci_initial_gzip_kb": 151.9`: OK.
- The rdb head, `git ls-tree --name-only 84f86ab8c csi-spl-rdb/src/sql/postgres/spool-hub/ | tail -1` -> `0331_scheduled_tasks.sql`; the last claim is `refs/rdb-claims/0331`. Both OK.
- Every action the plan names exists on master (`git grep -l '^<action>()'`, one file each): `do_check_qto_doc_drift`, `do_spl_doctree_export_md`, `do_spl_lang_review_gct`, `do_check_pre_push_lang_review`, `do_rdb_migration_next`, `do_check_pre_push_e2e`, `do_spl_spec_import_issues`.
- Every R2 test file exists on the base (`git cat-file -e`), except two:
  - `tests/unit/mobile-messages.test.mjs` is MISSING. `tests/e2e/mobile-messages.test.mjs` is OK, and the plan names no dir, so this is acceptable.
  - `internal/store/file_detach_test.go` is MISSING: W5.

### 1.3 Check 3: R1 / R16, disjoint batches, order against spec section 6

- **Batch 1 (F1, F3, F7):** F1 touches `csi-spl-rdb/` plus one new `internal/store/*_migrate_test.go`. F3 touches `csi-spl-wui/src/{utils,components,types}`, `csi-spl-wui/i18n/`, and three `csi-spl-wui/tests/` files. F7 touches `csi-spl-doc/specs/005`, `003 contracts`, `doc/help` and `csi-spl-wui/src/public/help-md/`. No path in two rows: OK.
- **Batch 2 (F2, F5, F6):** F2 touches `internal/hub` and `internal/store`. F5 touches the 18 non-en locales and `i18n/lang-review/`. F6 touches `tests/e2e/msg-forward.test.mjs` and `e2e-shard-weights.txt`. No path in two rows: OK.
- **Batch 3:** F4 alone.
- **Order:** F4 after F1+F2, F5 and F6 after F3, as spec section 6 says. F2 comes later than the spec asks: the spec lets F1, F2, F3 and F7 start together, and the plan puts F2 after F1 has rolled on dev and prd (plan N2). That is stricter than the spec and safe; see N5.

### 1.4 Check 4: R3 lane map, spec 186 / 196, live WUI lanes

Command, 2026-11-27T06:37:56Z, 32 paths (the existing and the new paths of F1-F7):
`bash /opt/csi/csi-spl-desk-cron/csi-spl-orc/src/bash/features/spawn-agents/scripts/lane-map.sh --check <32 paths> --agent c-715`
-> **rc=3**:
`csi-spl-wui/src/utils/spool-client-mock.mjs owned by c-068@<box-a> c-068-rotate (changed in its worktree; no files recorded)`.
Every other path was free. The plan's 06:22Z read named `a-542` as the owner (N1).

`do_spl_spawn_queue` (06:38Z) still lists every overlap the plan orders
around: `s169-t18` 4/77, `s169-t19` 6/77, `s196-t2` 20/77, `s186-m8` 35/77,
`s179-b6` 40/77, `s190-x2` 76/77. The plan's section 4.2 guard covers all of
them:

- F2 is not placed beside `s196-t2` (`message_edit*.go`).
- F3 and F5 are not placed beside `s179-b6`, `s186-m8`, `s169-t18..19` or `s190-x2` (locales, `MessageCard.vue`, `msg-menu.mjs`, `spool-client*.mjs`).
- F6 is not placed beside `s169-t19` (shard weights).

Spec 186 M2 has landed: `wui.go:147` is `McID string \`json:"mc_id,omitempty"\``
on the base. So `wui.go` and `postgres.go` are free of spec 186 code lanes, as
the plan says. Ordered around every shared file: **yes**.

### 1.5 Check 5: vendors

- **No mistral on any row.** Plan :87 says "No row in this round may go to `mistral`", and the vendor column of 2.1 (:95-101) names claude or agy only. The help-md row F7 also says never mistral (:97, :189). OK.
- **R7 cross-vendor:** agy reviews claude rows and claude reviews agy rows (:89). OK. The waiver id is miscited: **W3**.
- **The i18n row names `do_spl_lang_review_gct`** (:169, :172, :307), with agy optional, and F3 runs it too (:151, :291). OK.

### 1.6 Check 6: open decisions

- **H1** (plan :233-235) asks the holder, and the owner by form if needed, how Forward is disabled when no topic can take it. It is open in the spec: section 4 step 1 says it is disabled, but not how the menu knows. The plan asks and does not guess: OK.
- The plan makes two choices the spec does not state: `mc_id` with `forward_of` -> `bad_json`, and skipping `isNoteToSelf`. See N4. Neither is an owner question: each follows Q6 and spec 186 section 8.1. But each must reach F7's contract, and F7 already lists `mc_id` (:191).

### 1.7 Check 7: distribution hygiene

I ran it on the plan's own tree, in a throwaway detached worktree of `c2633a2c8`
(removed afterwards):
`cd <worktree>/csi-spl-iac && ./run -a do_check_dist_hygiene`
-> **rc=0**, `INFO distribution-hygiene: clean over the tracked tree`.

## 2. Defects

- **W1, plan :70, a line that does not exist.**
  - The plan says `tests/unit/help-sync.test.mjs:86-88` "fails CI if" help-md drifts.
  - `git show 84f86ab8c:csi-spl-wui/tests/unit/help-sync.test.mjs | wc -l` -> **82**.
  - The drift check is at `:20-22` (`const drift = helpDrift()` ... `ok('src/public/help-md matches csi-spl-doc/doc/help', ...)`), and its control is at `:36-48`.
  - Fix: cite `:20-22` (and `:36-48`).
- **W2, plan :52 and :244, two functions swapped.**
  - The plan puts `topicLoopBeforeAgent` at `topic_loop_fire.go:217` and `topicLoopHuman` at `:227`.
  - On the base it is the reverse: `:217 func (s *Server) topicLoopHuman(`, `:227 func (s *Server) topicLoopBeforeAgent(`.
- **W3, plan :89, and every R7 cell of :95-101 and 6.1-6.7: the waiver is cited by the wrong ruling id.**
  - The plan says a claude waiver seat applies "per fleet ruling `dc84300a`".
  - On the tree, `git grep -n dc84300a 31a526346 -- csi-spl-doc` -> 3 lines (`bug-round-45-plan.md:171`, `-46:410`, `-47:458`), and each reads "No grok (c-001 `dc84300a`)". There the claude waiver seat is `1a7c70da` (or c-001 `77ba5669` in round 45), and so is spec 153's plan.
  - I did not read either message in the hub, so check it there. Fix: cite the waiver id the hub holds, and keep `dc84300a` for "no grok".
- **W4, plan :192 and :323, a red control with no test behind it.**
  - F7's control is "a contract check grepping §7.1.1's tokens in `wui-live-ws.md` fails RED". No such check exists, and F7's file list (:186-189, :321) creates none.
  - Spec 186 row M9 says the same of this file (`git show 31a526346:csi-spl-doc/specs/186-multicast-prompt/spec.md | sed -n 632p`): "none automatic: no test parses the fields of `wui-live-ws.md`; the reviewer re-runs the grep with one name removed and must see the count drop".
  - Fix: either name a new test file in F7's files, or write the control as M9 does: a named `grep -c -e forward_of -e forward_not_found -e forward_no_topic ...` with its expected count and a 0 on the base, re-run with one name removed.
- **W5, plan :131 and :163, R2 test columns that miss callers (rulebook 2.2: every test that names a function the row changes).**
  - F2 changes the SELECT and Scan of `GetEditable` (:129). `git grep -l GetEditable 84f86ab8c -- 'csi-spl-api/src/go/spool-hub-api/internal/*_test.go'` -> **30 files**, and F2's column names 3 of them (`edit_test.go`, `topic_archived_input_test.go`, `topic_create_prio_test.go`). Among the missing are the postgres ones: `store/channel_copy_apply_postgres_test.go`, `store/read_batch_test.go`, `store/returning_write_test.go`, `store/topic_promote_test.go`, `hub/dm_ref_test.go`, `hub/attachment_remove_test.go`.
  - F4's column names "`api:store/file_detach` tests", but `internal/store/file_detach_test.go` is MISSING on the base. `git grep -l -E 'detachEverywhere|/v1/attachments/' 84f86ab8c -- '<api>/*_test.go'` -> `hub/attachment_remove_test.go`, **`hub/demo_test.go`**, and the column leaves out `demo_test.go`.
  - Fix: name the packages (`go test ./internal/store/... ./internal/hub/...` on Memory and Postgres), or list the files.

## 3. Notes

- **N1, plan :211-212 and :287, the owner of the mock file changed.** At 06:37:56Z the owner of `spool-client-mock.mjs` is `c-068@<box-a>` (`c-068-rotate`), not `a-542`. The plan's standing guard (:225, re-run `lane-map.sh --check` at placement) covers this. Write F3's wait as "until `lane-map.sh --check` is free", not "until a-542 closes".
- **N2, plan :249, the public channel list is short by one.** `PUBLIC_CHANNELS` (`spool-client.mjs:296`) also holds `public`. List it with lobby, alerts, feedback and issues, or say "`isPublicChannel`" only.
- **N3, F2: spec 186 section 8.1 asks for a shared helper.** "A later lane may share one helper for 'the target topic must exist and be readable' (185's `forward_no_topic`, 186's `multicast_no_topic`); whichever lands first owns it, the other calls it." Spec 186 landed first (`wui_multicast.go`: `multicastTopic` `:354`, `outOfScopeToken` `:293-305`, `tokenMulticastNoTopic` `:25`), and the plan has 0 matches for `multicast_no_topic`, `multicastTopic` or `8.1`. F2's brief should say whether it calls that helper. `multicastTopic` refuses a DM topic, which a forward allows, so F2 may need a new one, and it should say why.
- **N4, two refusals the plan adds beyond spec 185 section 7.1.** `mc_id` with `forward_of` -> `bad_json` (:245), and the `isNoteToSelf` skip (:243). Both follow Q6 and spec 186 section 8.1, which treats forward and multicast as separate sends. Record them in the panel record as plan decisions the holder can overrule.
- **N5, F2 starts later than the spec asks.** The F2-after-F1-rolled gate (N2 of the plan) is safe: F2 adds `fwd_of` to every insert (`insertMessageSQL`), so its hub must never run before the column exists. But the spec lets F2 code at once on the store interface. The holder may let F2 start with batch 1 and land only after F1 is served on dev and prd. That saves a batch's wait and keeps the same deploy order.
- **N6, plan :19, :224 and :336, a stale status line.** These lines say this seat is queued or pending. Update them in v1.0.

## 4. Record

| when (UTC) | who | what |
|---|---|---|
| 2026-11-27 | c-715 (claude) | FAIL on `c2633a2c8e5ba3e31131ad16c0380f9b9b5357fe`, W1-W5, N1-N6 |
