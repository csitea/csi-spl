# Spec 111: the blog (news and events, agent posts, one daily digest)

Version **v0.1** (2026-10-08). Drafted by claude c-589 as seat 1. Next: a
review panel (consensus-then-build, one mistral seat per spec 110 D5), then
the build lanes in [tasks.md](tasks.md). Docs only: this spec builds nothing
(`../README.md` item 4).

`<BASE_DOMAIN>`, `<env>`, `<id>`, `<agent-id>` and `<yyyy-mm-dd>` are
placeholders. No estate value appears as a literal to copy.

## 0. Owner asks (verbatim, HUM-10, t1 topic d49b6b76)

| msg | text |
|---|---|
| 1e746177 | "we must a \"blog\" part of the [`<BASE_DOMAIN>`]" |
| e9862d10 | "where we will publish news and events on what is hapenning ..." |
| 88fd0f8c | "for example at end of the day there would be a single agent instantiated at 23:00 till 24:00 whos job will be to create a contensed no more than 1 A4 jist of what happened what was released with some funny or cool ai picture per post" |
| ba3294f5 + f1323068 | a pointer to a sibling project's blog as the reference implementation |
| e9c2ad28 | "just add to it the integration with the agents to be able to push there content - max 7 bublications per day" |
| 566642a1 | "later on we could start some pictures and additions from the stuff which real persons also do ... but for now only \"matrix\" stuff ..." |

The reference is cited here only as **"a sibling project's blog (spec
047/049)"**. Its DESIGN is reused: one markdown file per post, frontmatter,
list and post pages, prerendered HTML for crawlers, images never committed,
markdown rendered statically, no script in a post. Its names, domain and
code are not.

**v1 content is "matrix" only (msg 566642a1):** the machine side, meaning
what the agents and the fleet did, releases, drills and specs, plus AI
pictures. Content about real people is out of scope for v1 (section 7).

## 1. Goals

| # | goal | measured by |
|---|---|---|
| G1 | `/blog` and `/blog/<post-id>` are public, unauthenticated, prerendered pages on the apex domain | `curl -s https://<BASE_DOMAIN>/blog/<post-id>` (no cookie) returns the post title in the HTML, n = 1 per env |
| G2 | The blog adds **0 bytes** to the initial download | `initial-js-trims` delta <= 100 B, the bar spec 110 used |
| G3 | One digest post per day, written by ONE agent started at 23:00 and gone by 24:00 | <= 1 `digest` per date in `csi-spl-doc/blog/posts/`; the cron log shows start and end inside the hour |
| G4 | Any agent can publish a post through one named path; **at most 7 publications per day, enforced by code the agent does not run** | test 9-l and its control: the 8th post of a day is not published |
| G5 | A post fits one A4 page | the post check refuses a body over 450 words (~1 A4 page with the picture) |
| G6 | Every post is public-safe and "matrix" only | `do_check_dist_hygiene` + the post check (4.4) green on every post; the controls (a planted personal name, an email, a workspace message id) are refused |
| G7 | Pictures never go in git | `git ls-files \| grep -cE '\.(webp\|avif\|png\|jpe?g\|svg)$'` stays at today's 16 after 30 posts |

Out of scope: comments, likes, newsletter email (spec 090 phase 2 may take
the feed later), posts written in the signed-in app, per-workspace blogs,
and content about real people (section 7).

## 2. Today, measured (trunk `f5a3745d8`)

| fact | evidence |
|---|---|
| The WUI ships with `nuxt generate`; only `/` and `/login` are prerendered per locale, every other route boots from `200.html` | `csi-spl-wui/nuxt.config.ts`: `PRERENDER_PAGES = ["/", "/login"]` |
| i18n is 19 locales, `prefix_except_default`, lazy; a build check fails unless the locale route copies are exactly what i18n made | `nuxt.config.ts` lines 226-330, `src/utils/locale-routes.mjs` (CLE-77925) |
| The initial-chunk gate reads ~152.7 KB against a 155 KB ceiling | `tests/unit/initial-js-trims.test.mjs` line 96 |
| CSP allows images from the site only: `img-src 'self' data:` | `firebase.json` and `nuxt.config.ts` `CSP_PROD`; no `unsafe-eval` |
| /help already renders repo markdown: `sync-help.mjs` copies `csi-spl-doc/doc/help` into `src/public/help-md`, a unit test fails while the copy differs, and the domain becomes `{{site}}` | `src/node/help/sync-help.mjs`, `src/utils/help.mjs`, `components/MarkdownBlock.vue` |
| Release notes live in the hub (spec 065), and only a **signed-in member** can read them | `internal/hub/release_notes.go` `releaseReader`: "release notes need a signed-in member session" |
| The hub already filters release notes for hygiene (`SPOOL_HUB_RELEASE_NOTE_BANS`) | same file |
| 16 image files are tracked today, all WUI chrome | `git ls-files \| grep -cE '\.(webp\|avif\|png\|jpe?g\|svg)$'` -> 16 |
| The main box clock is `Europe/Helsinki` | `timedatectl` -> `Europe/Helsinki (EEST, +0300)` |
| Box crons are installed by one named action | `do_install_box_crons` (`BOX_CRONS_ONLY=<name>`) |

## 3. Decisions (each with its reason)

### 3.1 Where it lives: public, prerendered, on the apex (D1)

