# Spec 180: Import an Outlook calendar into a member's spool-hub calendar

Version **0.1.0** (2026-11-17). Authored by lane `c-060` (`claude`).
Issue: **SPL-5784** (status `wip`, tenant `t1`). Epic: **SPL-2750** (from the
seat brief; to be confirmed by the dispatcher). Class: `feature`.
Discussion: csitea topic `40c3f89d-bedb-427d-90fe-78699a2a0f0a`.
Next-free check (`git ls-tree --name-only origin/master csi-spl-doc/specs/ | sort | tail -2`
at `aaccd3460` -> `179-pause-agents-of-a-discussion`, `README.md`):
`180-outlook-calendar-import` is free.

Nearest prior specs: [`112`](../112-goals-strategy-roadmap/) (`source_key`
upsert, rdb 0156), [`149`](../149-google-calendar-connect/spec.md) (Google
Calendar connect; its section 2.10 B is the read-only import model this spec
follows), [`119`](../119-personal-realm/spec.md) (calendar across workspaces).
`csi-spl-doc/specs/README.md` is a Qto export and is left untouched, as for
specs 100..179.

**Data rule.** This spec is product text. It holds no calendar content and
no customer host, box or account name. The source box is called "the
Outlook box" below; its Windows user and home are `$WIN_USR` / `$WIN_HOME`.

---

## 0. The owner's words (HUM-10, csitea, 2026-11-17), verbatim

- msg `ac88f807`: "As the admin and biz owner of hte spool-hub I would like
  to have an 30 min sync between the calendar in teams or outlook on [the Outlook
  box] and my calendar so that the calendar in teams would not show anything
  which is on the spool-hub calendar , but the spool-hub calendar will get
  automatically updated on every 30 min from the time of 06:30 till 20:30
  every 30 min"
- msg `3ccb9db4` (the method): "export the calendar entries into file(s) and
  than transfer them via [the box link] and import them into the spool-hub ( create
  import from outlook api )"
- msg `193aeae1`: "could you create such are powershell based export of hte
  calendar data at least for the next 2 weeks and provide it for work out
  and import for the spool-hub"
- msg `c225ffae` (poll `fb30da00`): time zone **A, Europe/Helsinki**; source
  **C, a scheduled job on the Outlook box that pushes the entries to
  spool-hub**.
- Earlier answers recorded in the topic: private to the owner, stored in
  csitea, shown in every workspace through My calendar (spec 119); the
  entries may leave the customer (`d7566b50`); they also go out to the
  owner's Google Calendar (`1c9f6219`), an exception to spec 149 2.10 B.

## 1. What exists on master (measured at `aaccd3460`, 2026-11-17)

1. **No Outlook import.** `git grep -il outlook origin/master -- csi-spl-api csi-spl-orc`
   -> 3 files, all about the `email_client` preference
   (`internal/auth/handler.go`, `preferences_test.go`, `humans_test.go`).
2. **The upsert by key exists**, but only for roadmap keys:
   `store/calendar_sync.go` `UpsertCalendarBySourceKey`, key families
   `calendarSourceKeyRe = ^(goal|spec|release|db):...`, unique index
   `calendar_events_source_key (tenant_id, source_key)` (rdb 0156). Its route
   `PUT /v1/calendar/sync` is the roadmap sync and is not open to this use.
3. **The operator write route exists**: `POST /v1/operator/calendar/events`
   (`hub/calendar_operator_write.go`), called by `do_spl_calendar_event_add`
   as the environment's service account (`SPOOL_HUB_OPERATOR_EMAILS`), with
   an owner and `audience=private`.
4. **The Google out-half sends these rows.** `hub/gcal_sync.go` `push` skips
   only an unmapped `gcal:` key; every other live event the member reads goes
   to their "Spool Hub" Google calendar.
