# 119 addition: the primary workspace of a person

**Status**: v0.3.1, 2026-11-17, c-958 (SPL-5788, epic SPL-2396). Docs only:
builds nothing. Every owner question is answered (section 9: `1a`, `2c`,
`3a`, `7b`, then `8b`, `9c`); Q4..Q6 fall away under `1a`. Nothing is
built before a review seat passes this file. Build rows:
[tasks.md](tasks.md), section "Primary workspace".
Topic: t1 #spool-hub-ui `69d3f60c-d161-43de-ad64-e73683414064`.

Part of [119 personal realm](spec.md) (section 16 links here). Builds on,
and does not repeat: [calendar across workspaces](calendar-across-workspaces.md)
(the personal calendar view, sections 4, 5, 7), [154 contacts](../154-contacts-section/spec.md)
(sections 2.2, 2.6, 3), [155 notes](../155-notes-section/spec.md)
(sections 2.2, 2.8, 4), [118 multi-workspace hours](../118-multi-workspace-hours/spec.md)
sections 5.2 and 7 (one read and one write per workspace, each in its own
scope), [091 public dataset export](../091-public-dataset-export/spec.md).

Prose says **workspace**; **tenant** appears only in column, code and
config names.

## 0. The owner's words

HUM-10, 2026-11-17, csitea `40c3f89d` (msg `fd55c253`):

> "each person should be able to select in their settings, which of ALL of
> the workspaces they do have access to acts as the primary storage for
> their calendar entries, their notes and their contacts .. and for me this
> entries should be in the csitea workspace"

csitea `eaf71db0` (msg `3d2de205`, 10:23:18Z): "... change the storage for
my contacts to be the csitea workspace". Later in the same topic:

> "ok , if we do have those fences than the most logical place to store the
> global contacts and calendar entries and notes for each persons should be
> the spool-hub's t1 workspace" (msg `86c02094`)
>
> "or do we need some knd of uber workspace global , per spool-hub claud
> instance storage area with tables" (msg `8ceb284a`)

The dispatcher answered (msg `1a4f1b2e`) that the personal realm, schema
`personal`, is that per-instance area, and put three places to the owner:
A the personal realm, B the t1 workspace, C a workspace the person picks.
v0.1 of this file weighed the three for each kind of item and asked the
owner; the answers are in section 9.1 and shape sections 2 to 6.

## 1. Facts (origin/master `d0137722c`; prd read 2026-11-17)

Paths: `RDB` = `csi-spl-rdb/src/sql/postgres/spool-hub`, `GO` =
`csi-spl-api/src/go/spool-hub-api/internal`. Prd rows come from
`cd csi-spl-orc && ENV=prd SQL="..." ./run -a do_spl_db_query` (read only,
operator scope); only names and counts are written here.

