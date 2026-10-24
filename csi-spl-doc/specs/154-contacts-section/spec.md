# 154 Contacts section, synced with Google Contacts

Version v0.3 (2026-10-24), the editor's draft with both panel seats'
reviews folded in (section 10). Step 2 of the
owner rule for a big change: the written spec, then the panel, then the
build. Written by c-951@sat (claude) because agy, the main vendor for
specs, is out of quota; a panel follows. Nothing in it is built.

Source: prd topic in the owner's workspace,
`topic:451c020f-5440-4849-8dea-2246d5796ed4`. Issue: SPL-3156 (this v0.1),
epic SPL-3036. Each build row in section 6 gets its own issue when it is
placed.

Paths used below:

- `api/` = `csi-spl-api/src/go/spool-hub-api/`
- `hub/` = `api/internal/hub/`, `store/` = `api/internal/store/`
- `rdb/` = `csi-spl-rdb/src/sql/postgres/spool-hub/`
- `wui/` = `csi-spl-wui/src/`
- `cnf/` = `csi-spl-cnf/csi-spl/`

Every `file:line` was read on origin/master `9e8ece102` with `git grep -n`,
`grep -n` or `sed -n` on that tree. Nothing was read from prd or GCP and no
Google API was called. A claim about Google's own behaviour (the People
API, its scopes, quotas and sync tokens) that the editor did not test is
marked "unchecked, I believe".

Builds on, and does not repeat:
[149 Google Calendar connect](../149-google-calendar-connect/spec.md) v1.0
(the per-member Google connection this spec reuses),
[010 social auth](../010-spool-social-auth/spec.md),
[022 top-bar search](../022-spool-wui-top-bar-search/spec.md) (the
omnibox), [100 search index](../100-search-index/spec.md),
[141 invite display name](../141-invite-display-name/spec.md) (email
visibility, not built).

Per the owner's wording rule this spec says **workspace**; **tenant**
appears only in code identifiers and columns. Examples use
`FirstName LastName` and `example.com` only.

## 0. The owner's ask, verbatim

HUM-10, prd t1 topic `451c020f`, 2026-10-21:

> "a contacts section that syncs with Google contacts" (msg `47559637`)

> "it should be searchable from the omnibox ..." (msg `75798873`)

> "it should contain only certain amaount of attributes per person - first name , last name , email phone number one should be able to send directly spool-hub.ai msgs from it" (msg `8e89a5a3`)

2026-10-23 21:45Z: "Go implrment" (msg `b28cae33`).

## 1. What exists on master (measured)

### 1.1 Nothing of the feature is built

`git grep -niE 'contact' 9e8ece102 -- csi-spl-api csi-spl-rdb csi-spl-wui/src`
hits only mailto:/tel: link handling (`rdb/0193_human_contact_links.sql`,
`wui/utils/contact-links.mjs`), payment contact info
(`api/internal/payments/handler.go`, `wui/utils/checkout-client.ts`), a
help line and tests. None of them is a contact list. Every case in section 5
is red on master today unless marked (C).

### 1.2 The code this spec stands on

