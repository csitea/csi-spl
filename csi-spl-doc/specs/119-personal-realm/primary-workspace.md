# 119 addition: the primary workspace of a person

**Status**: v0.2.1, 2026-11-17, c-958 (SPL-5788, epic SPL-2396). Docs only:
builds nothing. The owner answered Q1, Q2, Q3 and Q7 (section 9.1:
`1a`, `2c`, `3a`, `7b`); Q4..Q6 fall away under `1a`. `2c` raises two
follow-up questions, Q8 and Q9 (section 9.2); the rows that depend on
them wait. Nothing is built before a review seat passes this file. Build
rows: [tasks.md](tasks.md), section "Primary workspace".
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
| F9 | Before this file, a leaver keeps hours receipts, never content; a calendar entry is content and stays in its workspace | 119 REQ-4/5 (section 6.1); calendar-across-workspaces section 7 | the owner's `2c` makes a realm copy of entries; what that copy does on a leave is Q9 (section 3.5) |
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

## 3. Calendar entries: the realm mirror (owner: `2c`)

The owner chose `2c`, "Mirror every entry into the realm". Every
calendar entry stays in its workspace and is still edited there (F1); the
person's realm keeps a read-only copy of it, the **mirror**. The
workspace row is the source; the mirror follows it and is never edited
by itself.

### 3.1 Which entries

"Every entry" is read as **every entry that is P's** in each workspace of
`Memberships(P)` that passes the `topics.read` gate: the "mine" rule of
[calendar across workspaces](calendar-across-workspaces.md) section 3.1
(P made it, P owns it, P is a guest or `@`-mentioned on it; a Google
import is P's own event). Issue deadlines are not events and are not
mirrored. The other reading, every entry P can read (a whole workspace
calendar, other people's entries included), is Q8 `8b` (section 9.2).

**The private filter applies first.** The source row is selected, for
each human, with the workspace's own private filter for that human as the
viewer, ANDed with the "mine" predicate, exactly as calendar-across-workspaces
3.1 reads it: `calendarPrivateSQL` = `(audience <> 'private' OR ($2::text <> ''
AND (creator_id = $2 OR $2 = ANY (mentions))))`
(`GO/store/calendar_postgres.go:35`, viewer at `$2`). That filter does not
include `owner_id`, so a private entry whose owner is P, made by someone
else and not naming P, is hidden from P in W and makes **no** mirror row.
The mirror never holds an entry the workspace calendar would hide from P;
an entry that turns private and hidden from P is deleted from P's mirror.

### 3.2 The table

One new realm table, in the shape of every `personal.*` table (F2, F3):

`personal.calendar_mirror`

| column | type | from |
|---|---|---|
| `person_id` | `text NOT NULL REFERENCES public.humans (human_id) ON DELETE CASCADE` | P |
| `workspace_id` | `text NOT NULL` (1..200, no FK, like `personal.note_links.workspace_id`) | the source workspace |
| `event_id` | `uuid NOT NULL` (no FK) | the source `calendar_events.event_id` |
| `workspace_name` | `text NOT NULL` | the workspace's display name at the last copy |
| `relation` | `text NOT NULL CHECK (relation IN ('creator','owner','guest','mention'))` | how the event is P's (3.1), the first that holds in this order: `creator` (`creator_id = P`), `owner` (`owner_id = P`), `guest` (P is in the event's guest list), `mention` (P is in `mentions` only; guests are a subset of `mentions`, 097 3.2) |
| `title`, `description`, `kind`, `starts_at`, `ends_at`, `all_day`, `time_zone`, `rrule`, `recur_until`, `recurring_event_id`, `original_start`, `status` | as in `calendar_events` (rdb 0125, 0139), same checks | the source row |
| `source_updated_at` | `timestamptz NOT NULL` | the source `updated_at` |
| `copied_at` | `timestamptz NOT NULL DEFAULT now()` | |
| `left_at` | `timestamptz NULL` | set when P's access to the workspace ends (3.5); NULL while P is a member |

Key `(person_id, workspace_id, event_id)`. FORCE RLS with the one
`person_scope` policy and no other (F3): no admin, member or operator
reads a mirror row, and the operator scope reads 0 rows of it as it does
of notes and contacts (F4). Not copied: `mentions`, the guest list,
`props`, `topic_id`, `issue_keys`, `remind_at`, `audience`, `creator_id`
and `owner_id`. Those name other people, link workspace content, or drive
workspace behaviour; the mirror keeps what P needs to see their own
calendar.

### 3.3 How it is written

Each step is its own transaction and the scopes are never set together
(119 8.1, 118 5.2).

1. The workspace write commits as today, in `inTenant(W)`: create,
   update, delete, restore from trash, an RSVP, a guest added or removed,
   a Google import (149).
2. Then, for each human H the write may concern (the creator, the
   owner, each human guest or mention, before and after the write), the
   hub first checks H's gate in W (`Memberships(H)` holds W and H has
   `topics.read` there, 3.1); a human who fails it gets no row and loses
   any row of W. For the rest it reads the source row fresh in
   `inTenant(W)` with H as the private filter's viewer and the "mine"
   predicate (3.1), then runs one `inPerson(H)` transaction that writes
   what that read returned: an upsert (`ON CONFLICT (person_id,
   workspace_id, event_id) DO UPDATE` of every copied column), or a
   delete when the read returned nothing (the entry was deleted or
   trashed, is no longer H's, or is now private and hidden from H). The
   write is not ordered by `updated_at`: a trash keeps `updated_at`
   (`GO/store/calendar_postgres.go:292`), and an RSVP or a guest change is
   not known to bump it (unchecked), so each step 2 copies the state it
   has just read. Two step 2s racing on one row can leave the older state;
   the sweep repairs it. A trashed entry is deleted from the
   mirror and comes back on restore. Writing a realm row for a person
   other than the session's follows the receipt precedent (119 8.1: the
   hub writes the leaver's receipt during an admin's removal).