| # | fact | check | so |
|---|---|---|---|
| F1 | A calendar entry belongs to one workspace: `calendar_events.tenant_id NOT NULL`, FORCE RLS on `app.tenant_id` | `RDB/0125_calendar.sql:21` (the column), `:48` (FORCE RLS) | an entry has one home; its audience, guests, reminders and trash are that workspace's |
| F2 | Notes and contacts are realm tables: `personal.notes`, `note_items`, `note_links` (`RDB/0225_personal_notes.sql:27,41,53`), `personal.contacts` (`RDB/0226_contacts.sql:62`), `personal.contact_photos` (`RDB/0265_contacts_import.sql:39`); each with `person_id` first, no `tenant_id`, FORCE RLS and the one `person_scope` policy | the files named; prd: `select table_name, string_agg(column_name, ',') from information_schema.columns where table_schema='personal' group by 1` -> 9 tables, none with a `tenant_id` column | one list per person, the same in every workspace (154 O5 = B, 155 D1) |
| F3 | `person_scope` matches only when `app.person_id` is the row's person, no workspace scope is set and the scope is not operator | `RDB/0168_personal_realm.sql:142-148` | no admin, member or operator reads a realm row |
| F4 | The operator scope reads 0 realm rows on prd, and reads workspace rows | prd: `select (select count(*) from personal.notes), (select count(*) from personal.contacts), (select count(*) from calendar_events)` -> `0`, `0`, `2738` | the realm fence holds even for the operator; a workspace table would not have it |
| F5 | `personal.settings` is a history: key `(person_id, valid_from)`, a change adds a row, so a past week is judged by the limit it had | `RDB/0168_personal_realm.sql:91-99`; 119 section 7.3 | a setting with no history belongs in `personal.profile` (one row per person, `RDB/0168_personal_realm.sql:80-89`), not in `settings` (section 2.2) |
| F6 | The person's workspaces are `Memberships(human)`: no `channel_guest` seat, no disabled human or membership, none past `access_until` | `GO/store/memberships.go:140-152` | the list the setting offers starts from it |
| F7 | A browser calendar write needs `notes.send`, refuses a demo visitor and a workspace whose billing does not allow writes | `GO/hub/calendar.go:935-945` (`calendarWriter`) | the setting offers only workspaces where those pass (section 2.1) |
| F8 | The personal calendar's create dialog asks for the workspace first, preselecting the last one used, else the one the person came from; an entry never moves between workspaces | [calendar-across-workspaces.md](calendar-across-workspaces.md) section 5 | the setting becomes the first preselect (2.5) |
| F9 | Before this file, a leaver keeps hours receipts, never content; a calendar entry is content and stays in its workspace | 119 REQ-4/5 (section 6.1); calendar-across-workspaces section 7 | it still holds: under the owner's `9c` the realm copy of `2c` is dropped on a leave (3.5) |
| F10 | The contacts Google sync binds exactly one of the person's workspace connections: `contacts_sync`, key `human_id`, FK to `tenant_memberships`; a second binding is 409 `contacts_sync_elsewhere` | `RDB/0226_contacts.sql:142-166`; `GO/hub/contacts.go:516`; 154 section 2.2 step 3 | the binding has a workspace even though the list does not; it stays as today (`7b`, section 5) |
| F11 | A Google Calendar connection is per member per workspace (`UNIQUE (tenant_id, human_id)`); imports land as that member's private events in that workspace | `RDB/0217_google_calendar.sql:17,40`; 149 sections 2.1, 2.10 B | where Google imports land is the connection's workspace, not this setting (section 5) |
| F12 | The daily public dataset export reads the workspaces `t1`, `spool` and `demo` | `csi-spl-cnf/csi-spl/prd.env.yaml:487-488` (`public_dataset.workspace_ids`) | personal data stored in t1 would sit in an exported workspace, fenced by one allow-list (`1b`, not chosen) |
| F13 | The workspace the owner names, csitea, is not one of them | prd: `select count(*), count(*) filter (where tenant_id in ('t1','spool','demo')) from tenants where display_name ilike '%csitea%'` -> `1`, `0` | `1c` with csitea would have been outside the export list (not chosen) |
| F14 | 13 humans on prd hold a seat in 2 or more workspaces | prd: `select count(*) from (select human_id from tenant_memberships where role <> 'channel_guest' group by human_id having count(*) > 1) x` -> `13` | the setting matters to those 13 today; a person with one workspace has nothing to pick |
| F15 | Backups are of the whole Cloud SQL instance (built-in backups and the daily dump), every workspace and the realm together | `csi-spl-iac/src/terraform/040-cloud-sql-postgres/03-cloud-sql.tf:58-60`; `csi-spl-iac/src/terraform/045-gcs-db-backups/03-backups-bucket.tf:1-12` | the mirror changes nothing about backups (section 6) |
| F16 | Realm routes refuse an act-as session, a live clone, an agent and a box token (403 `person_only`) | `GO/hub/realm.go:108` (`realmRefuses`); 119 section 9 C2 | the setting's routes take the same gate |

## 2. The setting

### 2.1 What it offers

One setting, **Primary workspace**, per person. The list offers every
workspace W in `Memberships(P)` (F6) where P may write: P holds
`notes.send` in W, P's seat in W is not a demo visit, and W's billing allows
writes (the three checks of `calendarWriter`, F7). A workspace that fails a
check is not shown. A person with one such workspace sees it, preselected
and read only; with none, the row is hidden.

**Default**: none (`NULL`). With none set, everything behaves as on master
today: the calendar dialog preselects as F8, notes and contacts stay where
they are.

### 2.2 Where it is stored