| # | what | measured on `9e8ece102` | what it means here |
|---|---|---|---|
| 1 | how a person is stored | `rdb/0006_users_and_memberships.sql:19-27` `humans`: `human_id`, `display_name` (<= 200), `email` ("Last verified email seen at sign-in; informational, not unique", :23-24), `created_at`, `disabled_at` | no first name, last name or phone; a member is not a contact |
| 2 | verified addresses | `rdb/0006_users_and_memberships.sql:30-39` `human_identities`: `(provider, subject)`, `email` (:34), `email_verified` (:35) | the only safe key to match a contact to a member (2.4) |
| 3 | membership | `rdb/0006_users_and_memberships.sql:45` `tenant_memberships` | "member of this workspace" |
| 4 | a phone column | none: `rdb/0193_human_contact_links.sql:21-23` `email_client`, `phone_app` are the app a link opens, not stored numbers | a contact's phone is new data; its link reuses 0193 (2.4) |
| 5 | store types | `store/member_directory.go:20` `type Member struct`, `store/search.go:87` `type HumanEntry struct`; no `type Human struct` | a contact gets its own type |
| 6 | the People section | `wui/pages/people/index.vue:1-2` and `[id].vue:1-4`: the workspace's members; the card has a Message button that opens the DM | Contacts is a separate section, not a filter of People (P3) |
| 7 | a DM | `store/view.go:38` `DM bool // only messages with no channel`; the page is `wui/pages/dm/[peer].vue`, reached at `/dm/<peer>` (`wui/composables/usePaletteItems.ts:88-89`) | there is no DM to create: "message this contact" is a route to `/dm/<peer>` |
| 8 | sending a message | a WebSocket frame: `GET /v1/wui/ws` (`hub/server.go:416`), `case "send"` (`hub/wui.go:368`) -> `wuiSend` (`hub/wui.go:571`), recipient from `wuiRecipient` (`hub/wui.go:859`, `to = f.To` :860) | Contacts sends nothing itself; the DM page does |
| 9 | inviting a non-member | `POST /v1/members/invites` (`hub/rbac.go:552`, handler `:324`), gated by `rbac.MembersInvite` (`:325`); body email, role, ttl_hours, no_mail (`:329-336`) | the one existing way to bring a non-member in (O4) |
| 10 | the omnibox | `wui/components/TopBar.vue:1-4`: one composer; plain text goes to the page's send target, `/search <q>` opens `/search?q=`; `wui/stores/omnibox.ts:5-7` "with no target ... the Omnibox only searches" | contacts are found through `/search` (2.3) |
| 11 | the hub search | `GET /v1/view/search` (`hub/search.go:50`), handler `:111`; entity types `search/grammar.go:30-45` (message, topic, file, robot, user, channel, box, tenant, event, issue); members as hits from `TenantHumans` (`hub/search.go:484-485`) | a new type `contact`, the reader's own rows only |
| 12 | the command palette | `wui/composables/usePaletteItems.ts:40` `PALETTE_GROUPS = ['sections', 'channels', 'people', 'topics', 'docs', 'settings']`; client-side over the stores' lists (`:83-107`) | an optional `contacts` group (B10) |
| 13 | rail sections | `wui/utils/rail-order.ts:20` `export const RAIL_TABS`; the palette lists them (`usePaletteItems.ts:63-80`) | a new rail tab `contacts` |
| 14 | spec 149's Google connection | landed: `rdb/0217_google_calendar.sql:17-41` `gcal_connections`, `UNIQUE (tenant_id, human_id)` (:40), sealed tokens `access_sealed`, `refresh_sealed`, `kms_key_id` (:26-28); no column for the granted scopes | one Google connection per member per workspace exists; contacts adds a scope to it, not a second login (2.2) |
| 15 | spec 149's Google client | landed (`bf5a169e4`): `api/internal/gcal/oauth.go:172-174` sends `scope` from cnf `gcal.scopes` (:58) and `include_granted_scopes=true`; the token answer's `scope` is parsed (`:235`, :247) | the granted scope string is already in hand; but `AuthorizeURL(state)` (:167) takes no scope argument, the scope is fixed per client from cnf (:58, :172), so asking for one part's scope needs a change in `oauth.go` (B7) |
| 16 | spec 149's hub side | `ls hub/ \| grep -c gcal` -> 0: no connect route, sync or WUI yet (149 B5-B10 not landed) | B7, B8 and B9 here come after 149 B5, B6a and B8 |
| 17 | sign-in scopes | `cnf/all.env.yaml:704` `SPOOL_HUB_AUTH_GOOGLE_SCOPES: "openid email profile"`; `auth/idp.go:146` `access_type=online` | sign-in never returns a refresh token; the connect flow is 149's (149 P1) |
| 18 | the sealer | `api/internal/marketing/seal.go:115` `Seal`, `:139` `Open`; `:87` names 149's purpose `spool-gcal-token/v1` | tokens stay sealed under 149's purpose; contacts adds no token |
| 19 | RLS shape | `rdb/0187_marketing.sql:107-114`: ENABLE + FORCE, `tenant_scope` on `app.tenant_id`, `operator_scope` on `app.rls_scope` | the two policies on every new table |
| 20 | per-member RLS | `grep -l "app.human_id" rdb/*.sql` -> none | no Postgres policy can isolate members today; the store does it, as in 149 (C3) |
| 21 | the sweeper | `hub/server.go:585` `func (s *Server) RunSweeper` | the contacts sync ticker starts there, as 149's |
| 22 | data export / erase | none for a member: the nearest are `GET /v1/hours/export` (`hub/hours_team.go:348`), `DELETE /v1/embed/{embed_id}/visitor` (`hub/embed_visitor.go:52`), `DELETE /v1/members/{human_id}` (`hub/rbac.go:556`, handler `:473`) | contacts bring their own export and erase routes (2.6) |
| 23 | settings sections | `wui/utils/settings-nav.mjs:6-14` (7 ids); 149 B8 adds `calendar-google` | the contacts switch of the Google connection lives in that section (2.7) |
| 24 | next migration | re-measured on `fb7b73093`: `ls rdb/ \| tail -1` -> `0220_hours_v2_entries_key.sql` (0219, 0220 landed after `9e8ece102`) | `<next>` = 0221 today, fixed at build time |

## 2. The design

### 2.1 Scope

In: a member's own contact list inside a workspace; each contact holds
exactly four attributes: **first name, last name, email, phone** (one of
each); add, edit, delete in Spool; find a contact from the omnibox
(`/search`); open a direct message with a contact who is a member; an
optional sync with the member's Google Contacts; export and erase.

Out (each can get its own spec): more attributes (company, address,
birthday, photo, notes, labels or groups), several emails or phones per
contact, a contact list shared by a workspace, contacts from other
providers (Outlook, CardDAV), import from a vCard file, sending email or
SMS from Spool.

A contact needs at least one of the four values (CHECK in section 3).
Without a Google connection the list works on its own: the sync is an
add-on, never a precondition.

### 2.2 One Google connection, one more scope

The member connects Google once, through spec 149's connect flow
(149 section 2.2): the same `gcal_connections` row, the same sealed tokens,
the same consent screen. Contacts adds one scope; it is not a second
login:

1. The connect URL takes `?want=calendar|contacts|calendar,contacts`; the
   hub asks for `openid email` plus the scopes of each wanted part (cnf
   `gcal.scopes` for calendar, new cnf `contacts.scopes` for contacts;
   B7 gives `AuthorizeURL` in `api/internal/gcal/oauth.go` the scope to
   ask, as today it sends the one cnf string) with
   `include_granted_scopes=true` (`api/internal/gcal/oauth.go:174`), so an
   existing calendar grant is kept and only the contacts scope is asked for.
2. The callback stores the token answer's `scope` string (oauth.go:235,
   :247) in a new column `gcal_connections.granted_scopes`. The callback
   UPDATES the existing row in place (`INSERT ... ON CONFLICT (tenant_id,
   human_id) DO UPDATE`), never delete-and-insert: a delete would cascade
   to `contacts_sync` (section 3). The new refresh token replaces the old
   one: the landed client forces consent (`oauth.go:175`) and `Exchange`
   refuses an answer without a refresh token (`oauth.go:204-206`), so the
   callback never sees one (C14c). Each sync
   checks the scope it needs in that string: calendar sync skips a row
   without the calendar scope, contacts sync skips a row without the
   contacts scope. 149's calendar cycle needs that one check (B7), or a
   contacts-only connection would get a "Spool Hub" calendar created.
3. Turning contacts off in settings stops the contacts sync and keeps the
   connection; disconnect (149 2.4) ends both.

