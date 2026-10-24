# 154 Contacts section, synced with Google Contacts

Version v1.1 draft (2026-10-24), NOT signed yet: it folds the owner's five
answers (section 9) into v1.0 (`225f4e583`, signed by both panel seats,
section 10). The two review seats sign v1.1 in their own messages before it
is final. Step 2 of the owner rule for a big change: the written spec, then
the panel, then the build. v1.0 by c-951@sat, v1.1 by c-988@sat (both
claude). Nothing in it is built.

Source: prd topic in the owner's workspace,
`topic:451c020f-5440-4849-8dea-2246d5796ed4`. Issues: SPL-3156 (v0.1 to
v1.0), SPL-3192 (v1.1), epic SPL-3036. Each build row in section 6 gets its
own issue when it is placed.

**What v1.1 changes, from the owner's answers.** O5 = B: the list belongs to
the person, and the same list shows in every workspace they belong to. So
`contacts` moves into spec 119's personal realm as `personal.contacts`, with
no `tenant_id`, isolated by the realm's own `person_scope` policy. Leaving
a workspace no longer erases the list, and the Google sync binds one of the
person's workspace connections (2.2, 2.5, 2.6, 3). The other four answers
settle what v1.0 left open: O1 = A (two-way sync), O2 = A (one combined
Google review), O3 = A (Message, matched in the current workspace only) and
O4 = A (Invite, to the current workspace only).

**v1.1 amendment, the same day (owner msgs `14cdf0ad`, `31bb12ea`).** There
is no separate Contacts section: the existing **People** section shows the
reader's contacts together with the workspace's members, in one list. The
list has three groups: members online now, then the other members, then
the reader's other contacts, sorted A-Z inside each group. A filter shows
only the members of the current workspace (2.7). B1 (data) does not change.
B6 becomes a member match carried on every contact in the list, in place of
the `/peer` route. B9 edits the People section and adds no rail tab. B10
puts contacts in the palette's existing `people` group.

Paths used below:

- `api/` = `csi-spl-api/src/go/spool-hub-api/`
- `hub/` = `api/internal/hub/`, `store/` = `api/internal/store/`
- `rdb/` = `csi-spl-rdb/src/sql/postgres/spool-hub/`
- `roles/` = `csi-spl-rdb/src/sql/postgres/spool-hub-roles/`
- `wui/` = `csi-spl-wui/src/`
- `cnf/` = `csi-spl-cnf/csi-spl/`

Every `file:line` of v1.0 was read on origin/master `9e8ece102` with
`git grep -n`, `grep -n` or `sed -n` on that tree. v1.1 re-read section 1.2
on origin/master `e0f02e7ff`, one `git show e0f02e7ff:<file> | sed -n
<lines>p` per row. Rows 1-19, 22 and 23 hold as written. Rows 20, 21 and 24
are corrected, and rows 25-31 are new. Nothing was read from prd or GCP and
no Google API was called. A claim about Google's own behaviour (the People
API, its scopes, quotas and sync tokens) that the editor did not test is
marked "unchecked, I believe".

Builds on, and does not repeat:
[149 Google Calendar connect](../149-google-calendar-connect/spec.md) v1.0
(the per-member Google connection this spec reuses),
[119 personal realm](../119-personal-realm/spec.md) (the person-level layer
the list lives in),
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

2026-10-23 21:45Z: "Go implrment" (msg `b28cae33`). The five answers of
2026-10-24 are in section 9.

## 1. What exists on master (measured)

### 1.1 Nothing of the feature is built

`git grep -niE 'contact' 9e8ece102 -- csi-spl-api csi-spl-rdb csi-spl-wui/src`
hits only mailto:/tel: link handling (`rdb/0193_human_contact_links.sql`,
`wui/utils/contact-links.mjs`), payment contact info
(`api/internal/payments/handler.go`, `wui/utils/checkout-client.ts`), a
help line and tests. None of them is a contact list. Re-run on `e0f02e7ff`
(`git grep -li contact`): the same kinds of files, 14 of them, and still no
contact list. Every case in section 5 is red on master today unless marked
(C).

### 1.2 The code this spec stands on

