# Prompt: 013 Spool chat reverse — Top Omnibox, prepend feed, 3-pane, avatars

This is the prompt that, handed to a capable coding agent at the start, would
have produced `013-spool-chat-reverse` (spec, plan, tasks and the
`csi-spl-wui` code) with the fewest detours. It is written after the fact from
the spec, its git history and the source; the snapshot at the end records
what the source actually held when this was written.

---

## 1. Goal and why

You own the M3 WUI chat display for the spool (`csi-spl-wui`, Nuxt 3 +
TypeScript). Turn the 005 live-chat MVP (oldest-first transcript, composer at
the bottom) into the owner's **reverse-flow prepend** chat:

1. **Top Omnibox** — one input pinned at the top of the middle pane. Enter
   sends a `note`; a leading `@CLE-07` makes it a `task` to that agent.
   `/search <q>` (and `/s <q>`) sends nothing and filters the feed on body,
   author (`id` and `id@box`) and file names; `/search` alone or Esc clears.
2. **Newest-first feed** directly under the Omnibox. Own sends and live WS
   arrivals enter at the top with a short entrance transition (none under
   `prefers-reduced-motion`). Scrolling down reveals older history; a bottom
   sentinel loads the next older window (50 rows).
3. **Right thread pane** for a `task_id`: the root (oldest message of that
   `task_id`) pinned on top, then the pane's own reply Omnibox, then replies
   newest first, live over the same socket.
4. **Avatars** for everyone: `HUM-*` → identicon; every agent (`CLE-*`,
   `GRK-*`, `AGY-*`, any other non-HUM prefix) → a wild, funny, deterministic
   robot from `id@box`, chassis tinted by prefix. Used on message cards, the
   roster and the `@mention` suggestions.
5. **Accessibility**: DOM and focus order = visual order (Omnibox, newest,
   older); the feed is `role="feed"` of `article`s with
   `aria-posinset`/`aria-setsize`; the Omnibox is labelled; live arrivals are
   announced politely.

Why: the owner adopted this as the binding default M3 UX on 2026-09-18
(`csi-spl-doc/doc/md/SPEC-spool-chat-reverse.md`, with
`SPEC-spool-wui-layout.md` §1.1 and `SPEC-spool-avatars.md`). Those three
narratives are binding; read them first and treat them as the requirement.

Pages in scope: `/lobby`, `/t/<id>`, `/` with the live pane (`/?thread=<id>`),
and — the owner's X3 extension — `/channel/<name>`, `/dm/<peer>` and the
channel `ThreadPane`. Do all of them in one pass; do not stop after the lobby.

## 2. Binding constraints and non-goals

- **Display only.** No `v:1` field change. Hub storage stays chronological
  (`ts`, `msg_id`, `task_id` in Postgres). CLI, MCP and `spool tail` stay
  oldest-first. Everything you write lives in `csi-spl-wui`.
- **Evolve, do not rewrite.** Reuse the 005 pieces unchanged in contract:
  `utils/live-ws.mjs`, `composables/useLive.ts`, `stores/live.ts`,
  `MessageComposer.vue`, `MessageCard.vue`, and on `/channel` + `/dm` the
  existing merge (`mergeLive`, `rowFromAck`) — the channel store keeps holding
  rows oldest first; you only derive a newest-first view from it. One feed
  component (`LiveFeed.vue`) serves every page; `MessageFeed.vue` renders it
  rather than growing a second feed.
- **Frozen contracts you consume, not change:** 003
  `contracts/view-v1.md` and `contracts/wui-live-ws.md`. The one hub-side
  need — a newest-first window on view-v1 §4.4 — belongs to 003. Ask for it
  as a gap row with an owner; do not implement it in the hub. (It shipped as
  `order=desc&limit=&before=`; consume that.)
- **Hygiene (CLAUDE.md §7 and avatars §2/§4):** avatars are generated in the
  client as inline-SVG data URIs — **no image files committed**, no
  third-party avatar CDN, no user text interpolated into the SVG. Org-neutral
  text, no personal names, no host literals in code or docs.