The People API scope: `https://www.googleapis.com/auth/contacts` for two-way
sync, `https://www.googleapis.com/auth/contacts.readonly` for Google ->
Spool only (O1). Both are scopes Google reviews (unchecked, I believe, that
they are "sensitive" and not "restricted"), so the review question of
149 O2 applies to them too (O2 here). The scope string lives in cnf and is
written there with owner step S2, from O1's answer: B8 reads it and does
not hard-code it.

The table keeps its 149 name `gcal_connections`: renaming a landed table
with live rows is a separate migration for no user gain (P2).

### 2.3 Find a contact from the omnibox

The owner's "searchable from the omnibox" is the composer's `/search <q>`
(`wui/components/TopBar.vue:4`), which opens `/search?q=` and calls
`GET /v1/view/search` (`hub/search.go:50`).

- A new entity type `contact` in `search/grammar.go` (beside `user`, :36),
  searched by default, so `/search FirstName` shows matching contacts with
  the members. `type:contact` narrows to contacts.
- The hub matches `q` against first name, last name, `first || ' ' || last`,
  email and phone digits (a query of digits matches the phone with its
  spaces and punctuation removed), case-insensitive, prefix per word.
- **Only the reader's own contacts**, in the current workspace: the store
  query names `(tenant_id, owner_id)` (2.6). An admin's search does not
  see a member's contacts.
- A hit shows the name, email and phone, and its actions (2.4).
- The command palette gets a `contacts` group (B10), filled from
  `GET /v1/me/contacts` the first time the palette opens; it is a separate
  row so B5 does not wait for it.

A member's list is small (Google caps an account at 25,000 contacts,
unchecked, I believe), so an index on `(tenant_id, owner_id)` and an
`ILIKE` over that member's rows is enough; no search-index change (spec 100).

### 2.4 Message this contact

The owner: "one should be able to send directly spool-hub.ai msgs from it".

- **The contact is a member of this workspace.** The hub matches the
  contact's email to a human with a **verified** identity of that address
  (`human_identities.email` with `email_verified`,
  `rdb/0006_users_and_memberships.sql:34-35`, not `humans.email`, which is
  "informational", :23) who has a membership in the current workspace and
  is not disabled. The match answers the member's `human_id`; the WUI shows
  a **Message** button that opens `/dm/<peer>`, the same route the People
  card and the palette use (`usePaletteItems.ts:89`). The DM page sends as
  today (`hub/wui.go:571`). Whether a match may be shown at all is O3 (it
  tells the reader which member owns that address).
- **The contact is not a member** (no match, or a match in another
  workspace only). The Message button does not appear. What appears instead
  is O4: (A) an Invite button for a reader who holds `rbac.MembersInvite`,
  which fills `POST /v1/members/invites` (`hub/rbac.go:552`) with the
  contact's email, and nothing for others; (B) no Spool action, only the
  email link. A match in another workspace is never revealed.
- **Email and phone are links** in every case, opened by the reader's own
  0193 choices (`wui/utils/contact-links.mjs`): mail client, `tel:`,
  WhatsApp and the others in `rdb/0193_human_contact_links.sql:19`.
- The match runs in the hub per request and is not stored; a contact's
  data never goes into a message or the peer's view.

### 2.5 Sync with Google Contacts

All sync runs in the hub, on its own ticker started from `RunSweeper`
(`hub/server.go:585`), as 149 2.5 does. Contacts change less often than
events: a due connection is synced every 10 minutes, plus "Sync now". There
is no push for contacts (unchecked, I believe: the People API offers no
watch channel), so polling is the only trigger.