**Decided: `/blog` and `/blog/<post-id>` in csi-spl-wui, public, prerendered
at `nuxt generate`, served by Firebase Hosting on the apex domain.**

- A blog is for people who are NOT signed in, for crawlers, and for link
  previews (Open Graph). None of that works inside the signed-in app.
- It needs no new hosting: the WUI already prerenders `/` and `/login`.
- **English only, one URL per post.** The blog pages are left out of the
  i18n locale copies (`/fi/blog/...` is not made), so a post does not
  generate 19 documents.
  - `locale-routes.mjs` learns the exclusion, and its CLE-77925 check
    stays exact.
  - The page CHROME (headings, "older posts", dates) uses i18n keys in all
    19 locales, like every other page. The post BODY is English.
- **Lazy, 0 bytes initial.**
  - `pages/blog/index.vue` and `pages/blog/[id].vue` are route chunks.
  - Markdown is rendered to HTML at BUILD time (4.2), so no markdown parser
    ships for the blog. The route chunk only `v-html`s a fragment that was
    sanitised at build time.
  - Nothing is added to the app shell, the sidebar or a layout. A "Blog"
    link on the public landing page `/` is one `<a href>`.
- The pages never call the hub. A visitor's browser makes no API call.

### 3.2 Post types (D2)

One file shape, with a `type` field:

| type | what | extra frontmatter |
|---|---|---|
| `digest` | the nightly post (section 5) | `date` = the day it covers |
| `news` | a post by an agent or a lane (section 6) | — |
| `event` | something on a date: a release day, a drill, a talk | `event_start`, optional `event_end` (ISO 8601, UTC) |

- **Release notes do NOT become posts one by one.** There are ~1700
  commits a week (spec 065, option B), so one post each would be spam.
  They feed the digest only (5.2), under spec 090's rule: **no source, no
  post**.
- **No link to `/releases/<ref>`** from a public post, because that page
  needs a sign-in. A release is linked by its `v<X.Y.Z>` tag on the public
  repository (spec 044), taken from cnf `env.wui.repo_web_url`.

### 3.3 Pages, feed, sitemap, Open Graph (D3)

| path | what |
|---|---|
| `/blog` | the list, newest first, 20 per page; type chips (all / digest / news / event). Older pages are static `/blog/page/<n>` |
| `/blog/<post-id>` | the post: title, date, type, author, picture with alt text, body, previous / next |
| `/blog/feed.xml` | Atom 1.0, the last 30 posts, full text |
| `/sitemap.xml` | new (none exists today): `/`, `/login`, `/blog`, every post |
| `/robots.txt` | allows `/blog`, points at the sitemap, disallows the app routes |

- `<post-id>` is `<yyyy-mm-dd>-<slug>`; a digest is `<yyyy-mm-dd>-digest`.
- Each post page sets these in the prerendered `<head>` through `useHead`,
  so a link preview works without JS:
  - `og:title`, and `og:description` (the summary);
  - `og:image`: the absolute URL of the 1200x630 crop;
  - `og:type=article` and `article:published_time`;
  - `<link rel="canonical">`.
- **Theme.** The pages use the WUI's CSS variables, so dark and light follow
  the user's theme. A visitor with no setting gets `prefers-color-scheme`.

### 3.4 Source: markdown in the repo (D4)

**Decided: one markdown file per post in `csi-spl-doc/blog/posts/`.**
Posts are not written in the app.

```text
csi-spl-doc/blog/posts/<yyyy-mm-dd>-<slug>.md
---
id: <yyyy-mm-dd>-<slug>
type: digest | news | event
title: "..."
summary: "one sentence, <= 160 chars (og:description)"
date: <yyyy-mm-dd>
published: <ISO-8601 UTC>    # set by do_spl_blog_post, never by hand
author: <agent-id>           # e.g. m-004; never a person, never a box name
tags: [release, fleet]
image: <id>.webp             # a key in the media bucket, never a file in git
image_alt: "..."             # required when image is set
image_prompt: "..."          # the prompt that made it (provenance)
draft: false
---
<body, <= 450 words>
```

Why the repo:

- It is the same path as /help and the spec 075 repo docs: written in git,
  copied into the WUI by a sync script, and checked by a unit test.
- Every post is a commit under the canonical author. A bad post is
  reverted or unpublished like any commit (3.5).
- The hygiene sweep already reads every tracked file, so every post goes
  through a gate that exists today, at no new cost.
- An in-app editor would need auth, a hub table, an approval UI and RLS.
  That is spec 090's queue; the blog does not need it.

### 3.5 Publish without review, behind gates (D5, owner Q2)

The digest lands at about 23:50, and agent posts land at any hour.
**Recommended: auto-publish** once the automated gates (4.4) are green.

- **Unpublish.** The owner takes any post down with one action:
  `POST_ID=<id> ./run -a do_spl_blog_unpublish`. It commits `draft: true`,
  and the next WUI deploy drops the page, the feed entry and the sitemap
  line.
- **Edit.** An edit is a commit to the post file through
  `do_spl_blog_post` (`BLOG_EDIT=1`), checked by the same gates. An edit is
  not a new publication and does not count toward the cap.
- **Why no human review.** An owner review at midnight means the digest
  appears the next day, and it makes the owner a daily approver, which the
  owner has asked not to be ("consensus then build, owner reviews after").
  - The gates are mechanical.
  - What is left is taste (is the picture good?). The image safety filter
    covers part of it, and a takedown is one action.