| # | what | measured on `9e8ece102` (v1.1: `e0f02e7ff`) | what it means here |
|---|---|---|---|
| 1 | how a person is stored | `rdb/0006_users_and_memberships.sql:19-27` `humans`: `human_id` (CHECK `'^HUM-[0-9]+$'`, :21), `display_name` (<= 200), `email` ("Last verified email seen at sign-in; informational, not unique", :23-24), `created_at`, `disabled_at` | no first name, last name or phone; a member is not a contact |
| 2 | verified addresses | `rdb/0006_users_and_memberships.sql:30-39` `human_identities`: `(provider, subject)`, `email` (:34), `email_verified` (:35) | the only safe key to match a contact to a member (2.4) |
| 3 | membership | `rdb/0006_users_and_memberships.sql:45` `tenant_memberships` | "member of this workspace" |
| 4 | a phone column | none: `rdb/0193_human_contact_links.sql:21-23` `email_client`, `phone_app` are the app a link opens, not stored numbers | a contact's phone is new data; its link reuses 0193 (2.4) |
| 5 | store types | `store/member_directory.go:20` `type Member struct`, `store/search.go:87` `type HumanEntry struct`; no `type Human struct` | a contact gets its own type |
| 6 | the People section | `wui/pages/people/index.vue:1-2` and `[id].vue:1-4`: the workspace's members; the card has a Message button that opens the DM | the amendment merges contacts into it (2.7, P3; rows 32-34) |
| 7 | a DM | `store/view.go:38` `DM bool // only messages with no channel`; the page is `wui/pages/dm/[peer].vue`, reached at `/dm/<peer>` (`wui/composables/usePaletteItems.ts:88-89`) | there is no DM to create: "message this contact" is a route to `/dm/<peer>` |
| 8 | sending a message | a WebSocket frame: `GET /v1/wui/ws` (`hub/server.go:416`), `case "send"` (`hub/wui.go:368`) -> `wuiSend` (`hub/wui.go:571`), recipient from `wuiRecipient` (`hub/wui.go:859`, `to = f.To` :860) | Contacts sends nothing itself; the DM page does |
| 9 | inviting a non-member | `POST /v1/members/invites` (`hub/rbac.go:552`, handler `:324`), gated by `rbac.MembersInvite` (`:325`); body email, role, ttl_hours, no_mail (`:329-336`) | the one existing way to bring a non-member in (O4) |
| 10 | the omnibox | `wui/components/TopBar.vue:1-4`: one composer; plain text goes to the page's send target, `/search <q>` opens `/search?q=`; `wui/stores/omnibox.ts:5-7` "with no target ... the Omnibox only searches" | contacts are found through `/search` (2.3) |
| 11 | the hub search | `GET /v1/view/search` (`hub/search.go:50`), handler `:111`; entity types `search/grammar.go:30-45` (message, topic, file, robot, user, channel, box, tenant, event, issue); members as hits from `TenantHumans` (`hub/search.go:484-485`) | a new type `contact`, the reader's own rows only |
| 12 | the command palette | `wui/composables/usePaletteItems.ts:40` `PALETTE_GROUPS = ['sections', 'channels', 'people', 'topics', 'docs', 'settings']`; client-side over the stores' lists (`:83-107`) | contacts join the existing `people` group (B10, amendment) |
| 13 | rail sections | `wui/utils/rail-order.ts:20` `export const RAIL_TABS`; `people` is one of them (:45); the palette lists them (`usePaletteItems.ts:63-80`) | no new rail tab (amendment): contacts live in `people` |
| 14 | spec 149's Google connection | landed: `rdb/0217_google_calendar.sql:17-41` `gcal_connections`, `UNIQUE (tenant_id, human_id)` (:40), sealed tokens `access_sealed`, `refresh_sealed`, `kms_key_id` (:26-28); no column for the granted scopes | one Google connection per member per workspace exists; contacts adds a scope to it, not a second login (2.2) |
| 15 | spec 149's Google client | landed (`bf5a169e4`): `api/internal/gcal/oauth.go:172-174` sends `scope` from cnf `gcal.scopes` (:58) and `include_granted_scopes=true`; the token answer's `scope` is parsed (`:235`, :247) | the granted scope string is already in hand; but `AuthorizeURL(state)` (:167) takes no scope argument, the scope is fixed per client from cnf (:58, :172), so asking for one part's scope needs a change in `oauth.go` (B7) |
| 16 | spec 149's hub side | `ls hub/ \| grep -c gcal` -> 0: no connect route, sync or WUI yet (149 B5-B10 not landed); v1.1: `git ls-tree --name-only e0f02e7ff api/internal/hub/ \| grep -c gcal` -> 0 | B7, B8 and B9 here come after 149 B5, B6a and B8 |
| 17 | sign-in scopes | `cnf/all.env.yaml:704` `SPOOL_HUB_AUTH_GOOGLE_SCOPES: "openid email profile"`; `auth/idp.go:146` `access_type=online` | sign-in never returns a refresh token; the connect flow is 149's (149 P1) |
| 18 | the sealer | `api/internal/marketing/seal.go:115` `Seal`, `:139` `Open`; `:87` names 149's purpose `spool-gcal-token/v1` | tokens stay sealed under 149's purpose; contacts adds no token |
| 19 | RLS shape of a workspace table | `rdb/0187_marketing.sql:107-114`: ENABLE + FORCE, `tenant_scope` on `app.tenant_id`, `operator_scope` on `app.rls_scope` | the two policies on `contacts_sync`, the one new workspace table (3) |
| 20 | per-person RLS (**corrected in v1.1**) | v1.0 read `grep -l "app.human_id" rdb/*.sql` -> none, and concluded that no policy isolates a person. That grep looked for the wrong setting. On `e0f02e7ff`: `rdb/0168_personal_realm.sql:133-151` puts the policy `person_scope` on every table of the schema `personal`: the row's `person_id` equals `app.person_id`, `app.tenant_id` is unset and the scope is not operator (:142-148). `app.person_id` is set only by `store/rls.go:82` `inPerson` (constant `pgScopePerson`, :59). Also `rdb/0176_hours_entry_spans.sql:22` has a member scope, `app.member_id` (`store.inMember`) | Postgres does isolate a person today, in `personal`. The list goes there (2.6, 3); it is not "the store is the only guard" |
| 21 | the sweeper | `hub/server.go:585` `func (s *Server) RunSweeper`; v1.1: now `hub/server.go:586` | the contacts sync ticker and the purge start there, as 149's |
| 22 | data export / erase | none for a member: the nearest are `GET /v1/hours/export` (`hub/hours_team.go:348`), `DELETE /v1/embed/{embed_id}/visitor` (`hub/embed_visitor.go:52`), `DELETE /v1/members/{human_id}` (`hub/rbac.go:556`, handler `:473`) | contacts bring their own export and erase routes (2.6) |
| 23 | settings sections | `wui/utils/settings-nav.mjs:6-14` (7 ids); 149 B8 adds `calendar-google` | the contacts switch of the Google connection lives in that section (2.7) |
| 24 | next migration (**corrected in v1.1**) | `git ls-tree --name-only e0f02e7ff rdb/ \| tail -2` -> `0221_fleet_lanes_issue_key.sql`, `0222_hours_v2_terminals.sql` | `<next>` = 0223 today, fixed at build time |
| 25 | the realm's table rule (new) | `rdb/0168_personal_realm.sql:16-23`: every realm table has `person_id` first (FK to `humans`, ON DELETE CASCADE), no column named `tenant_id`, no FK to a table that carries one, ENABLE + FORCE and one policy `person_scope`, and no `operator_scope` (asOperator reads 0 realm rows). Cross-person work goes through SECURITY DEFINER doors owned by NOLOGIN roles (:25-47; `personal.due_receipts` :168-176). The runtime gets realm grants by name only: `roles/runtime-grants.sql:38-51` (no default privileges in `personal`) | `personal.contacts` follows that rule exactly; its cross-person purge is a door of the same kind (2.6, 3) |
| 26 | the realm's tests (new) | `store/personal_catalogue_test.go:23` `personalTables`; :30-42 pin the exact table list and policy list of `personal`; :91-97 the runtime's exact grants; :114-121 "each realm role owns exactly its one SECURITY DEFINER function" (count 2). `store/personal_scope_test.go:25` `personCallers` (every caller of `inPerson`, named); :43 `realmTenantCallers` (empty: no realm function may also open a tenant or operator scope); :78 a realm file is one whose name starts with `personal` | B1 updates the catalogue lists; B2 names its methods in `personCallers` and keeps `realmTenantCallers` empty |
| 27 | the workspace-table RLS tests (new) | `store/rls_test.go:76-81` `TestRLSCoversEveryTenantTable` and `store/crosstenant_test.go:563-569` `tenantTables` (used by `TestCrossTenantEveryTable`, :630) both pick tables by a `tenant_id` column in `current_schema()`; :640 fails when a tenant table has no seed row | `personal.contacts` is outside both by design (no `tenant_id`, another schema). `contacts_sync` is inside both on its own; B1 seeds it in `crosstenant_test.go` |
| 28 | the person gate (new) | `hub/realm.go:108-121` `realmRefuses`: refuses an act-as session (`auth.ProviderActAs`) or a live clone, an id that is not `HUM-<n>`, and seats that are all agent or time-accountant; `realmCaller` (:62) also refuses a workspace header (:65-67) | contacts routes call `realmRefuses`; they keep the workspace header, because O3, O4 and the kill switch need it (2.6, 4) |
| 29 | who deletes a human (new) | `git grep -n 'DELETE FROM humans' e0f02e7ff -- csi-spl-api ':!*_test.go'` -> `store/demo_stay.go:227` (a demo human with no membership left, :227-228) and `store/embed_visitor_messages.go:128` (a channel guest). A clone is never deleted: `store/clones.go:132-138` drops its channel rows and membership and sets `disabled_at` | the humans FK cascade erases a demo human's or guest's list; a clone needs the gate of row 28 instead (2.6) |
| 30 | 149's connection and membership (new) | `rdb/0217_google_calendar.sql:19-20`: `gcal_connections` references `tenants` and `humans` only, with no FK to `tenant_memberships` | leaving a workspace does not remove a 149 connection; `contacts_sync` gets its own membership FK, so the contacts sync stops on a leave (2.2) |
| 31 | the membership key (new) | `rdb/0006_users_and_memberships.sql:45-52`: `PRIMARY KEY (tenant_id, human_id)` | the target of `contacts_sync`'s membership FK (3) |
| 32 | the People list (new, amendment) | `wui/components/ChannelSidebar.vue:506-544`, the sidebar panel `sidebar-panel-people`: one `nav-item` row per entry of `memberRows`, linking to `/people/<id>` (:531), with the "you" or owner tag (:540-541). `memberRows` (:931-933) is `roster.people` filtered to human ids, so it needs no fetch of its own (comment :928-930) | the merged list is built here (2.7) |
| 33 | how People is ordered today (new, amendment) | `roster.people` = `peopleRows(...)` (`wui/stores/roster.ts:38`), which ends `rows.sort((a, b) => a.label.localeCompare(b.label))` (`wui/utils/live-follow.mjs:296`). The label is `<id>@<box>` (`wui/utils/channel-feed.mjs:50-53`, used at `live-follow.mjs:281`), so today's order is by member id, not by the name shown, and online people are not put first | the owner's order (online, then members, then contacts, each A-Z) is new (2.7, C24b) |
| 34 | what "online" means in People (new, amendment) | `wui/stores/roster.ts:12` `online`, the peer labels the hub calls online: from the `GET /v1/view/roster` snapshot (`roster.ts:62`, `mergeSnapshotOnline`) and from live `presence` frames over the WUI socket (`hub/channels.go:349-351` `presenceFrame`; applied by `applyPresence`, `wui/utils/live-follow.mjs:203`, through `roster.ts:45-48`). A row is online when its label is in that list (`live-follow.mjs:284`; `roster.isOnline`, `roster.ts:77-80`) | group 1 is the rows the roster store calls online right now; a presence frame moves a row between groups 1 and 2 at once |
| 35 | the member card and the People help (new, amendment) | `wui/pages/people/[id].vue`: the member's card from `/v1/view/roster` (`:1-4`), its Message button (:48); `wui/pages/people/index.vue:12` shows only `people.empty` before a row is picked. The People help is `csi-spl-doc/doc/help/people.md` (its WUI copy `wui/public/help-md/people.md:3-5`: "lists every member of the workspace") | the contact card is a new page beside it; the help text changes (B12) |

## 2. The design

### 2.1 Scope

In: a person's own contact list, **one list that follows the person into
every workspace they belong to** (O5 = B). Each contact holds exactly four
attributes: **first name, last name, email, phone** (one of each). The
list shows inside the existing **People** section, together with the
workspace's members (amendment, 2.7). In scope: add, edit and delete in
Spool; find a contact from the omnibox
(`/search`); open a direct message with a contact who is a member of the
current workspace; invite a contact who is not; a two-way sync with the
person's Google Contacts; export and erase.

Out (each can get its own spec): more attributes (company, address,
birthday, photo, notes, labels or groups), several emails or phones per
contact, a contact list shared by a workspace, contacts from other
providers (Outlook, CardDAV), import from a vCard file, sending email or
SMS from Spool.

A contact needs at least one of the four values (CHECK in section 3).
Without a Google connection the list works on its own: the sync is an
add-on, never a precondition.

### 2.2 One Google connection, one more scope, one binding per person

The person connects Google through spec 149's connect flow (149 section
2.2): the same `gcal_connections` row, the same sealed tokens, the same
consent screen. Contacts adds one scope; it is not a second login:

1. The connect URL takes `?want=calendar|contacts|calendar,contacts`. The
   hub asks for `openid email` plus the scopes of each wanted part: cnf
   `gcal.scopes` for calendar and new cnf `contacts.scopes` for contacts.
   B7 lets `AuthorizeURL` in `api/internal/gcal/oauth.go` take the scope to
   ask for; today it always sends the one cnf string. The URL keeps
   `include_granted_scopes=true` (`api/internal/gcal/oauth.go:174`), so an
   existing calendar grant is kept and only the contacts scope is asked for.
2. The callback stores the token answer's `scope` string (oauth.go:235,
   :247) in a new column `gcal_connections.granted_scopes`. The callback
   UPDATES the existing row in place (`INSERT ... ON CONFLICT (tenant_id,
   human_id) DO UPDATE`), never delete-and-insert: a delete would cascade
   to `contacts_sync` (section 3). The new refresh token replaces the old
   one. The landed client forces consent (`oauth.go:175`) and `Exchange`
   refuses an answer without a refresh token (`oauth.go:204-206`), so the
   callback never gets an answer that lacks one (C14c). Each sync checks
   in that string for the scope it needs: calendar sync skips a row
   without the calendar scope, contacts sync skips a row without the
   contacts scope. 149's calendar cycle needs that one check (B7);
   without it, a contacts-only connection would get a "Spool Hub"
   calendar created.
3. **One binding per person (O5 = B).** 149's connection is per
   workspace (`UNIQUE (tenant_id, human_id)`, 1.2 row 14), but the list is
   the person's. So the contacts sync binds exactly ONE of the person's
   workspace connections: the `contacts_sync` row of that workspace,
   `UNIQUE (human_id)` (section 3). The Contacts switch in workspace W
   creates the binding on W's connection. If the person's binding is
   already in another workspace, the switch answers 409
   `contacts_sync_elsewhere`, and the settings page says that sync is on in
   another of their workspaces and must be turned off there first (P9).
   That answer tells the person only about their own row.
4. Turning contacts off in settings stops the contacts sync and keeps the
   connection; disconnect (149 2.4) ends both.