3. A failed step 2 does not fail the workspace write (the source is
   already right). It is logged with ids and counts only, never a title,
   and the sweep repairs it.

**The sweep**: a named action on the existing sweep cadence (119 8.1's).
For each person with a live membership it compares the mirror with the
source "mine" set, one workspace at a time (`inTenant(W)` read with P as
the private filter's viewer, the same read as step 2, then `inPerson(P)`
write), and fixes what differs, comparing every copied column. Its first run fills the
mirror for every existing entry. The person list comes from the
membership list, the sweep's only operator read (the 119 8.1 shape).

### 3.4 How it is read

- `GET /v1/me/realm/calendar/events` (calendar across workspaces section
  4) still reads each live workspace directly. The mirror is not a second
  source for those: P never sees the same entry twice.
- The mirror's rows with `left_at` set (Q9 `9a` / `9b` only) are added to
  that answer as read-only entries, workspace `{"workspace_id","name",
  "state":"left"}`, never draggable and never editable, opening a
  read-only sheet that says P left that workspace.
- `GET /v1/me/realm/calendar/mirror?start=&end=` (same 62-day bound,
  realm gate F16) reads the mirror alone, for the export (section 6) and
  tests.
- Under act-as, a clone, an agent or a box token: 403 `person_only` (F16).

### 3.5 Leaving, lost access, workspace deleted (Q9)

This is where `2c` meets 119: a receipt holds hours and never content
(REQ-5), and calendar-across-workspaces section 7 drops a left
workspace's entries from the view. A mirror kept after a leave hands the
leaver content, including meetings that others made in which P was
only a guest. So Q9 (section 9.2) asks what the copy does on a leave:

- `9a` keep every mirror row of W, read-only, with `left_at` set.
- **`9b` (recommended)** keep the entries P made or owns
  (`relation in ('creator','owner')`) with `left_at` set; delete the
  ones where P was only a guest. P keeps their own entries; other
  people's meetings stay with the workspace.
- `9c` delete every mirror row of W. The mirror is then only a copy for
  the members of W, and 119 REQ-5 and calendar-across-workspaces section
  7 stand unchanged.

The order is 119 8.1's, copy first and change second: before a removal,
a ban or a workspace delete, the hub brings P's mirror of W up to date
(3.3 step 2 for all of P's entries in W), then applies Q9 to it, then
runs the change. A failed refresh blocks the change (503
`mirror_failed`, retried), as a failed receipt does. A lapsed
`access_until` is handled by the sweep, which can only apply Q9 to the
mirror as last copied: access already ended. A **disabled** membership
(rdb 0074) is not a leave: its rows stay as they are and the sweep skips
it until it is enabled or removed. A rejoin clears `left_at` and the
sweep re-syncs the rows.

Under `9a` / `9b`, 119 REQ-5 gains one sentence: "A person keeps the
calendar mirror of section 3 of primary-workspace.md (its Q9), which is
not a receipt." Calendar-across-workspaces section 7 gains the
`state:"left"` rows of 3.4. Both edits land with the build row, not
before.

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
  they are mirrored (3.1) like any other entry of P's.

## 6. Export, erase, backups

- **Export**: unchanged for notes (`GET /v1/me/realm/notes/export`, 155
  2.8) and contacts (`GET /v1/me/contacts/export`, 154 2.6). The mirror
  gets `GET /v1/me/realm/calendar/mirror/export`: the person's mirror rows
  as JSON, realm gate (F16). No workspace export carries any of them.
- **Public dataset export** (091): the realm is never in it.
  `personal.calendar_mirror` goes on 091's never-exported list (its
  section 4.2), so the gate refuses it whatever an allow-list says; a
  catalogue test fails if it is missing there.
- **Erase**: the `humans` delete cascades the mirror (realm FK, 3.2).
  `DELETE /v1/me/realm/calendar/mirror?workspace=W` lets P drop the kept
  rows of a workspace P has left (`left_at` set). For a workspace P is
  still in it is 409 `mirror_live`: the sweep would copy the rows back.
- **Backups**: one instance, every workspace and the realm together
  (F15); the mirror changes nothing about who backs up or restores.
- **Size**: prd holds 2738 `calendar_events` rows in all (F4). The mirror
  holds one row per (person, entry) pair whose entry is "mine", so it is
  bounded by the entries times the people on each.

## 7. Not built

- Under `1a`: options `1b` and `1c` and their v0.1 sections 5 and 6.
- Under `7b`: the contacts binding following the primary workspace (v0.1
  T021).
- Under `2c`: the `2b` private realm calendar. The mirror is never a place
  to create or edit an entry.

## 8. Risks

- **Two copies drift**: the source wins. A missed step 2 is repaired by
  the next sweep, so the mirror lags by at most one sweep interval; T-PW5
  pins the repair.
- **Write fan-out**: one workspace write makes at most 1 + (guests and
  mentions) realm transactions, run after the response at most 2 in flight
  (the 118 bound), never inside the workspace transaction.
- **Content kept by a leaver** under `9a` / `9b`: the owner's call (Q9),
  written here so it is a decision and not a side effect.

## 9. The owner's answers and the open questions

### 9.1 Answered (HUM-10, t1 `69d3f60c`, msg `6fccf8a9`, 2026-11-17, poll `6312c024`)

| # | question | answer | so |
|---|---|---|---|
| Q1 | Where are each person's notes and contacts stored? | **`1a`** the personal realm, the per-instance area above every workspace, as today | section 4: nothing moves |
| Q2 | What does the primary workspace do for calendar entries? | **`2c`** mirror every entry into the realm | section 3 |
| Q3 | One setting or one per kind? | **`3a`** one Primary workspace setting | section 2 |
| Q4..Q6 | only under `1b` / `1c` | fall away (c-002, msg `89c52d2e`) | v0.1 sections 5, 6 dropped |
| Q7 | Contacts Google sync | **`7b`** as today, on in any one workspace | section 5 |

### 9.2 Open: raised by `2c` (recommended option first; keys at most 3 characters)

| # | question | options |
|---|---|---|
| Q8 | Which calendar entries go into a person's mirror? | **`8a` (recommended)** the person's own: made, owned, guest or mentioned, Google imports (3.1). `8b` every entry the person can read in each workspace, other people's included |
| Q9 | When a person leaves a workspace, what happens to its entries in their mirror? | **`9b` (recommended)** they keep the entries they made or own, read-only; meetings where they were only a guest are dropped. `9a` they keep every mirrored entry, read-only. `9c` all of that workspace's entries are dropped (as today: a leaver keeps hours, never content) |

With `8a` and `9b`, the owner's own case reads: every csitea, t1 and
other entry that is the owner's is also in the owner's realm; new entries
made in "My calendar" go to csitea by default; notes and contacts stay in
the realm, read by no one else; contacts sync stays where it is now; on
leaving a workspace the owner keeps the entries they made there.

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
- **T-PW3** mirror write (3.3): create, edit, trash, restore and delete an
  entry with a guest; after each step the creator's and the guest's
  mirror rows match the source; removing the guest deletes the guest's
  row; an entry P can merely read (`workspace` audience, not P's) makes no
  row (under `8a`); an entry that names P only in `mentions` makes a
  row with `relation = 'mention'`; a `private` entry whose `owner_id` is
  P, made by someone else and not naming P, makes no row for P. Red
  controls: skip the guest in step 2, the guest's row is missing; drop
  the private filter from the step-2 read, the owner-only private entry
  gets a row.
- **T-PW4** isolation: under `inTenant(W)` and the operator scope,
  `personal.profile`'s new column and `personal.calendar_mirror` read 0
  rows; another person's `inPerson` reads 0 rows (119 T-N2, T-N4
  extended). Red control: add an `operator_scope` policy to the mirror,
  the operator read returns rows.
- **T-PW5** sweep repair: delete a mirror row by hand, and edit a source
  row with step 2 disabled; one sweep run restores both; a second run
  changes nothing; a private, owner-only entry not naming P gets no row
  from the sweep either. Red controls: the sweep skips the compare, the
  row stays missing; the sweep reads without the private filter, the
  owner-only entry gets a row.
- **T-PW6** leave (Q9's answer): remove P from W; the rows Q9 keeps have
  `left_at` set and show in the personal view as `state:"left"`, read
  only; the rows it drops are gone; a failed refresh blocks the removal
  with 503 `mirror_failed`. A disabled membership changes no row. Red
  control: run the change before the copy, the last edit is missing from
  the kept row.
- **T-PW7** export gate: `personal.calendar_mirror` is on 091's
  never-exported list; removing it fails the catalogue test.

## 11. Version log

| version | date | by | what |
|---|---|---|---|
| 0.1 | 2026-11-17 | c-958 | draft: facts F1..F16, the setting (stored on `personal.profile`), calendar options `2a`..`2c`, notes and contacts options `1a`..`1c` (realm, t1, picked workspace), moves and leaves under `1b` / `1c`, readers, Google sync, export / erase / backups, Q1..Q7, tests T-PW1..T-PW4 |
| 0.2 | 2026-11-17 | c-958 | the owner's answers `1a`, `2c`, `3a`, `7b` (msg `6fccf8a9`): the setting is the "My calendar" preselect (2.5); the realm calendar mirror (section 3: table, write, sweep, read, leave); notes and contacts unchanged; v0.1 sections 5, 6 and the contacts-binding row dropped; new open questions Q8 (which entries) and Q9 (on leaving); tests T-PW1..T-PW7 |
| 0.2.1 | 2026-11-17 | c-958 | R7 c-990 (msg `d9e33ac3`): `relation` gains `mention` (W1); step 2 and the sweep read the source with the workspace private filter for each human, so an owner-only private entry is not mirrored (W2); step 2 checks each human's gate (N3); no `updated_at` ordering (N4); F1 cites `:48` (N5); T-PW3, T-PW5 red controls |

<!-- version: 0.2.1 · updated: 2026-11-17 -->
