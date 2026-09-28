# Spec: user settings, GitHub-style, and the Keys section (023)

**Feature**: `specs/023-spool-user-settings-keys` · **Created**: 2026-09-19 · **Lane**: CLE-3408

## 1. Owner order (verbatim, 2026-09-19)

> "enable the user setting called keys - on click the user will get into a
> page for the settings (like the github interface - each setting on the left
> and its content on the right) and the keys section will have a default
> public private key created and the user will be able to download the private
> key and the public key, or upload new public key"

## 2. What exists (measured on `de06bd7`)

| aspect | today | file |
|---|---|---|
| settings page | one page, four stacked cards: Profile, Language (CLE-3403 `<LanguageSetting/>`), Appearance, Sign-in and security (CLE-3402 `12ece07`) | `csi-spl-wui/src/pages/settings.vue` |
| entry | the user menu's Settings item → `localePath('/settings')` | `csi-spl-wui/src/components/UserMenu.vue:55-62` |
| routing | `/settings` is not prerendered: Firebase serves the SPA fallback, so any `/settings/<x>` deep link hydrates client-side | `nuxt.config.ts` (`PRERENDER_PAGES = ["/", "/login"]`) |
| box key format | private = base64(64-byte Ed25519 seed‖pub) + `\n`, file `box-<id>.key` 0600; public pin = base64(32 bytes) + `\n`, `box-<id>.pub` | `internal/sign/sign.go` (`GenerateKey`, `Pin`) |
| tenant root key | the same private format (`spool root-keygen --out`) | `cmd/spool/hub.go:447` (`cmdRootKeygen`) |
| a human's key | none: a human (HUM-*, rdb 0006) authenticates only by the 010/015 session cookie; the hub verifies box signatures by pins (004), never a human's | `rdb 0006`, `internal/hub/rest.go` |
| SEC-03 | private key material is shown once, never stored by the hub, never mailed (006 FR-014 as amended by 017 T008) | `specs/006-spool-hub-rental/spec.md` FR-014 |

## 3. Decisions

### 3.1 Where the default key pair is generated — the browser (option a)

The default Ed25519 pair is generated **in the browser** (WebCrypto
`Ed25519`) the first time a signed-in human opens **Settings → Keys** with no
active key. The page uploads **only the public key**; the private key lives in
page memory, is offered as a download (and the public key too), and is gone
when the page is left. The hub never receives, stores, logs or returns a
private key.

Security reasoning:

- **No custody, no breach surface.** A hub that never holds a private key
  cannot leak one from its database, its backups, a log line or a stolen
  session. Server-side custody (b) turns every session-cookie theft into a
  key theft, and the Postgres backups into key backups.
- **Consistent with SEC-03** (017 T008): the tenant root key is minted once
  and shown once; keys are not escrowed or mailed. A human key follows the
  same rule.
- **The browser is already trusted with the session.** Generating in the page
  adds no new trust: the same origin already carries the session cookie.
  WebCrypto's generator is the platform CSPRNG; the private bytes are exported
  only into a `Blob` for the download.
- **Refusal on the wire.** The API rejects any body that carries a field it
  does not know (so no `private_key` can be sent), refuses a 64-byte key or a
  `PRIVATE KEY` block, and answers nothing but public material.

Consequence: "download later" of the **private** key is not possible after the
page is left. The page says so next to the download, and offers
**Generate a new key pair** (the old one is revoked, history kept) for a
human who lost it. The **public** key stays downloadable any time. Server
custody is refused (OQ-1 answered by the owner 2026-09-19: (a) browser only).

A browser without WebCrypto Ed25519 (Chrome < 137, Firefox < 129, Safari < 17)
gets no default pair: the page says so and shows the CLI route
(`spool root-keygen --out <file>` prints the public key to upload).

### 3.2 Formats — the ones the boxes already use, plus OpenSSH

| file | content | works with |
|---|---|---|
| `<HUM-n>.key` | base64(64-byte seed‖pub) + `\n` | exactly `spool keygen` / `root-keygen` output: `sign.LoadPrivate`, `--root-key` |
| `<HUM-n>.pub` | base64(32 bytes) + `\n` | exactly a pin value: `spool pin --pubkey "$(cat HUM-n.pub)"`, `hub-pin --pubkey` |
| `<HUM-n>.openssh.pub` | `ssh-ed25519 AAAA… spool:<HUM-n>` | OpenSSH `authorized_keys`, `ssh-keygen -lf` |