5. **Leaving W ends W's binding, never the list.** `contacts_sync`
   references `tenant_memberships (tenant_id, human_id)` with ON DELETE
   CASCADE. So whichever of the four store paths removes the membership
   (1.2 row 29 and 2.6), the binding goes with it, and the sync stops.
   This does not depend on 149: `gcal_connections` itself has no
   membership FK (1.2 row 30). The person can then turn sync on in another
   workspace, where the first-sync rules of 2.5 re-link the list.

The People API scope is `https://www.googleapis.com/auth/contacts`: O1 = A,
two-way (unchecked, I believe, that this is the scope that allows writes;
`contacts.readonly` is not used). Google reviews this scope (unchecked, I
believe, that it is "sensitive" and not "restricted"). O2 = A: it goes into
the same review as 149's calendar scope (section 7). The scope string lives
in cnf, written with owner step S2; B8 reads it from there and never
hard-codes it.

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
- **Only the reader's own contacts**, from the person's one list: the same
  hits in every workspace the reader is in. The store reads them under
  `inPerson(<session's HUM>)` in their own transaction, beside the
  workspace-scoped reads of the rest of the search, never nested in one
  (`TestPersonScopeCallers`, 1.2 row 26). An admin's search does not see a
  member's contacts, and neither does the operator scope (2.6).
- A hit shows the name, email and phone, and its actions (2.4).
- The command palette lists contacts in its existing `people` group
  (B10; `PALETTE_GROUPS` stays at six, `usePaletteItems.ts:40`), filled
  from `GET /v1/me/contacts` the first time the palette opens. A contact
  row opens the contact's card (2.7); a contact matched to a member here
  shows once, as that member. It is a separate row so B5 does not wait
  for it.

A person's list is small (Google caps an account at 25,000 contacts,
unchecked, I believe), so an index on `person_id` and an `ILIKE` over that
person's rows is enough; no search-index change (spec 100).

### 2.4 Message or invite this contact

The owner: "one should be able to send directly spool-hub.ai msgs from it".

- **The contact is a member of the workspace the reader is in now** (O3 =
  A). The hub matches the contact's email to a human with a **verified**
  identity of that address (`human_identities.email` with `email_verified`,
  `rdb/0006_users_and_memberships.sql:34-35`; not `humans.email`, which is
  "informational", :23). That human must have a membership in the session's
  workspace and must not be disabled. The match answers the member's
  `human_id` as the contact's `member_id` on every contact the list and
  card routes return (amendment: one match per list page, not one
  request per contact, because the People list needs it for every row).
  The WUI shows a **Message** button that opens
  `/dm/<peer>`, the same route the People card and the palette use
  (`usePaletteItems.ts:89`). The DM page sends as today (`hub/wui.go:571`).
- **The match never looks outside the current workspace.** The list is the
  same in every workspace, but the match is not. A contact whose address
  belongs to a member of W1 shows Message while the reader is in W1, and
  not while they are in W2, unless that person is a member of W2 too.
  Read from W2, the contact's `member_id` is `null` both for "a member of
  W1 only" and for "no Spool human at all" (C13c), so the list never reveals another
  workspace's membership. That holds even for a workspace the reader is in
  themselves.
- **The contact is not a member here** (no match in the current
  workspace). There is no Message button. O4 = A: a reader who holds
  `rbac.MembersInvite` **in the current workspace** sees an **Invite**
  button, which fills `POST /v1/members/invites` (`hub/rbac.go:552`) with
  the contact's email and the current workspace (the session's, as every
  invite today); it never invites to another workspace. Any other reader
  sees only the email and phone links. A contact who is a member here
  shows Message and never Invite.
- **Email and phone are links** in every case, opened by the reader's own
  0193 choices (`wui/utils/contact-links.mjs`): mail client, `tel:`,
  WhatsApp and the others in `rdb/0193_human_contact_links.sql:19`.
- The match runs in the hub on each request and is never stored. It reads
  the contact under `inPerson` and the identity and membership in the
  workspace scope, in two transactions (1.2 row 26). A contact's data never
  goes into a message or into the peer's view.

### 2.5 Sync with Google Contacts (O1 = A, two-way)

All sync runs in the hub, on its own ticker started from `RunSweeper`
(`hub/server.go:586`), as 149 2.5 does. Contacts change less often than
events: a due binding is synced every 10 minutes, plus "Sync now". There is
no push for contacts (unchecked, I believe: the People API offers no watch
channel), so polling is the only trigger.