One new column on the realm profile, `personal.profile.primary_workspace_id
text NULL CHECK (length(primary_workspace_id) BETWEEN 1 AND 200)`: plain
text with no FK, like `personal.note_links.workspace_id` (the realm rule,
119 7.3: no FK to a table that carries `tenant_id`). Not in
`personal.settings`: that table is a history keyed by `valid_from` (F5),
and the primary workspace has no history. Read and written only under
`inPerson`, through the existing `GET` / `PUT /v1/me/realm/profile`
(`GO/hub/realm.go:437-438`), so it gets the realm gate (F16) and no admin
or operator reads it (F3).

The hub checks on `PUT` that the id passes 2.1 for the session's person
(else 400 `bad_primary_workspace`, nothing written), and on every read that
uses it that it still passes; a stale value is treated as unset (2.4).

### 2.3 Where it is shown

Settings dialog -> Profile (`csi-spl-wui/src/components/settings/profile.vue`),
one row "Primary workspace": a native select listing the workspaces of 2.1
by display name, with a "None" entry. Desktop and phone use the same
settings component; on the phone the select is the platform's own picker,
the row is at least 44 px high, and the text wraps at 360 and 390 px. Under
act-as the row is read-only text (the `PUT` is 403 `person_only`, F16).

### 2.4 Losing the primary workspace

When W stops passing 2.1 (removed, banned, `access_until` passed, disabled,
workspace deleted, billing stops writes), the stored value is kept but
read as unset: nothing is written on the leave itself. The next time P
opens Settings or the calendar create dialog, a one-line notice says the
primary workspace is no longer available and asks for another. Nothing
else depends on it: notes and contacts stay in the realm (`1a`), and the
calendar mirror is per source workspace, not per primary (section 3).

### 2.5 What the setting does, under the owner's answers

With `1a` (notes and contacts in the realm, as today), `7b` (contacts sync
as today) and `2c` (the calendar mirror of section 3, which covers every
workspace whatever the setting says), the one thing the setting changes is
the workspace a new entry made in "My calendar" goes to: the create
dialog's first preselect (F8), the primary workspace, else the last one
used, else the one P came from. The workspace's own calendar page still
creates in that workspace. An existing entry never moves (F8).

## 3. Calendar entries: the realm mirror (owner: `2c`, `8b`, `9c`)

The owner chose `2c`, "Mirror every entry into the realm", then `8b`
(every entry the person can read, other people's included) and `9c` (a
leaver's mirror of that workspace is dropped; a leaver keeps hours, never
content). Every calendar entry stays in its workspace and is still edited
there (F1). While P is a member of W, P's realm holds a read-only copy of
every W entry P can read: the **mirror**. The workspace row is the
source; the mirror follows it, is never edited by itself, and never
outlives P's access to W.

### 3.1 Which entries: exactly what P can read in W

For each workspace W of `Memberships(P)` (F6) where P holds `topics.read`
(the per-workspace gate of calendar-across-workspaces section 4), the
mirror holds every live (not trashed) `calendar_events` row of W that W's
own calendar shows to P:

- the workspace's **private filter** with P as the viewer:
  `calendarPrivateSQL` = `(audience <> 'private' OR ($2::text <> '' AND
  (creator_id = $2 OR $2 = ANY (mentions))))`
  (`GO/store/calendar_postgres.go:35`, viewer at `$2`). It does not
  include `owner_id`: a private entry whose owner is P, made by someone
  else and not naming P, is hidden from P in W and makes **no** mirror row
  (R7 W2);
- for a demo visitor in W (`isDemoVisitor`, `GO/hub/demo_quota.go:38`),
  only `workspace` and `public` entries, as the workspace route's
  `visibleTo` keeps (`GO/hub/calendar.go:636`).

Series masters and their exception rows are copied as rows (recurrence is
expanded on read, as the store's `calendarWithSeries` does,
`GO/store/calendar_series.go:140`). Issue deadlines are not
events and are not mirrored. Official days are not mirrored.

So the mirror never holds an entry the workspace calendar would hide from
P, and an entry that turns private and hidden from P is deleted from P's
mirror. The "mine" predicate of calendar-across-workspaces 3.1 is **not**
applied: under `8b` other people's readable entries are copied too.

### 3.2 The table

One new realm table, in the shape of every `personal.*` table (F2, F3):

`personal.calendar_mirror`

