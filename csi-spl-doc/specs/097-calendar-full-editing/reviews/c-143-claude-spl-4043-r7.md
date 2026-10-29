review: c-143 claude FAIL 4283ae643 ran: PRE_PUSH_NO_CACHE=1 PRE_PUSH_TIER=full ./run -a do_check_pre_push (postgres:16-alpine, 6 e2e), go test probes (short topic id, non-member ordered_by), locale key counts, hygiene grep | read: the 44-file diff 9a48fb4d4..4283ae643, spec 097 section "Discussion, issues and the owner (SPL-4043)", calendar_operator.go, calendar_links.go, calendar-event-form.mjs | log: csi-spl-doc/specs/097-calendar-full-editing/reviews/c-143-claude-spl-4043-r7.md

# R7 review of SPL-4043: calendar entries get a discussion link, issue links and an owner

- Reviewer: c-143 (claude). Author: g-523 (grok), request msg 03ae73ea.
- Branch `review/c002-calendar-event-discussion-issue-links` = `4283ae6437673916a60fa32d9c35ba82b0a3429d`.
  `git diff 9a48fb4d4 4283ae643 | git patch-id --stable` -> `abcb27a282a51944f14caa21a1739d07c16df2de` (matches the request).
- Base 9a48fb4d4; 44 files, +1343/-40 (`git diff --stat` tail).
- Verdict: **FAIL**. Two defects must be fixed: W1 and W2. Everything else is green.

## Gate runs

The first run reused the author's cached verdicts (every part said "green verdict re-used"), so I ran the gate again without the cache:

`PATH=/usr/local/go/bin:$PATH PRE_PUSH_NO_CACHE=1 PRE_PUSH_TIER=full ./run -a do_check_pre_push` on a detached worktree at 4283ae643, base origin/master -> `EXIT=0`, `all parts PASSED`:

| part | result |
|---|---|
| distribution-hygiene, lint-* (incl. lint-migration, lint-gosec 169 s) | PASS |
| csi-spl-orc suite + feature tests | PASS (1396 s, 116 s) |
| csi-spl-wui unit + typecheck | PASS (148 s) |
| csi-spl-wui browser e2e | PASS: `runs 6 file(s): calendar-event-fields, calendar-phone-peek, calendar-events, calendar-phone-sheet, calendar-drag, calendar`, then `e2e runner: all 6 file(s) passed` |
| csi-spl-api suite on Postgres | PASS: `temp Postgres up (docker postgres:16-alpine)`, `spool migrate applies 242 file(s); re-run is a no-op`, store and hub groups a..d `ok`, `RLS: 44 TestRLS PASS`, cross-tenant store 4 / hub 8 PASS |
| release-note | WARN only: 7 of 7 commits lack the note |

## Findings

### W1 (must fix): the dialog accepts a short topic id, and the hub refuses it

- The WUI side: `csi-spl-wui/src/utils/calendar-event-form.mjs` `calDiscussionRef` accepts `TOPIC_SHORT = /^[0-9a-f]{8}$/`, and `/t/<8 hex>` through `TOPIC_LINK`. `calFormBody` then sends that value as `topic_id`. The unit test pins it: `calendar-event-form.test.mjs:260` `assert.equal(calDiscussionRef('  AABBCCDD '), 'aabbccdd')`.
  - Command: `node -e` with `calFormBody({...calFormFromEvent(null,'2026-10-30'), title:'x', discussion:'5ea2e615'})` -> `"5ea2e615"`.
  - With `discussion: 'https://h.example/t/5ea2e615'` it also gives `"5ea2e615"`.
- The hub side: `hub/calendar_operator.go:131` `if !uuidRe.MatchString(id)` refuses anything but a full uuid (`view.go:47`). This commit also wires that check into the member create and the PATCH (`hub/calendar.go:978`, `:1127`).
- Probe: a temporary hub test (removed afterwards) put a message on topic `5ea2e615-1111-4222-8333-944455556666`, then created an event with each form of the id:
  - `topic_id="5ea2e615-1111-4222-8333-944455556666" -> 201 <nil>`
  - `topic_id="5ea2e615" -> 400 bad_event`
- Effect: the placeholder says "Topic link or id", and the 8-hex short id is the form people quote. The form accepts it, then Save fails.
- Fix, either one:
  - The hub resolves a unique short id to its topic uuid.
  - The WUI accepts only a full uuid, or a `/t/<uuid>` link, and shows `error_discussion` for anything else, with the unit test changed to match.