Upload accepts either public form: the 44-char base64 pin value or an
`ssh-ed25519` line (the comment is ignored). The fingerprint shown is
OpenSSH's (`SHA256:` + unpadded base64 of sha256 over the ssh wire blob), so
`ssh-keygen -lf <file>` prints the same string.

### 3.3 What the key is FOR

Today, **nothing in the hub verifies a human key**: box traffic is verified by
box pins (004 pin-semantics), and a human is authenticated by the session
cookie. The key is a registered, downloadable **identity key** for the human,
format-compatible with the box keys, so it can be used where a box key or a
root key is used:

- as the key of a personal box (`box-<id>.key` under `~/.spool/keys`, pinned
  with the `.pub`), which is the one use that works end to end today;
- as the future identity for a human signing as a box peer (a HUM-* signing a
  message from the CLI) — no hub consumer yet (OQ-2).

The Keys section says so on the page too: the hub keeps the public key as
your identity key and no spool feature requires it yet.

### 3.4 Settings layout — GitHub-style

`/settings` becomes a two-column page: a left nav of sections, the selected
section on the right. Each section is its own route and deep-linkable:

| route | section | content (moved, not duplicated) |
|---|---|---|
| `/settings` | → redirects to `/settings/profile` | |
| `/settings/profile` | Profile | the old Profile card, plus Display name (`DisplayNameSetting`, `e3cc76b0`) |
| `/settings/language` | Language | CLE-3403's `<LanguageSetting/>` |
| `/settings/appearance` | Appearance | theme (3.6), font size (3.5), Debug pane (`DebugPaneSetting`, `b8e376ba`, rdb 0038) |
| `/settings/security` | Sign-in and security | method, password change, sign out |
| `/settings/keys` | Keys | 3.1-3.3 |

Locale prefixes apply (`/fi/settings/keys`). Below 720px the nav collapses to
a wrapping row of links above the content (no x-scroll). The signed-out state
renders once, in the parent, for every section.

### 3.5 Font size (CLE-3495, owner 2026-09-25) — Implemented

> "also make the default font a big bigger , actually we need a setting in the
> personal settings to regulate the size of the default onts , with + for
> getting bigger fornts and - for getting smaller - 5 levels with radio buttons"

- **Five levels**, a native radiogroup on `/settings/appearance`, with a `−`
  (one level smaller) and a `+` (one level bigger) each disabled at its end.
- **One root variable.** `html { font-size: var(--font-root) }`, set per level
  by `data-font-size` on `<html>`: 87.5 / 100 / 112.5 / 125 / 137.5 % of the
  browser default (16px → 14 / 16 / 18 / 20 / 22 px). Every text size in the
  WUI is rem so it follows; the exceptions are avatar initials (fixed-px
  circles) and the five "A" samples in the control. Gate:
  `tests/unit/font-size.test.mjs`.
- **Default is level 3 (18px).** Measured before the change on dev and prd
  (`/login`, headless Chrome, n=1 each): `html` and `body` computed 16px — that
  is level 2 now.
- **Persistence: per browser** (`localStorage` `spool-font-size`, like the
  theme — `utils/prefs.mjs`), not hub-side like `preferred_locale`. The locale
  is on the hub because the hub mails in it; nothing on the hub reads a font
  size, and a hub field would cost a migration, a hub roll and a preferences
  contract change for a purely visual choice. A reader on a phone and on a
  desktop may also want different sizes.

### 3.6 Theme picker and five themes (CLE-34994, owner 2026-09-26) — Implemented

> "fix the title of the app in the upper left corner - it is spool-hub and not
> bare spool and change the theme switching to a painter pallette icon and add
> several more themes which will be in between , aka the pallete will open a
> drop box where themes could be chosed , and for now we would like to have
> dark , light , light violette , and light green , and light violette and
> light yellow themes"

- **Brand.** The top-left brand, the page `<title>`, the PWA manifest
  `name`/`short_name`, the iOS home-screen title and the no-env signed-out bar
  read `spool-hub` (trunk `a159f76f`). The dev/prd signed-out bars already read
  `spool-dev` / `spool-hub`.