5. **The one-off import of 2026-11-17 (Implemented, outside git):**
   - The export: a PowerShell script reads Outlook through COM for the next
     14 days, expands recurrences, drops cancelled meetings, and writes title,
     start and end in UTC, all-day, location, busy status and a source id
     (`GlobalAppointmentID@<local start>`). It writes no body and no
     attendees.
   - It ran on the Outlook box through the box link's remote run:
     exit 0 in 7 s, 16 entries.
   - The bridge loop called `do_spl_calendar_event_add` 16 times on prd
     (csitea, private, owner HUM-10).
   - Checked on the prd db: 16 rows, 16 distinct sources, every row
     `audience=private`, `owner_id=HUM-10`. `gcal_event_map` holds 16 rows
     for the owner's csitea Google connection.
   - It is **not idempotent**: those rows carry no `source_key`, so a re-run
     duplicates every meeting. Task T6 adopts them.
6. **Defect found in the run:** a Finnish-locale box wrote `06.30.00` for
   `06:30:00`, because `ToString('HH:mm:ss')` uses the culture's time
   separator. The script now formats with `InvariantCulture`; the importer
   still refuses a time that is not RFC 3339 (FR-3).

## 2. Requirements

| id | requirement | status |
|---|---|---|
| FR-1 | **Export script** `csi-spl-orc/src/powershell/outlook-calendar-export.ps1`: Outlook COM, the next `-Days` days (default 14) from today 00:00 local, recurrences expanded, cancelled left out, JSON `format: spool-hub-outlook-export/1` with `exported_at`, `time_zone`, `from`, `to`, `count`, `events[]` (`source_id`, `title`, `starts_at`, `ends_at` UTC RFC 3339, `all_day`, `day`, `end_day`, `location`, `busy_status`, `private`, `recurring`). No body, no attendees. Every date is formatted with `InvariantCulture`. `-OutFile STDOUT` prints the JSON. | Partial: works (section 1.5), not in git |
| FR-2 | **Import route** `PUT /v1/operator/calendar/import/outlook?tenant=<t>&owner=<HUM-n>`, body = one FR-1 export. The caller is an operator (service account in `SPOOL_HUB_OPERATOR_EMAILS`). Answers `{created, updated, unchanged, deleted}`. | Planned |
| FR-3 | **Validation before any write:** the format string, `from <= to`, at most 2000 events, every `starts_at`/`ends_at` RFC 3339 with `ends_at > starts_at` (all-day: `day <= end_day`), a non-empty `source_id`, `title` cut to 200 chars. One bad event refuses the whole batch (400, which event and why); nothing is written. | Planned |
| FR-4 | **Upsert by key.** Key family `outlook:` is added to `calendarSourceKeyRe`. Key = `outlook:<owner>:<first 24 hex of SHA-256(source_id)>` (hashed: the raw id was 128 chars in the 2026-11-17 export and is opaque). Each row: kind `other`, `audience=private`, `owner_id=<owner>`, `mentions={<owner>}`, creator = the operator, description `Imported from Outlook`, plus busy status and location. A row whose fields did not change is left alone (`updated_at` too), as in spec 112. | Planned |
| FR-5 | **Moved or cancelled meetings.** An `outlook:<owner>:` row that starts inside the batch window `[from, to)` and is not in the batch is soft-deleted (`deleted_by` = the operator). A row outside the window is never touched. A key back in a later batch restores its row with the same id. | Planned |
| FR-6 | **Private to the owner** in the owner's chosen workspace (csitea), and visible in every workspace through My calendar (spec 119). | Planned (follows from FR-4) |
| FR-7 | **Out to Google.** `outlook:` rows go out through spec 149 2.5 like any of the owner's events: an exception to 149 2.10 B (owner `1c9f6219`). The `gcal:` skip in `gcal_sync.go` `push` is not widened. Test: an `outlook:` row gets a map row. | Implemented by the current code (section 1.4); test Planned |
| FR-8 | **Nothing written back** to Outlook or Teams. The export is read-only COM. | Implemented (script) |
| FR-9 | **Orc action** `do_spl_calendar_import_outlook` (`ENV`, `TENANT_ID`, `EVENT_OWNER`, `IMPORT_FILE`, `DRY_RUN`, default 1): validates the file locally, calls FR-2, logs the four counts, and never logs a title. | Planned |
| FR-10 | **Schedule:** every 30 min from `06:30` to `20:30` Europe/Helsinki, Monday to Friday (29 runs a day). Section 3 covers where the timer lives. | Planned |
| FR-11 | **Kill switch:** cnf `calendar.outlook_import.enabled` (false by default). When it is off, the route answers 404 and the schedule does nothing. | Planned |