### W2 (must fix): operator create now fails when ordered_by is not a member of the target workspace

- `hub/calendar_operator.go:109-114`: when the body has no `owner_id`, the owner becomes `ordered_by`, and `bindEventLinks` then requires it to be a member or an agent of the tenant. Before this change, `ordered_by` was only format-checked and logged. In the test at base, `git show 9a48fb4d4:.../calendar_operator_test.go | grep -n '"ordered_by"'` -> `43: ... "ordered_by": "HUM-10"`. The branch changed it to a seeded member (`memA`).
- Probe: I set the test back to `"ordered_by": "HUM-10"` and dropped only the new `owner_id` assertion:
  - Command: `go test ./internal/hub/ -run '^TestOperatorCalendarEvent$'`
  - Output: `create: 400 map[detail:owner HUM-10 is not a member or an agent of this workspace error:bad_event]`
  - The file was restored afterwards.
- Effect: `do_spl_calendar_event_add ... ORDERED_BY=HUM-n` (the action's own `@example`, line 32) now fails in any workspace where that human is not a member, even though no owner was asked for. That is a regression of an existing operator path.
- Fix: validate only an `owner_id` the body names. When the default `ordered_by` is not a member, fall back to the agent, and add a test that keeps a non-member `ordered_by` at 201.

### W3 (note, not blocking): an owner may not see their own private event

`store/calendar.go:467` `calendarOwnsOrNamed` and `calendar_postgres.go:35` `calendarPrivateSQL` check only `creator_id` and `mentions`. A private event whose owner is neither the creator nor mentioned is hidden from that owner. Spec 097 does not say whether the owner should see it. Either add the owner to the private filter, or say in the spec that the owner must also be mentioned.

### W4 (note): before the migration is applied, the owner and issues are dropped silently

Until rdb 0242 is applied, the hub writes neither column, so a member's owner or issues are accepted and dropped without an error. The migration header says this on purpose ("a hub may roll first"). That is acceptable only if the migration reaches dev and prd together with the hub. Recorded so the deploy does not separate them.

## Brief checks

1. **Spec rows.**
   - Owner: `owner_id` is a column separate from `creator_id`, and guests stay in their own rows. A new event defaults to its creator (`hub/calendar.go` newEvent; store `normalizeCalendarEvent`). A PATCH with `owner_id ""` resets it to the creator (TestCalendarEventLinks, TestCalendarLinks0242).
   - Discussion: one link, `topic_id`.
   - Issues: zero to 20 keys, canonicalised and checked against the workspace (`calendar_links.go` `canonicalIssueKeys`). The spec allows an empty list: "Empty fields stay as placeholders".
   - Behaviour matches the spec, except W1 (the discussion input) and W2 (the operator default).
2. **Store, hub, auth and the migration.**
   - Full tier on Postgres: green, see above.
   - The migration is forward-only and additive (`ADD COLUMN IF NOT EXISTS` ×2, then a backfill `UPDATE`). The backfill runs under the migrator's operator scope (`store/migrate.go:80-82` `scope := pgScopeOperator`), so FORCE RLS does not hide rows.
   - Prefix: `git ls-tree --name-only origin/master csi-spl-rdb/src/sql/postgres/spool-hub/ | tail -1` at origin/master `03377dd59` -> `0241_fleet_ask_discussion.sql`, and `grep -c '/0242_'` -> `0`. So 0242 is **free on master** at my run. c-954's `0242_marketing_metrics.sql` competes for the number; which lands first is not mine to decide.
3. **WUI.** typecheck PASS. The 6 named e2e ran and passed: calendar-event-fields, calendar-phone-peek, calendar-events, calendar-phone-sheet, calendar-drag, calendar (125 checks in `calendar` alone).
4. **Locales.** I did not judge the wording. Key counts after flattening, one line per file: all 19 files = `3129` keys.
   - The new keys: for each `i18n/locales/*.json`, `git diff 9a48fb4d4 HEAD -- $f | grep '^+ '` key names, sorted, md5 -> `19 7d2dfc26 16`. That is the same 16 key names in all 19 files.
5. **Hygiene.**
   - The added lines of `git diff 9a48fb4d4 HEAD` swept with the org, person, OS-user, box and owner-mail patterns of the distribution-hygiene rules -> no hits (exit 1).
   - The only URL added is `https://spool.example/t/${id}?x=1`, a placeholder in a unit test.
   - The distribution-hygiene part of the gate: clean.

## Re-review

After the fix lands on the review branch, send the new sha. I will re-run the W1 and W2 probes and the gate on it.