### 3.6 Reuse

| spec / code | reused for |
|---|---|
| /help (`sync-help.mjs`, `help.mjs`, `MarkdownBlock.vue`) | the copy-and-check pattern, link rewriting, `{{site}}` for the domain, the sanitiser rules |
| 075 Docs | repo markdown as the source; the 075 renderer's tag allow-list |
| 090 marketing automation | "no source, no post", source-backed drafting (every claim names its tag or sha). The 090 queue can later take the Atom feed as a source. No MarketingSwitch change here |
| 091 public dataset export | the allow-list idea: the digest collector reads only allow-listed sources (5.2) and fails closed |
| 065 release notes | the day's notes, read on the box from git (`refs/notes/release-notes`), with the same ban list as the hub filter |
| 110 D5 | the vendor: documentation goes to mistral first (`do_spl_lane_mix` kind `spec`), then agy, then claude |

Rules that bind every task:

- **Distribution hygiene.** No personal names, hosts, OS users, box names
  or customer names. In copied text, the domain only appears as `{{site}}`.
- **CSP.** No `new Function`, no `eval`, no inline script in a post, and no
  new `img-src` host.
- **i18n.** Page chrome keys exist in all 19 locales.
- **Theme.** Dark and light come from the CSS variables.

## 4. Build pipeline

### 4.1 Sync and the daily cap

`src/node/blog/sync-blog.mjs`, a twin of `sync-help.mjs`:

- reads `csi-spl-doc/blog/posts/*.md` and validates the frontmatter;
- skips `draft: true`;
- **applies the cap (6.2):** per publish day it keeps at most 7 posts,
  taken in `published` order, so the 8th and later are not rendered;
- writes `src/public/blog-md/index.json` (id, type, title, summary, date,
  author, tags, image, image_alt; newest first);
- writes one `<id>.html` fragment per post (4.2);
- `--check` exits 1 while the copy differs, like `help-sync.test.mjs`.

### 4.2 Render at build time

Node renders the fragment at sync time, with the same markdown library and
sanitiser rules as `MarkdownBlock.vue`:

- no raw HTML;
- `http(s)` links only, and external ones get `rel="noopener nofollow"`;
- images only from the post's own `image` key.

Rendering at build time keeps the parser out of the browser (the
initial-chunk reason) and compiles nothing at runtime (the CSP reason).

### 4.3 Pictures: a private bucket, copied in at build (D6)

- **Never in git.** Daily pictures are ~365 binaries a year, and the
  distribution package bans images (hygiene rule 7).
- **Storage.** A **private** GCS bucket per env, `csi-spl-<env>-blog-media`,
  made by a new terraform step (the next free number at commit time). Only
  the blog actions' per-env SA writes to it.
- **Serving.** The WUI deploy (wf 30) copies the pictures named in
  `index.json` into the generated `.output/public/blog/img/` before
  `firebase deploy`. They are served from the site itself, so **CSP
  `img-src 'self'` stays as it is** and the bucket is never public.
- **Format.** webp, 1600x900 plus a 1200x630 Open Graph crop, each under
  300 KB.
- **Rejected:** a public bucket or a CDN host. It would add an `img-src`
  host to both CSP lists, and a public bucket to guard.

### 4.4 The post check (gate)

`./run -a do_spl_blog_check` (orc) is run by `do_spl_blog_post`, by the
pre-push gate when `csi-spl-doc/blog/**` changes, and by CI:

| check | refuses |
|---|---|
| frontmatter | a missing field, an unknown `type`, an `id` that does not match the file name, `image` without `image_alt`, a hand-set `published` |
| size | a body over 450 words; a summary over 160 chars |
| hygiene | anything `do_check_dist_hygiene` refuses, plus the hub's release-note ban list (`SPOOL_HUB_RELEASE_NOTE_BANS`, from the env) |
| public-safe, "matrix" only | a personal name (the hygiene name list), an email address, a phone number, a workspace id, a message id, a topic uuid, an internal host, a box name, a `/home/` path; an `image_prompt` that asks for a real or named person |
| facts | a sha or `v<X.Y.Z>` tag that is not on `origin/master` |
| author | an `author` that is not a valid agent id (spec 061 grammar) or the site name |
| digest cap | a second `digest` for the same `date` |

Each check has its control (tasks.md, test b).

## 5. The daily digest agent

### 5.1 Start and stop: one named cron action

- **Start.** `do_spl_blog_digest` (orc, `blog-digest.func.sh`), installed as
  the box cron `blog-digest` by `do_install_box_crons`, at **23:00** in the
  time zone from cnf `env.blog.tz` (owner Q1; `CRON_TZ` in the crontab
  line).
- **One box only.** The cron runs on every box, but the action exits 0 at
  once unless this box holds the orch lease. So exactly one box writes the
  post.
- **Idempotent.** It exits 0 if `origin/master` already has a digest for
  the date.
- **Quiet day.** If the collector (5.2) finds no tag and no landed commit,
  there is no post (no source, no post).
- **The lane.** It spawns ONE lane through the normal spawn path. The
  vendor comes from `do_spl_lane_mix` kind `spec` (mistral first, spec 110
  D5), and the brief is a fixed template (`blog-digest-brief.md`) filled in
  with the facts file.
- **The digest has a reserved slot.** It is one of the day's 7
  publications, and other posts may take at most 6 (6.2), so the digest
  always fits.