- **State**: one row per connection in `contacts_sync` (section 3): the
  People `syncToken`, an `out_cursor`, `due_at` and its own
  `sync_lease_until`. A separate lease from the calendar's, so a long
  calendar sync never holds back contacts and the other way round. The
  claim, fencing token and per-page renewal are 149 2.5's, applied to
  `contacts_sync`. The claim joins `gcal_connections` and takes only rows
  with `status = 'connected'` (as 149's due index, `0217:42`); an
  `ErrInvalidGrant` (`oauth.go:210-211`) in a contacts cycle marks the
  connection revoked through the same helper 149 2.4 uses, never a second
  copy (C23b).
- **One token pair, two cycles**: the calendar and the contacts cycle may
  both refresh the access token of one row at once. The refresh is written
  by one shared helper (149's) with a single `UPDATE gcal_connections SET
  access_sealed, access_expiry` and nothing else, so neither cycle
  overwrites the other's `due_at`, `sync_token` or `out_cursor`. Last
  writer wins on the access token (unchecked, I believe, that an older
  access token stays valid until it expires).
- **In (Google -> Spool)**: `people.connections.list` on `people/me` with
  `personFields=names,emailAddresses,phoneNumbers,metadata`,
  `requestSyncToken=true`, page size 1000, then the stored `syncToken`
  (unchecked, I believe, for every parameter name and limit). Per person:
  first name = the primary `names[].givenName`, last name = its
  `familyName`, email = the primary `emailAddresses[].value` (else the
  first), lowercased, phone = the primary `phoneNumbers[].value` (else the
  first), as Google stores it. A person with none of the four is skipped.
  An unknown `resourceName` is inserted; a known one is patched; a person
  with `metadata.deleted` is soft-deleted in Spool.
- **Out (Spool -> Google, O1 = A only)**: contacts whose
  `GREATEST(updated_at, COALESCE(deleted_at, updated_at))` is after
  `out_cursor` (149 P7's lesson: `updated_at` alone misses deletes):
  `people.createContact` for a contact without `google_resource`,
  `people.updateContact` with the stored `etag` and
  `updatePersonFields=names,emailAddresses,phoneNumbers` for a changed one,
  `people.deleteContact` for a deleted one. An update reads the person
  first and changes only the primary email and phone in its lists, so a
  second email or phone the member keeps at Google is never lost (Spool
  holds one of each; Google may hold many).
- **Echo**: `sync_hash` = SHA-256 of the four values joined by newlines. An
  incoming person whose hash equals the stored one is skipped; so is an
  outgoing write whose hash did not change.
- **Conflict**: the newer side wins (Spool `updated_at` vs Google
  `metadata.sources[].updateTime`, unchecked, I believe); a tie goes to
  Spool; a delete beats an edit on either side. An `etag` mismatch on
  update (unchecked, I believe, that Google answers 400 `FAILED_PRECONDITION`)
  re-reads the person and decides again on the next cycle.
- **Deletes**: Google -> Spool is a soft delete (`deleted_at`,
  `deleted_by = 'google-sync'`), purged after 30 days. Spool -> Google
  deletes the person at Google (O1 = A). The first sync of a new connection
  never deletes on either side; it links contacts that match by email, else
  inserts (no duplicate for a contact typed in Spool before connecting).
  Email is not unique per owner: of several Spool contacts with the
  person's email, the oldest (`created_at`) with no `google_resource` is
  linked, the others stay unlinked (C20b).
- **An expired sync token** (unchecked, I believe: after 7 days, answered
  410 or `EXPIRED_SYNC_TOKEN`): cleared, a full list, matched by
  `google_resource`, no duplicates, no deletes from that pass.
- **Rate limits**: the People API has per-project and per-user quotas
  (numbers unchecked, I believe). The cycle sends a member's writes one at
  a time (Google asks that mutations for one user be sequential, unchecked,
  I believe), at most 200 writes per cycle, the rest the next cycle; a 429
  or 503 backs off with `Retry-After` or 2^n minutes up to 1 h and sets
  `status_detail`. One member's backlog never delays another's: the claim
  takes one connection at a time, oldest `due_at` first.

### 2.6 Privacy

Contacts are personal data of people who never agreed to be in Spool.

- **Per member, per workspace**: a contact belongs to `(tenant_id,
  owner_id)`. No other member, admin or owner of the workspace reads it,
  through any route, search or export. Whether a member's list follows
  them to their other workspaces is O5.
- **RLS**: `tenant_scope` + `operator_scope` on both new tables
  (`rdb/0187_marketing.sql:107-114`). Postgres has no per-member policy on
  master (1.2 row 20), so member isolation is the store's: every store
  method takes `(tenant, owner)` and every query names both (C3, C4). The
  sync cycle picks due rows under `operator` scope, then reads and writes
  each under its own tenant and owner.
- **Never logged**: no contact value (name, email, phone) in a log line, an
  error body or a metric label; logs carry `contact_id` only (C12).
- **Export**: `GET /v1/me/contacts/export` answers the member's contacts as
  CSV with exactly the four columns plus `google_resource`.
- **Erase**: `DELETE /v1/me/contacts/{id}` (one; also at Google when the
  sync is two-way) leaves every read at once. With a Google delete to
  send (O1 = A, a `google_resource`, the contacts sync on) it is a soft
  delete (`deleted_at = now()`, `deleted_by = 'member'`): the sync cycle
  sees it through `out_cursor` and calls `people.deleteContact` (C17b).
  With nothing to send to Google it is a hard delete at once (C7b). `DELETE
  /v1/me/contacts?scope=spool` (all, in Spool only, nothing at Google) is a
  hard delete in one transaction that also sets `contacts_sync.enabled =
  false` for the member's connection, so a later full list does not import
  them again. Soft-deleted rows are purged 30 days after `deleted_at` by
  B3's job on the existing `RunSweeper` retention (`hub/server.go:585`),
  not by the sync, so the purge works before B8 and O1. A member-deleted
  row whose Google delete has not gone out by then (sync off, backoff) is
  purged anyway and `contacts_sync.status_detail` says the delete did not
  reach Google (C7c).
- **Leaving the workspace**: by whatever path the membership row goes,
  the contacts in that workspace go with it, by the schema: `contacts`
  references `tenant_memberships (tenant_id, human_id)` with `ON DELETE
  CASCADE` (section 3). Four store paths delete memberships today
  (`git grep -ln 'DELETE FROM tenant_memberships' -- csi-spl-api
  ':!*_test.go'` -> `clones.go`, `demo_stay.go`,
  `embed_visitor_messages.go`, `humans_rbac_postgres.go`), and the demo
  workspace removes by `BanMember` (`hub/rbac.go:510-511`), so one call in
  `RemoveMember` would miss three of them. Each of the four is a real leave
  (a clone retired, a demo stay ended, a channel guest erased, a member
  removed), none a delete-and-insert of a member who stays. When their human is deleted,
  the cascade on `humans` does it. Valid for O5 = A; on O5 = B `tenant_id`
  leaves `contacts` and B1 changes anyway.
- **Disconnect** keeps the contacts in Spool unless the member ticks
  "remove imported contacts" (those with a `google_resource`).

### 2.7 WUI

- A new rail tab **Contacts** (`wui/utils/rail-order.ts:20`), pages
  `wui/pages/contacts/index.vue` and `[id].vue`, in the People section's
  shape (1.2 row 6): the list, a filter box, Add, and a card with the four
  fields, Edit, Delete, the Message or O4 action and the 0193 links.
- In the 149 settings section `calendar-google`: a **Contacts** switch
  (connect with `want=contacts`; off stops the sync), last sync time and
  status, Sync now.
- The section is its own lazy chunk: it does not raise `ci_initial_gzip_kb`.
- Every string is a translation key (developer guide 2.4).

### 2.8 Local dev and tests

`SPOOL_CLOUD_PROVIDER=none` (spec 148): the contacts list works; the Google
switch answers 503 `gcal_not_configured` (149 2.8). Tests run against a new
`api/internal/gcal/fakegcal/people.go` (connections list with sync tokens,
an expired token, create, update with an etag check, delete, a 429) and
`marketing.NewFakeKMS`. No test reaches Google.

### 2.9 Kill switch

cnf `contacts.workspaces` (per env, `[]` = off), as `gcal.workspaces`
(149 2.9): outside it every `/v1/me/contacts*` route answers 404, the rail
tab is hidden and `/search` returns no `contact` section. Turning it on in
an env is an owner go (S4). The Google part also needs `gcal.workspaces`.

## 3. Data

One additive migration, `rdb/<next>_contacts.sql` (`<next>` = 0221 on
`fb7b73093`, 1.2 row 24). RLS in the 0187 shape.

```sql
ALTER TABLE gcal_connections
    ADD COLUMN granted_scopes text NOT NULL DEFAULT ''
        CHECK (length(granted_scopes) <= 2000);

CREATE TABLE contacts (
    contact_id      uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       text        NOT NULL REFERENCES tenants (tenant_id) ON DELETE CASCADE,
    owner_id        text        NOT NULL REFERENCES humans (human_id) ON DELETE CASCADE,
    FOREIGN KEY (tenant_id, owner_id) REFERENCES tenant_memberships (tenant_id, human_id) ON DELETE CASCADE,
    first_name      text        NOT NULL DEFAULT '' CHECK (length(first_name) <= 100),
    last_name       text        NOT NULL DEFAULT '' CHECK (length(last_name) <= 100),
    email           text        NULL
        CHECK (email IS NULL OR (email = lower(email) AND length(email) BETWEEN 3 AND 320)),
    phone           text        NULL
        CHECK (phone IS NULL OR phone ~ '^[+0-9 ().-]{3,40}$'),
    google_resource text        NULL CHECK (google_resource IS NULL OR length(google_resource) <= 200),
    google_etag     text        NOT NULL DEFAULT '' CHECK (length(google_etag) <= 200),
    sync_hash       text        NULL CHECK (sync_hash IS NULL OR length(sync_hash) = 64),
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now(),
    deleted_at      timestamptz NULL,
    deleted_by      text        NULL CHECK (deleted_by IS NULL OR deleted_by IN ('member', 'google-sync')),
    CHECK (first_name <> '' OR last_name <> '' OR email IS NOT NULL OR phone IS NOT NULL)
);
CREATE INDEX contacts_owner ON contacts (tenant_id, owner_id) WHERE deleted_at IS NULL;
CREATE UNIQUE INDEX contacts_google ON contacts (tenant_id, owner_id, google_resource)
    WHERE google_resource IS NOT NULL;

CREATE TABLE contacts_sync (
    connection_id    uuid        PRIMARY KEY REFERENCES gcal_connections (connection_id) ON DELETE CASCADE,
    tenant_id        text        NOT NULL REFERENCES tenants (tenant_id) ON DELETE CASCADE,
    enabled          boolean     NOT NULL DEFAULT true,
    sync_token       text        NULL,
    out_cursor       timestamptz NULL,
    due_at           timestamptz NOT NULL DEFAULT now(),
    sync_lease_until timestamptz NULL,
    backoff_until    timestamptz NULL,
    status_detail    text        NOT NULL DEFAULT '' CHECK (length(status_detail) <= 500),
    last_synced_at   timestamptz NULL,
    created_at       timestamptz NOT NULL DEFAULT now(),
    updated_at       timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX contacts_sync_due ON contacts_sync (due_at) WHERE enabled;

ALTER TABLE contacts ENABLE ROW LEVEL SECURITY;
ALTER TABLE contacts FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_scope ON contacts
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''));
CREATE POLICY operator_scope ON contacts
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');
-- the same two policies on contacts_sync
```

The `phone` CHECK accepts what people type (`+1 555 010 0000`,
`(555) 010-0000`); it is not E.164, because Google stores the value as
entered and a normalised copy would break the echo hash. The digits-only
form for search is computed in the query.

## 4. Routes

| route | who | answer |
|---|---|---|
| `GET /v1/me/contacts?q=&cursor=` | member | `{contacts:[{contact_id, first_name, last_name, email, phone, google}], next}`, the caller's own only |
| `POST /v1/me/contacts` | member | 201 `{contact}`; 400 `contact_empty` with none of the four |
| `PATCH /v1/me/contacts/{id}` | member | 200 `{contact}`; 404 for another member's id |
| `DELETE /v1/me/contacts/{id}` | member | 204; 404 for another member's id |
| `DELETE /v1/me/contacts?scope=spool` | member | 204, every own contact in this workspace |
| `GET /v1/me/contacts/export` | member | `text/csv`, own contacts |
| `GET /v1/me/contacts/{id}/peer` | member | `{human_id}` when 2.4 matches (and O3 allows), else 404 |
| `PUT /v1/me/contacts/sync` `{enabled}` | member | 204; 409 `gcal_not_connected` without a connection; 409 `scope_missing` with a URL to add the scope |
| `POST /v1/me/contacts/sync` | member | 202; 409 `sync_in_progress` while the lease is held |
| `GET /v1/view/search?q=` | member | gains a `contact` section, own rows only |
| `OPTIONS` on each `/v1/me/contacts*` path | browser preflight | as every `/v1/me` route (149 section 4) |

Errors: `{"error":"<code>"}`: `not_found` 404 (workspace off, or not the
caller's), `contact_empty` 400, `bad_email` 400, `bad_phone` 400,
`gcal_not_connected` 409, `scope_missing` 409, `sync_in_progress` 409.

## 5. Cases

Every case is **planned**. "Master today" is `9e8ece102`. Each red control
fails on master today and passes once its row lands; (C) marks a control
that must pass on both. "n/a" = the route or table does not exist yet; the
control then carries its twin.

| # | row | case | master today | expected | red control |
|---|---|---|---|---|---|
| C1 | B1 | the migration applies after `0220` | tables absent | `contacts`, `contacts_sync`, the column, 4 policies | rdb test: `\d contacts` errors today |
| C1b | B1 | `TestCrossTenantEveryTable` and `TestRLSChannelScopeCatalogue` with the new tables | pass | pass (C) | B1 seeds both tables in `store/crosstenant_test.go`; no `channel` column |
| C2 | B1 | as tenant A, read a tenant B row of `contacts` | n/a | 0 rows | Postgres test; twin: the same row as tenant B is read |
| C2b | B1 | insert a contact with all four empty | n/a | CHECK violation | Postgres test; twin: one value set inserts |
| C3 | B2 | store: member M2 lists, reads, patches, deletes M1's contact, same workspace | n/a | not found, nothing changed | Go test, memory and Postgres; twin: M1 does each |
| C4 | B3 | an admin (`rbac.MembersRoles`) calls `GET /v1/me/contacts/{M1's id}` | 404 (no route) | 404 | Go test; twin: M1 gets 200 |
| C5 | B3 | `POST /v1/me/contacts` with `FirstName`, `LastName`, `first.last@example.com`, `+1 555 010 0000` | 404 | 201, the four values back | Go test |
| C6 | B3 | the same in a workspace not in `contacts.workspaces` | 404 | 404 (C) | Go test |
| C7 | B3 | export | 404 | CSV header `first_name,last_name,email,phone,google_resource`, own rows only | Go test with two members |
| C7b | B3 | delete a contact with no `google_resource` | n/a | the row is gone (hard) | Go test; twin: with a `google_resource` and the sync on, soft |
| C7c | B3 | a soft-deleted row 31 days old, Google delete never sent | n/a | purged; `status_detail` set | Go test, fake clock; twin: 29 days old stays |
| C8 | B4 | M1 is removed from the workspace (`RemoveMember`) | contacts n/a | M1's contacts there are gone; M1's contacts in another workspace stay | Postgres test; twin: another member's stay |
| C8b | B4 | a demo user is banned (`BanMember`), and a demo stay expires (`demo_stay.go`) | contacts n/a | their contacts there are gone | Postgres test; twin: a member who stays keeps theirs |
| C9 | B5 | `/v1/view/search?q=FirstName` as M1 | no `contact` section | M1's matching contact in it | Go test |
| C10 | B5 | the same query as M2 | n/a | no M1 contact | Go test; twin: M1's own search finds it (else it passes on an empty result) |
| C10b | B5 | `q=5550100000` against `+1 555 010 0000` | n/a | found | Go test |
| C11 | B5 | `type:contact` | `bad_query` | contacts only | Go test |
| C12 | B3, B8 | after create, search and a sync, no contact value appears in any captured log line | n/a | true | Go test greps the captured log for the fixture's four values |
| C13 | B6 | `/peer` for a contact whose email is a verified identity of a member here | 404 | `{human_id}` | Go test |
| C13b | B6 | the address is only in `humans.email`, not verified | n/a | 404 | Go test; twin: verified matches |
| C13c | B6 | the address is a member of another workspace only | n/a | 404 | Go test; twin: a member here matches |
| C13d | B6 | the matched member is disabled | n/a | 404 | Go test |
| C14 | B7 | connect with `want=contacts` on a row that holds the calendar scope | no `want` | the URL asks the contacts scope with `include_granted_scopes=true`; the callback stores both scopes in `granted_scopes` | Go test beside the 149 connect test |
| C14c | B7 | reconnect of a connected row | n/a | the same `connection_id`, the new `refresh_sealed`, the `contacts_sync` row kept | Postgres test; twin: a delete-and-insert callback loses the `contacts_sync` row |
| C14b | B7 | a contacts-only connection, one 149 calendar cycle | n/a (149 B6a not landed) | no calendar call at the fake | Go test counts the fake's calendar calls; twin: the calendar scope present -> one calendar call |
| C15 | B8 | a new person on the fake | n/a | a contact with the four values and `google_resource` | Go test on `fakegcal` |
| C15b | B8 | a Google person with two emails, the second primary | n/a | the primary one stored | Go test |
| C15c | B8 | `metadata.deleted` on the fake | n/a | soft-deleted, `deleted_by = 'google-sync'` | Go test |
| C16 | B8 | echo: the next list returns the same person | n/a | 0 writes | Go test |
| C17 | B8 | a Spool edit, O1 = A | n/a | one update with the stored etag; the person's second phone at the fake kept | Go test reads the fake's person |
| C17b | B8 | a Spool delete, O1 = A | n/a | one delete at the fake | Go test; twin: an `updated_at`-only cursor misses it |
| C18 | B8 | conflict: both edited, Google later | n/a | Google's values in Spool, no update sent | Go test, fake clock |
| C19 | B8 | expired sync token | n/a | full list, no duplicates, no deletes | Go test |
| C20 | B8 | first sync with a Spool contact of the same email | n/a | linked, one contact | Go test |
| C20b | B8 | first sync, two Spool contacts of that email | n/a | the older one linked, the newer unlinked | Go test |
| C21 | B8 | a 429 from the fake | n/a | `backoff_until` set, no further call that cycle | Go test |
| C22 | B8 | 300 pending Spool writes | n/a | 200 sent this cycle, 100 the next | Go test counts the fake's writes |
| C23 | B8 | two cycles at once (Postgres) | n/a | each connection synced once; no transaction open during a fake call | Postgres test, as 149 C21 |
| C23b | B8 | a revoked connection; and an `invalid_grant` from the fake | n/a | no fake call; the connection turns `revoked` | Go test; twin: a connected row is synced |
| C23c | B8 | a calendar refresh and a contacts cycle on one row | n/a | `due_at`, `sync_token`, `out_cursor` of the other cycle unchanged | Postgres test |
| C24 | B9 | the Contacts tab and page on the mock bundle: add, find, Message for a member, no Message for a non-member | absent | as stated | e2e on the mock bundle |
| C25 | B9 | initial JS budget | - | not raised (C) | `csi-spl-orc/src/bash/scripts/perf-budget.py` |
| C26 | B10 | palette `contacts` group | 6 groups | 7, filled on first open | wui unit test on `usePaletteItems.ts` |
| C27 | B11 | the new keys in every locale; the two ratchet counts not raised | missing | present | `i18n-untranslated` and `i18n-no-raw-text` tests |

## 6. Build rows

Disjoint files per row. Data, then store and API, then Google, then WUI;
i18n with the agy review last. Author per the fleet table
(`complex_coding` and `tests`: claude; `i18n` and `specs_and_docs`: agy; no
mistral coding, owner 2026-10-17). R7 reviewer
(`csi-spl-doc/doc/md/rounds-rulebook.md` 2.7.2): cross-vendor, named in the
row brief before spawn. Contacts are personal data: every coding row
routes as `secret` kind (claude, grok or mistral only; never qwen or agy),
and its fixtures use `FirstName LastName` and `example.com` only. "api
tests" = `bash csi-spl-api/src/bash/tests/run-all-tests.sh`; "full tier" =
`cd csi-spl-iac && PRE_PUSH_TIER=full ./run -a do_check_pre_push`.

| row | area | files (only these) | after | cases | test | author | R7 reviewer (backup) |
|---|---|---|---|---|---|---|---|
| B1 data | rdb, api | new `rdb/<next>_contacts.sql`; `store/crosstenant_test.go` (seed both tables) | **O5** | C1-C2b | rdb apply + Postgres tests; full tier | claude | grok (claude) |
| B2 store | api | new `store/contacts.go`, `store/contacts_memory.go`, `store/contacts_postgres.go`, `store/contacts_test.go`; one field in `store/memory.go` | B1 | C3 | `store/contacts_test.go`, memory and Postgres; full tier | claude | grok (claude) |
| B3 contacts routes | api, cnf | new `hub/contacts.go` + `_test.go` (CRUD, export, erase); one route line and one Options field in `hub/server.go`; one opts line in `api/cmd/spool/hub.go` (as 149 B5); the purge on `RunSweeper`'s retention; a `contacts:` block in `cnf/all.env.yaml` (`workspaces: []`, `scopes` empty until S2) and its tpl-gen output; one block in `api/internal/config/config.go` | B2 | C4-C7c, C12 | `hub/contacts_test.go`; api tests; `ENV=<env> ./run -a do_tpl_gen` + `git diff --exit-code` | claude | grok (claude) |
| B4 leave = erase | api | tests only: the cascade is B1's foreign key; new Postgres cases in `store/humans_rbac_test.go` (remove) and the demo ban and stay tests beside `store/demo_stay.go`; the memory store's membership deletes drop the owner's contacts too (`store/contacts_memory.go` hook, B2's file) | B2 | C8-C8b | the new Postgres test; full tier | claude | grok (claude) |
| B5 search | api | `search/grammar.go` (`TypeContact`); `hub/search.go` (the `contact` section); their tests | B2 | C9-C11 | `go test ./internal/search/ ./internal/hub/ -run Search`; api tests | claude | grok (claude) |
| B6 member match | api | new `hub/contacts_peer.go` + `_test.go` (`/peer`); one registration line in `hub/contacts.go`'s route func (B3's file, so B6 lands after B3); no new `server.go` line | B3, **O3** | C13-C13d | `hub/contacts_peer_test.go`; api tests | claude | grok (claude) |
| B7 the contacts scope | api | `api/internal/gcal/oauth.go` (`AuthorizeURL` takes the scope to ask) + `oauth_test.go`; `hub/gcal_connect.go` (149 B5's file: `want`, `granted_scopes`, the upsert) and one scope check in `hub/gcal_sync.go` (149 B6a's file); their tests | 149 B5, 149 B6a, B1 | C14-C14c | the 149 connect and sync tests plus the two new ones; api tests | claude | grok (claude) |
| B8 contacts sync | api | new `hub/contacts_sync.go` + `_test.go`; new `api/internal/gcal/people.go` + test; new `api/internal/gcal/fakegcal/people.go`; a `PeopleBase` in `api/internal/gcal/oauth.go` Config (after B7's edit of the same file), `api/internal/config/config.go`, `api/cmd/spool/hub_gcal.go` (149 B5's file) and its cnf key; one line in `hub/server.go` `RunSweeper` (:585) | B3, B7, **O1** | C12, C15-C23c | `go test ./internal/gcal/... ./internal/hub/ -run Contacts`; api tests; full tier | claude | grok (claude) |
| B9 WUI | wui | `wui/utils/rail-order.ts` (one tab); new `wui/pages/contacts/index.vue`, `wui/pages/contacts/[id].vue`, `wui/utils/contacts-client.mjs`; the Contacts switch in `wui/components/settings/calendar-google.vue` (149 B8's file); `csi-spl-wui/i18n/locales/en.json` (new keys only); unit + e2e tests | B3, B6, 149 B8, **O4** | C24-C25 | `pnpm run typecheck`; unit tests; `BASE_URL=<mock bundle> pnpm run test:e2e`; `perf-budget.py` | claude | grok (claude) |
| B10 palette | wui | `wui/composables/usePaletteItems.ts` (the `contacts` group) + its unit test | B9 | C26 | the unit test; `perf-budget.py` | claude | grok (claude) |
| B11 i18n | wui | `csi-spl-wui/i18n/locales/*.json` except `en.json` (new keys only); agy has the last word (`LANE_MIX_KIND=i18n`) | B9, B10 | C27 | the two ratchet tests | agy | claude |
| B12 help | doc | a new help page (what is stored, who sees it, Google sync, export and erase), written in its qto doc and exported (`do_spl_doctree_export_md`); agy review | B9 | - | `cd csi-spl-iac && ./run -a do_check_dist_hygiene`; the qto doc drift check | agy | claude |

Order: B1 once O5 is answered (on B, `tenant_id` leaves `contacts` and the
RLS shape changes); then B2; then B3, B4 and B5 at once (no shared file);
B6 after B3 and only once O3 is answered; B7 after spec 149's B5 and B6a
have landed (it edits their files, so it rebases onto them and its brief
names their lanes); B8 after B7 and only once O1 is answered; B9 after B3,
B6, 149 B8 and O4; B10 after B9; B11 and B12 last. B3 and B8 both edit
`hub/server.go` (one line each): B8 rebases onto B3. B7 and B8 both edit
`api/internal/gcal/oauth.go`: B8 rebases onto B7, and its brief says so.

What waits on the owner: B1 (O5), B6 (O3), B8 (O1) and B9's non-member
action (O4). O2 and S1-S4 gate switching the Google part on, not any row:
every row is tested on the fake (2.8) and lands behind
`contacts.workspaces: []`.

## 7. Owner steps (never a lane)

| # | step | what |
|---|---|---|
| S1 | enable the People API | add `people.googleapis.com` to the API list (`cnf/all.env.yaml:60-85`) in the project of 149's S1, then the 001 step apply (owner go; terraform only through the tf-runner) |
| S2 | consent screen | add the O1 contacts scope to that project's consent screen, beside 149's calendar scope; Google's review is O2 |
| S3 | no new client, redirect, key or secret | 149's client, its redirect URI (149 S3) and the KMS key are reused |
| S4 | switch on | `contacts.workspaces` per env, dev first, after B9 is live; a step-030 apply each (149 S5) |

## 8. Editor's proposals (for the panel)

| # | question | proposal | reason |
|---|---|---|---|
| P1 | a second Google connection for contacts | no: 149's row, one more scope, a `granted_scopes` column | one Google account per member; `include_granted_scopes=true` is in the landed client (`gcal/oauth.go:174`), a per-call scope is not (B7 adds it, 1.2 row 15) |
| P2 | rename `gcal_connections` to a neutral name | not in v1 | a rename of a landed table with rows is its own migration; the name is internal |
| P3 | Contacts inside People, or its own section | its own rail tab | People is the workspace's members (`wui/pages/people/index.vue:1-2`); contacts are private and may not be members |
| P4 | several emails or phones | one each, the primary; write-back keeps Google's others | the owner's four attributes; losing a second number at Google would be data loss |
| P5 | member match key | a verified identity email only | `humans.email` is informational (`rdb/0006_users_and_memberships.sql:23`); an unverified address could point a contact at the wrong person |
| P6 | Postgres per-member policy | no: store isolation, as 149 | no `app.human_id` setting on master (1.2 row 20); adding one touches every session setup |
| P7 | push for contacts | none, a 10 min poll | no watch channel for the People API (unchecked, I believe) |
| P8 | search index | none: `ILIKE` over the reader's own rows | a member's list is small; spec 100's index is workspace-wide by design |

## 9. Owner questions

Only the owner can answer these. The dispatcher posts them after the panel,
one form per post (`csi-spl-doc/doc/help/how-to-post.md` section 7).

```poll
O1. Which way should contacts sync with Google?
(A) Both ways: contacts added, changed or deleted in Spool change in Google too, and the other way round
(B) One way only: Google contacts come into Spool; changes made in Spool stay in Spool
```

```poll
O2. Contacts access is a scope Google reviews, like calendar access. What do we do about Google's review?
(A) Submit contacts and calendar together in one review, once both scopes are on the consent screen
(B) Do for contacts whatever is decided for calendar
(C) Do not submit for now: only members we list as test users can connect contacts
```

```poll
O3. When a contact's email belongs to a member of the same workspace, may Spool show a Message button for that member? It tells the person that this member uses that email address.
(A) Yes, show Message for a contact whose email is a verified address of a member here
(B) No, never match contacts to members; the person finds the member in People instead
```

```poll
O4. What can a person do with a contact who is not a member of the workspace?
(A) People who may invite members see an Invite button that sends a workspace invite to the contact's email; others see only the email and phone links
(B) Nothing in Spool: only the email and phone links
```

```poll
O5. Whose list is it, when a person is in several workspaces?
(A) One list per workspace: contacts added in one workspace are not seen in another
(B) One personal list that follows the person into every workspace they belong to
```

## 10. Panel record

| when (UTC) | who | what |
|---|---|---|
| 2026-10-24 | c-951@sat | v0.1 `0618ced5f`: section 1 measured on `9e8ece102` (24 rows), sections 2-9 written; agy (main) out of quota |
| 2026-10-24 04:21 | a-957@sat (seat agy) | review d5f81cad on `fb7b73093`: 1.2 rows 1-23 OK, row 24 stale (next migration 0221); member delete must be soft (2.6 vs 2.5, C17b); callback must upsert and keep the refresh token; B4, B6 file lists. Scope class "sensitive, not restricted": stated without a source, kept "unchecked, I believe" (dispatch holder c-003, dcb58aae) |
| 2026-10-24 | c-951@sat | v0.2 `813557fe5`: all of a-957's findings folded except the scope-class wording; C14c added |
| 2026-10-24 04:29 | c-958@sat (seat claude) | review b362b28a on `813557fe5`: 1.2 rows 1-24 OK; W1 the landed `AuthorizeURL` has no per-call scope (row 15, P1, B7); W2 `Exchange` refuses an answer without a refresh token, so v0.2's keep-the-old-token clause was wrong (C14c); W3 four store paths delete memberships, so leave = erase belongs in the schema; G1 claim only connected rows, revoke on invalid_grant; G2 one token pair, two cycles; G3 B8 needs a People base URL; G4 B3 wiring; G5 purge before B8, hard delete when nothing goes to Google; G6 first-sync link with a duplicate email; G7 C14b is n/a on master; O4 wording |
| 2026-10-24 | c-951@sat | v0.3, this commit: all of c-958's findings folded (each checked on the tree); W2 by its option (a), no landed code changes; new cases C7b, C7c, C8b, C20b, C23b, C23c |

<!-- version: 0.3 · updated: 2026-10-24 -->