## 3. The schedule and the transfer (owner question)

The owner's method (`3ccb9db4`): export to file(s) on the Outlook box,
transfer through the box link, and import through the new API. Answer C
(`c225ffae`) asks for a job **on the Outlook box** that pushes.

What the box link does today (measured on 2026-11-17): the hub
side queues a signed command, the box runs it, and the result zip
(`stdout.txt`, `result.json`) returns to the hub side. The run itself took
7 s. The full round trip was not timed. Whether the box link also carries a file
that the box starts sending on its own is **unchecked**.

- **(A, recommended)** The timer runs on the hub side (a cron entry in
  Europe/Helsinki). Each tick queues a remote run of the FR-1 script, and
  the result's `stdout.txt` is the file that FR-9 imports. The export still
  runs on the Outlook box and travels through the box link, so the owner's method
  holds. Nothing is installed on the box, and this path has been proven once.
- **(B)** A Windows Task Scheduler entry on the Outlook box writes the export
  file, and the box link carries it home. This needs a box-to-hub file path in
  the box link (unchecked; if it is missing, it is a change to the box link,
  outside this repo) and a task registered on the box by the owner.

The SPL-1910 hygiene sweep forbids naming the box link anywhere in this
repo. So under A, the timer and the code that calls the box link are
name-neutral and read the box link's command and result paths from a
box-local `KEY=VALUE` file outside git (no file = no-op), the shape used for
the box-link watcher (SPL-4816).

The window has the same cost either way: 29 runs a day, each holding the
owner's Outlook through COM for about 7 s. If Outlook is closed, the run
fails with a COM error and the hub keeps the previous rows (FR-5 runs only
on a valid batch).

## 4. Cases

1. A new meeting: created, private, owner set, and on Google within one gcal cycle.
2. The same batch twice: `created=0, updated=0, unchanged=N`.
3. A meeting moved to another time in the window: its occurrence key
   changes (`@<local start>`), so the old row is deleted and a new row is
   created.
4. A meeting cancelled: its row is deleted (FR-5).
5. A meeting more than two weeks out: outside the window, so it is not
   touched; it is created when the window reaches it.
6. A batch with one `06.30.00` time: 400 that names the event, nothing written.
7. An owner that is not a member of the tenant: 403, nothing written.
8. Kill switch off: 404, nothing written.

## 5. Tasks (for the coding lane; placed by the dispatcher)

| id | task | files |
|---|---|---|
| T1 | FR-1 into git with a smoke test (`pwsh` if present, else skipped with a reason) | `csi-spl-orc/src/powershell/` |
| T2 | `outlook:` key family and window prune in both stores, tests on Postgres | `internal/store/calendar_sync*.go` |
| T3 | FR-2/3/11 route and its tests (cases 2, 3, 4, 6, 7, 8) | `internal/hub/calendar_operator*.go` |
| T4 | FR-9 action and its test | `csi-spl-orc/src/bash/run/` |
| T5 | FR-10 timer, per the owner's answer in section 3 | orc cron (A), or the box link outside this repo (B) |
| T6 | Adopt the 16 rows of 2026-11-17: set their `source_key` from the `source:` line of their description (a one-time operator action, dry run first), so the first scheduled run updates them and does not duplicate them | orc action |
| T7 | Docs: calendar user guide, a line on the import | `csi-spl-doc/doc/md/` |

## 6. Owner steps (never a lane)

- Answer section 3 (A or B).
- For B only: register the Task Scheduler entry on the Outlook box.
- Keep Outlook signed in on the Outlook box during the window.

<!-- version: 0.1.0 · updated: 2026-11-17 · last-edit: 2026-11-17T17:10:00Z -->