- **State**: one row per binding in `contacts_sync` (section 3): the People
  `syncToken`, an `out_cursor`, `due_at` and its own `sync_lease_until`.
  The lease is separate from the calendar's, so a long calendar sync never
  holds back contacts, and the other way round. The claim, the fencing
  token and the per-page renewal are 149 2.5's, applied to `contacts_sync`.
  The claim joins `gcal_connections` on `(tenant_id, human_id)` and takes
  only rows with `status = 'connected'` (as 149's due index, `0217:42`). An
  `ErrInvalidGrant` (`oauth.go:210-211`) in a contacts cycle marks the
  connection revoked through the same helper 149 2.4 uses, never a second
  copy of it (C23b).
- **Three scopes per cycle, never nested.** (1) The claim runs as the
  operator over `contacts_sync`, a workspace table that holds no contact
  value. (2) The token read and refresh run in the binding's workspace
  scope, through 149's helper. (3) Every read and write of
  `personal.contacts` runs under `inPerson(contacts_sync.human_id)`. Each
  is its own short transaction, and none is open while Google is called
  (C23). The operator scope reads 0 rows of `personal.contacts` (1.2
  row 20), so the cycle cannot reach the contacts through (1).
- **One token pair, two cycles**: the calendar and the contacts cycle may
  both refresh the access token of one row at once. One shared helper
  (149's) writes the refresh, with a single `UPDATE gcal_connections SET
  access_sealed, access_expiry` and nothing else, so neither cycle
  overwrites the other's `due_at`, `sync_token` or `out_cursor`. Last
  writer wins on the access token (unchecked, I believe, that an older
  access token stays valid until it expires).
- **Which Google account a contact is linked to.** A contact linked to
  Google records the account it is linked under, in `google_account` (the
  binding connection's `google_email`), beside `google_resource`. A cycle
  treats a contact linked under another account as unlinked. So when a
  person's binding moves to a connection with another Google account, the
  first-sync rules below apply: link by email, else create at the new
  account. Nothing is deleted at the old account, which is no longer bound
  (C23d).
- **In (Google -> Spool)**: `people.connections.list` on `people/me` with
  `personFields=names,emailAddresses,phoneNumbers,metadata`,
  `requestSyncToken=true`, page size 1000, then the stored `syncToken`
  (unchecked, I believe, for every parameter name and limit). Per person:
  first name = the primary `names[].givenName`, last name = its
  `familyName`, email = the primary `emailAddresses[].value` (else the
  first), lowercased, phone = the primary `phoneNumbers[].value` (else the
  first), as Google stores it. An unknown person with none of the four is
  skipped. An unknown `resourceName` is inserted and a known one is
  patched. A person with `metadata.deleted`, or a known person whose four
  values are now all empty, is soft-deleted in Spool and nothing is sent
  back.
- **Out (Spool -> Google)**: the cycle picks contacts whose
  `GREATEST(updated_at, COALESCE(deleted_at, updated_at))` is after
  `out_cursor` (149 P7's lesson: `updated_at` alone misses deletes). It
  calls `people.createContact` for a contact not linked under the bound
  account, `people.updateContact` for a changed one (with the stored `etag`
  and `updatePersonFields=names,emailAddresses,phoneNumbers`), and
  `people.deleteContact` for a deleted one. An update reads the person
  first and changes only the primary email and phone in its lists, so a
  second email or phone the person keeps at Google is never lost (Spool
  holds one of each; Google may hold many). A create stores the answer's
  `resourceName`, `etag` and the new `sync_hash` on the contact.
- **Echo**: `sync_hash` = SHA-256 of the four values joined by newlines. An
  incoming person whose hash equals the stored one is skipped; so is an
  outgoing write whose hash did not change.
- **Conflicts, the full table for O1 = A.** "Changed" means changed since
  the binding's last completed cycle. Spool's time is `updated_at`;
  Google's is `metadata.sources[].updateTime` (unchecked, I believe).

  | Spool side | Google side | result |
  |---|---|---|
  | edited | edited | the newer side wins; a tie goes to Spool; the losing side is overwritten (C18) |
  | edited | deleted | the delete wins: soft-deleted in Spool (`deleted_by = 'google-sync'`), no update sent; the Spool edit is lost (C23e) |
  | deleted | edited | the delete wins: `people.deleteContact` is sent; the Google edit is lost (C23f) |
  | deleted | deleted | nothing to send. A `deleteContact` that Google answers "not found" counts as done (unchecked, I believe, that the answer is 404 `NOT_FOUND`) |
  | etag mismatch on update | - | re-read the person and decide again on the next cycle (unchecked, I believe, that Google answers 400 `FAILED_PRECONDITION`) |

- **Deletes**: Google -> Spool is a soft delete (`deleted_at`,
  `deleted_by = 'google-sync'`), purged after 30 days (2.6). Spool ->
  Google deletes the person at Google; once Google confirms, the Spool row
  is hard-deleted at once. The first sync of a new binding never deletes
  on either side. It links contacts that match by email, else inserts, so
  a contact typed in Spool before connecting gets no duplicate. Email is
  not unique per person: of several Spool contacts with the Google
  person's email, the oldest (`created_at`) that is not linked under the
  bound account is linked, and the others stay unlinked (C20b).
- **An expired sync token** (unchecked, I believe: after 7 days, answered
  410 or `EXPIRED_SYNC_TOKEN`): cleared, a full list, matched by
  `(google_account, google_resource)`, no duplicates, no deletes from that
  pass.
- **Rate limits**: the People API has per-project and per-user quotas
  (numbers unchecked, I believe). The cycle sends a person's writes one at
  a time (Google asks that mutations for one user be sequential, unchecked,
  I believe), at most 200 writes per cycle, the rest the next cycle. A 429
  or 503 backs off with `Retry-After` or 2^n minutes up to 1 h and sets
  `status_detail`. One person's backlog never delays another's: the claim
  takes one binding at a time, oldest `due_at` first.

### 2.6 Privacy

Contacts are personal data of people who never agreed to be in Spool.

- **The list belongs to the person, not to a membership** (O5 = B). The
  owner of a row is the human (`person_id`, a `HUM-<n>`). There is no
  `tenant_id` on the list, and the same list shows in every workspace the
  person is in. No other human reads it, through any route, search or
  export: not a member, not an admin, not a workspace owner, and not the
  operator scope.
- **How Postgres isolates it: the personal realm.** `personal.contacts` is
  a table of spec 119's realm and follows its rule exactly (1.2 row 25):
  `person_id` first with the FK to `humans`, no `tenant_id`, no FK to a
  table that carries one, ENABLE + FORCE, and the one policy
  `person_scope` (`rdb/0168_personal_realm.sql:142-148`, the same text).
  A row is visible and writable only when `app.person_id` is that person,
  no workspace scope is set and the scope is not operator. Only
  `inPerson` sets `app.person_id` (`store/rls.go:82`), and the person
  always comes from the authenticated session, never from a path, query
  or body. The store also names `person_id` in every query, so isolation
  has two layers, as for every workspace table. This is the precedent on
  master for a table without `tenant_id` (1.2 row 20), not "the store is
  the only guard".
- **`contacts_sync` is a workspace table.** It is the sync state of one
  binding: the workspace, the human, the token, cursors and status. It
  holds no contact value and gets the 0187 policies (`tenant_scope` +
  `operator_scope`, 1.2 row 19), so the operator can claim due rows as
  149's cycle does.
- **The tests that guard it** (1.2 rows 26, 27):
  `TestRLSCoversEveryTenantTable` and `TestCrossTenantEveryTable` pick
  tables by a `tenant_id` column in `public`. `personal.contacts` is
  outside both by design, and `TestRLSPersonalCatalogue` covers it
  instead: B1 adds `contacts` to its table, policy and grant lists and adds
  the purge door below. `contacts_sync` falls inside both tenant tests on
  its own, with no list to edit, and B1 seeds it in `crosstenant_test.go`
  (:640 fails otherwise). `TestPersonScopeCallers` names every contacts
  store method that calls `inPerson` (B2), and `realmTenantCallers` stays
  empty: no contacts store function opens two scopes. The hub calls them
  one after the other (2.4, 2.5).
- **The operator-scope cycles.** (1) The sync claim, as in 2.5: operator
  scope over `contacts_sync` only, then the binding's workspace scope for
  the token, then `inPerson` for the contacts. (2) The 30-day purge of
  soft-deleted contacts must reach every person's rows, and the operator
  scope reads none of them. It therefore goes through one SECURITY DEFINER
  door, the realm's precedent (`personal.due_receipts`, `0168:168-176`):
  `personal.purge_deleted_contacts(before timestamptz) RETURNS TABLE
  (person_id text, pending_google boolean)`. The function is owned by a
  new NOLOGIN NOBYPASSRLS role `spool_realm_contacts_purger`, which holds
  column `SELECT (person_id, deleted_at, deleted_by, google_resource)` and
  `DELETE` on `personal.contacts` only. The role gets two policies of its
  own, `FOR SELECT` and `FOR DELETE` `TO spool_realm_contacts_purger
  USING (deleted_at IS NOT NULL)`. The door deletes the rows soft-deleted
  before `before` and returns each person whose purged rows held an unsent
  Google delete. EXECUTE goes to the runtime by name in
  `roles/runtime-grants.sql` (P11). For those persons the hub sets
  `contacts_sync.status_detail` under the operator scope, saying the
  delete did not reach Google (C7c). The door runs on `RunSweeper`'s
  retention (`hub/server.go:586`) and needs no Google connection, so it
  works before B8.
- **Never logged**: no contact value (name, email, phone) in a log line, an
  error body or a metric label; logs carry `contact_id` only (C12).
- **Export**: `GET /v1/me/contacts/export` answers the person's contacts
  as CSV with exactly the four columns plus `google_resource`.
- **Erase one**: `DELETE /v1/me/contacts/{id}` removes the contact from
  every read at once. If a Google delete must be sent (the contact is
  linked under the bound account and the binding is enabled), it is a soft
  delete (`deleted_at = now()`, `deleted_by = 'member'`): the cycle sees it
  through `out_cursor`, calls `people.deleteContact`, then hard-deletes the
  row (C17b). With nothing to send to Google it is a hard delete at once
  (C7b).
- **Erase all (the person's own erase)**: `DELETE
  /v1/me/contacts?scope=spool` erases the person's whole list, which is
  the same list in every workspace, in Spool only. It sends nothing to
  Google. Disabling the binding first keeps a later full list from
  importing the contacts again. The hub lists the person's memberships
  (`store.MembershipLister`, as `realmRefuses` does) and sets
  `contacts_sync.enabled = false` in each workspace scope where the
  person's binding is, then hard-deletes every row in one `inPerson`
  transaction. If the hub stops in between, the sync is off and the
  contacts are still there, and the person can repeat the erase (C8e).
- **Leaving or being removed from ONE workspace changes nothing in the
  list**: it follows the person. Four store paths delete memberships
  (`git grep -ln 'DELETE FROM tenant_memberships' e0f02e7ff -- csi-spl-api
  ':!*_test.go'` -> `clones.go`, `demo_stay.go`,
  `embed_visitor_messages.go`, `humans_rbac_postgres.go`), and the demo
  workspace removes members by `BanMember` (`hub/rbac.go:510-511`). By
  any of these paths, only that workspace's `contacts_sync` row goes, by
  its membership FK, and the sync stops (2.2 step 5). The contacts and
  their Google links stay, still readable from every other workspace of
  the person (C8). A person who left every workspace keeps the list too,
  as they keep their realm (`hub/realm.go:107`). Spool shows it again
  once they hold a seat, because the contacts routes run inside a
  workspace session (section 4).
- **What erases the whole list**, and nothing else does:
  1. **The human is deleted**: the list goes by its FK to `humans` with ON
     DELETE CASCADE. On master that happens to a demo human whose last
     membership ended (`store/demo_stay.go:227-228`) and to a channel guest
     (`store/embed_visitor_messages.go:128`) (C8b, C8d).
  2. **The person's own erase**: `DELETE /v1/me/contacts?scope=spool`
     above (C8e).
  3. **A demo or clone human retired.** A demo human is deleted when its
     last membership ends, so item 1 applies. A demo human who still
     holds a seat elsewhere is a person with a seat, and the list follows
     them, as for anyone. A clone is never deleted, only disabled
     (`store/clones.go:132-138`, 1.2 row 29), so a clone must never hold a
     contact. Every contacts route refuses an act-as session or a live
     clone through `realmRefuses` (`hub/realm.go:108-113`) with 403
     `person_only`. A retired clone then has nothing to erase (C4b, C8c).
     The same gate refuses an agent session.
  A human who is disabled but not deleted (`humans.disabled_at`) keeps
  the list, and no one can read it until the human is deleted (unchecked,
  I believe, that a disabled human cannot hold a session).
- **Disconnect** keeps the contacts in Spool unless the person ticks
  "remove imported contacts" (those linked under that connection's
  account).

### 2.7 WUI: contacts inside People (amendment)

The owner, 2026-10-24: "actually the new contacts section should be merged
wit hthe current people section ... aka one should be able to see all of
his contacts and just filter those which are part of the spool-hub
workspace" (msg `14cdf0ad`), and "aka those which are online should be
shown first and the other which are part of the spool-hub - ak amebers
after that ... each of those in alpabetical order ..." (msg `31bb12ea`).
The dispatcher's reading, posted to the owner: group 1 online now, group 2
the other workspace members, group 3 the reader's other contacts; A-Z
inside each; the "in this workspace" filter shows groups 1 and 2.

- **No new rail tab.** The People panel (`ChannelSidebar.vue:506-544`,
  1.2 row 32) shows one list in three groups:
  1. **online now**: workspace members whose row the roster store calls
     online (1.2 row 34);
  2. **members**: the other workspace members;
  3. **contacts**: the reader's contacts whose `member_id` is `null` in
     this workspace (2.4).
  A contact whose `member_id` names a member here is not listed twice: it
  is that member's row, in group 1 or 2, with a small "contact" tag.
- **A-Z inside each group**, by the name shown, compared case-insensitively
  in the reader's locale (`Intl.Collator(locale, { sensitivity: 'base' })`).
  A member is sorted by the name `HumanName` shows; a contact by
  `first_name + ' ' + last_name`, else its email, else its phone. That
  replaces today's sort by `<id>@<box>` (1.2 row 33) for this panel only;
  `peopleRows` and the DM list keep theirs. The reader's own row stays in
  the list, sorted like any member, with its "you" tag (`:540`).
- **Live**: a `presence` frame moves a member between groups 1 and 2 at
  once (the list is a `computed` over `roster.online`, 1.2 row 34). A
  contact is never in group 1: the hub sends presence for members, and a
  contact who is not a member here has none.
- **The filter**: a two-choice control at the top of the panel, **All**
  (default) and **In this workspace**. "In this workspace" shows groups 1
  and 2 only, so the panel looks as it does today, apart from the new
  order. The choice is a per-viewer convenience kept in `localStorage`
  (wrapped in try/catch, default All).
- **Rows and cards**: a member row opens `/people/<id>` as today
  (`:531`). A contact row opens a new card page
  `wui/pages/people/contact/[id].vue`. The card shows the four fields,
  Edit and Delete, Message (when `member_id` is set) or Invite (2.4, O4),
  and the 0193 links. The member card (`wui/pages/people/[id].vue`) gets one
  line, "In your contacts", linking to the contact card when one of the
  reader's contacts matches that member. An **Add contact** button sits in
  the panel header.
- **Kill switch** (2.9): in a workspace outside `contacts.workspaces` the
  panel shows only members, with no filter and no Add button, exactly as
  today apart from the new order.
- In the 149 settings section `calendar-google`: a **Contacts** switch
  (connect with `want=contacts`; off stops the sync), last sync time and
  status, Sync now. On 409 `contacts_sync_elsewhere` it says that sync is
  on in another of the person's workspaces.
- **Budget**: `ChannelSidebar.vue` ships on the first screen. The contact
  rows, the filter's list fetch and the contact card are a lazy component
  (`<LazyPeopleContactRows>`, a new `wui/components/PeopleContactRows.vue`)
  plus the lazily routed card page. `GET /v1/me/contacts` runs only when the
  People panel first opens, so `ci_initial_gzip_kb` is not raised (C25).
  The panel's own new strings follow the first-screen catalogue rule; the
  contact rows' and the card's strings load with their chunk.
- Every string is a translation key (developer guide 2.4).

### 2.8 Local dev and tests

`SPOOL_CLOUD_PROVIDER=none` (spec 148): the contacts list works; the Google
switch answers 503 `gcal_not_configured` (149 2.8). Tests run against a new
`api/internal/gcal/fakegcal/people.go` (connections list with sync tokens,
an expired token, create, update with an etag check, delete, a 429) and
`marketing.NewFakeKMS`. No test reaches Google.

### 2.9 Kill switch

cnf `contacts.workspaces` (per env, `[]` = off), as `gcal.workspaces`
(149 2.9). In a workspace outside it, every `/v1/me/contacts*` route
answers 404, the People panel shows members only (2.7) and `/search`
returns no `contact` section. The person's list itself is untouched and shows again in any
workspace inside the switch. Turning it on in an env is an owner go (S4).
The Google part also needs `gcal.workspaces`.

## 3. Data

One additive migration, `rdb/<next>_contacts.sql` (`<next>` = 0223 on
`e0f02e7ff`, 1.2 row 24). The person's list is in the realm (1.2 row 25),
and the binding's state is a workspace table in the 0187 shape.

```sql
ALTER TABLE gcal_connections
    ADD COLUMN granted_scopes text NOT NULL DEFAULT ''
        CHECK (length(granted_scopes) <= 2000);

-- The person's list: spec 119's realm rule (0168:16-23).
CREATE TABLE IF NOT EXISTS personal.contacts (
    person_id       text        NOT NULL REFERENCES public.humans (human_id) ON DELETE CASCADE
                                CHECK (person_id ~ '^HUM-[0-9]+$'),
    contact_id      uuid        NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    first_name      text        NOT NULL DEFAULT '' CHECK (length(first_name) <= 100),
    last_name       text        NOT NULL DEFAULT '' CHECK (length(last_name) <= 100),
    email           text        NULL
        CHECK (email IS NULL OR (email = lower(email) AND length(email) BETWEEN 3 AND 320)),
    phone           text        NULL
        CHECK (phone IS NULL OR phone ~ '^[+0-9 ().-]{3,40}$'),
    google_account  text        NULL
        CHECK (google_account IS NULL OR (google_account = lower(google_account) AND length(google_account) BETWEEN 3 AND 320)),
    google_resource text        NULL CHECK (google_resource IS NULL OR length(google_resource) <= 200),
    google_etag     text        NOT NULL DEFAULT '' CHECK (length(google_etag) <= 200),
    sync_hash       text        NULL CHECK (sync_hash IS NULL OR length(sync_hash) = 64),
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now(),
    deleted_at      timestamptz NULL,
    deleted_by      text        NULL CHECK (deleted_by IS NULL OR deleted_by IN ('member', 'google-sync')),
    CHECK ((google_account IS NULL) = (google_resource IS NULL)),
    CHECK (first_name <> '' OR last_name <> '' OR email IS NOT NULL OR phone IS NOT NULL)
);
CREATE INDEX IF NOT EXISTS contacts_person ON personal.contacts (person_id) WHERE deleted_at IS NULL;
CREATE UNIQUE INDEX IF NOT EXISTS contacts_google ON personal.contacts (person_id, google_account, google_resource)
    WHERE google_resource IS NOT NULL;
ALTER TABLE personal.contacts ENABLE ROW LEVEL SECURITY;
ALTER TABLE personal.contacts FORCE ROW LEVEL SECURITY;
-- person_scope: the exact text of 0168:142-148 (TestRLSPersonalCatalogue pins it)
CREATE POLICY person_scope ON personal.contacts
    USING (person_id = NULLIF(current_setting('app.person_id', true), '')
           AND NULLIF(current_setting('app.tenant_id', true), '') IS NULL
           AND current_setting('app.rls_scope', true) IS DISTINCT FROM 'operator')
    WITH CHECK (person_id = NULLIF(current_setting('app.person_id', true), '')
           AND NULLIF(current_setting('app.tenant_id', true), '') IS NULL
           AND current_setting('app.rls_scope', true) IS DISTINCT FROM 'operator');
-- The purge door (2.6): role spool_realm_contacts_purger, created and
-- granted as 0168:51-75 does for its two roles; column SELECT (person_id,
-- deleted_at, deleted_by, google_resource) + DELETE on personal.contacts;
-- policies FOR SELECT and FOR DELETE TO spool_realm_contacts_purger
-- USING (deleted_at IS NOT NULL); the function
-- personal.purge_deleted_contacts(before timestamptz)
-- RETURNS TABLE (person_id text, pending_google boolean), SECURITY DEFINER,
-- SET search_path = pg_catalog, pg_temp, created as that role (0168:161-209),
-- EXECUTE revoked from PUBLIC and held by the migrator WITH GRANT OPTION.

-- The binding's sync state: a workspace table, no contact value.
CREATE TABLE contacts_sync (
    human_id         text        NOT NULL PRIMARY KEY,
    tenant_id        text        NOT NULL REFERENCES tenants (tenant_id) ON DELETE CASCADE,
    FOREIGN KEY (tenant_id, human_id) REFERENCES gcal_connections (tenant_id, human_id) ON DELETE CASCADE,
    FOREIGN KEY (tenant_id, human_id) REFERENCES tenant_memberships (tenant_id, human_id) ON DELETE CASCADE,
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

ALTER TABLE contacts_sync ENABLE ROW LEVEL SECURITY;
ALTER TABLE contacts_sync FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_scope ON contacts_sync
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''));
CREATE POLICY operator_scope ON contacts_sync
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');
```

Key choices:

- `contacts_sync`'s primary key `human_id` is the "one binding per
  person" rule (2.2 step 3). A unique violation is not hidden by RLS, so a
  second binding in another workspace is refused even though that row is
  invisible, and the hub maps the violation to 409
  `contacts_sync_elsewhere`.
- `contacts_sync` has two FKs on `(tenant_id, human_id)`: to
  `gcal_connections` (`UNIQUE (tenant_id, human_id)`, `0217:40`) and to
  `tenant_memberships` (its primary key, 1.2 row 31). Disconnect and leave
  each end the binding. The callback's upsert (2.2 step 2) keeps it.
- Grants: `personal` has no default privileges, so B1 adds `GRANT SELECT,
  INSERT, UPDATE, DELETE ON personal.contacts` and `EXECUTE` on the purge
  door to `roles/runtime-grants.sql` (beside :45-51). `contacts_sync` is
  in `public` and is covered by `GRANT ... ON ALL TABLES IN SCHEMA public`
  (`roles/runtime-grants.sql:16`; psql runs that file after every
  `spool migrate`, :1-4, and the default privileges cover a later public
  table, :10-13).
- The `phone` CHECK accepts what people type (`+1 555 010 0000`,
  `(555) 010-0000`). It is not E.164, because Google stores the value as
  entered and a normalised copy would break the echo hash. The digits-only
  form for search is computed in the query.

## 4. Routes

Every `/v1/me/contacts*` route runs in a signed-in human's workspace
session, as every `/v1/me` view route does. The person is the session's
`HUM-<n>`, and `realmRefuses` (`hub/realm.go:108`) answers 403
`person_only` for an act-as session, a live clone, an agent seat or a
non-HUM id. Unlike the realm routes, the session's workspace is kept. It
decides the kill switch (2.9), the Message match (O3) and the Invite target
(O4); it never decides which contacts are read.

| route | who | answer |
|---|---|---|
| `GET /v1/me/contacts?q=&cursor=` | person | `{contacts:[{contact_id, first_name, last_name, email, phone, google, member_id}], next}`, the caller's own list only (the same in every workspace); `member_id` is the 2.4 match in the session's workspace, else `null` |
| `GET /v1/me/contacts/{id}` | person | 200 `{contact}` with `member_id`; 404 for another person's id |
| `POST /v1/me/contacts` | person | 201 `{contact}`; 400 `contact_empty` with none of the four |
| `PATCH /v1/me/contacts/{id}` | person | 200 `{contact}`; 404 for another person's id |
| `DELETE /v1/me/contacts/{id}` | person | 204; 404 for another person's id |
| `DELETE /v1/me/contacts?scope=spool` | person | 204, the person's whole list (every workspace: it is one list) |
| `GET /v1/me/contacts/export` | person | `text/csv`, own contacts |
| `PUT /v1/me/contacts/sync` `{enabled}` | person | 204; 409 `gcal_not_connected` without a connection in this workspace; 409 `scope_missing` with a URL to add the scope; 409 `contacts_sync_elsewhere` when the person's binding is in another workspace |
| `POST /v1/me/contacts/sync` | person | 202; 409 `sync_in_progress` while the lease is held; 409 `gcal_not_connected` when no binding is in this workspace |
| `GET /v1/view/search?q=` | person | gains a `contact` section, own rows only |
| `OPTIONS` on each `/v1/me/contacts*` path | browser preflight | as every `/v1/me` route (149 section 4) |

Errors: `{"error":"<code>"}`: `not_found` 404 (workspace off, or not the
caller's), `person_only` 403, `contact_empty` 400, `bad_email` 400,
`bad_phone` 400, `gcal_not_connected` 409, `scope_missing` 409,
`contacts_sync_elsewhere` 409, `sync_in_progress` 409.

## 5. Cases

Every case is **planned**. "Master today" is `9e8ece102` for v1.0's cases
and `e0f02e7ff` for the cases v1.1 adds or changes (marked v1.1). Each red
control fails on master today and passes once its row lands; (C) marks a
control that must pass on both. "n/a" means the route or table does not
exist yet; the control then carries its twin. P1 and P2 are two persons,
W1 and W2 two workspaces.

| # | row | case | master today | expected | red control |
|---|---|---|---|---|---|
| C1 | B1 | (v1.1) the migration applies after `0222` | tables absent | `personal.contacts`, `contacts_sync`, `gcal_connections.granted_scopes`, `personal.purge_deleted_contacts`, role `spool_realm_contacts_purger`, the policies of section 3 | rdb test: `\d personal.contacts` errors today |
| C1b | B1 | (v1.1) `TestCrossTenantEveryTable` with `contacts_sync` seeded in `store/crosstenant_test.go`; `TestRLSCoversEveryTenantTable` | pass | pass (C) | without the seed, :640 fails ("seedTenantAll wrote no row") once the table exists |
| C1c | B1 | (v1.1) `TestRLSPersonalCatalogue` with `contacts` in the table, policy and grant lists and the third realm role and its door | pass | pass (C) | the old lists fail on the new catalogue (:30-33 "personal holds exactly ...", :114-121 "count(*) <> 2") |
| C2 | B1 | (v1.1) a row of P2 in `personal.contacts`, read under P1's `app.person_id`; under P2's with `app.tenant_id` set; under the operator scope | n/a | 0 rows each | Postgres test at SQL level, as `personal_catalogue_test.go`; twin: under P2's `app.person_id` alone it is read |
| C2b | B1 | insert a contact with all four empty | n/a | CHECK violation | Postgres test; twin: one value set inserts |
| C2c | B1 | (v1.1) a second `contacts_sync` row for the same human in another workspace | n/a | unique violation | Postgres test; twin: another human's row inserts |
| C2d | B1 | (v1.1) the purge door as the runtime: rows soft-deleted 31 days ago of P1 and P2 | n/a | both deleted, the result names each person once; rows 29 days old and live rows stay | Postgres test; twin: the runtime's own `DELETE` under the operator scope deletes 0 rows |
| C3 | B2 | (v1.1) store: P2 lists, reads, patches, deletes P1's contact | n/a | not found, nothing changed | Go test, memory and Postgres; twin: P1 does each |
| C3b | B2 | (v1.1) P1's list read through a W1 session and through a W2 session | n/a | the same rows | Go test, memory and Postgres |
| C3c | B2 | (v1.1) `TestPersonScopeCallers` with the contacts methods | pass | pass (C); each contacts method that calls `inPerson` is in `personCallers`, `realmTenantCallers` stays empty | without the `personCallers` lines the test fails ("inPerson callers: new [...]") |
| C4 | B3 | an admin (`rbac.MembersRoles`) calls `GET /v1/me/contacts/{P1's id}` | 404 (no route) | 404 | Go test; twin: P1 gets 200 |
| C4b | B3 | (v1.1) `POST /v1/me/contacts` from an act-as clone session, and from an agent session | 404 (no route) | 403 `person_only` | Go test; twin: the admin's own session gets 201 |
| C5 | B3 | `POST /v1/me/contacts` with `FirstName`, `LastName`, `first.last@example.com`, `+1 555 010 0000` | 404 | 201, the four values back | Go test |
| C6 | B3 | the same in a workspace not in `contacts.workspaces` | 404 | 404 (C) | Go test; twin (v1.1): the same person's list read from a workspace inside the switch is unchanged |
| C7 | B3 | export | 404 | CSV header `first_name,last_name,email,phone,google_resource`, own rows only | Go test with two persons |
| C7b | B3 | delete a contact not linked under the bound account | n/a | the row is gone (hard) | Go test; twin: linked and the binding enabled, soft |
| C7c | B3 | (v1.1) a member-deleted, linked row 31 days old whose Google delete never went out | n/a | purged by the door; the binding's `status_detail` set | Go test, fake clock; twin: 29 days old stays |
| C7d | B3 | (v1.1) `PUT /v1/me/contacts/sync {enabled:true}` in W2 while P1's binding is in W1 | 404 | 409 `contacts_sync_elsewhere`; W1's binding unchanged | Go test; twin: with no binding elsewhere, 204 |
| C8 | B4 | (v1.1) P1 (in W1 and W2, binding in W1) is removed from W1 (`RemoveMember`) | contacts n/a | P1's list unchanged and read from W2; the W1 `contacts_sync` row gone | Postgres test; control: the row count of P1's list before and after |
| C8b | B4 | (v1.1) a demo user with no other seat is banned (`BanMember`) and the stay expires (`demo_stay.go`) | contacts n/a | the human is deleted, so the list is gone | Postgres test; twin: a demo human with a seat in another workspace keeps the list |
| C8c | B4 | (v1.1) a clone is retired (`clones.go` sweep) | contacts n/a | the clone holds 0 contacts before and after (C4b refuses its writes) | Postgres test |
| C8d | B4 | (v1.1) a channel guest is erased (`embed_visitor_messages.go:128`), or any human row is deleted | contacts n/a | its list is gone (FK cascade) | Postgres test; twin: another person's list stays |
| C8e | B3 | (v1.1) `DELETE /v1/me/contacts?scope=spool` | 404 | 0 rows of P1's list from every workspace; P1's binding `enabled = false` | Go test, memory and Postgres; twin: P2's list stays |
| C9 | B5 | `/v1/view/search?q=FirstName` as P1 | no `contact` section | P1's matching contact in it | Go test |
| C10 | B5 | the same query as P2 | n/a | no P1 contact | Go test; twin: P1's own search finds it (else it passes on an empty result) |
| C10b | B5 | `q=5550100000` against `+1 555 010 0000` | n/a | found | Go test |
| C10c | B5 | (v1.1) P1 searches from W2 for a contact added in W1 | n/a | found | Go test |
| C11 | B5 | `type:contact` | `bad_query` | contacts only | Go test |
| C12 | B3, B8 | after create, search and a sync, no contact value appears in any captured log line | n/a | true | Go test greps the captured log for the fixture's four values |
| C13 | B6 | (amended) the list and the card for a contact whose email is a verified identity of a member of the session's workspace | 404 | `member_id` = that member's `human_id` | Go test |
| C13b | B6 | the address is only in `humans.email`, not verified | n/a | `member_id` null | Go test; twin: verified matches |
| C13c | B6 | (v1.1, amended) P1 is in W1 and W2; the address is a verified identity of a member of W1 only; read from W2 | n/a | `member_id` null, the same body as for an address of no human | Go test; twin: read from W1, it matches |
| C13d | B6 | the matched member is disabled | n/a | `member_id` null | Go test |
| C13e | B6 | (amendment) a page of 100 contacts | n/a | one match query for the page, not one per contact | Go test counts the store calls; twin: an empty page makes none |
| C14 | B7 | connect with `want=contacts` on a row that holds the calendar scope | no `want` | the URL asks the contacts scope with `include_granted_scopes=true`; the callback stores both scopes in `granted_scopes` | Go test beside the 149 connect test |
| C14c | B7 | reconnect of a connected row | n/a | the same `connection_id`, the new `refresh_sealed`, the `contacts_sync` row kept | Postgres test; twin: a delete-and-insert callback loses the `contacts_sync` row |
| C14b | B7 | a contacts-only connection, one 149 calendar cycle | n/a (149 B6a not landed) | no calendar call at the fake | Go test counts the fake's calendar calls; twin: the calendar scope present -> one calendar call |
| C15 | B8 | a new person on the fake | n/a | a contact with the four values, `google_account` and `google_resource` | Go test on `fakegcal` |
| C15b | B8 | a Google person with two emails, the second primary | n/a | the primary one stored | Go test |
| C15c | B8 | `metadata.deleted` on the fake | n/a | soft-deleted, `deleted_by = 'google-sync'` | Go test |
| C16 | B8 | echo: the next list returns the same person | n/a | 0 writes | Go test |
| C17 | B8 | a Spool edit | n/a | one update with the stored etag; the person's second phone at the fake kept | Go test reads the fake's person |
| C17b | B8 | a Spool delete | n/a | one delete at the fake, then the row is hard-deleted | Go test; twin: an `updated_at`-only cursor misses it |
| C18 | B8 | conflict: both edited, Google later | n/a | Google's values in Spool, no update sent | Go test, fake clock; twin: Spool later -> one update |
| C19 | B8 | expired sync token | n/a | full list, no duplicates, no deletes | Go test |
| C20 | B8 | first sync with a Spool contact of the same email | n/a | linked, one contact | Go test |
| C20b | B8 | first sync, two Spool contacts of that email | n/a | the older one linked, the newer unlinked | Go test |
| C21 | B8 | a 429 from the fake | n/a | `backoff_until` set, no further call that cycle | Go test |
| C22 | B8 | 300 pending Spool writes | n/a | 200 sent this cycle, 100 the next | Go test counts the fake's writes |
| C23 | B8 | two cycles at once (Postgres) | n/a | each binding synced once; no transaction open during a fake call | Postgres test, as 149 C21 |
| C23b | B8 | a revoked connection; and an `invalid_grant` from the fake | n/a | no fake call; the connection turns `revoked` | Go test; twin: a connected row is synced |
| C23c | B8 | a calendar refresh and a contacts cycle on one row | n/a | `due_at`, `sync_token`, `out_cursor` of the other cycle unchanged | Postgres test |
| C23d | B8 | (v1.1) the binding moves from account `a@example.com` to `b@example.com` | n/a | contacts linked under `a@` are linked by email or created at `b@`; 0 calls for `a@` | Go test; twin: the same account -> 0 creates |
| C23e | B8 | (v1.1) a contact edited in Spool, then deleted at Google, before the next cycle | n/a | soft-deleted in Spool, 0 updates sent | Go test |
| C23f | B8 | (v1.1) a contact deleted in Spool, then edited at Google, before the next cycle | n/a | one delete at the fake; the contact not re-imported | Go test |
| C23g | B8 | (v1.1) the cycle's contacts reads and writes run under `inPerson` of the binding's human | n/a | a cycle in which the claim's operator scope is used for contacts reads 0 rows | Postgres test; twin: under `inPerson` it reads them |
| C24 | B9 | (amended) the People panel on the mock bundle: no new rail tab; add a contact, find it, open its card; Message for a contact who is a member here, no Message for a non-member; Invite shown with `members.invite` and hidden without it, and Invite posts the current workspace | no contacts in People | as stated | e2e on the mock bundle; control: `RAIL_TABS` length unchanged |
| C24b | B9 | (amendment) the order: members A (online), B (offline), C (online), contacts D and E; names chosen so the id order differs from the name order | sorted by `<id>@<box>` (`live-follow.mjs:296`), online not first | the online members A-Z, then the offline members A-Z, then the contacts A-Z | unit test on the panel's order function; red control: today's `memberRows` order fails the expected sequence |
| C24c | B9 | (amendment) a presence frame turns B online | n/a | B moves into group 1 at its A-Z place | unit test; twin: B offline again moves back |
| C24d | B9 | (amendment) the filter "In this workspace" | n/a | groups 1 and 2 only; contacts gone; a contact matched to a member stays as that member's row | unit test; twin: All shows group 3 |
| C24e | B9 | (amendment) a contact whose `member_id` names member A | n/a | one row for A, with the "contact" tag, not two | unit test |
| C24f | B9 | (amendment) a workspace outside `contacts.workspaces` | n/a | members only, no filter, no Add button; `GET /v1/me/contacts` not called | e2e on the mock bundle |
| C25 | B9 | initial JS budget | - | not raised (C) | `csi-spl-orc/src/bash/scripts/perf-budget.py` |
| C26 | B10 | (amended) contacts in the palette's `people` group | 6 groups, no contact rows | still 6 groups; contact rows in `people`, filled on first open; a contact matched to a member appears once | wui unit test on `usePaletteItems.ts`; control: `PALETTE_GROUPS` length 6 |
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

v1.1 changed rows B1, B2, B3, B4, B5 (cases only), B6, B8 and B9 (cases and
"after"); B7, B10, B11 and B12 are unchanged. The amendment (People merge)
changes B6, B9, B10 and B12 and leaves B1-B5, B7, B8 and B11 as they were;
the row count stays twelve.

| row | area | files (only these) | after | cases | test | author | R7 reviewer (backup) |
|---|---|---|---|---|---|---|---|
| B1 data | rdb, api | new `rdb/0223_contacts.sql` (section 3; the number re-checked at build time); `roles/runtime-grants.sql` (the `personal.contacts` grant and the door's EXECUTE, beside :45-51); `store/crosstenant_test.go` (seed `contacts_sync` in `seedTenantAll` (:28), beside its `gcal_connections` seed (`seedGcal`, :495, :503), on that row's tenant and human; the comment at :492-493 calls that human "the seeded member", and that it holds a `tenant_memberships` row is unchecked, I believe; if it does not, B1 seeds one); `store/personal_catalogue_test.go` (`personalTables` :23, the table and policy lists :30-42, the runtime grant list :91-97, the definer-role checks :109-121 for the third role and its door, plus a T-R7-like check that the purger role holds no grant on the other realm tables); a new `store/contacts_rls_test.go` (C2, C2c, C2d at SQL level) | - (v1.0: O5, answered B) | C1-C2d | `cd csi-spl-api/src/go/spool-hub-api && go test ./internal/store/ -run 'TestRLS\|TestCrossTenant\|TestContactsRLS'` against Postgres (hub-pg.tst.sh); full tier | claude | grok (claude) |
| B2 store | api | new `store/personal_contacts.go`, `store/personal_contacts_memory.go`, `store/personal_contacts_postgres.go`, `store/personal_contacts_test.go` (the list, `inPerson` only); new `store/contacts_sync.go`, `store/contacts_sync_memory.go`, `store/contacts_sync_postgres.go`, `store/contacts_sync_test.go` (the binding: workspace and operator scope only, no `personal` prefix); one field in `store/memory.go`; the new method names in `personCallers` in `store/personal_scope_test.go` (:25) | B1 | C3-C3c | the four test files, memory and Postgres; `go test ./internal/store/ -run TestPersonScopeCallers`; full tier | claude | grok (claude) |
| B3 contacts routes | api, cnf | new `hub/contacts.go` + `_test.go` (CRUD, export, erase one and all, the sync switch with 409 `contacts_sync_elsewhere`, the `realmRefuses` gate); one route line and one Options field in `hub/server.go`; one opts line in `api/cmd/spool/hub.go` (as 149 B5); the purge door call on `RunSweeper`'s retention; a `contacts:` block in `cnf/all.env.yaml` (`workspaces: []`, `scopes` empty until S2) and its tpl-gen output; one block in `api/internal/config/config.go` | B2 | C4-C7d, C8e, C12 | `hub/contacts_test.go`; api tests; `ENV=<env> ./run -a do_tpl_gen` + `git diff --exit-code` | claude | grok (claude) |
| B4 leave keeps, erase erases | api | tests only (the behaviour is B1's FKs and B3's gate): new Postgres cases in `store/humans_rbac_test.go` (remove), `store/demo_stay_test.go` (ban, stay), `store/clones_test.go` (retire) and one human-delete case; the memory store drops the person's binding (never the contacts) where it deletes a membership: one call beside `store/humans_rbac.go:197` (`removeMemberLocked`, which `BanMember` shares, :186) to a hook in `store/contacts_sync_memory.go` (B2's file) | B2, B3 | C8-C8d | the new Postgres tests; full tier | claude | grok (claude) |
| B5 search | api | `search/grammar.go` (`TypeContact`); `hub/search.go` (the `contact` section, calling B2's `inPerson` search method in its own transaction); their tests | B2 | C9-C11 | `go test ./internal/search/ ./internal/hub/ -run Search`; api tests | claude | grok (claude) |
| B6 member match | api | new `hub/contacts_match.go` + `_test.go` (the batch match of 2.4, in the session's workspace only); one call in `hub/contacts.go`'s list and card handlers that fills `member_id` (B3's file, so B6 lands after B3; until then `member_id` is `null`); no new route, no `server.go` line | B3 (v1.0: also O3, answered A) | C13-C13e | `hub/contacts_match_test.go`; api tests | claude | grok (claude) |
| B7 the contacts scope | api | `api/internal/gcal/oauth.go` (`AuthorizeURL` takes the scope to ask) + `oauth_test.go`; `hub/gcal_connect.go` (149 B5's file: `want`, `granted_scopes`, the upsert) and one scope check in `hub/gcal_sync.go` (149 B6a's file); their tests | 149 B5, 149 B6a, B1 | C14-C14c | the 149 connect and sync tests plus the two new ones; api tests | claude | grok (claude) |
| B8 contacts sync | api | new `hub/contacts_sync.go` + `_test.go`; new `api/internal/gcal/people.go` + test; new `api/internal/gcal/fakegcal/people.go`; a `PeopleBase` in `api/internal/gcal/oauth.go` Config (after B7's edit of the same file), `api/internal/config/config.go`, `api/cmd/spool/hub_gcal.go` (149 B5's file) and its cnf key; one line in `hub/server.go` `RunSweeper` (:586) | B3, B7 (v1.0: also O1, answered A) | C12, C15-C23g | `go test ./internal/gcal/... ./internal/hub/ -run Contacts`; api tests; full tier | claude | grok (claude) |
| B9 WUI (People merge) | wui | `wui/components/ChannelSidebar.vue` (the People panel :506-544 and `memberRows` :931-933: the three groups, the A-Z order, the filter, the Add button, the lazy contact rows); new `wui/components/PeopleContactRows.vue`; new `wui/utils/people-order.mjs` (the group and A-Z function, unit-tested alone); new `wui/pages/people/contact/[id].vue` (the contact card); `wui/pages/people/[id].vue` (one "In your contacts" line); new `wui/utils/contacts-client.mjs` (including the Invite call to `POST /v1/members/invites`); the Contacts switch in `wui/components/settings/calendar-google.vue` (149 B8's file); `csi-spl-wui/i18n/locales/en.json` (new keys only); unit + e2e tests. Not `wui/utils/rail-order.ts` | B3, B6, 149 B8 (v1.0: also O4, answered A) | C24-C25 | `pnpm run typecheck`; unit tests; `BASE_URL=<mock bundle> pnpm run test:e2e`; `perf-budget.py` | claude | grok (claude) |
| B10 palette | wui | `wui/composables/usePaletteItems.ts` (contact rows in the existing `people` group, deduplicated against members) + its unit test | B9 | C26 | the unit test; `perf-budget.py` | claude | grok (claude) |
| B11 i18n | wui | `csi-spl-wui/i18n/locales/*.json` except `en.json` (new keys only); agy has the last word (`LANE_MIX_KIND=i18n`) | B9, B10 | C27 | the two ratchet tests | agy | claude |
| B12 help | doc | the People help page `csi-spl-doc/doc/help/people.md` and its WUI copy (amendment: no new page): contacts in People, the order and the filter, what is stored, that the list is one per person across workspaces, who sees it, Google sync, export and erase; written in its qto doc and exported (`do_spl_doctree_export_md`); agy review | B9 | - | `cd csi-spl-iac && ./run -a do_check_dist_hygiene`; the qto doc drift check | agy | claude |

Order: B1 first; it no longer waits on the owner. Then B2. Then B3 and B5
at once (no shared file), then B4 after B3, whose gate C8c relies on. B6
after B3. B7 after spec 149's B5 and B6a have landed (it edits their files,
so it rebases onto them and its brief names their lanes). B8 after B7. B9
after B3, B6 and 149 B8. B10 after B9; B11 and B12 last. B3 and B8 both
edit `hub/server.go` (one line each): B8 rebases onto B3. B7 and B8 both
edit `api/internal/gcal/oauth.go`: B8 rebases onto B7, and its brief says
so. B4 and B2 share no file: B4 calls a hook in B2's
`contacts_sync_memory.go` and does not edit it.

What waits on the owner: no build row (O1-O5 are answered). Switching the
Google part on waits on S1-S4: every row is tested on the fake (2.8) and
lands behind `contacts.workspaces: []`.

## 7. Owner steps (never a lane)

| # | step | what |
|---|---|---|
| S1 | enable the People API | add `people.googleapis.com` to the API list (`cnf/all.env.yaml:60-85`) in the project of 149's S1, then the 001 step apply (owner go; terraform only through the tf-runner) |
| S2 | consent screen and ONE Google review (O2 = A) | add `https://www.googleapis.com/auth/contacts` (O1 = A) to that project's consent screen, beside 149's calendar scope (149 S2), and write the same string to cnf `contacts.scopes`. Then submit contacts and calendar **together in one Google review**, once both scopes are on the consent screen: one submission, not one per scope |
| S3 | no new client, redirect, key or secret | 149's client, its redirect URI (149 S3) and the KMS key are reused |
| S4 | switch on | `contacts.workspaces` per env, dev first, after B9 is live; a step-030 apply each (149 S5) |

## 8. Editor's proposals (for the panel)

| # | question | proposal | reason |
|---|---|---|---|
| P1 | a second Google connection for contacts | no: 149's row, one more scope, a `granted_scopes` column | one Google account per member; `include_granted_scopes=true` is in the landed client (`gcal/oauth.go:174`), a per-call scope is not (B7 adds it, 1.2 row 15) |
| P2 | rename `gcal_connections` to a neutral name | not in v1 | a rename of a landed table with rows is its own migration; the name is internal |
| P3 | Contacts inside People, or its own section (**decided by the owner, amendment**) | inside People: one list, online members first, then members, then contacts, A-Z in each, with an "In this workspace" filter | owner msgs `14cdf0ad`, `31bb12ea` (2026-10-24); v1.0 proposed its own rail tab |
| P4 | several emails or phones | one each, the primary; write-back keeps Google's others | the owner's four attributes; losing a second number at Google would be data loss |
| P5 | member match key | a verified identity email only | `humans.email` is informational (`rdb/0006_users_and_memberships.sql:23`); an unverified address could point a contact at the wrong person |
| P6 | Postgres isolation of a person (**changed in v1.1**) | the personal realm's `person_scope` on `personal.contacts`, plus the store naming `person_id` | v1.0 said "store isolation, as 149" from a grep for the wrong setting; `rdb/0168` isolates persons on master (1.2 row 20), and O5 = B makes the list a person's |
| P7 | push for contacts | none, a 10 min poll | no watch channel for the People API (unchecked, I believe) |
| P8 | search index | none: `ILIKE` over the reader's own rows | a person's list is small; spec 100's index is workspace-wide by design |
| P9 | (v1.1) a person with Google connected in two workspaces | one binding per person (`contacts_sync` primary key `human_id`); a second switch-on answers 409 `contacts_sync_elsewhere` until the first is turned off | one list must sync with one Google account, or two accounts would write one list both ways; moving the binding silently would need an operator write in a request path |
| P10 | (v1.1) clones and contacts | refused: `realmRefuses` gates every contacts route | a clone is disabled, never deleted (`store/clones.go:132-138`), so its list would outlive it; an admin acting as a member must not build or read a personal list |
| P11 | (v1.1) the 30-day purge across persons | one SECURITY DEFINER door owned by a third NOLOGIN realm role | the operator reads 0 realm rows (`0168:21-23`), and the realm already does cross-person work this way (`personal.due_receipts`, :168-176); widening `person_scope` for the operator would undo the realm's OQ-1 A |

## 9. Owner questions

All five are answered (HUM-10, prd t1 topic `451c020f`, 2026-10-24
08:0x-08:1xZ). Each poll stays as it was posted, followed by the answer.

```poll
O1. Which way should contacts sync with Google?
(A) Both ways: contacts added, changed or deleted in Spool change in Google too, and the other way round
(B) One way only: Google contacts come into Spool; changes made in Spool stay in Spool
```

Answer: **A**, both ways (poll `aed118ff`, msg `23612a98`). Built as 2.5;
scope `contacts` (2.2, S2).

```poll
O2. Contacts access is a scope Google reviews, like calendar access. What do we do about Google's review?
(A) Submit contacts and calendar together in one review, once both scopes are on the consent screen
(B) Do for contacts whatever is decided for calendar
(C) Do not submit for now: only members we list as test users can connect contacts
```

Answer: **A**, one combined review (poll `22c0ca12`, msg `4f3a251f`). Owner
step S2 (section 7).

```poll
O3. When a contact's email belongs to a member of the same workspace, may Spool show a Message button for that member? It tells the person that this member uses that email address.
(A) Yes, show Message for a contact whose email is a verified address of a member here
(B) No, never match contacts to members; the person finds the member in People instead
```

Answer: **A** (poll `26afbdb7`, msg `ee0538a1`). With O5 = B the match runs
against the workspace the person is in at that moment only (2.4, C13c).

```poll
O4. What can a person do with a contact who is not a member of the workspace?
(A) People who may invite members see an Invite button that sends a workspace invite to the contact's email; others see only the email and phone links
(B) Nothing in Spool: only the email and phone links
```

Answer: **A** (poll `71f2fc7e`, msg `d407984c`). The invite is to the
current workspace only (2.4, C24).

```poll
O5. Whose list is it, when a person is in several workspaces?
(A) One list per workspace: contacts added in one workspace are not seen in another
(B) One personal list that follows the person into every workspace they belong to
```

Answer: **B** (poll `1daf054d`, msg `e90b08c9`). The list moves to the
personal realm (2.6, 3); leaving a workspace keeps it (2.6).

No new owner question in v1.1.

## 10. Panel record

| when (UTC) | who | what |
|---|---|---|
| 2026-10-24 | c-951@sat | v0.1 `0618ced5f`: section 1 measured on `9e8ece102` (24 rows), sections 2-9 written; agy (main) out of quota |
| 2026-10-24 04:21 | a-957@sat (seat agy) | review d5f81cad on `fb7b73093`: 1.2 rows 1-23 OK, row 24 stale (next migration 0221); member delete must be soft (2.6 vs 2.5, C17b); callback must upsert and keep the refresh token; B4, B6 file lists. Scope class "sensitive, not restricted": stated without a source, kept "unchecked, I believe" (dispatch holder c-003, dcb58aae) |
| 2026-10-24 | c-951@sat | v0.2 `813557fe5`: all of a-957's findings folded except the scope-class wording; C14c added |
| 2026-10-24 04:29 | c-958@sat (seat claude) | review b362b28a on `813557fe5`: 1.2 rows 1-24 OK; W1 the landed `AuthorizeURL` has no per-call scope (row 15, P1, B7); W2 `Exchange` refuses an answer without a refresh token, so v0.2's keep-the-old-token clause was wrong (C14c); W3 four store paths delete memberships, so leave = erase belongs in the schema; G1 claim only connected rows, revoke on invalid_grant; G2 one token pair, two cycles; G3 B8 needs a People base URL; G4 B3 wiring; G5 purge before B8, hard delete when nothing goes to Google; G6 first-sync link with a duplicate email; G7 C14b is n/a on master; O4 wording |
| 2026-10-24 | c-951@sat | v0.3 `1cf55cf6e`: all of c-958's findings folded (each checked on the tree); W2 by its option (a), no landed code changes; new cases C7b, C7c, C8b, C20b, C23b, C23c |
| 2026-10-24 | a-957@sat (seat agy) | signed v1.0 on v0.3 `1cf55cf6e` (msg 42c902b9) |
| 2026-10-24 | c-958@sat (seat claude) | signed v1.0 on v0.3 `1cf55cf6e` plus one B4 file-list line (msg f297efda): the memory store's membership delete is `store/humans_rbac.go:197` |
| 2026-10-24 | c-951@sat | v1.0 `225f4e583`: that B4 line, nothing else; owner questions O1-O5 (section 9) go to the owner next |
| 2026-10-24 | c-988@sat | v1.1 draft, this commit (SPL-3192): the owner's five answers folded (O1 A, O2 A, O3 A, O4 A, O5 B). 1.2 re-measured on `e0f02e7ff`: row 20 corrected (person RLS exists, 0168), rows 21, 24 corrected (next migration 0223), rows 25-31 new. O5 = B: `personal.contacts` in the realm (no `tenant_id`, `person_scope`), `contacts_sync` one binding per person, leave keeps the list, the purge door; clones refused. Sections 0-10 updated; new cases C1c, C2c, C2d, C3b, C3c, C4b, C7d, C8c-C8e, C10c, C23d-C23g; B1, B2, B3, B4, B6, B8, B9 rows changed. Not signed: the two review seats sign in their own messages |
| 2026-10-24 | c-988@sat | v1.1 amendment, this commit (SPL-3192): the owner's People merge (msgs `14cdf0ad`, `31bb12ea`, relayed by c-002 cc083bf1, c04f855b). The People section was measured: 1.2 rows 32-35 are new and rows 6, 12, 13 changed. 2.7 is rewritten (three groups, A-Z, the filter, the lazy contact rows, no rail tab). The `/peer` route is replaced by `member_id` on the list and card routes, and `GET /v1/me/contacts/{id}` is added. New cases C13e, C24b-C24f; C13-C13d, C24 and C26 amended; B6, B9, B10, B12 and P3 changed. B1 is unchanged. Not signed |

<!-- version: 1.1-draft (amended: People merge) · updated: 2026-10-24 -->