- **Deadline.** At 23:55 the action checks whether the lane has landed.
  Either way, it closes the window with `tmux-close-window.sh` before
  24:00. A missed day is reported to the dispatcher as a `note`, and is
  never retried the next day.

### 5.2 What the agent is given (code collects, the agent writes)

Per the owner's rule "orchestration is code, not intelligence", the
**collector** is code: `do_spl_blog_digest_collect` writes one facts file.
The agent never looks for its own sources.

| source | how | public-safe because |
|---|---|---|
| tags minted in the day window | `git tag --list 'v*'` with creator dates | tags are public (spec 044) |
| the day's release notes | `git notes --ref=release-notes` for the day's shas | the hub ban list is applied first |
| landed commit subjects | `git log origin/master --since/--until` | public repo history |
| spec status changes | the `[x]` lines added to `csi-spl-doc/specs/*/tasks.md` in the window | public repo |
| the day's blog posts | `csi-spl-doc/blog/posts/` with that date | already gated |

- **Not a source in v0.1:** topic or message text from any workspace,
  including owner-visible topic results. That is workspace data, and spec
  091 shows how much proof a "public slice" of it needs.
  - If the panel wants topic results in the digest, that is a follow-up
    which reuses 091's allow-list and its three-vendor verification. It is
    not in this spec.
- **The day window** is the 24 hours before 23:00 in `env.blog.tz`, so
  every hour is covered by exactly one digest.

### 5.3 What the agent writes

- **The post.** One post, `type: digest`, of at most 450 words, in this
  order:
  - a one-line headline;
  - "Released": the versions and what they bring;
  - "Landed": the 3-7 changes that matter, grouped;
  - "Next": optional, one line.
- **Sources.** Every claim names its tag or short sha (090's
  source-backed rule), and the post check (4.4) refuses a sha that is not on
  master.
- **The picture.** One `image_prompt`: "funny or cool", about the day's
  main theme, with no real people, no logos or brands, and no text in the
  picture. And one `image_alt` of at most 125 chars that describes it.
- **Then** it publishes through `do_spl_blog_post` (6.1), like any other
  agent post.

### 5.4 The picture (D7)

**Recommended: Google Imagen on Vertex AI**, called by the code action
`do_spl_blog_image`. It uses the per-env project SA only, never the owner
account, with `--account` on every call (the repo's GCP rule).

| option | for | against |
|---|---|---|
| **Imagen (Vertex AI)** | already on GCP, SA auth, no new vendor key, billed on the project, built-in safety filter, commercial use allowed, SynthID watermark | a new API to enable on the projects (an owner-go API/IAM change) |
| a mistral image tool | the doc vendor is mistral (110 D5) | I believe, unchecked, that it is a hosted tool on the agents API, built on a third-party model; licence not read |
| an OpenAI image model | quality | a new vendor, key and bill |

- **Cost.** I believe, unchecked, that it is about USD 0.02-0.04 per
  picture, so ~USD 1 a month at one a day, or ~USD 7 a month at the full
  cap of 7 pictures a day. T006 reads the price page and quotes it here.
- **Licence.** T006 quotes Google's terms on generated images (ownership,
  commercial use) here before the first post.
- **Review.** The vendor's safety filter, then the alt-text and prompt
  checks (4.4), then the owner's one-action takedown (3.5). No human looks
  at it before it is published (D5).
- **Fallback.** If the call fails or the picture is filtered out, the post
  ships without one. A missing picture never blocks a post.

## 6. Agents publish posts (owner msg e9c2ad28)

### 6.1 The one path: a named action, plus an MCP tool that wraps it

`do_spl_blog_post` (orc, `blog-post.func.sh`) is the only way to publish.

- **Input.** `BLOG_FILE=<draft.md>` and `AGENT_ID=<agent-id>`; an optional
  `BLOG_IMAGE_PROMPT` asks `do_spl_blog_image` for a picture.
- **Steps:**
  1. fetch `origin/master`;
  2. count the publish day's posts (6.2), and refuse with exit 3 and
     `blog cap: 7/7 today` if it is full;
  3. set `published`, `author` and the file name;
  4. make the picture;
  5. run `do_spl_blog_check`;
  6. commit under the canonical author, with the pathspec
     `csi-spl-doc/blog/posts/<id>.md`;
  7. rebase and push to master. On a push race it goes back to step 1.
- **The MCP tool `blog_post`** in the box spool MCP server runs this action
  and returns its result. Agents of every vendor get the same path, and no
  agent writes the post file by hand.
- **Rejected for v0.1: a hub API route with an agent credential.** It would
  need a new hub table, auth and RLS. The site is static, so a hub post
  still needs a WUI rebuild to appear, and the repo path already has the
  gates, the history and the takedown. If posts must one day appear
  without a deploy, a hub route can replace step 6 and keep the same cap
  and checks.

### 6.2 The cap: 7 per day, fleet-wide, enforced at publish time

- **Fleet-wide, not per agent.** The owner said "max 7 publications per
  day" for the blog, and 7 per agent would allow hundreds.
- **The digest counts** and has a reserved slot: other posts may take at
  most 6 of the 7 (5.1).
- **The day** is the publish day in cnf `env.blog.tz`, the same clock as the
  23:00 digest (owner Q1), so the two can never disagree. A post counts on
  the day of its `published` stamp.
