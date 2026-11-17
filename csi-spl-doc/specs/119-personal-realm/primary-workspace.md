# 119 addition: the primary workspace of a person

**Status**: v0.1, 2026-11-17, c-958 (SPL-5788, epic SPL-2396). Docs only:
builds nothing. Draft with seven owner questions (section 9); nothing is
built before the owner answers and a review seat passes it. Build rows:
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
This file weighs the three for each kind of item (sections 3 to 5) and asks
the owner (section 9).

## 1. Facts (origin/master `d0137722c`; prd read 2026-11-17)

Paths: `RDB` = `csi-spl-rdb/src/sql/postgres/spool-hub`, `GO` =
`csi-spl-api/src/go/spool-hub-api/internal`. Prd rows come from
`cd csi-spl-orc && ENV=prd SQL="..." ./run -a do_spl_db_query` (read only,
operator scope); only names and counts are written here.

| # | fact | check | so |
|---|---|---|---|
| F1 | A calendar entry belongs to one workspace: `calendar_events.tenant_id NOT NULL`, FORCE RLS on `app.tenant_id` | `RDB/0125_calendar.sql:21` | an entry has one home; its audience, guests, reminders and trash are that workspace's |
| F2 | Notes and contacts are realm tables: `personal.notes`, `note_items`, `note_links` (`RDB/0225_personal_notes.sql:27,41,53`), `personal.contacts` (`RDB/0226_contacts.sql:62`), `personal.contact_photos` (`RDB/0265_contacts_import.sql:39`); each with `person_id` first, no `tenant_id`, FORCE RLS and the one `person_scope` policy | the files named; prd: `select table_name, string_agg(column_name, ',') from information_schema.columns where table_schema='personal' group by 1` -> 9 tables, none with a `tenant_id` column | one list per person, the same in every workspace (154 O5 = B, 155 D1) |
| F3 | `person_scope` matches only when `app.person_id` is the row's person, no workspace scope is set and the scope is not operator | `RDB/0168_personal_realm.sql:142-148` | no admin, member or operator reads a realm row |
| F4 | The operator scope reads 0 realm rows on prd, and reads workspace rows | prd: `select (select count(*) from personal.notes), (select count(*) from personal.contacts), (select count(*) from calendar_events)` -> `0`, `0`, `2738` | the realm fence holds even for the operator; a workspace table would not have it (section 6) |
| F5 | `personal.settings` is a history: key `(person_id, valid_from)`, a change adds a row, so a past week is judged by the limit it had | `RDB/0168_personal_realm.sql:91-99`; 119 section 7.3 | a setting with no history belongs in `personal.profile` (one row per person, `RDB/0168_personal_realm.sql:80-89`), not in `settings` (section 2.2) |
| F6 | The person's workspaces are `Memberships(human)`: no `channel_guest` seat, no disabled human or membership, none past `access_until` | `GO/store/memberships.go:140-152` | the list the setting offers starts from it |
| F7 | A browser calendar write needs `notes.send`, refuses a demo visitor and a workspace whose billing does not allow writes | `GO/hub/calendar.go:935-945` (`calendarWriter`) | the setting offers only workspaces where those pass (section 2.1) |
| F8 | The personal calendar's create dialog asks for the workspace first, preselecting the last one used, else the one the person came from; an entry never moves between workspaces | [calendar-across-workspaces.md](calendar-across-workspaces.md) section 5 | the setting becomes the first preselect (section 3) |
| F9 | A leaver keeps hours receipts, never content; a calendar entry is content and stays in its workspace | 119 REQ-4/5 (section 6.1); calendar-across-workspaces section 7 | mirroring entries into the realm would hand a leaver content (section 3, option `2c`) |
| F10 | The contacts Google sync binds exactly one of the person's workspace connections: `contacts_sync`, key `human_id`, FK to `tenant_memberships`; a second binding is 409 `contacts_sync_elsewhere` | `RDB/0226_contacts.sql:142-166`; `GO/hub/contacts.go:516`; 154 section 2.2 step 3 | the binding has a workspace even though the list does not (section 7) |
| F11 | A Google Calendar connection is per member per workspace (`UNIQUE (tenant_id, human_id)`); imports land as that member's private events in that workspace | `RDB/0217_google_calendar.sql:17,40`; 149 sections 2.1, 2.10 B | where Google imports land is the connection's workspace, not this setting (section 7) |
| F12 | The daily public dataset export reads the workspaces `t1`, `spool` and `demo` | `csi-spl-cnf/csi-spl/prd.env.yaml:487-488` (`public_dataset.workspace_ids`) | personal data stored in t1 would sit in an exported workspace, fenced by one allow-list (section 4, option `1b`) |
| F13 | The workspace the owner names, csitea, is not one of them | prd: `select count(*), count(*) filter (where tenant_id in ('t1','spool','demo')) from tenants where display_name ilike '%csitea%'` -> `1`, `0` | option `1c` with csitea is outside the export list |
| F14 | 13 humans on prd hold a seat in 2 or more workspaces | prd: `select count(*) from (select human_id from tenant_memberships where role <> 'channel_guest' group by human_id having count(*) > 1) x` -> `13` | the setting matters to those 13 today; a person with one workspace has nothing to pick |
| F15 | Backups are of the whole Cloud SQL instance (built-in backups and the daily dump), every workspace and the realm together | `csi-spl-iac/src/terraform/040-cloud-sql-postgres/03-cloud-sql.tf:58-60`; `csi-spl-iac/src/terraform/045-gcs-db-backups/03-backups-bucket.tf:1-12` | no option changes what is backed up (section 8) |
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
primary workspace is no longer available and asks for another. Under
options `1b` / `1c` the notes and contacts stored in W need more than
that: section 5.