| column | type | from |
|---|---|---|
| `person_id` | `text NOT NULL REFERENCES public.humans (human_id) ON DELETE CASCADE` | P |
| `workspace_id` | `text NOT NULL` (1..200, no FK, like `personal.note_links.workspace_id`) | the source workspace |
| `event_id` | `uuid NOT NULL` (no FK) | the source `calendar_events.event_id` |
| `title`, `description`, `kind`, `starts_at`, `ends_at`, `all_day`, `audience`, `time_zone`, `rrule`, `recur_until`, `recurring_event_id`, `original_start`, `status` | as in `calendar_events` (rdb 0125, 0139, 0159..0161), same checks | the source row |
| `source_updated_at` | `timestamptz NOT NULL` | the source `updated_at`, for display only (3.3) |
| `copied_at` | `timestamptz NOT NULL DEFAULT now()` | |

Key `(person_id, workspace_id, event_id)`. FORCE RLS with the one
`person_scope` policy and no other (F3): no admin, member or operator
reads a mirror row, and the operator scope reads 0 rows of it as it does
of notes and contacts (F4).

No `relation` column (R7 W1): v0.2 had one to tell creator, owner and
guest apart for Q9 `9b`; under `8b` most rows are no relation of P's at
all, and under `9c` nothing reads it. Not copied either: `mentions`, the
guest list, `props`, `topic_id`, `issue_keys`, `remind_at`, `creator_id`,
`owner_id`, `source_key`. They name other people, link workspace content
or drive workspace behaviour (reminders stay the workspace's,
calendar-across-workspaces 4.1); the mirror keeps what the calendar grid
shows.

### 3.3 How it is written

Each step is its own transaction and the scopes are never set together
(119 8.1, 118 5.2).

1. The workspace write commits as today, in `inTenant(W)`: create,
   update, delete, trash, restore, an RSVP, a guest added or removed, an
   audience change, a Google import (149).
2. Then the hub refreshes the mirror of that one event for the humans it
   may concern: the **union** of the set the row concerned **before**
   the write and the set it concerns **after** it. A `private` row
   concerns its creator and the humans in its `mentions`; a row of any
   other audience concerns every human of `Memberships` in W who passes
   the gate (3.1), since under `8b` a workspace-wide entry is in every
   member's mirror. So if either the before-row or the after-row was not
   private, every gated member is refreshed: a `workspace` entry turned
   `private` deletes the row of each member it no longer shows to, at
   once, not at the next sweep (R7 v0.3 W1). A create has no before-row,
   a delete no after-row. For each such
   human H it reads the source row fresh in `inTenant(W)` with the 3.1
   filter and H as the viewer, then runs one `inPerson(H)` transaction
   that writes what that read returned: an upsert (`ON CONFLICT
   (person_id, workspace_id, event_id) DO UPDATE` of every copied
   column), or a delete when the read returned nothing (deleted, trashed,
   or now hidden from H). A human who fails the gate gets a delete.
   Writing a realm row for a person other than the session's follows the
   receipt precedent (119 8.1: the hub writes the leaver's receipt during
   an admin's removal).
3. Step 2 runs after the response, at most 2 humans in flight (the 118
   bound). A failed step 2 does not fail the workspace write (the source
   is already right). It is logged with ids and counts only, never a
   title, and the sweep repairs it.

The write is not ordered by `updated_at`: a trash keeps `updated_at`
(`GO/store/calendar_postgres.go:292`), and an RSVP or a guest change is
not known to bump it (unchecked). So each step 2 copies the state it has
just read. Two step 2s racing on one row can leave the older state; the
sweep repairs it.

**The sweep**: a named action on the existing sweep cadence (119 8.1's).
For each person P with a membership it reads, one workspace at a time,
the 3.1 set for P (`inTenant(W)`, P as viewer, the same read as step 2),
then in `inPerson(P)` upserts what differs (every copied column
compared) and deletes the rest. It also deletes every mirror row of a
workspace that is no longer in `Memberships(P)` or fails P's gate (3.5).
Its first run fills the mirror for every existing entry. The person list
comes from the membership list, the sweep's only operator read (the 119
8.1 shape).

### 3.4 How it is read

- `GET /v1/me/realm/calendar/events` (calendar-across-workspaces section
  4) still reads each live workspace directly, with its "mine" predicate;
  it does not read the mirror, so P never sees an entry twice and the view
  is never staler than the workspace.
- `GET /v1/me/realm/calendar/mirror?start=&end=` (the same 62-day bound,
  realm gate F16) reads the mirror alone: every entry P can read across
  P's workspaces, each with its `workspace_id` and the workspace's current
  name. It is filtered at read time to the workspaces that are in
  `Memberships(P)` and pass P's gate **now**, so a row the sweep has not
  yet dropped (3.5) is never answered.
- Under act-as, a clone, an agent or a box token: 403 `person_only` (F16).

What the mirror gives P that the live view does not: one realm read of
P's whole readable calendar across workspaces (the `/mirror` route and its
export, section 6), with no fan-out of up to 20 workspace reads. Under
`9c` it keeps nothing after a leave.