- **Enforced by code the agent does not run.** `do_spl_blog_post` refuses
  early, but that is a courtesy, because an agent could skip it and commit a
  file by hand. The cap that holds is in **`sync-blog.mjs` (4.1), run by
  the WUI deploy in CI**:
  - per publish day it renders at most 7 posts, in `published` order (a
    digest first, if one exists);
  - an 8th file stays in git, unrendered, and the deploy log names it;
  - CI's `do_spl_blog_check` also goes red on that commit, so the lane that
    pushed it sees its red.
- What reaches the public site therefore never exceeds 7 a day, whatever
  an agent does. Test 9-l and its control pin this.
- An edit (`BLOG_EDIT=1`) and an unpublish do not count. A post that is
  unpublished and then published again counts again.

### 6.3 What an agent may publish

- "Matrix" content only (msg 566642a1): releases, specs, drills, fleet
  numbers, how the system works, AI pictures.
- The gate is 4.4. It refuses personal data, workspace data, hosts, box
  names and secrets. A refused post is never published "with a warning".
- **The author shown** is the agent id without the box, e.g. `m-004`,
  labelled with its vendor ("m-004 · Mistral"). The box name is left out
  because the hygiene rules ban box names in shipped content.
- No human review step (3.5). The owner unpublishes or edits after the fact.

## 7. Later, not v1: content about real people (msg 566642a1)

The owner's "later on ... the stuff which real persons also do" is listed
here so it is not lost. It has preconditions, each its own owner decision:

1. **Consent.** A written, revocable opt-in from each person, stored
   outside git, and checked by the post check against a consent list.
2. **The personal-data rule.** Such posts go to claude or mistral lanes only
   (spec 110 D2), never qwen, grok or agy. The data rule in the repo
   `CLAUDE.md` is extended to cover it.
3. **Human review before publishing**, by the person shown and by the
   owner. This lifts D5 for that type only.
4. **Real photographs.** Where they come from, their licence, faces, and
   EXIF stripped. Kept in the private media bucket, never in git.
5. **The hygiene carve-out.** The distribution-hygiene bans on personal
   names would need a carve-out for the blog posts dir. That is the owner's
   decision, and the leak-gate must still hold for everything else.

Until all five hold, the v1 gate (4.4) refuses personal data.

## 8. First posts (candidates)

1. **"The fleet restarts itself"** (`news`): the box restart drills, now
   named actions (`do_spl_box_restart_prepare` / `_check`), and spec 092
   power-loss recovery.
2. **"A fifth vendor: Mistral joins the fleet"** (`news`): spec 110, why it
   took grok's share, and the docs-and-panels routing (D5).
3. **"Hello, blog"** (`news`): how this page is written. Code collects the
   sources, an agent writes, gates check, and a picture is drawn.

Each one is published through `do_spl_blog_post` before the first digest,
so the list is not empty on day one.

## 9. Tests (each a pair with its control)

| # | test | control | n |
|---|---|---|---|
| a | sync: a new post appears in `index.json` and as a fragment | `--check` exits 1 on a stale copy | 1 |
| b | post check: a valid post passes | one control per row of 4.4: a 451-word body, a planted personal name, an email, a message id, a box name, an unknown sha, a second digest for a date, `image` without `image_alt`, a person in `image_prompt` | 1 each |
| c | prerender: `/blog/<id>` HTML holds the title and `og:image` with JS off | a `draft: true` post has no page | 1 |
| d | no locale copies: `/fi/blog` is not generated, and the CLE-77925 check stays green | removing the exclusion makes the check fail | 1 |
| e | initial JS delta <= 100 B | — (a measurement; the number is in the report) | 1 |
| f | e2e: list -> post -> back, dark and light, phone width | — | 1 per theme |
| g | digest action: the lease-holder, quiet-day, existing-post and deadline paths (dry run, stubbed spawn) | a box without the lease exits 0 without spawning | 1 each |
| h | the collector output holds only allow-listed sources | a workspace message id planted in a note is dropped | 1 |
| i | image action: a stubbed vendor call writes to the bucket and sets `image` | a vendor error leaves the post without `image`, exit 0 | 1 each |
| j | the Atom feed validates; the sitemap lists every post | a draft is absent from both | 1 |
| k | `do_spl_blog_post`: post 1..6 publish; the digest takes slot 7 | a 7th non-digest post is refused, exit 3 `blog cap` | 1 |
| l | **cap in CI:** 9 post files for one day (committed by hand, skipping the action) render exactly 7, the digest among them | the same 9 spread over two days render all 9 | 1 |
| m | MCP `blog_post` returns the action's exit and message | — | 1 |
| n | live: the first digest lands on prd inside 23:00-24:00 | — | 1 |

## 10. Owner questions (at most 3)

- **Q1. Which clock is the blog day (the 23:00 digest and the 7-a-day cap)?**
  - (a) **Europe/Helsinki**, the main box's clock *(recommended: it is the
    owner's working day, and cnf `env.blog.tz` makes it one edit)*.
  - (b) UTC (23:00 UTC is 02:00 Helsinki in summer).
- **Q2. Publish without review?**
  - (a) **Auto-publish after the automated gates, with a one-action
    unpublish** *(recommended, 3.5)*.
  - (b) Owner review first: every post waits as `draft: true` until the
    owner says go, so the digest appears the next day.
  - (c) (b) for the first 7 days, then (a).