## 3. Calendar entries

| option | what it means | for | against |
|---|---|---|---|
| **`2a` (recommended)** stay in their workspaces; the setting is the first preselect of the create dialog in the personal calendar | F8's preselect becomes: the primary workspace, else the last one used, else the one P came from. The workspace's own calendar page still creates in that workspace | no data moves; every audience, guest, reminder and trash rule stays the workspace's (F1); the personal view already shows all of P's entries in one place | a team meeting is still made in the team's workspace, by design |
| `2b` add a realm calendar for private entries only | a new realm table for entries with no guests, no audience and no mentions, shown in the personal view beside the workspace ones | private appointments belong to P alone and survive every leave | a second event model (recurrence, reminders, trash, Google sync) to build and keep in step with 089 / 097 / 149; an entry that later gets a guest must move into a workspace |
| `2c` mirror every entry into the realm | a copy of each of P's workspace entries in the realm | none the personal view does not already give | a leaver keeps content, which 119 REQ-4/5 forbids (F9); two copies that drift |

Under every option an existing entry never moves (F8): moving one is a
delete in A and a create in B, which guests see.

## 4. Notes and contacts: where they are stored

| option | what it means | for | against |
|---|---|---|---|
| **`1a` (recommended)** the personal realm, as today | the per-instance, per-person area the owner describes in msg `8ceb284a` is schema `personal` (F2): it is above every workspace, already built and live for notes and contacts. The setting does not move them; for contacts it picks the Google binding's workspace (section 7) | no admin, member or operator reads them (F3, F4); they follow P into every workspace and survive every leave (154 2.6, 155 2.2); in no workspace's export (F12); no rows move | they belong to no workspace: a company cannot keep a leaver's contacts |
| `1b` the t1 workspace, for everyone | new workspace tables (with `tenant_id`) in t1 for every person's notes and contacts | one known place | t1 is one of the three workspaces of the daily public export (F12): personal data of people who never agreed to Spool would sit one allow-list line from publication; every person of the instance would need a seat in t1; t1's admins and the operator scope become readers unless section 6 holds; leaving t1 is section 5 |
| `1c` the workspace each person picks (the owner: csitea) | the same new tables, rows in P's primary workspace | matches the owner's first words; csitea is not exported (F13); the company that owns the workspace can govern the data | the fences of section 6 must be built; a leave or a lost seat moves or loses the list (section 5); notes and contacts become read-only when that workspace's billing stops writes (F7) |