### 3.5 Leaving, lost access, workspace deleted (owner: `9c`)

The owner chose `9c`: when P's access to W ends, every mirror row of W in
P's realm is deleted. 119 REQ-4/5 (a leaver keeps hours receipts, never
content) and calendar-across-workspaces section 7 stand unchanged; no
edit to either.

The order is **drop first, change second**, the mirror image of 119
8.1's copy first:

| trigger | how |
|---|---|
| removal or ban | in the request: `inPerson(P)` deletes P's rows of W, then the membership change runs, then `inPerson(P)` deletes P's rows of W once more. A failed first delete blocks the removal (503 `mirror_failed`, retried). The second delete catches a row that another member's step 2 wrote between the first delete and the change (P was still a member then); if it fails, the read filter of 3.4 already hides the row (P is out of `Memberships`) and the sweep deletes it. A change that fails after the first delete leaves P a member with an empty mirror of W; the next sweep refills it |
| `access_until` passes | access already ended (rdb 0113, `Memberships`); the sweep deletes the rows. Until it runs they stay in the table, but the read-time filter of 3.4 never answers them |
| membership disabled (rdb 0074) | `Memberships` drops it: the sweep deletes the rows, the read filter hides them at once; enabled again, the sweep refills them |
| workspace deleted | the delete action deletes the rows of W for every member, in `inPerson` per member, before `DELETE FROM tenants`; a delete that cannot drop them is refused |
| P loses `topics.read` in W | as `access_until`: the read filter hides them at once, the sweep deletes them |
| rejoin | the sweep refills the mirror from the live rows |

## 4. Notes and contacts (owner: `1a`)

The owner chose `1a`: notes and contacts stay in the personal realm,
schema `personal` (F2), the per-instance, per-person area above every
workspace that the owner describes in msg `8ceb284a`. Nothing moves and
nothing is built for them. They stay readable by no admin, member or
operator (F3, F4), follow P into every workspace, survive every leave
(154 2.6, 155 2.2), and are in no workspace's export (F12). The setting
does not touch them (2.5).

Options `1b` (t1) and `1c` (the picked workspace, csitea for the owner)
are not built. Their move, leave and reader rules (v0.1 sections 5 and 6,
Q4..Q6) fall away with them.

## 5. Google sync (owner: `7b`)

- **Contacts** (154 2.2): unchanged. The person turns Contacts sync on in
  any one workspace; the binding stays there (F10) whatever the primary
  workspace is. No T021 "binding follows" row.
- **Calendar** (149): unchanged. Each workspace connection imports into
  its own workspace (F11). The imports are P's own private events, so
  they are mirrored (3.1) like any other entry P can read.

## 6. Export, erase, backups

- **Export**: unchanged for notes (`GET /v1/me/realm/notes/export`, 155
  2.8) and contacts (`GET /v1/me/contacts/export`, 154 2.6). The mirror
  gets `GET /v1/me/realm/calendar/mirror/export`: P's mirror rows, with
  3.4's read-time filter, as JSON, realm gate (F16). It holds what P can
  already read in each workspace today, no more. No workspace export
  carries any of it.
- **Public dataset export** (091): the realm is never in it.
  `personal.calendar_mirror` goes on 091's never-exported list (its
  section 4.2), so the gate refuses it whatever an allow-list says; a
  catalogue test fails if it is missing there.
- **Erase**: the `humans` delete cascades the mirror (realm FK, 3.2); a
  leave drops a workspace's rows (3.5). No separate erase route: the
  sweep would copy live rows back.
- **Backups**: one instance, every workspace and the realm together
  (F15); the mirror changes nothing about who backs up or restores.
- **Size, prd 2026-11-17** (`do_spl_db_query`, read only): 1817 live
  `calendar_events` rows, 1700 of them `private`; 22 workspaces with
  84 non-guest seats, at most 19 in one. The non-private live rows times
  their workspace's seats come to 542 mirror rows; each private row adds
  one per human it shows to (creator plus mentions). A few thousand rows
  in all today.