- **No sideways scroll anywhere** (no-x-scroll invariant), including the
  3-pane pages at 390×844 with the pane open. Desktop geometry per layout
  §1.1: left `--sidebar-w: 260px`, middle flex, right `--thread-w: 380px`;
  below 1100px the right pane overlays.
- **Non-goals:** custom avatars (`file_id` profile map, avatars §3), server
  paging of older channel/DM threads (`listThreads before=`), any change to
  CLI/MCP output order.
- In `v:1` a thread **is** a `task_id`. The pane opens a `task_id` — from a
  thread row (plain click; Ctrl/middle-click still opens `/t/<id>`), from
  `/?thread=<id>`, or from "Open thread" on a card whose `task_id` differs
  from the current feed's.

## 3. Order of work

1. **Spec first.** Create `csi-spl-doc/specs/013-spool-chat-reverse/`
   (`spec.md`, `plan.md`, `tasks.md`) per `specs/README.md` §2.3 status words
   (Implemented / Partial / Planned). Check the next free number with
   `ls csi-spl-doc/specs` — 012 was already taken. Record the gap to 003 (D1,
   newest-first window) and to "later" (D2, custom avatars). Commit and push
   the Planned spec before any code.
2. **Pure helpers + unit tests** (commit, push):
   `src/utils/feed.mjs` — `newestFirst` (stable), `windowed`,
   `parseOmnibox`, `matchesSearch`, `rootAndReplies`;
   `src/utils/avatar.mjs` — `robotSvg`, `identiconSvg`, `avatarSvg`,
   `avatarDataUri`, deterministic per `id@box`;
   `tests/unit/feed-avatar.test.mjs`.
3. **Components** (commit, push): `MessageComposer.vue` `omnibox` mode
   (emits `search`, Esc clears, labelled textarea); `SpoolAvatar.vue` on
   cards, roster and mention list; `LiveFeed.vue` (`TransitionGroup`
   `prepend`, `IntersectionObserver` bottom sentinel, `role="feed"`, polite
   announcer); `stores/live.ts` → `useLiveFeed('main' | 'pane')` sharing the
   one WS socket; `LiveThreadPane.vue`; CSS in `assets/css/main.css` +
   `variables.css`; wire `/lobby`, `/`, `/t/<id>`; add the pane-open path to
   `tests/e2e/no-x-scroll.test.mjs`.
4. **Server windows** once 003's `order=desc&before=` is on trunk (commit,
   push): `getThread({ order, limit, before })` in `spool-client.mjs` with the
   mock serving the same desc windows; feeds open with the newest 50, the
   sentinel shows held rows first, then fetches `before=<next>`; pinned-root
   views page to the oldest row. Unit tests in `tests/unit/view-api.test.mjs`.
5. **X3 pages** (commit, push): `utils/channel-feed.mjs` `channelView`
   (one card per thread root, newest first, search, 50-row windows);
   `stores/channel.ts` gains only `newestFirst`/`hasOlder`/`search`/
   `lastLive`/`loadOlder`/`setSearch`; `pages/channel/[name].vue` and
   `pages/dm/[peer].vue` put the Omnibox above `MessageFeed.vue`, which
   renders `LiveFeed` (optional `count-for` / `always-thread` props);
   `ThreadPane.vue` becomes pinned root + reply Omnibox + newest-first
   `LiveFeed`. Add `/dm/<peer>` to the e2e path list;
   `tests/unit/channel-reverse.test.mjs`.
6. **Live acceptance** under lde against a trunk `spool serve`, then tick
   each task with the commit sha and the measured evidence (n, date).

## 4. Acceptance criteria and exact checks

Run from `csi-spl-wui` (as the box user). All must hold:

| # | Criterion | Check |
|---|---|---|
| A1 | Unit suite green | `node --test tests/unit/*.test.mjs` → 0 fail |
| A2 | Helpers covered | `node --test tests/unit/feed-avatar.test.mjs tests/unit/view-api.test.mjs tests/unit/channel-reverse.test.mjs` → 0 fail |
| A3 | Types | `npx nuxi typecheck` → exit 0 |
| A4 | No sideways scroll incl. 3-pane pages | `node tests/e2e/no-x-scroll.test.mjs` → all OK; paths include `/?thread=<id>`, `/channel/lobby`, `/dm/CLE-07%40box-a` at 390×844 and 1280×800 |
| A5 | No console errors | `node tests/e2e/console-errors.test.mjs` → zero |
| A6 | One feed component | `command grep -c '<LiveFeed' src/components/MessageFeed.vue` → 1 |
| A7 | Channel pane pins the root | `command grep -c 'pinned-root' src/components/ThreadPane.vue` → 1 |
| A8 | Reduced motion honoured | `grep -n 'prefers-reduced-motion' -A2 src/assets/css/main.css` shows `.prepend-enter-active` with `transition: none` |
| A9 | No image files added | `git diff --name-only origin/master... -- '*.png' '*.jpg' '*.jpeg' '*.gif' '*.svg' '*.ico' '*.webp'` → empty |
| SC-001 | Two sessions, lde, live hub: A's send prepends at A's top at once and at B's top live, announced | manual, record n and time |
| SC-002 | `/search foo` filters without sending; plain Enter sends | manual |
| SC-003 | Robots for `CLE-*`/`GRK-*`/`AGY-*`, identicons for `HUM-*`; same id → same avatar | unit + manual |
| SC-004 | Lobby > 50 rows opens with the newest 50; the sentinel loads the rest; the hub log shows the second `before=` read | manual |

## 5. Traps the history shows — avoid them up front

- **Assume the paging gap and design around it.** view-v1 §4.4 had no
  newest-first window when this began. Build client-side windows over the
  paged thread first, keep the window size (50) in one place, and make
  `getThread` take `{ order, before }` so the switch to server windows is a
  small store change, not a rewrite.
- **Do the X3 pages in the same pass.** The first pass covered only `/lobby`,
  `/t` and the live pane; `/channel`, `/dm` and `ThreadPane` needed a second
  round (`14f821a`). Reuse `LiveFeed` there instead of adding a feed.
- **Keep the store order oldest-first on `/channel` and `/dm`.** Derive the
  newest-first view in a pure function (`channelView`); do not reorder the
  stored rows, or the existing live merge breaks.
- **Paths are under `csi-spl-wui/src/`** (the project refactor moved them).
  Write `src/...` paths in plan.md and task citations; a path check in the
  plan must be `ls`-able from the repo root.
- **Count what you claim.** Put the exact command and the measured count in
  each task line; re-run it at the tick, not from memory (T009 claimed 11
  where the file holds 12 tests).
- **The layout narrative's `min-width: 400px` on the middle pane conflicts
  with the no-x-scroll invariant at 390px.** The invariant wins
  (`.spool-main { min-width: 0 }`); say so in the spec rather than leaving
  the narrative silently contradicted.
- **Close doc drift in the same commit as the code that causes it.** A later
  drift sweep (`76ed70a`) had to fix 013's plan (`LiveThreadPane` path) after
  the fact.
- **Live evidence needs the view door off** on a local `spool serve`; run two
  headless sessions as different `?as=HUM-n` identities, one at 390×844 and
  one at 1280×800.

## 6. Rules of the road

- Work in your own worktree; commit small with explicit pathspecs; rebase on
  `origin/master` and fast-forward push to `master` after every commit.
- Commit with the identity the repo `CLAUDE.md` names, for author and
  committer (pass it to the rebase too); no `Co-Authored-By`, `Claude-Session` or `Generated with`
  trailers.
- Watch CI on your sha (the WUI test workflow and the dev site deploy) until
  green, and confirm the dev site serves your sha.

## 7. Hand back