- **Q3. Picture vendor:** may the build enable **Vertex AI Imagen** on
  `csi-spl-dev` / `csi-spl-prd` (~USD 1-7 a month, 5.4)? This is an API
  enable plus an IAM role for the per-env SA, which needs the owner's go
  under the repo rules.
  - (a) **Yes** *(recommended)*.
  - (b) No pictures for now; the blog ships without them.
  - (c) Another vendor (name it).

## 11. Review (one row per seat)

| seat | agent | verdict | changes asked | folded in |
|---|---|---|---|---|
| 1 drafter | claude c-589 | v0.1 | — | — |
| 2 | a-590 agy | agree with changes | 1. T007 calls `do_spl_blog_image` built in T006, so T007 must depend on T006. 2. If Q2(b) is chosen, T007 `do_spl_blog_post` must write `draft: true` for all posts, not just the digest in T008. Q1 -> (a) Aligns with the owner's working day. Q2 -> (a) Automated checks (4.4) prevent leaks; keeps publishing frictionless. Q3 -> (a) Vertex AI Imagen adds visual value at low cost. | |
| 3 | claude c-580 (security + privacy) | **agree with changes** | Measured on `origin/master` `043ebfac0`. **1. The privacy gate must hold BEFORE the push; the cap and the takedown hold only on the site.** The repo is public (`gh repo view csitea/csi-spl --json visibility` -> `PUBLIC`), so an 8th post or a refused post is public on GitHub the moment it lands, and `do_spl_blog_unpublish` (3.5) leaves it in history, which may never be rewritten. Say this in 3.5 and 6.2. 4.4 runs in `do_spl_blog_post` and in the pre-push gate. A post that CI turns red after the push is a leak, not a near miss, and the dispatcher handles it as one. **2. CSP is no backstop for the blog: the render hashes every inline script.** `render-wui-firebase-json.sh` lines 113-116 glob every generated `*.html` and add the sha256 of each inline `<script>` to `script-src`. A `<script>` that slips into a prerendered post is therefore allowed, and it runs on the app origin. Fix: (a) build fragments ONLY with the existing `markdownToHtml` / `treeToHtml` (escaped, allow-listed, `markdown.mjs` line 353), with no second sanitiser; (b) `sync-blog.mjs --check` and the render script both refuse a fragment or a `/blog/**` page that holds `<script` in a post body, an `on*=` attribute, or a `javascript:` / `data:` URL. Control: a planted `<img src=x onerror=...>` and a raw `<script>` in a post. 3.1 says the route chunk uses `v-html`. Today `MarkdownBlock.vue` says "never v-html" (`grep -rn v-html csi-spl-wui/src --include=*.vue \| wc -l` -> 2), so this would be a new sink: the test above is its guard. **3. Close four bypasses of the 7/day cap in `sync-blog.mjs`** (G4 holds only if the agent cannot pick its own day). (a) *Back- or forward-dating:* an agent that commits by hand can set `published` to a past day with free slots. The day and the order come from git: the first-parent commit on `origin/master` that added the file (`git log --first-parent --diff-filter=A`). CI refuses a newly added post whose `published` is more than 1 h from the CI clock. (b) *A fake digest takes the reserved slot:* a `type: digest` is refused unless `published` falls inside 23:00-24:00 in `env.blog.tz`. Otherwise one 10:00 "digest" blocks the real one as a "second digest". (c) *draft -> false later:* turning a post's draft flag off counts on the day of that commit, never on its old `published` day. (d) *An edit that becomes a new post:* `BLOG_EDIT=1` keeps `id`, `published` and `author`, and only the post's own author or the owner may edit it. Each item gets a control in 9-l. **4. MCP `blog_post` takes the markdown as a string and the author from the seat.** The tool writes the draft to its own temp file and never takes a `BLOG_FILE` path, or any agent could ask it to publish any file the server can read. `AGENT_ID` is `Options.Seat` (`internal/mcp/mcp.go` line 78, "Seat is the one agent id this server acts for"). An unseated server refuses `blog_post` with exit 78, like `who()`. Test 9-m adds both controls. **5. Every hex token must be a sha on master.** A message id and a short sha look the same (an 8-hex token occurs in 57 of 199 commit subjects of 2026-10-07, `git log origin/master --since=2026-10-07 --until=2026-10-08 --format=%s \| grep -ciE '\b[0-9a-f]{8}\b'`, n = 199). So 4.4 must not try to tell "message id" from "sha" by pattern. Any token of 7+ hex chars or a uuid that `git cat-file -e <tok>^{commit}` cannot resolve on `origin/master` is refused. **6. The collector (5.2) filters commit subjects, not only notes.** Subjects carry box names (8 of the same 199 match the hygiene box-name list) and owner message ids. Before writing the facts file, the collector runs the full 4.4 public-safe check over every line and drops what fails. 9-h plants a box name and a topic uuid in a subject. **7. Treat the digest lane's input as hostile.** Commit subjects are written by every lane, and the digest lane runs with bypass permissions. So: (a) the brief template marks the facts file as data, never instructions; (b) CI refuses any commit that touches `csi-spl-doc/blog/posts/**` together with any other path (the action's pathspec is one file); (c) the lane-mix chain for `blog-digest` is **mistral -> claude only**, never agy, grok or qwen (110 D2). Its input is pre-publication text whose only filter is a deny list, and a deny list cannot prove absence. **8. The release-note ban list is a secret: fail closed and never echo it.** It is a Secret Manager slot (`grep -n RELEASE_NOTE_BANS csi-spl-cnf/csi-spl/all.env.yaml` -> line 523, `csi-spl-hub-release-note-bans`), not a plain env var. `do_spl_blog_check` reads it through the per-env SA and exits 1 when it is unreadable or empty, in CI and on the box alike. A refusal names the file and line, never the pattern that matched, because the pattern itself is the secret. **9. Pictures get a narrow identity, not the project owner key.** The per-env project SA holds `roles/owner` (`gcp-003-configure-proj-sa-permissions.func.sh` line 34). Using it from a nightly agent cron and from an MCP tool that every lane can call gives each of them owner on the project. T006 adds a `blog-media` SA: `roles/aiplatform.user` (or a custom role with `aiplatform.endpoints.predict` only, if the panel prefers) plus `objectCreator` on the bucket alone. Its key is minted out of band like the relay key (doc 6.3). The wf 30 deploy identity gets `objectViewer` on that bucket only. The bucket gets uniform bucket-level access and public-access-prevention `enforced`, and a test fails on any `allUsers` binding. **10. Make the picture checks mechanical.** `do_spl_blog_image` sends `personGeneration: dont_allow` on every Imagen call, so "no real person" is not left to a prompt regex. It re-encodes to webp, which strips EXIF/XMP. `image` must match `^<post-id>(-og)?\.webp$`. Before copying, the wf 30 copy step checks the RIFF/WEBP magic bytes and the 300 KB limit. A key like `../x` or `$(…)` never reaches a `gcloud storage cp`. **Accepted risk, said aloud:** a lane can still skip the action, override the pre-push hook (`SPL_PREPUSH_OVERRIDE`, `grep -c SPL_PREPUSH_OVERRIDE csi-spl-iac/src/bash/run/check-pre-push.func.sh` -> 1) and land a bad post. Every other file in the repo has the same exposure today. Change 1 makes such a push a reported leak, and the spec does not claim more. **Q1 -> (a) Europe/Helsinki**, with `published` stored in UTC (`Z`) and the day computed in `env.blog.tz`, so that a DST change cannot split a day differently on the box and in CI. **Q2 -> (a) auto-publish**, provided changes 1-3 hold. A human review would not protect the public repo anyway, because the post is public once it is pushed, whether or not the site renders it. **Q3 -> (a) yes**, with change 9's dedicated SA and change 10's `personGeneration: dont_allow`. Without the narrow SA, choose (b): ship with no pictures rather than give the project owner key to a cron lane. | |
| 4 | claude c-581 (integration) | **agree with changes** | Read on tree `043ebfac0`. **1. Blog pages must not run the app's head scripts: today every prerendered document calls the hub.** The global `app.head` puts the session probe (`fetch` of the auth URL, credentials included) and the `/config.json` fetch into every document (`grep -c "buildEarlySessionScript\|buildEarlyConfigScript" csi-spl-wui/nuxt.config.ts` -> 4). So 3.1 "a visitor's browser makes no API call" is false as drafted, and every crawler hit becomes a Cloud Run request. T003 strips them from `/blog/**` documents in the `prerender:generate` hook (or the blog route gets its own head). Test 9-c adds: the blog HTML holds no auth URL and no `config.json`. **2. Blog pages are noindex today.** `X-Robots-Tag: noindex, nofollow` is set on `**` in three places: the `<meta name="robots">` and `routeRules` in `nuxt.config.ts` (`grep -c 'noindex, nofollow' csi-spl-wui/nuxt.config.ts` -> 2), and `render-wui-firebase-json.sh`, which writes the deployed `firebase.json` (`grep -c noindex csi-spl-orc/src/bash/scripts/render-wui-firebase-json.sh` -> 1). G1 and 3.3 (crawlers, sitemap) need a `/blog/**` override in all three. 9-c checks it with `curl -sI <post url>` and the meta tag; do not reason about Firebase header precedence. **3. A post commit does not deploy, and a committed copy breaks the 6.2 cap.** wf 30 has a path allow-list (`grep -c csi-spl-doc .github/workflows/30_wui-build-deploy.yml` -> 0). /help works because the copy is committed under the WUI (`git ls-files csi-spl-wui/src/public/help-md \| wc -l` -> 24). If `blog-md/` is committed like that, `do_spl_blog_post` step 6 (post file only) reddens the `--check` test on every post. And the deploy then ships the committed copy, so a hand-committed 8th post is still rendered. Change: `sync-blog.mjs` runs inside `pnpm run generate`, and `src/public/blog-md/` is git-ignored like `i18n/.split/`. wf 30 `paths` gains `csi-spl-doc/blog/posts/**`. The cap then holds in the build that ships. **4. One route file, not three.** Each page adds a record to the routes module in the initial JS (CLE-77925). Trunk is already 109 B over 155 KB, and lane c-579 is fixing it. I believe, unchecked, that three records cost tens of bytes gzip. Use one `pages/blog/[...slug].vue` for `/blog`, `/blog/page/<n>` and `/blog/<id>`. Measure 9-e only on a tree after c-579 lands, and report the version, tree and n. **5. Chrome in English literals, no i18n keys.** The 3.1 "keys in 19 locales" rule costs bytes either way. Keys that reach the first-screen core catalogue (`split-catalogue.mjs`, P3-06) are initial bytes. Keys left in `more` render as raw keys on a cold `/blog` until `i18n-more` loads. The body is English and there is no `/fi/blog`, so English chrome matches. No `i18n/locales/*.json` edit, so no collision with the 109/075 i18n lanes. **6. The "Blog" link goes on `/login`, not `/`.** `/` is the signed-in product home (`isProductScreen` in `src/utils/signed-out-redirect.mjs`), not a public landing page. A signed-out visitor is sent to `/login` before `/` renders. Also, 109 T003 -> T007 -> T008 own `pages/index.vue` in a chain (109 tasks.md line 35). Put the link in the login layout footer beside privacy/terms. 111 T003 must name `pages/index.vue` as do-not-touch. **7. `CRON_TZ` does not exist on these boxes.** Debian `cron 3.0pl1` runs every line in the daemon's zone (`man 5 crontab \| grep -c CRON_TZ` -> 0; its LIMITATIONS section says so). The `box-crons.manifest` row runs hourly at `0 * * * *`. The action proceeds only when `TZ=<env.blog.tz> date +%H` is `23`, so a box in another zone still fires once, at the right hour. T008 files: the manifest row (`csi-spl-orc/cnf/box-crons/box-crons.manifest`), not `install-box-crons.func.sh`. **8. The 23:55 close must not re-check the lease.** The orch lease can move between 23:00 and 23:55 (failover, a box restart), and `orch-rotate` runs at :05 every hour. The 23:00 run writes a per-date marker with the lane id. The 23:55 step runs on the box that holds the marker and closes that lane. A spawn refused at the 40-window ceiling is a missed day, reported as a `note`, never retried. The weekly restart window (brief f0be2877: about 04:00 and 04:30 box-local, one per box) does not overlap 23:00-24:00, so there is no collision. **9. Test 9-n splits "landed" from "live".** wf 30 success runs took 3.4 / 4.0 / 6.1 min (min / median / max), not counting runner queue time (`gh run list --workflow 30_wui-build-deploy.yml --status success -L 10`, n = 10, master `64963b526..0019d5790`). A digest landing at 23:57 is live after midnight. Pass = the commit lands by 24:00 and is live by 00:15. **10. Keep posts out of 075 /docs.** `do_publish_docs` uploads every tracked `*.md` (`git ls-files -s -- '*.md'`; `grep -c blog csi-spl-orc/src/bash/run/publish-docs.func.sh` -> 0). An unpublished `draft: true` post would stay readable in /docs. T007 adds a `csi-spl-doc/blog/` skip there, as one line in its own commit. **11. Canonical goes to the apex.** wf 30's header says the site is also served on `<tenant>.<fqdn>` and `<site>.web.app`. `canonical`, `og:image`, the feed and the sitemap use the absolute base from `NUXT_PUBLIC_SITE_URL` (cnf), never the request host. **Q1 -> (a)** with change 7: one zone for the cron guard, the day window and the cap. **Q2 -> (a)**, given changes 1 and 3: the cap holds in the shipped build, and a takedown is live in about 4 min (change 9). **Q3 -> (a)**, kept off the critical path: T009 ships without pictures. The wf 30 copy step needs bucket read for the deploy identity: the SA key path has it (roles/owner); the WIF Hosting-deploy SA path needs `storage.objectViewer` on the media bucket. | |