## 7. Not built

- Under `1a`: options `1b` and `1c` and their v0.1 sections 5 and 6.
- Under `7b`: the contacts binding following the primary workspace (v0.1
  T021).
- Under `2c`: the `2b` private realm calendar. The mirror is never a place
  to create or edit an entry.
- Under `9c`: no kept copy after a leave, no `left_at`, no "left
  workspace" rows in the personal view, no change to 119 REQ-5 or to
  calendar-across-workspaces section 7.

## 8. Risks

- **Two copies drift**: the source wins. A missed step 2 is repaired by
  the next sweep, so the mirror lags by at most one sweep interval; T-PW5
  pins the repair. The personal view reads the live rows (3.4), so a lag
  shows only in the `/mirror` route and its export.
- **Write fan-out under `8b`**: a non-private write refreshes one row per
  gated member of W: at most 19 on prd today (section 6), each a small
  `inPerson` transaction after the response, 2 in flight. A private write
  touches its creator and mentions only. The sweep is the bulk path.
- **A leaver's rows** (`9c`): a removal, a ban or a workspace delete
  drops them before the change; an expiry, a disable or a lost
  `topics.read` leaves them in the table until the next sweep, never
  answered by a read (3.4). T-PW6 and T-PW6b pin both.
- **Other people's entries in P's realm** (`8b`): only what W shows P
  today (3.1), dropped when P's access ends; no admin or operator reads
  them (F3, F4).

## 9. The owner's answers

### 9.1 Poll `6312c024` (HUM-10, t1 `69d3f60c`, msg `6fccf8a9`, 2026-11-17)

| # | question | answer | so |
|---|---|---|---|
| Q1 | Where are each person's notes and contacts stored? | **`1a`** the personal realm, the per-instance area above every workspace, as today | section 4: nothing moves |
| Q2 | What does the primary workspace do for calendar entries? | **`2c`** mirror every entry into the realm | section 3 |
| Q3 | One setting or one per kind? | **`3a`** one Primary workspace setting | section 2 |
| Q4..Q6 | only under `1b` / `1c` | fall away (c-002, msg `89c52d2e`) | v0.1 sections 5, 6 dropped |
| Q7 | Contacts Google sync | **`7b`** as today, on in any one workspace | section 5 |

### 9.2 Poll `1dd970be` (HUM-10, t1 `69d3f60c`, msg `4cb7194f`, 2026-11-17)

| # | question | answer | so |
|---|---|---|---|
| Q8 | Which calendar entries go into a person's mirror? | **`8b`** every entry the person can read in each workspace, other people's included | 3.1: W's own read for P, private filter and demo rule included |
| Q9 | When a person leaves a workspace, what happens to its entries in their mirror? | **`9c`** all of that workspace's entries are dropped, as today: a leaver keeps hours, never content | 3.5: drop first, change second; 119 REQ-5 unchanged |

No question is open. The owner's own case reads: every entry the owner
can read in csitea, t1 and each other workspace is also in the owner's
realm, read by no one else; new entries made in "My calendar" go to csitea
by default; notes and contacts stay in the realm; contacts sync stays
where it is; on leaving a workspace its entries leave the owner's realm.

## 10. Tests (for the build rows; Postgres, runtime role)

- **T-PW1** setting: `PUT /v1/me/realm/profile` with a workspace outside
  2.1 (not a member, a `channel_guest` seat, no `notes.send`, a demo visit,
  billing read-only) is 400 `bad_primary_workspace` and writes nothing; a
  valid one is stored and read back; act-as, an agent and a box token get
  403 `person_only`. Red control: drop the `notes.send` check, the
  accountant-only workspace is stored.
- **T-PW2** calendar preselect (2.5): with the primary workspace set, the
  "My calendar" create dialog preselects it; unset, F8's order holds; a
  stale primary (membership removed) is treated as unset and the notice
  shows. Red control: skip the 2.1 check on read, the removed workspace is
  preselected.