What `1a` already guarantees, and `1b` / `1c` would have to rebuild:
isolation by Postgres policy (F3), not by a hub filter; the 0-row
operator read (F4); the same list from every workspace without a
cross-workspace read.

## 5. Under `1b` or `1c`: existing items and leaving

Only if the owner picks `1b` or `1c`.

- **Existing items** (Q4): `4a` (recommended) on the first `PUT` of the
  setting the hub moves all of P's notes (with items and links) and
  contacts (with photos) from the realm into W, in two steps that never
  share a scope: copy in `inTenant(W)` with the same ids, verify the
  counts, then delete in `inPerson(P)`. A retry is idempotent (same ids,
  `ON CONFLICT DO NOTHING`). `4b` new items only: the list is split
  between the realm and W for ever, and every read merges two stores.
- **Changing the primary workspace** from W1 to W2 moves them again, W1 to
  W2, the same two-step way, each step in one workspace scope.
- **Leaving W, losing access, W deleted** (Q5): `5a` (recommended) copy
  first, change second, as 119 section 8.1 does for receipts: before the
  membership ends or the workspace is deleted, the hub copies P's items
  into the realm under `inPerson(P)`, then the change runs; a failed copy
  blocks the removal (503 `primary_move_failed`, retried). P then picks
  another primary workspace (2.4). `5b` the items stay with W: P loses
  them on leaving, the workspace keeps them.
- **`access_until`** passes without a request: the 119 receipt sweep
  (section 8.1) gains a step that runs the `5a` copy for the lapsed
  membership.

## 6. Who reads the items in the workspace (`1b` / `1c` only)

A workspace table carries `tenant_scope` and, by the fleet's shape,
`operator_scope` (`RDB/0226_contacts.sql:162-167` for `contacts_sync`). So
in a workspace a notes or contacts row is readable by any code in that
workspace's scope, and by the operator, unless the table is built
otherwise. Q6:

- **`6a` (recommended)** only the person. The tables get `tenant_scope`
  only, no `operator_scope`, and every query names the session's person;
  no member, admin, biz owner or operator route reads them. A test in the
  shape of 119 T-N1..T-N4 pins it, with a red control (add
  `operator_scope`, the operator read returns rows).
- `6b` the person, plus the workspace's `biz_owner` read-only (a handover
  when someone leaves, under `5b`).

Other members never read them under either option.

## 7. Google sync

- **Contacts** (154 2.2): the sync binds one workspace connection per
  person (F10). Q7: `7a` (recommended) the binding follows the primary
  workspace: turning Contacts sync on picks the primary workspace's Google
  connection, and changing the primary workspace moves the binding (off in
  W1, on in W2; the first-sync rules of 154 2.5 re-link the list). `7b` as
  today, the person turns it on in any one workspace.
- **Calendar** (149): unchanged under every option. Each workspace
  connection imports into its own workspace (F11) and the "Spool Hub"
  calendar sends each workspace's entries. A person who wants Google
  imports in the primary workspace connects Google there.

## 8. Export, erase, backups

- **Export**: unchanged routes under every option:
  `GET /v1/me/realm/notes/export` (155 2.8) and `GET /v1/me/contacts/export`
  (154 2.6) answer the person's own items wherever they are stored. No
  workspace export carries them.
- **Public dataset export** (091): the realm is never in it. Under `1b` or
  `1c` the new workspace tables go on 091's "never exported" list (its
  section 4.2), so the gate refuses them whatever an allow-list says; a
  catalogue test fails if they are missing there.
- **Erase**: unchanged: `DELETE /v1/me/realm/notes` and
  `DELETE /v1/me/contacts?scope=spool` erase the person's own items
  wherever stored; the `humans` delete cascades them (realm FK; under
  `1b` / `1c` the new tables get the same FK).