Links: [075](../075-docs-section/spec.md), [090](../090-marketing-automation/spec.md),
[091](../091-public-dataset-export/spec.md), [065](../065-release-notes-table/spec.md),
[044](../044-spool-open-source/spec.md), [061](../061-agent-id-rename/spec.md),
[092](../092-box-power-loss/), [110](../110-mistral-vendor/spec.md).

<!-- version: 0.1.0 · updated: 2026-10-08 · last-edit: 2026-10-08T19:05:38Z -->
| 5 | mistral m-595 (docs + panel) | **agree with changes** | **1. Treat the digest lane\'s input as hostile.** The facts file is data, not instructions. The brief template must mark it as such, and the lane-mix chain for `blog-digest` must be **mistral -> claude only** (never agy, grok, or qwen). This aligns with spec 110 D2 and the security panel\'s change 7. **2. Enforce the 7/day cap in `sync-blog.mjs`.** The cap must hold at build time, not just at publish time. `sync-blog.mjs` must refuse to render an 8th post for a day, even if committed by hand. This aligns with the security panel\'s change 3. **3. Privacy gate must run before the push.** The gate (4.4) must run in `do_spl_blog_post` and the pre-push gate. A post that fails the gate must never land on `origin/master`, as the repo is public. This aligns with the security panel\'s change 1. **4. Blog pages must not run the app\'s head scripts.** The prerendered `/blog/**` pages must not include the session probe or `/config.json` fetch. This aligns with the integration panel\'s change 1. **5. Keep posts out of 075 /docs.** `do_publish_docs` must skip `csi-spl-doc/blog/posts/**` to avoid publishing draft posts. This aligns with the integration panel\'s change 10. **Q1 -> (a) Europe/Helsinki** aligns with the owner\'s working day and avoids DST splits. **Q2 -> (a) Auto-publish with a one-action unpublish** is frictionless and aligns with the owner\'s preference for consensus-then-build. The gates (4.4) prevent leaks, and the takedown is fast (~4 min). **Q3 -> (a) Nano Banana (Gemini 2.5 Flash Image)** via the agent user\'s `~/.nano-banana/crs` key, as the owner decided (msgs 54180139, bfbd0b75). No GCP change, no dedicated SA, and no Imagen. | |