- **T-PW3** mirror write (3.3): in W with members P, Q, R: Q creates a
  `workspace` entry, and P's, Q's and R's mirrors each get the row; Q
  edits it and all three follow; Q trashes it and all three rows go;
  restore brings them back; delete removes them. Q creates a `workspace`
  entry, all three mirrors get it, then Q turns it `private` naming P
  only: Q's and P's rows are updated and **R's row is deleted** by that
  step 2, with no sweep run (R7 v0.3 W1). A `private` entry by Q
  naming P makes rows for Q and P and none for R. **A `private` entry by
  Q with `owner_id = P` and P not in `mentions` makes no row for P** (R7
  W2). An `internal` entry makes no row for a demo visitor. Red controls:
  drop the private filter from the step-2 read, the owner-only private
  entry gets a row for P (and R gets the private row); drop the demo
  rule, the demo visitor gets the `internal` row; refresh only the
  after-set in step 2, R keeps the now-private row.
- **T-PW4** isolation: under `inTenant(W)` and the operator scope,
  `personal.profile`'s new column and `personal.calendar_mirror` read 0
  rows; another person's `inPerson` reads 0 rows (119 T-N2, T-N4
  extended). Red control: add an `operator_scope` policy to the mirror,
  the operator read returns rows.
- **T-PW5** sweep repair: delete a mirror row by hand, and edit a source
  row with step 2 disabled; one sweep run restores both; a second run
  changes nothing; the sweep never writes the owner-only private entry of
  T-PW3 for P. Red controls: the sweep skips the compare, the row stays
  missing; the sweep reads without the private filter, the owner-only
  entry gets a row.
- **T-PW6** leave (`9c`, T022): remove P from W, and P's rows of W are
  gone before the membership row changes; a failed first delete blocks
  the removal with 503 `mirror_failed`; a step 2 for Q's write injected
  between the first delete and the change leaves no row of P's after the
  removal returns (the second delete); a workspace delete leaves no row
  of W in any realm. Red control: run the change before the delete with
  the delete failing, P is out with rows left; skip the second delete,
  the injected row stays.
- **T-PW6b** lost access without a request (`9c`, T021: the read filter
  and the sweep): after `access_until` passes and after a disable,
  `/mirror` answers no row of W at once and the next sweep deletes them;
  re-enable refills them. Red control: drop the read-time filter, the
  expired workspace's rows are answered.
- **T-PW7** export gate: `personal.calendar_mirror` is on 091's
  never-exported list; removing it fails the catalogue test.

## 11. Version log

| version | date | by | what |
|---|---|---|---|
| 0.1 | 2026-11-17 | c-958 | draft: facts F1..F16, the setting (stored on `personal.profile`), calendar options `2a`..`2c`, notes and contacts options `1a`..`1c` (realm, t1, picked workspace), moves and leaves under `1b` / `1c`, readers, Google sync, export / erase / backups, Q1..Q7, tests T-PW1..T-PW4 |
| 0.2 | 2026-11-17 | c-958 | the owner's answers `1a`, `2c`, `3a`, `7b` (msg `6fccf8a9`): the setting is the "My calendar" preselect (2.5); the realm calendar mirror (section 3: table, write, sweep, read, leave); notes and contacts unchanged; v0.1 sections 5, 6 and the contacts-binding row dropped; new open questions Q8 (which entries) and Q9 (on leaving); tests T-PW1..T-PW7 |
| 0.2.1 | 2026-11-17 | c-958 | R7 c-990 (msg `d9e33ac3`): `relation` gains `mention` (W1); step 2 and the sweep read the source with the workspace private filter for each human, so an owner-only private entry is not mirrored (W2); step 2 checks each human's gate (N3); no `updated_at` ordering (N4); F1 cites `:48` (N5); T-PW3, T-PW5 red controls |
| 0.3 | 2026-11-17 | c-958 | the owner's `8b`, `9c` (msg `4cb7194f`): the mirror holds every entry P can read in W (W's private filter with P as viewer, the demo rule), dropped on a leave, drop first; no `relation`, no `left_at` (R7 W1 resolved by removal); step 2 fans out to the gated members for a non-private write; prd size; no open questions; T-PW3, T-PW6 rewritten with red controls (R7 W2) |
| 0.3.1 | 2026-11-17 | c-958 | R7 c-990 on v0.3 (msg `7b94207f`): step 2 refreshes the union of the before- and after-row sets, so a `workspace` entry turned `private` deletes other members' rows at once (W1), with a T-PW3 case and red control; a removal deletes again after the change (N1); the read-filter and sweep cases move to T-PW6b under T021 (N2) |

<!-- version: 0.3.1 · updated: 2026-11-17 -->