- **Five themes**, dark to light: `dark`, `light`, `light-violet`,
  `light-green`, `light-yellow` ("light violette" named twice, read as one).
  Each is a full `:root[data-theme=…]` palette in `variables.css` with the
  light theme's token set (gate: `tests/unit/theme-tokens.test.mjs`).
  Tokens: trunk `a159f76f`.
- **Picker.** The sun/moon toggle becomes a palette-icon button
  (`ThemeToggle.vue`, top bar right of the brand and Settings → Appearance)
  opening a listbox of the five themes, the current one checked, each with a
  swatch of its own background + accent. Keyboard: Enter/Space/Arrow open on
  the current theme, arrows wrap, Home/End, Enter/Space choose, Escape and a
  choice return focus to the button. Persistence unchanged: `localStorage`
  `spool-theme`, `html[data-theme]`, default dark, no system-follow (it never
  existed). Trunk `a95ee9dc`; names in 19 locales `c2070757` (GRK-3520).
  Settings → Appearance opens the list end-aligned (`align="end"`) so it
  stays on a phone screen. Gates: `tests/unit/theme-toggle.test.mjs`,
  `theme-names-i18n.test.mjs`. Local proof (generated bundle, headless
  Chrome, n=1): each theme picked by mouse sets `data-theme`, storage and the
  body background, focus returns to the button; keyboard open / End / wrap /
  Enter / Escape; reload keeps the choice; 390px list on screen, no x-scroll.
- **On the account too** (owner follow-up 2026-09-26, topic 689495d0: "set
  her ... color theme to light blue"). `humans.preferred_theme` (rdb 0057,
  0059) is returned by the session and applied once per sign-in
  (`plugins/preferred-theme.client.ts`, `37fec7e6`); an operator sets it with
  `ENV=<env> HUMAN_ID=HUM-<n> THEME=<id> ./run -a do_spl_human_theme`
  (`light` is the light-blue palette). From hub 0.8.6 (`0a4839a1`) the
  picker writes a signed-in member's pick back through `PUT
  /api/v1/auth/preferences` `preferred_theme` (`saveThemeToAccount` in
  `utils/theme.mjs`), so the operator default and the person's own choice are
  one field and a new device starts from it. A failed save is silent;
  `localStorage` stays this browser's source. Hub 0.8.7 (`977af005`): the native
  `POST /login` answer carries `preferred_theme` too - before it a password
  sign-in never applied a stored theme (the WUI adopts that answer with no
  session probe). Issue SPL-965. Live proof (dev, hub 0.8.7, WUI `bb849ff0`,
  n=1): a pick in browser A (PUT 200) is the theme a fresh browser B signs in
  to.
- **Contrast, computed** (`tests/unit/theme-contrast.test.mjs`, trunk
  `a159f76f`, worst pair per theme; bars text 4.5:1, focus ring 3:1):

  | theme | text | muted | accent text | button text | error text | focus ring |
  |---|---|---|---|---|---|---|
  | dark | 13.5 | 6.2 | 9.7 | 8.3 | 5.0 | 10.2 |
  | light | 12.1 | 5.4 | **3.0** | **3.2** | 4.8 | **1.75** |
  | light-violet | 10.6 | 5.7 | 5.6 | 6.1 | 5.6 | 4.0 |
  | light-green | 11.7 | 5.8 | 5.3 | 5.6 | 5.9 | 3.6 |
  | light-yellow | 11.8 | 6.7 | 5.9 | 6.3 | 6.0 | 4.0 |

  The three new themes clear every bar. The light theme's three shortfalls
  predate this change (the ring is the 2026-09-20 "lighter line" order,
  CLE-3427); they are pinned at today's value so they cannot worsen, and are
  left for the owner to rule on.

### 3.7 Behaviour → Text fields (SPL-976, owner 2026-09-26) — Implemented

> "add a new setting in the personal settings, new section 'behaviour', which
> defines how a text field should behave. The options: Enter sends,
> Shift+Enter adds a line; or Enter adds a line, Control+Enter saves"

- **Section.** `/settings/behaviour`, after Appearance in the nav
  (`utils/settings-nav.mjs`). One radiogroup, "Text fields"
  (`components/SubmitKeySetting.vue`), strings in all 19 locales.
- **Two modes**, `submit_key`:

  | id | Enter | Shift/Alt+Enter | Ctrl/Cmd+Enter |
  |---|---|---|---|
  | `enter` | sends / saves | new line | sends / saves |
  | `ctrl-enter` | new line | new line | sends / saves |

  In both modes a bare Enter inside an open ``` block adds a line, and an
  IME composition never sends.