- **Backups**: one instance, every workspace and the realm together (F15);
  no option changes what is backed up or who restores it.

## 9. Questions for the owner (recommended option first; keys at most 3 characters)

| # | question | options |
|---|---|---|
| Q1 | Where are each person's notes and contacts stored? | **`1a` (recommended)** the personal realm, the per-instance area above every workspace, as today. `1b` the t1 workspace, for everyone. `1c` the workspace each person picks as primary (for you: csitea) |
| Q2 | What does the primary workspace do for calendar entries? | **`2a` (recommended)** entries stay in their workspaces; the primary workspace is the default for a new entry made in "My calendar". `2b` also a private realm calendar for entries with no guests. `2c` mirror every entry into the realm |
| Q3 | One setting or one per kind? | **`3a` (recommended)** one "Primary workspace" setting. `3b` one per kind (calendar, notes, contacts) |
| Q4 | Under `1b` / `1c`: the items that exist today | **`4a` (recommended)** all move when the setting is first set. `4b` only new items go there |
| Q5 | Under `1b` / `1c`: leaving or losing the primary workspace | **`5a` (recommended)** the items are copied back to the realm first, then the leave runs; the person picks another. `5b` they stay with the workspace |
| Q6 | Under `1b` / `1c`: who reads them inside the workspace | **`6a` (recommended)** only the person, no admin, no operator. `6b` also the workspace's business owner, read only |
| Q7 | Contacts Google sync | **`7a` (recommended)** it follows the primary workspace. `7b` as today, turned on in any one workspace |

With `1a`, Q4, Q5 and Q6 do not apply. With `1a`, `2a`, `3a`, `7a`, the
owner's own case reads: calendar entries made in "My calendar" go to
csitea by default; notes and contacts stay in the owner's realm, in no
workspace (not t1, not csitea), read by no one else; the contacts Google
sync runs on the csitea connection.

## 10. Tests (for the build rows; Postgres, runtime role)

- **T-PW1** setting: `PUT /v1/me/realm/profile` with a workspace outside
  2.1 (not a member, a `channel_guest` seat, no `notes.send`, a demo visit,
  billing read-only) is 400 `bad_primary_workspace` and writes nothing; a
  valid one is stored and read back; act-as, an agent and a box token get
  403 `person_only`. Red control: drop the `notes.send` check, the
  accountant-only workspace is stored.
- **T-PW2** calendar preselect (`2a`): with the primary workspace set, the
  "My calendar" create dialog preselects it; unset, F8's order holds; a
  stale primary (membership removed) is treated as unset and the notice
  shows. Red control: skip the 2.1 check on read, the removed workspace is
  preselected.
- **T-PW3** contacts binding (`7a`): turning Contacts sync on binds the
  primary workspace's connection; changing the primary moves the binding,
  and the person never meets 409 `contacts_sync_elsewhere` on that path.
  Red control: bind the session's workspace instead, the binding stays in
  W1 after the change.
- **T-PW4** isolation unchanged (`1a`): the new column is readable only
  under `inPerson`; under `inTenant(W)` and the operator scope
  `personal.profile` reads 0 rows (119 T-N2, T-N4 extended to the column).
- Under `1b` / `1c` the build rows add the move, leave and fence tests of
  sections 5 and 6, each with a red control; they are written when the
  owner picks that option.

## 11. Version log

| version | date | by | what |
|---|---|---|---|
| 0.1 | 2026-11-17 | c-958 | draft: facts F1..F16, the setting (stored on `personal.profile`), calendar options `2a`..`2c`, notes and contacts options `1a`..`1c` (realm, t1, picked workspace), moves and leaves under `1b` / `1c`, readers, Google sync, export / erase / backups, Q1..Q7, tests T-PW1..T-PW4 |

<!-- version: 0.1.0 · updated: 2026-11-17 -->
