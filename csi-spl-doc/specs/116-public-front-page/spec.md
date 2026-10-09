# 116 Public front page: what a visitor sees before signing in

Status: draft 5 (c-697, rewritten from the owner's words and c-002's two
rejects, not patched from draft 4). Doc only: nothing is built until the panel
accepts it and the owner picks in section 7.

## 0. Owner words

HUM-10, t1 topic 2242b163-053f-4460-97c7-c35adef3ab24, 2026-10-09, plus one
post from topic afefc1d6-25ef-4a33-b7a1-f64e92a13317. Verbatim; ids read with
`spool hub-tail --task <topic> --json` (n=7 posts, all found).

| # | msg | time (UTC) | text |
|---|---|---|---|
| 1 | a249610c | 14:03:16 | total refactor of the front page |
| 2 | 11543586 | 14:03:29 | the front page HAS TO BE COOL |
| 3 | df0a268d | 14:03:44 | it has to provide pretty shortly as description on WHAT this is |
| 4 | b65e6e0a | 14:03:53 | and than links for futher reading what is it |
| 5 | 2ca97512 | 14:06:06 | yes before signing ... the forms for the logging in should be smaller , it should be more visual and there should be a textual descrption - one slogan and no more than 3 sentences what this is |
| 6 | a3977546 | 14:06:24 | and it should be flashy , but style |
| 7 | b892aec0 (topic afefc1d6) | 14:10:39 | we need mutiple posts , and those shoud be linked to the landing page |

## 1. Reading

The front page is what a signed-out visitor sees at the site's address. Today
there is none: `/` is a product screen, so a signed-out visitor is sent to
`/login` (section 5, C1). The owner's words decide:

| decided | from |
|---|---|
| The page is the one **before** sign-in, not the signed-in home. | 5 ("yes before signing") |
| The **sign-in form is ON the page, and smaller** than today. It is not a "sign in" link to another page. | 5 |
| The page is **mainly visual**. | 5 |
| The text is **one slogan plus at most 3 sentences** saying what this is. | 3, 5 |
| It **links to further reading**. | 4 |
| It is **cool, flashy but stylish**. | 2, 6 |
| The **feature blog posts are linked from it**. | 7 |

So the front page is the sign-in page, redesigned: `pages/login.vue` in
`layouts/login.vue`. Every signed-out visitor on a product screen already
lands there (C1), so no new route and no change to the redirect are needed,
and the form keeps the sign-in components it has today (C2). The signed-in
home (`pages/index.vue`) is not touched.

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

One slogan and one block of at most 3 sentences, picked by the owner
(question 2). Today's heading, `auth.login.where_humans_meet` ("where people
meet with ai", `en.json:263`), is replaced by the pick.

### 2.1 Slogan candidates

| # | slogan |
|---|---|
| S1 | Where people meet AI. |
| S2 | Your team and your AI agents, in one conversation. |
| S3 | One workspace. People and AI agents, side by side. |

S1 keeps today's line, tidied.

### 2.2 Three-sentence candidates

| # | text |
|---|---|
| T1 | Spool is a workspace where people and AI agents work together. Channels, topics and direct messages carry the work, and every agent has its own name and presence, like any colleague. You join from the browser; your agents join from their terminal. |
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
| Release notes (`/releases`) | yes | not in `isProductScreen` (`signed-out-redirect.mjs:55-60`) |
| Source code (the public `github.com/csitea/csi-spl` repository) | yes | external |
| Docs (`/docs`) | **no** | `signed-out-redirect.mjs:60` makes `/docs` and `/docs/*` a product screen, so a signed-out visitor is sent to `/login`; the help page says "You have to be signed in" (`help-md/docs.md:5`) |

`/docs` is linked only once lane c-694 lands: it is making docs marked
`public: true` readable signed-out (lane map: `c-694-pub-docs`,
`csi-spl-wui/src/pages/docs.vue`). Until then the front page does not link
`/docs`, so no link sends a visitor back to the page they are on.

### 3.2 Features area (owner quote 7)

A row of cards, one per feature blog post: image, title, one-line summary,
linking `/blog/<id>`, plus "All posts" to `/blog`.

- **Which posts:** those whose `tags` hold `feature`, the tag the feature
  series carries (`all.env.yaml:960`, `cap_exempt_tags: [feature]`; spec 111).
  Today 9 `en` posts carry it
  (`grep -l 'tags: \[.*feature' csi-spl-doc/blog/posts/en/*.md | wc -l` -> 9).
- **Built without a hub call:** the blog's build-time copy
  `src/public/blog-md/index.json` (`sync-blog.mjs:6`) already lists every post
  with `tags`, `summary` and `image` (`sync-blog.mjs:302`, `ENTRY_KEYS`). The
  front page reads it the way `pages/blog.vue` does (`readBlog`,
  `blog.vue:147`): from disk while prerendering, so the cards are in the HTML;
  from the site's own static file in the browser, never from the hub. A locale
  without its own copy shows the `en` entry, as the blog does.
- **Order and count:** newest first, at most 6 cards; the rest are one click
  away under "All posts".

## 4. The three visual directions

Each is built as a mock page and shown to the owner as screenshots (desktop
and phone, light and dark), who picks one (question 1). Rules for all three:

- **Flashy, but stylish** (quote 6): a strong opening picture, colour and
  motion, held in check by theme tokens, one type family and one accent.
- **The visitor's theme wins:** light or dark as their device or setting says;
  no direction forces dark.
- **Motion off** under `prefers-reduced-motion: reduce`: every animation shows
  its final frame, still (C5).
- **Same order on every direction:** slogan, 3 sentences, the compact sign-in
  card, the features row, the links.

### 4.1 Direction A: Live channel

The hero is a mock channel drawn in the app's own chrome. Posts arrive one by
one: a person asks an agent (`@c-007 add the sign-in tests`), the agent
answers (`result: 14 tests green`), a second agent joins the topic. The sign-in
card sits beside it on desktop, under the text on a phone.

| | |
|---|---|
| flashy | posts slide in with a short spring, presence dots pulse, agent badges glow once in the accent colour |
| tasteful | real app chrome, not a cartoon; plays once (about 8 s) and then holds still; one accent colour |
| reduced motion | the finished channel, all posts shown, no pulse |

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

## 5. Constraints

Each line below is a `grep -n` run on this tree (base `fe8d8883e`).

| # | constraint | evidence |
|---|---|---|
| C1 | A signed-out visitor at `/` is sent to `/login`; the front page is therefore the login page, and that redirect stays as it is. | `signed-out-redirect.mjs:55: if (p === '/' \|\| p === '/lobby' \|\| p === '/search') return true` and `:81: return { path: '/login', query: ended ? { ...query, ended: '1' } : query }` |
| C2 | The form keeps today's components and their order: social buttons, then the password form, then the demo intro BELOW the buttons (owner HUM-10 msg 39c26092), the buy link, the help link. Only its size and placement change. | `login.vue:14` `<SocialAuthButtons ...>`, `:15` `<NativeAuthForm ...>`, `:19` `<LazyDemoIntro ...>`, `:29` `<BuyWorkspaceLink ...>`, `:31` `login-help` |
| C3 | "Smaller": today the card is up to 880 px wide. The new sign-in card is a compact column (about 360 px) beside the hero on desktop and full width under the text on a phone. | `login.vue:125: width: min(880px, 100%);` |
| C4 | Initial JS stays under the 155 KB gzip ceiling (not 160). The hero animation is CSS, or its own lazy chunk. | `csi-spl-doc/specs/027-spool-performance/contracts/perf-budgets.json:4: "ci_initial_gzip_kb": 155.0,` |
| C5 | Motion off under reduced motion. The global rule already exists; each direction adds nothing that escapes it. | `base.css:117: @media (prefers-reduced-motion: reduce) {`; `layouts/login.vue:282: @media (prefers-reduced-motion: reduce) {` |
| C6 | The slogan and sentences ship in all 19 UI locales; agy has the final word on each translation (language rule, global CLAUDE.md "Spawn an agent"). | `signed-out-redirect.mjs:12-15`, `SIGNED_OUT_LOCALE_CODES` (19 codes) |
| C7 | No hub call is added. The page already probes the session and asks for the demo; the features area reads the build-time blog copy. | `login.vue:105: void session.probe()`, `:107: void loadDemo(...)`; `blog.vue:147: async function readBlog` |
| C8 | Every page is `noindex` today. Whether the front page becomes indexable is the owner's call (question 3); the blog is the precedent for how. | `nuxt.config.ts:629: { name: "robots", content: "noindex, nofollow" },`, `:680: "X-Robots-Tag": "noindex, nofollow",`; blog override `:389` |
| C9 | `/docs` is not linked until c-694 lands (section 3.1). | `signed-out-redirect.mjs:60: if (p === '/docs' \|\| p.startsWith('/docs/')) return true` |

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
```

## 6. Build outline

One small agent per task, each in its own lane.

| task | what | lane |
|---|---|---|
| 116-T1 | Three mock pages, one per direction (section 4), in mock mode; screenshots desktop + phone, light + dark, posted to the owner for question 1. | claude |
| 116-T2 | The picked slogan and sentences into `en.json` as new keys under `auth.login`; then the 18 other locales. | mistral drafts, agy final review |
| 116-T3 | The picked direction built into `layouts/login.vue` and `pages/login.vue`: hero, compact sign-in card (C2, C3), reduced motion (C5). | claude |
| 116-T4 | The features area (section 3.2): a lazy component reading `blog-md/index.json`, filtered on tag `feature`, newest 6. | claude |
| 116-T5 | The links row (section 3.1); `/docs` added in a follow-up once c-694 has landed. | mistral |
| 116-T6 | Tests: a unit test for the feature filter; e2e signed-out at `/` lands on the front page and shows the slogan, the form, at least one feature card and the links; under reduced motion no element is animating; the 155 KB budget holds. | claude |
| 116-T7 | Only if question 3 is yes: make the front page indexable the way the blog is (C8). | claude |

## 7. Open questions

1. **Which visual direction?** A Live channel, B Signal field or C Browser and
   terminal (section 4), picked from the screenshots of 116-T1.
2. **Which slogan and which three sentences?** S1-S3 and T1-T3 (section 2), or
   your own edit of one.
3. **Should search engines index the front page?** Today every page except the
   blog is `noindex` (C8).

## 8. Panel

Panel: pending (c-002 runs it after acceptance).