- **Default (never picked) = `enter`** since 2026-09-27 (owner, topic
  a4bc52dc: "change the default to the 'normal' one ... but keep the
  behaviour of the already set settings, aka mine as they are").
  `DEFAULT_SUBMIT_KEY` in `utils/submit-key.mjs` and `auth.DefaultSubmitKey`
  on the hub agree (unit-tested). NULL still means never picked; the hub never
  writes the default into a row. Measured before the flip: every row on dev
  (12) and prd (10) was NULL, the owner's too (a click on the already-checked
  radio stores nothing), so the owner's rows (prd HUM-10, dev HUM-9, HUM-17)
  were pinned to `ctrl-enter` with `do_spl_human_behaviour` first. Until then
  the default was `ctrl-enter` (the composer's rule of 2026-09-23, `b184c152`).
- **Kept on the account**, like the theme (3.6): `humans.submit_key` (rdb
  0062), `PUT /api/v1/auth/preferences` `submit_key` (auth-v1), answered by
  `GET /session` and the native `POST /login`; hub 0.9.3 (`af883284`). An
  operator sets it with
  `ENV=<env> HUMAN_ID=HUM-<n> SUBMIT_KEY=<enter|ctrl-enter> ./run -a do_spl_human_behaviour`.
  The radio is optimistic (claim first, reverted with a status line when the
  hub refuses), so every open field follows at once.
- **One helper.** `composables/useSubmitKey.ts` over the pure
  `utils/submit-key.mjs` (`submitKeyAction`). Fields: the message composer
  (every page's composer and thread replies — it is the one omnibox), the
  issue comment box, the issue description (saves; on a new issue it also
  creates the issue), the new-channel description (submits the form).
  Placeholders that name the keys follow the mode (`hintFor`: `<key>` is the
  Ctrl+Enter wording, `<key>_enter` the Enter one).
- **Not driven by it:** single-line inputs (the subtask dialog title, the
  issue title, the deadline) submit on Enter natively; the message-edit box
  keeps its own rule (`msg-edit.mjs`, 2026-09-22 order, CLE-35013/35014's
  lane); the Keys paste box has no submit key (Upload is a button).

### 3.8 Behaviour → Left panel order (SPL-979, owner 2026-09-26) — Implemented

> "one new setting in the user settings, new behaviour section - the order of
> the entities in the left most panel - direct messages, channels, issues,
> topics, flow, event log" — and: "the users should be able to set the order
> by simply dragging the icons of each one of them in the left most panel
> back and forth, and the same order should appear in their user settings,
> and they should be able to adjust it from there as well"

- **Seven tabs**, `utils/rail-order.mjs` `RAIL_TABS` (id, icon, label):
  `channels`, `dm`, `issues`, `topics`, `flow`, `archive` (SPL-983, owner,
  topic 8f58f802; the Archive page, `/archive`, CLE-35018) and `events`.
  That is also the **default order** for a person who never reordered
  (rail_order NULL): since 2026-09-27 Channels comes first (owner, topic
  116646c8: "channels, direct messages, issues, topics, flow and archive";
  the Event log, not named, goes last). Before that it was `dm`, `channels`,
  `issues`, `topics`, `flow`, `events`, `archive`.
  A stored order is kept as it is (measured then: prd HUM-10 and HUM-5
  explicit, everyone else NULL; dev all NULL). Hub `auth.RailTabs` lists the
  same order (unit test); rdb 0064's CHECK is order-free. The admin-only Users tab is not one of
  them and always stays last. An order stored before Archive existed (six ids)
  is drawn with Archive appended (`parseRailOrder`); the hub and rdb 0064
  admit both the legacy six and all seven (hub 0.9.5, `86cf0ff2`).
- **Drag in the rail** (primary). `composables/useDragReorder.ts`: pointer
  events, so mouse, pen and touch alike; a press becomes a drag only past
  `DRAG_THRESHOLD_PX` (6 px), so a plain click still navigates, and the click
  that ends a drag is swallowed. The icons follow the pointer while dragging;
  a drop saves at once. The rail icons carry `touch-action: none` so a touch
  drag reorders instead of scrolling.
- **Settings → Behaviour → Left panel order** (`RailOrderSetting.vue`): the
  same order as a list, each row with a drag grip, an up and a down button
  (keyboard; the pressed row keeps focus, a polite live region says the new
  position), and **Default order** (stores `null`). Strings in all 19
  locales.
- **One value, kept on the account**: `humans.rail_order` (rdb 0063, NULL or
  a permutation of the six ids, enforced by a CHECK), `PUT
  /api/v1/auth/preferences` `rail_order`, answered by `GET /session` and the
  native `POST /login`; hub 0.9.4 (`590fd54b`). The rail and the Settings list
  both draw from the `rail_order` claim (`composables/useRailOrder.ts`), and a
  save mirrors the claim first (reverted on a refusal), so a change in either
  place shows in the other at once. An operator sets it with
  `ENV=<env> HUMAN_ID=HUM-<n> RAIL_ORDER=<six ids> ./run -a do_spl_human_behaviour`.

### 3.9 Behaviour → Close buttons (SPL-1133, owner 2026-09-28)

> "we need a User Setting to put the X's for closing the modal dialogs etc.
> either Windows style, i.e. top right, or Mac style, i.e. top left" — then
> "use the Mac style as the default" (prd t1 topic 9e0379a6).

- **Two values**, `close_buttons`: `mac` (top left, **the default** for a
  person who never picked) | `windows` (top right). `humans.close_buttons`
  (rdb 0077, NULL or one of the two, CHECK), a hub view pref
  (`auth.ViewPrefs`, `PUT /api/v1/auth/preferences`, `GET /session`, native
  login answer). A never-picked row stays NULL; the default is not written into it.
- **Implemented once**: `app.vue` mirrors the claim on
  `<html data-close-buttons>`; `components/UiCloseButton.vue` is the one close
  X. Each header places it at BOTH ends (`side="start"` / `side="end"`) and
  exactly one renders (`closeButtonShown`), so the X is in the DOM where it
  is drawn: the first Tab stop in Mac style, the last in Windows style, and
  focus still returns to the opener on close.
- **Where**: `UiDialog` (so every dialog: UiConfirm, the issue modal
  SPL-1027, channel Properties, the logo, move picker, code / file viewers),
  the thread panes (`TopicPane`, `LiveTopicPane`), the Users edit pane, the
  Issues phone sheets (Filters, Sort).
- **Phones**: a full-screen dialog and a pane keep their Back chevron at the
  top left in both modes and show no X (unchanged, SPL-989/993); the bottom
  sheets that do show an X follow the setting.
- **Not moved**: toasts and snackbars (MoveUndoToast, ErrorSnackbar) and chip
  removers (a file chip, a label chip) - they dismiss an item, they do not
  close a window. The version pop-up and the search sheet have no X (the
  pop-up is a hover card; the phone search sheet was retired, SPL-1005).
- Proof: `tests/e2e/close-buttons.test.mjs` (mock, 1440 + 390).

## 4. Requirements

- **FR-001** `/settings` is the two-column layout of 3.4; the user menu's
  Settings entry lands there; each section has its own route.
- **FR-002** On first visit to Keys with no active key and a WebCrypto
  Ed25519 browser, the page generates a pair, registers the public key
  (`source: generated`) and offers both downloads. The private key is never
  sent to the hub.
- **FR-003** Download the public key (pin form and OpenSSH form) at any time;
  download the private key only while the page that generated it is open.
- **FR-004** Upload a public key (paste or file): it replaces the active key;
  the old one is kept as history with `revoked_reason = replaced`.
- **FR-005** Revoke the active key (no replacement): history keeps it with
  `revoked_reason = revoked`; the next visit generates a new default pair.
- **FR-006** The hub validates an uploaded key as exactly 32 Ed25519 bytes
  (base64 pin form or `ssh-ed25519` line), refuses private-key material,
  malformed input and a key already registered to any human (`duplicate_key`,
  the same answer whoever owns it).
- **FR-007** Every keys route needs a member session carrying a HUM-*;
  a human sees and changes only their own keys (another human's key id is
  `404`, never `403`, so ids do not leak).
- **FR-008** Writes are rate-limited per human (in-process window) and
  audited: a structured log line per add / revoke (human id, key id,
  fingerprint, source, reason) plus the durable history rows.
- **FR-009** i18n: every string is a catalogue key in all 19 locales. Check
  (GRK-3380, 2026-09-21): 19 locale files each carry all 58 `settings` leaves (71 on trunk `28442ef6`, python leaf walk: 71 in every locale, el 1/71 identical);
  identical-to-English is 0 for es/ru/tr/uk/he/sv/nl and 1/58 for el
  (`settings.email` = `Email`).
- **FR-010** No document x-scroll at phone width; CSP unchanged (WebCrypto
  and `blob:` downloads need no new directive).
- **FR-011** Font size (3.5): five levels as radios plus `−` / `+`, one level
  per step, stopping at 1 and 5; the body font-size grows strictly level to
  level; the default is one level above the old 16px root; the choice
  survives a reload. Strings in all 19 locales.
- **FR-012** Settings → Behaviour → Text fields (3.7) offers `enter` and
  `ctrl-enter`; the choice is stored per human on the hub, returned by the
  session and the native login, and applies at once to every open field.
- **FR-013** Every multi-line field with a submit reads Enter through
  `useSubmitKey` (the composer and thread replies, issue comments, issue
  descriptions, the new-issue form, the new-channel description); none keeps
  its own Enter handling. Gate: `tests/unit/submit-key.test.mjs`.
- **FR-014** An operator sets a human's mode with `do_spl_human_behaviour`
  (DRY_RUN default, one row or rollback); its list is rdb 0062's CHECK.
- **FR-015** Dragging a left-rail icon (mouse or touch) past a 6 px threshold
  reorders the six tabs and stores the order at once; a plain click still
  navigates and never reorders.
- **FR-016** Settings → Behaviour → Left panel order shows the same stored
  order and changes it by drag, by up / down buttons (keyboard) and back to
  the default; the rail and the list redraw at once from one value.
- **FR-017** The order is kept per human on the hub (rdb 0063), answered by
  the session and the native login, so every device draws it; an operator
  sets it with `do_spl_human_behaviour RAIL_ORDER=`.

### 4.1 Status (trunk `28442ef6`, n=1)

| FR | status | evidence |
|---|---|---|
| FR-001 | Implemented | T020; `utils/settings-nav.mjs` 5 sections, `pages/settings.vue:78` 720px breakpoint |
| FR-002, FR-003 | Implemented | T021, T030; `node tests/unit/human-keys.test.mjs` -> 7 passed |
| FR-004..FR-008 | Implemented | T010-T013; `go test ./internal/hub -run Keys -v` -> 5 PASS; routes `keys.go:63-67`, audit `keys.go:235,263` |
| FR-009 | Implemented | T022, T032 |
| FR-010 | Implemented | T031 |
| FR-011 | Partial | T040-T042; missing: px font sizes left in `MessageBody.vue` (1), `ChannelSidebar.vue` (7), `ChannelPropertiesDialog.vue` (2), still on the `font-size.test.mjs` allow-list -> T043 |
| FR-012..FR-014 | Implemented | SPL-976: hub `af883284` (0.9.3, rdb 0062 dev+prd); `node --test tests/unit/submit-key.test.mjs`; `bash csi-spl-orc/src/bash/tests/human-behaviour.tst.sh` 16 PASS; live proof `tests/e2e/submit-key-live.proof.mjs` (T050) |
| FR-015..FR-017 | Implemented | SPL-979: hub `590fd54b` (0.9.4, rdb 0063 dev+prd); `node --test tests/unit/rail-order.test.mjs`; `bash csi-spl-orc/src/bash/tests/human-behaviour.tst.sh`; live proof `tests/e2e/rail-order-live.proof.mjs` (T052) |

## 5. Open questions (owner)

- **OQ-1 private key "download later".** Answered by the owner 2026-09-19:
  **(a) browser only** — the server never holds private keys. Built: the
  default Ed25519 pair is generated in the browser; the private key is
  downloadable while the generating page is open, never on the hub.
  Alternative **(b)** (hub stores the private key encrypted and serves it to
  a signed-in session) is refused: every session theft would become a key
  theft and it contradicts SEC-03. Nothing further to build.
- **OQ-2 consumer.** No hub feature verifies a human key yet. Candidates: a
  HUM-* signing CLI messages, or pinning a personal box from the WUI. Pick one
  before the key becomes load-bearing.

<!-- version: 1.5.1 · updated: 2026-09-27 · last-edit: 2026-09-27T01:00:00Z -->