1. The pushed shas, one per step of §3.
2. `tasks.md` with every task ticked `[x]` citing its sha, its check command
   and the measured result (n, date); `spec.md` FR statuses cited.
3. The gap table (D1 closed with the 003 sha, D2 still later) and any drift
   between the narratives and the code you chose to accept, with the reason.
4. CI run ids and the dev-site sha check.

---

## Verification snapshot

Tree `dd447fa` (origin/master), 2026-09-19, n=1 each, run from
`csi-spl-wui`:

- `node --test tests/unit/*.test.mjs` → 222 tests, 222 pass, 0 fail.
- `node --test tests/unit/channel-reverse.test.mjs` → 12 tests, 0 fail.
- `node --test tests/unit/feed-avatar.test.mjs tests/unit/view-api.test.mjs` → 36 pass, 0 fail.
- `npx nuxi typecheck` → exit 0.
- `node tests/e2e/no-x-scroll.test.mjs` (mock, headless Chrome) → 14/14.
- `command grep -c '<LiveFeed' src/components/MessageFeed.vue` → 1;
  `command grep -c 'pinned-root' src/components/ThreadPane.vue` → 1.
- Not re-run: `console-errors` e2e, and the live two-session evidence of
  T007/T008/T012 (needs an lde hub); those are cited from `tasks.md`.

| FR | Verdict | Evidence |
|---|---|---|
| FR-001 Omnibox | VERIFIED | `src/utils/feed.mjs:25` `parseOmnibox`; `src/components/MessageComposer.vue:67-70,110,145-148` (omnibox mode, Esc, `search` emit); `src/stores/live.ts:166` (`@X` → `task`) |
| FR-002 newest-first + windows | VERIFIED | `src/utils/feed.mjs:11,19`; `src/stores/live.ts:103,133` (`order: 'desc'`, `before`); `src/utils/spool-client.mjs:174-190`; `src/components/LiveFeed.vue` sentinel + `IntersectionObserver` |
| FR-003 entrance transition / reduced motion | VERIFIED | `LiveFeed.vue` `TransitionGroup name="prepend"`; `src/assets/css/main.css:403-404` |
| FR-004 right pane | VERIFIED | `src/components/LiveThreadPane.vue:11,16,25,45`; `src/components/ThreadPane.vue:10,15,23,60`; `src/utils/feed.mjs:46` `rootAndReplies` |
| FR-005 3-pane geometry, no x-scroll | VERIFIED | `src/assets/css/variables.css:60-61`; `main.css:263,414-420`; e2e 14/14. DRIFT (narrative only): layout §1.1 `min-width: 400px` vs `.spool-main { min-width: 0 }` |
| FR-006 avatars | VERIFIED | `src/utils/avatar.mjs:29,51,99,118,123`; `SpoolAvatar` in `MessageCard.vue:9`, `ChannelSidebar.vue:41`, `MessageComposer.vue:19`. DRIFT (doc): D2 says custom avatars "later"; `SpoolAvatar` now also shows a stored IdP picture (`f8f1a00`, another lane) |
| FR-007 a11y | VERIFIED | `LiveFeed.vue` `role="feed"`, `aria-live="polite"`; `MessageCard.vue:2,5` `article`, `aria-posinset`; composer `aria-label` (`MessageComposer.vue:27`) |
| FR-008 no `v:1` change | VERIFIED | `git show --stat` of `c4b3cca ec3b91e 976d593 de3d67c 14f821a` touches only `csi-spl-wui` and `csi-spl-doc` |
| plan.md paths | DRIFT | plan names `utils/feed.mjs`, `stores/live.ts`, `assets/css/main.css` …; files live under `csi-spl-wui/src/` |
| T009 check count | DRIFT | claims "11 pass"; file holds 12 tests (unchanged since `14f821a`) |

MISSING: none.

<!-- version: 0.1.0 · updated: 2026-09-19 · last-edit: 2026-09-19T13:40:00Z -->
