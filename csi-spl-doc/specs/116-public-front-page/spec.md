# 116 Public front page: what a visitor sees before signing in

Status: draft 6 (c-650: draft 5 of c-697 with the panel folded, section 8,
and the owner's picks and three new requirements, quotes 8-13). Doc only.
116-T7 has landed (section 6); the rest waits for the direction (section 7).

## 0. Owner words

HUM-10, t1 topic 2242b163-053f-4460-97c7-c35adef3ab24, 2026-10-09, plus one
post from topic afefc1d6-25ef-4a33-b7a1-f64e92a13317. Verbatim; ids read with
`spool hub-tail --task <topic> --json` (n=7 posts, all found). Quotes 8-13
were relayed verbatim by c-002 (msgs 68793c56, 0541b458, 0c91ce75, edde1d27,
0a7cc2e8) and not re-read here: `spool hub-tail` on this seat says
`$SPOOL_HUB_URL is not set`. Quote 12 reached this lane cut at "...".

| # | msg | time (UTC) | text |
|---|---|---|---|
| 1 | a249610c | 14:03:16 | total refactor of the front page |
| 2 | 11543586 | 14:03:29 | the front page HAS TO BE COOL |
| 3 | df0a268d | 14:03:44 | it has to provide pretty shortly as description on WHAT this is |
| 4 | b65e6e0a | 14:03:53 | and than links for futher reading what is it |
| 5 | 2ca97512 | 14:06:06 | yes before signing ... the forms for the logging in should be smaller , it should be more visual and there should be a textual descrption - one slogan and no more than 3 sentences what this is |
| 6 | a3977546 | 14:06:24 | and it should be flashy , but style |
| 7 | b892aec0 (topic afefc1d6) | 14:10:39 | we need mutiple posts , and those shoud be linked to the landing page |
| 8 | 7b6ac09e | | s1 |
| 9 | 92480b42 | | T1 |
| 10 | 7e631e3a | | yes , they must find it |
| 11 | 2c6081a6 | | the front page should also contain links to the blok and the opened documentation |
| 12 | c88d7715 (topic 13b9c39e) | | revamp the new login page on mobile as well ... |
| 13 | e5634adb (topic 13b9c39e) | | it should have links to the blog and the open docs section and the calendar |

## 1. Reading

The front page is what a signed-out visitor sees at the site's address. Today
there is none: `/` is a product screen, so a signed-out visitor is sent to
`/login` (section 5, C1). The owner's words decide:

| decided | from |
|---|---|
| It is a **full redesign** of the page, not a patch: layout, text and hero change; only the sign-in components and their order stay (C2). | 1 |
| The page is the one **before** sign-in, not the signed-in home. | 5 ("yes before signing") |
| The **sign-in form is ON the page, and smaller** than today. It is not a "sign in" link to another page. | 5 |
| The page is **mainly visual**. | 5 |
| The text is **one slogan plus at most 3 sentences** saying what this is. | 3, 5 |
| It **links to further reading**. | 4 |
| It is **cool, flashy but stylish**. | 2, 6 |
| **Multiple posts are linked from it** (the feature posts, section 3.2). | 7 |
| It links to the **blog, the public docs and the public calendar**. | 11, 13 |
| It is **designed for the phone too**, not only shrunk: every direction has its own phone layout (section 4). | 12 |
| The slogan is **S1** and the text **T1** (section 2). | 8, 9 |
| Search engines **must find it**: it is indexable (C8, 116-T7). | 10 |

So the front page is the sign-in page, redesigned: `pages/login.vue` in
`layouts/login.vue`. Every signed-out visitor on a product screen already
lands there (C1), so no new route and no change to the redirect are needed,
and the form keeps the sign-in components it has today (C2). The signed-in
home (`pages/index.vue`) is not touched. The same front page shows on every
host, a tenant host too; it shows no tenant data signed out, and search engines
list only the apex address (C8).

What the product is, for the text in section 2. The visitor signs in to the
web app where people and AI agents work together in workspaces, channels and
topics, from the browser and from the terminal. There is a hub: it is not
peer-to-peer. The lines this rests on (`grep -n` output):

```
csi-spl-wui/src/public/help-md/index.md:3:Welcome to the **Spool Help Center**. Spool (`csi-spl`) is a real-time messaging and orchestration platform engineered for human software developers and autonomous AI coding agents (such as Claude Code, Grok, and Antigravity).
csi-spl-wui/src/public/help-md/agent-collaboration.md:3:... autonomous AI coding agents (such as Claude Code, Grok, and Antigravity) are not side-panel chatbots—they are **first-class peers on the message bus** with their own identities, cryptographic keys, presence dots, and execution capabilities.
csi-spl-wui/src/public/help-md/agent-collaboration.md:14:  - 🟢 **Online**: The agent's box daemon or sidecar is connected to the Spool hub via WebSocket.
csi-spl-wui/src/public/help-md/getting-started.md:9:Spool is organized around isolated workspaces. There is one address to sign in at:
csi-spl-wui/src/public/help-md/getting-started.md:21:Each workspace is strictly isolated: conversations, channels, cryptographic keys, and AI agent workers never cross workspace boundaries.
csi-spl-wui/src/public/help-md/connect-an-agent.md:11:- A terminal on the agent's machine: Linux or macOS, with `git` and Go 1.25 or newer (`go version`).
csi-spl-doc/doc/md/csi-spl.feature.md:23:| `csi-spl-wui` | Nuxt 3 SSR + TypeScript web application: Slack-like multi-channel interface (M3, referencing `pas-psf-wui`) |
csi-spl-wui/i18n/locales/en.json:263:      "where_humans_meet": "where people meet with ai",
```

Not used, on purpose: `csi-spl-doc/doc/md/csi-spl.feature.md:7` ("The spool
is the GCP estate that carries **git-rel**, the relay that moves gpg-encrypted
files ..."). That line describes the repository's internal infrastructure, not
what a visitor signs in to.

## 2. The text

One slogan and one block of at most 3 sentences. **Picked: S1 and T1**
(quotes 8, 9). They ship as new keys `auth.login.slogan` and `auth.login.about`;
today's heading `auth.login.where_humans_meet` ("where people meet with ai",
`en.json:263`) is removed from all 19 locales in the same commit (116-T2).
S2, S3, T2 and T3 are dropped; the tables stay as the record.

### 2.1 Slogan candidates

| # | slogan |
|---|---|
| S1 | Where people meet AI. **(picked, quote 8)** |
| S2 | Your team and your AI agents, in one conversation. |
| S3 | One workspace. People and AI agents, side by side. |

S1 keeps today's line, tidied.

### 2.2 Three-sentence candidates

| # | text |
|---|---|
| T1 **(picked, quote 9)** | Spool is a workspace where people and AI agents work together. Channels, topics and direct messages carry the work, and every agent has its own name and presence, like any colleague. You join from the browser; your agents join from their terminal. |
| T2 | Give your AI agents a seat at the table. In a Spool workspace, people and agents such as Claude Code post in the same channels and topics, hand off tasks and report results. You follow it live in the browser while the agents work from the terminal. |
| T3 | Spool is real-time chat for teams that work with AI coding agents. Each workspace is private: its channels, topics, people and agents never leave it. Sign in from the browser, connect an agent from its terminal, and watch the work happen. |

Each candidate is 3 sentences, rests only on the lines quoted in section 1,
and says nothing about relays, buckets or peer-to-peer. The picked text ships
in all 19 UI locales, and agy has the final word on every translation (C6).

## 3. Links and the features area

### 3.1 Further reading

| link | reachable signed-out today? | evidence |
|---|---|---|
| Help (`/help`) | yes | not in `isProductScreen` (`signed-out-redirect.mjs:55-60`); the login page links it today, `login.vue:31` |
| Blog (`/blog`) | yes | public by design, no API call: `nuxt.config.ts:356` (`BLOG_STRIPPED_SCRIPTS`) and `:389` (robots made `index, follow`) |
| Release notes | **no**, not linked (C10) | no `/releases` index route (only `pages/releases/[ref].vue`); the hub answers `GET /v1/release-notes` only to a signed-in member (`release_notes.go:150`) |
| Source code (the public `github.com/csitea/csi-spl` repository) | yes | external |
| Docs (`/docs`) | yes, the docs marked `public: true` (quotes 11, 13) | c-694, `2b9ab390b`: `/docs` left `isProductScreen` (`signed-out-redirect.mjs:60-61`); the signed-out copy holds only `public: true` docs (`src/node/docs/sync-public-docs.mjs`, `tests/unit/public-docs-sync.test.mjs`) |
| Calendar (`/public-calendar`) | yes (quote 13) | c-692, `c802a8ec5`: `pages/public-calendar.vue` reads only the build-time `/pub-cal/events.json` (feature posts, release days), no store, no hub; a signed-out visitor of `/calendar` is sent there |

The links row is: Blog, Docs, Calendar, Help, Source. Blog, Docs and Calendar
are the owner's (quotes 4, 11, 13) and come first; the order is a spec choice.

### 3.2 Features area (owner quote 7)

A row of cards, one per feature blog post: the post's image when it has one
(else a plain accent tile, `sync-blog.mjs:344` copies `image` only when set),
title, one-line summary, linking `/blog/<id>`, plus "All posts" to `/blog`.

- **Which posts:** those whose `tags` hold `feature`, the tag the feature
  series carries (`all.env.yaml:960`, `cap_exempt_tags: [feature]`; spec 111).
  At `418d44af4` 17 `en` posts carry it
  (`grep -l 'tags: \[.*feature' csi-spl-doc/blog/posts/en/*.md | wc -l` -> 17;
  9 at draft 5's `52b8c064c`).
- **Built without a hub call:** the blog's build-time copy
  `src/public/blog-md/index.json` (`sync-blog.mjs:6`) already lists every post
  with `tags`, `summary` and `image` (`sync-blog.mjs:302`, `ENTRY_KEYS`). The
  front page reads it the way `pages/blog.vue` does (`readBlog`,
  `blog.vue:147`): from disk while prerendering, so the cards are in the HTML;
  from the site's own static file in the browser, never from the hub. A locale
  without its own copy shows the `en` entry, as the blog does.
- **Order and count:** newest first, at most 6 cards (spec choice, not the
  owner's); the rest are one click away under "All posts".

## 4. The three visual directions

Each is built as a mock page and shown to the owner as screenshots (desktop
and phone, light and dark; the phone ones are required, quote 12), who picks
one (question 1). Rules for all three:

- **Flashy, but stylish** (quote 6): a strong opening picture, colour and
  motion, held in check by theme tokens, one type family and one accent.
- **The visitor's theme wins:** light or dark as their device or setting says;
  no direction forces dark.
- **Motion off** under `prefers-reduced-motion: reduce`: every animation shows
  its final frame, still (C5).
- **Same order on every direction** (spec choice): slogan, 3 sentences, the
  compact sign-in card, the features row, the links.
- **Phone first-class** (quote 12): each direction has its own phone layout
  (the `phone` row of its table), at 360-430 px wide, one column, no
  sideways scroll; the sign-in card is in the first screen or one swipe below.
- **Fixture content only:** the hero's posts, names and commands are static
  strings in the bundle, never fetched from a hub, the demo workspace or a
  tenant, and they never name a real agent, workspace or person.

### 4.1 Direction A: Live channel

The hero is a mock channel drawn in the app's own chrome. Posts arrive one by
one: a person asks an agent (`@build-agent add the sign-in tests`), the agent
answers (`result: 14 tests green`), a second agent joins the topic. The sign-in
card sits beside it on desktop, under the text on a phone.

| | |
|---|---|
| flashy | posts slide in with a short spring, presence dots pulse, agent badges glow once in the accent colour |
| tasteful | real app chrome, not a cartoon; plays once (about 8 s) and then holds still; one accent colour |
| reduced motion | the finished channel, all posts shown, no pulse, presence dots still |
| phone | slogan and text first; the channel shrinks to its last 3 posts, full width; the sign-in card under it |

### 4.2 Direction B: Signal field

Grows today's sign-in wallpaper (`layouts/login.vue:8`, the "beads of light"
paths, and the chip and robot drift layers) into a full-bleed hero: beads of
light run between person and agent avatars scattered across the field; the
slogan is set large with a gradient fill; the sign-in card is frosted glass
over the field.

| | |
|---|---|
| flashy | the full-screen light field, the large gradient slogan |
| tasteful | beads at low opacity and dark most of their cycle, as today; plain sentences under the slogan; the card stays calm and readable |
| reduced motion | the layout's own rule (`layouts/login.vue:282`) plus `base.css:117`: a still field |
| phone | the field fills the first screen behind the slogan with fewer beads; the frosted card sits over its lower half, full width |

### 4.3 Direction C: Browser and terminal

A split hero: a browser window on one side, a terminal on the other. A line is
typed in the terminal (`spool send --kind result --body "deploy is green"`) and
lands as a post in the browser's channel: the "people in the browser, agents
from the terminal" sentence, shown.

| | |
|---|---|
| flashy | the typing cursor, the message travelling from the terminal into the channel |
| tasteful | a monochrome terminal, the app's own colours in the browser, one run then still |
| reduced motion | both panes in their final state: the command typed, the post shown |
| phone | the panes stack: terminal on top, browser channel under it, the post travels down; the sign-in card follows |

## 5. Constraints

Each line below is a `grep -n` run on this tree (base `fe8d8883e`; C8-C11
re-checked at `418d44af4`).

| # | constraint | evidence |
|---|---|---|
| C1 | A signed-out visitor at `/` is sent to `/login`; the front page is therefore the login page, and that redirect stays as it is. | `signed-out-redirect.mjs:55: if (p === '/' \|\| p === '/lobby' \|\| p === '/search') return true` and `:81: return { path: '/login', query: ended ? { ...query, ended: '1' } : query }` |
| C2 | The form keeps today's components and their order: social buttons, then the password form, then the demo intro BELOW the buttons (owner HUM-10 msg 39c26092), the buy link, the help link. Only its size and placement change. Every other state the card shows today stays in it too: the error and session-ended lines, the invite hint, "session unavailable", and for a signed-in visitor the signed-in line and the change-password form (`login.vue:4`, `:7`, `:10-13`, `:21-28`). The hero shows in every state. | `login.vue:14` `<SocialAuthButtons ...>`, `:15` `<NativeAuthForm ...>`, `:19` `<LazyDemoIntro ...>`, `:29` `<BuyWorkspaceLink ...>`, `:31` `login-help` |
| C3 | "Smaller": today the card is up to 880 px wide. The new sign-in card is a compact column (about 360 px) beside the hero on desktop and full width under the text on a phone; each direction's phone layout is its own (section 4, quote 12). | `login.vue:125: width: min(880px, 100%);` |
| C4 | Initial JS stays under the 155 KB gzip ceiling (not 160). The hero animation is CSS, or its own lazy chunk. | `csi-spl-doc/specs/027-spool-performance/contracts/perf-budgets.json:4: "ci_initial_gzip_kb": 155.0,` |
| C5 | Motion off under reduced motion. The global rule already exists; each direction adds nothing that escapes it. | `base.css:117: @media (prefers-reduced-motion: reduce) {`; `layouts/login.vue:282: @media (prefers-reduced-motion: reduce) {` |
| C6 | The slogan and sentences ship in all 19 UI locales; agy has the final word on each translation (language rule, global CLAUDE.md "Spawn an agent"). | `signed-out-redirect.mjs:12-15`, `SIGNED_OUT_LOCALE_CODES` (19 codes) |
| C7 | No hub call is added: the page keeps today's two (session probe, public demo); the features area reads `/blog-md/index.json` from the site's own origin. | `login.vue:105: void session.probe()`, `:107: void loadDemo(...)`; `blog.vue:147: async function readBlog` |
| C8 | The front page is indexable (quote 10). The indexed URL is `/login` and its locale copies; `/` stays a noindex product screen. Canonical and hreflang on the apex, never a tenant host or the query. Landed as 116-T7. | `98b743cd5` (`utils/public-seo.mjs`), `339164421` (`render-wui-firebase-json.sh` `SEO_PUBLIC_SOURCES`, prd only via cnf `env.wui.seo_index`) |
| C9 | `/docs` is linked: since c-694 a signed-out visitor reads the docs marked `public: true` (quote 11, section 3.1). | `signed-out-redirect.mjs:60-61`: "/docs is not here: a doc marked public is read signed out" |
| C10 | Release notes are not linked: they need a signed-in member session. | `release_notes.go:150: writeForbidden(... "release notes need a signed-in member session")` |
| C11 | The front page HTML is the same bytes for every visitor and host: no session, user, invite address or tenant in the prerendered HTML; "signed in as", the invite hint and "session ended" render only after hydration. | `firebase.json:47-48` (`public, max-age=0`), `login.vue:67`, `useSpoolApi.ts:23` |

The greps, as run:

```
grep -n "p === '/' ||" csi-spl-wui/src/utils/signed-out-redirect.mjs
grep -n "p === '/docs'" csi-spl-wui/src/utils/signed-out-redirect.mjs
grep -n "return { path: '/login'" csi-spl-wui/src/utils/signed-out-redirect.mjs
grep -n -E 'SocialAuthButtons class|NativeAuthForm v-if|LazyDemoIntro|BuyWorkspaceLink v-if|login-help|width: min\(880px' csi-spl-wui/src/pages/login.vue
grep -n '"ci_initial_gzip_kb": 155' csi-spl-doc/specs/027-spool-performance/contracts/perf-budgets.json
grep -n 'prefers-reduced-motion: reduce' csi-spl-wui/src/assets/css/base.css csi-spl-wui/src/layouts/login.vue
grep -n -E '"robots", content: "noindex|"X-Robots-Tag": "noindex' csi-spl-wui/nuxt.config.ts
grep -n 'cap_exempt_tags: \[feature\]' csi-spl-cnf/csi-spl/all.env.yaml
grep -n 'SIGNED_OUT_LOCALE_CODES' csi-spl-wui/src/utils/signed-out-redirect.mjs
grep -n -E 'session.probe|loadDemo' csi-spl-wui/src/pages/login.vue
grep -n 'readBlog' csi-spl-wui/src/pages/blog.vue
grep -n -A1 "/docs is not here" csi-spl-wui/src/utils/signed-out-redirect.mjs
grep -n 'release notes need' csi-spl-api/src/go/spool-hub-api/internal/hub/release_notes.go
grep -n 'SEO_PUBLIC_SOURCES =' csi-spl-orc/src/bash/scripts/render-wui-firebase-json.sh
```

## 6. Build outline

One small agent per task, each in its own lane.

| task | what | lane |
|---|---|---|
| 116-T1 | Three mock pages, one per direction (section 4), in mock mode, opened at `/login`; screenshots desktop AND phone (required, quote 12), light + dark, posted to the owner for question 1. | claude |
| 116-T2 | S1 and T1 into `en.json` as `auth.login.slogan` and `auth.login.about`; then the 18 other locales; `where_humans_meet` removed from all 19 in the same commit. | mistral drafts, agy final review |
| 116-T3 | The picked direction built into `layouts/login.vue` and `pages/login.vue`: hero, compact sign-in card (C2, C3), its phone layout (section 4), reduced motion (C5). | claude |
| 116-T4 | The features area (section 3.2): a `Lazy` component (its own chunk, still server-rendered at prerender, so the cards are in the `/login` HTML) reading `blog-md/index.json` through `useAsyncData` as `blog.vue:148-172` does, filtered on tag `feature`, newest 6. | claude |
| 116-T5 | The links row (section 3.1): Blog, Docs, Calendar, Help, Source; no release notes (C10). | mistral |
| 116-T6 | Tests: a unit test for the feature filter (tag `feature`, newest first, at most 6, `en` fallback); e2e on the mock bundle opens `/login` (and `/fi/login`), at desktop and phone width, and shows the slogan, the 3 sentences, the sign-in form, at least one feature card and the links; under `prefers-reduced-motion: reduce` no element is animating; the generated login HTML holds no `@` address and no tenant id (C11); the 155 KB budget holds. The `/` -> `/login` redirect is not re-tested in e2e (the mock tenant never redirects, `shell-bootstrap.mjs:69`); `tests/unit/signed-out-redirect.test.mjs` covers it, and its `where_humans_meet` asserts move to the new keys with 116-T2. | claude |
| 116-T7 | **Landed** (`98b743cd5`, `339164421`): `/login` and its locale copies indexable on prd only, apex canonical + hreflang, the session and auth scripts kept (C8). | claude |

## 7. Open questions

1. **Which visual direction?** A Live channel, B Signal field or C Browser and
   terminal (section 4), picked from the desktop and phone screenshots of
   116-T1. **Open**: waits for 116-T1.
2. ~~Which slogan and which three sentences?~~ **Answered**: slogan **S1**
   "Where people meet AI." (quote 8) and text **T1** (quote 9).
3. ~~Should search engines index the front page?~~ **Answered: yes** (quote 10,
   "yes , they must find it"); 116-T7 has landed (C8).

## 8. Panel

Panel on draft 5 (`52b8c064c`), task dispatch-2242b163: agy + mistral + 2
claude. Verdicts: all four "agree with changes". Folded by c-650.

| seat | finding | folded |
|---|---|---|
| a-699 (agy) | F1 quote 1 missing from section 1 | applied, with c-633 N7's wording |
| a-699 | F2 "feature blog posts" is not the owner's word | applied: "Multiple posts" |
| a-699 | F3 greps for C6, C7 missing | applied (section 5 greps) |
| a-699 | section 7 answers | applied |
| m-635 (mistral) | F1 `/docs` row wording | rejected: superseded, `/docs` is public since c-694 (C9) |
| m-635 | F2 feature count is 6, not 9 | rejected: 9 held at `52b8c064c` (c-633, c-634 re-ran it); 17 at `418d44af4` |
| m-635 | F3 C9 "link in a follow-up" | rejected: superseded, `/docs` is linked now (quote 11) |
| m-635 | F4 rewrite T1 | rejected: the owner picked T1 verbatim (quote 9) |
| m-635 | F5 presence dots still under reduced motion | applied (4.1) |
| m-635 | open questions: S2, T2, noindex | rejected: the owner picked S1, T1, indexed (quotes 8-10) |
| c-633 (claude) | B1 release notes not reachable signed-out | applied (3.1, C10, 116-T5) |
| c-633 | B2 T7 rules (3 noindex layers, no strip-check, apex canonical, query, snippet) | applied: built by `98b743cd5` + `339164421`; C8, 116-T7 point there |
| c-633 | N3 public-cache constraint | applied (C11, 116-T6) |
| c-633 | N4 fixture-only hero, no `@c-007` | applied (section 4 rules, 4.1) |
| c-633 | N5 condition before linking `/docs` | applied: met by c-694 (`public-docs-sync.test.mjs`, 3.1) |
| c-633 | N6 C7 wording | applied |
| c-633 | N7 quote 1 row | applied (section 1) |
| c-634 (claude) | F1 e2e cannot see the redirect on the mock bundle | applied (116-T6, 116-T1 at `/login`) |
| c-634 | F2 C8 / T7: three edits plus apex canonical | applied: landed as 116-T7 (C8) |
| c-634 | F3 record the answers | applied (sections 0, 2, 7) |
| c-634 | F4 other card states | applied (C2) |
| c-634 | F5 prerendered `Lazy` component | applied (116-T4) |
| c-634 | F6 image only when the post has one | applied (3.2) |
| c-634 | F7 new keys, remove `where_humans_meet` | applied (section 2, 116-T2) |
| c-634 | F8 label spec choices | applied (3.1 order, 3.2 count, section 4 order) |
| c-634 | F9 same page on every host | applied (section 1) |
| g-632 (grok) | - | not reviewed: grok weekly limit |
