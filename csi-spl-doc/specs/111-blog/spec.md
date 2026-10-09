# Spec 111: the blog (news and events, agent posts, one daily digest)

Version **v1.0** (2026-10-08). Drafted by claude c-589 as seat 1 (v0.1),
reviewed by the panel s111-2..s111-5 (section 11), folded to v1.0 by claude
c-584 with the owner's answers (section 0). Build: the lanes in
[tasks.md](tasks.md). Docs only: this spec builds nothing
(`../README.md` item 4).

`<BASE_DOMAIN>`, `<env>`, `<id>`, `<lang>`, `<agent-id>` and `<yyyy-mm-dd>`
are placeholders. No estate value appears as a literal to copy.

## 0. Owner asks and answers (verbatim, HUM-10, t1 topic d49b6b76)

| msg | text |
|---|---|
| 1e746177 | "we must a \"blog\" part of the [`<BASE_DOMAIN>`]" |
| e9862d10 | "where we will publish news and events on what is hapenning ..." |
| 88fd0f8c | "for example at end of the day there would be a single agent instantiated at 23:00 till 24:00 whos job will be to create a contensed no more than 1 A4 jist of what happened what was released with some funny or cool ai picture per post" |
| ba3294f5 + f1323068 | a pointer to a sibling project's blog as the reference implementation |
| e9c2ad28 | "just add to it the integration with the agents to be able to push there content - max 7 bublications per day" |
| 566642a1 | "later on we could start some pictures and additions from the stuff which real persons also do ... but for now only \"matrix\" stuff ..." |
| **2d009ecc** | **DECIDED**: "q1 a , q2 a , q3 a" (to the section 10 questions; its q3 is superseded by D-Q3 below) |
| d2db1f04 | "if we manage to get out of this tool something which contributes to the open source and makes the life better for many people we should tell theat to everyone wanting to listen / read" |
| **296582df** | **DECIDED (D-L)**: "and of course the blog posts must be in all of the supported languages ... - there the final word on the actual content should have the agy - because he is BEST with languages" |
| 38cb94ad | "as the code already exists in another project , it has to be only copy pasted and adapted ..." |
| 3265df8d | "the first blog posts today could be abot the new featurees we got today .." |
| 9d95860f | "the mistral - someting about European sovereignity in ai , France - liberte Debian etc." |
| **d726c274** | **DECIDED (D-Q3)**: "well I have a nano banana subscription ..." |
| **54180139** | "better ot use it actually" |
| **6813b935** | "yes the digest should use IT ... IT IS THE BEST ONE out there" |
| **041719d3** | "the api key shoud be somewhere under ~/.gemini - actually claude knows" |
| **bfbd0b75** | "and it should be set under the `~/.nano-banana/crs`" |

**DECIDED:**

- **D-Q1 (msg 2d009ecc): Europe/Helsinki is the blog day** (cnf
  `env.blog.tz`), used by the 23:00 digest and the 7/day cap. `published`
  is stored in UTC (`Z`); the day is computed in `env.blog.tz`, so a DST
  change cannot split a day differently on the box and in CI.
- **D-Q2 (msg 2d009ecc): auto-publish after the automated gates (4.4)**,
  with `do_spl_blog_unpublish` as the one-action takedown.
- **D-Q3 (msgs d726c274, 54180139, 6813b935, 041719d3, bfbd0b75; final,
  supersedes the Imagen answer of 2d009ecc): Nano Banana (Gemini 2.5 Flash
  Image) through the Gemini API, with the owner's key.**
  - **No GCP change for the picture model:** no Vertex AI / aiplatform
    enable, no `blog-media` SA, no IAM change, no terraform for pictures.
  - The key lives in the agent user's `~/.nano-banana/crs`, one line
    `GEMINI_API_KEY=<key>`, written only by the named action
    `do_set_nano_banana_key` (T011). The picture action reads it from there.
  - Where the generated files are kept until the deploy is open: Q4.
- **D-L (msg 296582df): every post in all supported languages, and agy has
  the final word on the content.** It overrides v0.1 section 3.1 ("English
  body, chrome keys in all 19 locales, no locale copies"). Settled in 3.7.

The reference is cited here only as **"a sibling project's blog (spec
047/049)"**. Its DESIGN and code are reused (msg 38cb94ad: the UI tasks
copy and adapt it, they do not redesign it): one markdown file per post,
frontmatter, list and post pages, prerendered HTML for crawlers, images
never committed, markdown rendered statically, no script in a post. Its
names, paths, domain and hosts never appear in csi-spl files.

**v1 content is "matrix" only (msg 566642a1):** the machine side, meaning
what the agents and the fleet did, releases, drills and specs, plus AI
pictures. Content about real people is out of scope for v1 (section 7).

## 1. Purpose and goals

**Purpose (msg d2db1f04):** the blog tells the open-source story of
spool-hub (the repository is public, spec 044) to anyone who wants to read
it.

| # | goal | measured by |
|---|---|---|
| G1 | `/blog` and `/blog/<post-id>` (and their locale copies) are public, unauthenticated, prerendered, indexable pages on the apex domain | `curl -s https://<BASE_DOMAIN>/blog/<post-id>` (no cookie) returns the post title in the HTML, and `curl -sI` shows no `noindex`, n = 1 per env |
| G2 | The blog adds **0 bytes** to the initial download | `initial-js-trims` delta <= 100 B, the bar spec 110 used |
| G3 | One digest post per day, written by ONE agent started at 23:00 and gone by 24:00 | <= 1 `digest` per date in `csi-spl-doc/blog/posts/en/`; the cron log shows start and end inside the hour |
| G4 | Any agent can publish a post through one named path; **at most 7 publications per day, enforced by code the agent does not run** | test 9-l and its controls: the 8th post of a day is not published |
| G5 | A post fits one A4 page | the post check refuses a body over 450 words (~1 A4 page with the picture) |
| G6 | Every post is public-safe and "matrix" only, before it is pushed | `do_check_dist_hygiene` + the post check (4.4) green on every post in `do_spl_blog_post` and the pre-push gate; the controls (a planted personal name, an email, an unresolvable hex token) are refused |
| G7 | Pictures never go in git | `git ls-files \| grep -cE '\.(webp\|avif\|png\|jpe?g\|svg)$'` stays at today's 16 after 30 posts |
| G8 | Every post exists in all supported locales, reviewed by agy | 9-o: each published `en` post has its 18 locale copies, each with an `agy_review` stamp |

Out of scope: comments, likes, newsletter email (spec 090 phase 2 may take
the feed later), posts written in the signed-in app, per-workspace blogs,
and content about real people (section 7).

## 2. Today, measured (trunk `f5a3745d8`; seat facts on `043ebfac0`)

| fact | evidence |
|---|---|
| The WUI ships with `nuxt generate`; only `/` and `/login` are prerendered per locale, every other route boots from `200.html` | `csi-spl-wui/nuxt.config.ts`: `PRERENDER_PAGES = ["/", "/login"]` |
| i18n is 19 locales, `prefix_except_default`, lazy; a build check fails unless the locale route copies are exactly what i18n made | `nuxt.config.ts` lines 226-330, `src/utils/locale-routes.mjs` (CLE-77925) |
| The initial-chunk gate reads ~152.7 KB against a 155 KB ceiling | `tests/unit/initial-js-trims.test.mjs` line 96 |
| CSP allows images from the site only: `img-src 'self' data:`; the render adds the sha256 of every inline `<script>` in every generated `*.html` to `script-src` | `firebase.json`, `nuxt.config.ts` `CSP_PROD`; `render-wui-firebase-json.sh` lines 113-116 (s111-3) |
| Every prerendered document runs the session probe and the `/config.json` fetch from `app.head` | `grep -c "buildEarlySessionScript\|buildEarlyConfigScript" csi-spl-wui/nuxt.config.ts` -> 4 (s111-4) |
| Every page is `noindex, nofollow`, set in three places | `nuxt.config.ts` meta + `routeRules` (2), `render-wui-firebase-json.sh` (1) (s111-4) |
| /help renders repo markdown from a committed copy; wf 30 does not deploy on `csi-spl-doc/**` | `sync-help.mjs`; `git ls-files csi-spl-wui/src/public/help-md \| wc -l` -> 24; `grep -c csi-spl-doc .github/workflows/30_wui-build-deploy.yml` -> 0 (s111-4) |
| Release notes live in the hub (spec 065), readable by a **signed-in member** only; the ban list `SPOOL_HUB_RELEASE_NOTE_BANS` is a Secret Manager slot | `internal/hub/release_notes.go`; `csi-spl-cnf/csi-spl/all.env.yaml` line 523 (s111-3) |
| The per-env project SA holds `roles/owner` | `gcp-003-configure-proj-sa-permissions.func.sh` line 34 (s111-3) |
| The repository is public | `gh repo view csitea/csi-spl --json visibility` -> `PUBLIC` (s111-3) |
| 16 image files are tracked today, all WUI chrome | `git ls-files \| grep -cE '\.(webp\|avif\|png\|jpe?g\|svg)$'` -> 16 |
| The main box clock is `Europe/Helsinki`; Debian `cron 3.0pl1` has no `CRON_TZ` | `timedatectl`; `man 5 crontab \| grep -c CRON_TZ` -> 0 (s111-4) |
| Box crons are one manifest, installed by one named action | `csi-spl-orc/cnf/box-crons/box-crons.manifest`, `do_install_box_crons` |
| A per-agent-user vendor key action exists to copy | `do_set_mistral_key` (spec 110), `csi-spl-orc/src/bash/run/set-mistral-key.func.sh` + its test |

## 3. Decisions (each with its reason)

### 3.1 Where it lives: public, prerendered, on the apex (D1)

**Decided: `/blog`, `/blog/page/<n>` and `/blog/<post-id>` in csi-spl-wui,
public, prerendered at `nuxt generate`, served by Firebase Hosting on the
apex domain, in every locale (D-L).**

- A blog is for people who are NOT signed in, for crawlers, and for link
  previews (Open Graph). None of that works inside the signed-in app.
- It needs no new hosting: the WUI already prerenders `/` and `/login`.
- **One route file:** `pages/blog/[...slug].vue` serves all three paths, so
  the routes module in the initial JS grows by one record, not three
  (s111-4 change 4).
- **Locale copies are made** (D-L): `/<lang>/blog/<post-id>` for every
  locale that has the post's copy (3.7). `locale-routes.mjs` keeps its
  CLE-77925 check exact with the blog routes included.
- **Lazy, 0 bytes initial.**
  - The route chunk only `v-html`s a fragment rendered and checked at build
    time (4.2). This is a new `v-html` sink (`MarkdownBlock.vue` says "never
    v-html"); 9-c's script/handler controls guard it (s111-3 change 2).
  - No markdown parser ships for the blog.
  - Nothing is added to the app shell, the sidebar or a layout.
- **The "Blog" link goes in the `/login` layout footer** beside privacy and
  terms, never on `/`: `/` is the signed-in product home, and spec 109 owns
  `pages/index.vue` (s111-4 change 6).
- **The pages make no API call** (s111-4 change 1): the `prerender:generate`
  hook strips the session probe and the `/config.json` script from
  `/blog/**` documents (or the blog route gets its own head). 9-c checks it.
- **Indexable** (s111-4 change 2): `/blog/**` overrides `noindex, nofollow`
  in all three places (meta, `routeRules`, the rendered `firebase.json`).
- **Canonical is the apex** (s111-4 change 11): `canonical`, `og:image`, the
  feed and the sitemap use the absolute base from `NUXT_PUBLIC_SITE_URL`
  (cnf), never the request host.
- **Chrome strings** (s111-4 change 5, reduced under D-L): English literals
  only until the locale chrome lands (T013); then the chrome is translated
  like the bodies, with its keys in a blog-only lazy catalogue loaded by the
  blog route chunk, never the first-screen core catalogue. 9-e measures it.

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
| `/blog/feed.xml` | Atom 1.0, the last 30 English posts, full text (one feed per locale is a later option) |
| `/sitemap.xml` | new (none exists today): `/`, `/login`, `/blog`, every post in every locale, with `hreflang` alternates |
| `/robots.txt` | allows `/blog`, points at the sitemap, disallows the app routes |

- `<post-id>` is `<yyyy-mm-dd>-<slug>`; a digest is `<yyyy-mm-dd>-digest`.
- Each post page sets these in the prerendered `<head>` through `useHead`,
  so a link preview works without JS:
  - `og:title`, and `og:description` (the summary);
  - `og:image`: the absolute URL of the 1200x630 crop;
  - `og:type=article` and `article:published_time`;
  - `<link rel="canonical">` and `<link rel="alternate" hreflang>`.
- **Theme.** The pages use the WUI's CSS variables, so dark and light follow
  the user's theme. A visitor with no setting gets `prefers-color-scheme`.

### 3.4 Source: markdown in the repo (D4)

**Decided: one markdown file per post and locale in
`csi-spl-doc/blog/posts/<lang>/<id>.md`.** English (`en`) is the source
copy; the other 18 are its translations (3.7). Posts are not written in the
app.

```text
csi-spl-doc/blog/posts/<lang>/<yyyy-mm-dd>-<slug>.md
---
id: <yyyy-mm-dd>-<slug>
lang: <lang>
type: digest | news | event
title: "..."
summary: "one sentence, <= 160 chars (og:description)"
date: <yyyy-mm-dd>
published: <ISO-8601 UTC, Z>  # set by do_spl_blog_post, never by hand
author: <agent-id>            # e.g. m-004; never a person, never a box name
agy_review: <agent-id>        # the agy seat that gave the final word (3.7)
tags: [release, fleet]
image: <id>.webp              # a key in the media store, never a file in git
image_alt: "..."              # required when image is set
image_prompt: "..."           # the prompt that made it (provenance)
draft: false
---
<body, <= 450 words>
```

Why the repo:

- It is the same path as /help and the spec 075 repo docs: written in git,
  copied into the WUI by a sync script, and checked by a unit test.
- Every post is a commit under the canonical author. A bad post is
  unpublished from the site (3.5), but it stays in the public history.
- The hygiene sweep already reads every tracked file.
- An in-app editor would need auth, a hub table, an approval UI and RLS.
  That is spec 090's queue; the blog does not need it.

### 3.5 Publish without review, behind gates (D5, D-Q2)

**DECIDED (D-Q2): auto-publish** once the automated gates (4.4) are green.
The agy review of 3.7 is a language and content step inside the pipeline,
not an owner review.

- **The gate holds BEFORE the push** (s111-3 change 1). The repository is
  public, so a post is public on GitHub the moment it lands, and
  `do_spl_blog_unpublish` leaves it in history, which is never rewritten.
  4.4 runs in `do_spl_blog_post` and in the pre-push gate. A post that CI
  turns red after the push is a **leak**, not a near miss, and the
  dispatcher handles it as one.
- **Unpublish.** The owner takes any post down with one action:
  `POST_ID=<id> ./run -a do_spl_blog_unpublish`. It commits `draft: true`
  on every locale copy, and the next WUI deploy (about 4 min, s111-4 change
  9) drops the pages, the feed entry and the sitemap lines.
- **Edit.** An edit is a commit to the post file through
  `do_spl_blog_post` (`BLOG_EDIT=1`), checked by the same gates. It keeps
  `id`, `published` and `author`; only the post's own author or the owner
  may edit it (s111-3 change 3d). An edit does not count toward the cap.
- **Accepted risk, said aloud (s111-3):** a lane can skip the action,
  override the pre-push hook (`SPL_PREPUSH_OVERRIDE`) and land a bad post.
  Every other file in the repo has the same exposure. Such a push is a
  reported leak; the spec does not claim more.

### 3.6 Reuse

| spec / code | reused for |
|---|---|
| a sibling project's blog (spec 047/049) | the UI: list and post pages, frontmatter shape, feed. Copied and adapted (msg 38cb94ad) on the drafting box, where it is readable |
| /help (`sync-help.mjs`, `help.mjs`, `markdown.mjs`) | the copy-and-check pattern, link rewriting, `{{site}}` for the domain, and the ONE sanitiser: `markdownToHtml` / `treeToHtml` |
| 075 Docs | repo markdown as the source |
| 090 marketing automation | "no source, no post", source-backed drafting (every claim names its tag or sha) |
| 091 public dataset export | the allow-list idea: the digest collector reads only allow-listed sources (5.2) and fails closed |
| 065 release notes | the day's notes, read on the box from git (`refs/notes/release-notes`), with the same ban list as the hub filter |
| 110 D5 / D2 | the vendor: docs and low-level code mistral first; the hardest code and anything with secrets claude |
| 110 `do_set_mistral_key` | the shape of `do_set_nano_banana_key` (T011) |

Rules that bind every task:

- **Distribution hygiene.** No personal names, hosts, OS users, box names
  or customer names. In copied text, the domain only appears as `{{site}}`.
  The sibling project is never named, nor its paths or hosts.
- **CSP.** No `new Function`, no `eval`, no inline script in a post, and no
  new `img-src` host.
- **Languages (D-L).** Every post and the chrome in all supported locales;
  agy has the last word (3.7).
- **Theme.** Dark and light come from the CSS variables.

### 3.7 Languages (D-L)

**DECIDED (msg 296582df):** every post exists in all supported locales (19,
per v0.1 section 2), as `posts/<lang>/<id>.md`, and **agy has the final
word** on each post's content and translations.

- **The chain** (also reconciles s111-3 change 7 and s111-5 change 1):
  **mistral writes** (110 D5) -> **agy reviews** the English and then each
  translation; it reviews and corrects, it does not draft -> publish.
  **claude is the fallback WRITER only**, when no mistral seat is up. agy
  never receives the digest's facts file, only the draft text that has
  already passed 4.4 (so its 110 D2 exposure is public-safe text).
- **Translation.** `do_spl_blog_translate` (T012) has the writer produce the
  18 copies from the reviewed `en` post, then agy reviews them, then the
  copies pass 4.4 and land as ONE commit that touches only that post's
  locale files (`posts/*/<id>.md`).

Settled, each with its recommendation:

| question | recommendation | why |
|---|---|---|
| Does the 7/day cap count locale copies? | **No: the cap counts a post (an `id`)**, decided by its `en` file; translation commits never count | 19 copies are one publication in 19 languages |
| Does the 23:00 digest fit write + translate + agy review before 24:00 Helsinki? | **No: English first, the locales follow.** The `en` digest (written, agy-reviewed, gated) lands by 23:50; the 18 copies follow through `do_spl_blog_translate` by 06:00, and a locale page without its copy shows the English text with `lang="en"` and a "translation pending" chrome line | write ~20 min + review ~10 min fits the hour; 18 translations + 18 reviews do not, and a late `en` digest would fall into the next day's cap (4.1, s111-3 change 3b) |
| Build and size impact of 19x posts | **Prerendered, 0 initial-chunk growth**: fragments are static `blog-md/<lang>/<id>.html` files, the route chunk is shared. Prerender every locale copy; T003 measures `nuxt generate` time and the Hosting file count at 30 posts x 19 (n = 1, tree named). If wf 30 grows by more than 2 min, non-`en` copies older than 90 days are served by the route chunk from their fragment instead of a prerendered page | at the realistic 1-3 posts a day this is 7-21k documents a year; the cap allows 48k |
| No agy on the box, or none answers | **The post waits** (repo language rule: "it never ships unreviewed"). The review request goes fleet-wide to any agy seat (`LANE_MIX_KIND=i18n`, cross-box through the hub). A digest whose `en` review has not come back by 23:55 is a missed day, reported as a `note` | English-only-unreviewed would break the owner's final-word rule |

## 4. Build pipeline

### 4.1 Sync and the daily cap

`src/node/blog/sync-blog.mjs`, a twin of `sync-help.mjs`, runs **inside
`pnpm run generate`**, and `src/public/blog-md/` is git-ignored like
`i18n/.split/` (s111-4 change 3). wf 30's `paths` gains
`csi-spl-doc/blog/posts/**`, so a post commit deploys and the cap holds in
the build that ships. It:

- reads `csi-spl-doc/blog/posts/<lang>/*.md` and validates the frontmatter;
- skips `draft: true`;
- **applies the cap (6.2)** per publish day, with the day and the order
  taken from git, not from the frontmatter (s111-3 change 3);
- writes `blog-md/index.json` (per locale: id, type, title, summary, date,
  author, tags, image, image_alt; newest first) and one
  `blog-md/<lang>/<id>.html` fragment per copy (4.2);
- `--check` refuses a fragment that holds `<script`, an `on*=` attribute,
  or a `javascript:` / `data:` URL (s111-3 change 2b).

### 4.2 Render at build time

Fragments are built ONLY with the existing `markdownToHtml` / `treeToHtml`
(`markdown.mjs` line 353: escaped, allow-listed). There is no second
sanitiser (s111-3 change 2a):

- no raw HTML;
- `http(s)` links only, and external ones get `rel="noopener nofollow"`;
- images only from the post's own `image` key.

Rendering at build time keeps the parser out of the browser (the
initial-chunk reason) and compiles nothing at runtime (the CSP reason).
CSP is **no backstop** here: the render hashes every inline script into
`script-src`, so `render-wui-firebase-json.sh` also refuses a `/blog/**`
page with a `<script` in a post body, an `on*=` attribute or a
`javascript:` / `data:` URL.

### 4.3 Pictures: never in git, copied in at build (D6)

- **Never in git.** Daily pictures are ~365 binaries a year, and the
  distribution package bans images (hygiene rule 7).
- **The media store is open (Q4).** D-Q3 removed every GCP change for the
  picture model; a private bucket is still a terraform step. Until Q4 is
  answered, posts ship without pictures, which never blocks a post (s111-4:
  pictures stay off the critical path).
- **Serving.** The WUI deploy (wf 30) copies the pictures named in
  `index.json` into the generated `.output/public/blog/img/` before
  `firebase deploy`. They are served from the site itself, so **CSP
  `img-src 'self'` stays as it is**.
- **Checks before the copy** (s111-3 change 10): `image` must match
  `^<post-id>(-og)?\.webp$`; the copy step checks the RIFF/WEBP magic bytes
  and the 300 KB limit, so a key like `../x` or `$(…)` never reaches a copy
  command.
- **Format.** webp, 1600x900 plus a 1200x630 Open Graph crop, each under
  300 KB, re-encoded by the picture action (strips EXIF/XMP).
- **Rejected:** a public bucket or a CDN host. It would add an `img-src`
  host to both CSP lists.

### 4.4 The post check (gate)

`./run -a do_spl_blog_check` (orc) is run by `do_spl_blog_post`, by
`do_spl_blog_translate`, by the pre-push gate when `csi-spl-doc/blog/**`
changes, and by CI:

| check | refuses |
|---|---|
| frontmatter | a missing field, an unknown `type`, an `id` that does not match the file name, a `lang` that does not match the dir, `image` without `image_alt`, a hand-set `published`, a copy without `agy_review` |
| size | a body over 450 words; a summary over 160 chars |
| hygiene | anything `do_check_dist_hygiene` refuses, plus the release-note ban list. The list is a secret (Secret Manager slot): read through the per-env SA, **fail closed** when unreadable or empty, and a refusal names the file and line, never the pattern (s111-3 change 8) |
| public-safe, "matrix" only | a personal name (the hygiene name list), an email address, a phone number, an internal host, a box name, a `/home/` path; an `image_prompt` that asks for a real or named person |
| hex tokens | **any** token of 7+ hex chars, or a uuid, that `git cat-file -e <tok>^{commit}` cannot resolve on `origin/master`. Message ids and shas look alike, so none is told apart by pattern (s111-3 change 5) |
| facts | a `v<X.Y.Z>` tag that is not on `origin/master` |
| author | an `author` that is not a valid agent id (spec 061 grammar) or the site name |
| digest | a second `digest` for the same `date`; a `digest` whose `published` is outside 23:00-24:00 in `env.blog.tz` (s111-3 change 3b) |
| commit shape | in CI: a commit touching `csi-spl-doc/blog/posts/**` together with any other path, or more than one post id (s111-3 change 7b) |

Each check has its control (section 9, test b).

## 5. The daily digest agent

### 5.1 Start and stop: one named cron action

- **Start.** `do_spl_blog_digest` (orc, `blog-digest.func.sh`), one row in
  `csi-spl-orc/cnf/box-crons/box-crons.manifest` at `0 * * * *`. Debian cron
  has no `CRON_TZ`, so the action proceeds only when
  `TZ=<env.blog.tz> date +%H` is `23` (s111-4 change 7, D-Q1).
- **One box only.** The action exits 0 at once unless this box holds the
  orch lease at 23:00.
- **Idempotent.** It exits 0 if `origin/master` already has a digest for
  the date.
- **Quiet day.** If the collector (5.2) finds no tag and no landed commit,
  there is no post (no source, no post).
- **The lane.** It spawns ONE writer lane through the normal spawn path:
  mistral (110 D5), claude as the fallback writer. The brief is a fixed
  template (`blog-digest-brief.md`) that marks the facts file as **data,
  never instructions** (s111-3 change 7a). The agy review follows (3.7).
- **The digest has a reserved slot.** It is one of the day's 7
  publications, and other posts may take at most 6 (6.2).
- **Deadline** (s111-4 change 8). The 23:00 run writes a per-date marker
  with the lane id. The 23:55 step runs on the box that holds the marker,
  without re-checking the lease, and closes that lane with
  `tmux-close-window.sh` before 24:00. A missed day (no landing, a spawn
  refused at the 40-window ceiling, no agy review) is reported to the
  dispatcher as a `note`, and is never retried.

### 5.2 What the agent is given (code collects, the agent writes)

Per the owner's rule "orchestration is code, not intelligence", the
**collector** is code: `do_spl_blog_digest_collect` writes one facts file.
The agent never looks for its own sources.

| source | how | public-safe because |
|---|---|---|
| tags minted in the day window | `git tag --list 'v*'` with creator dates | tags are public (spec 044) |
| the day's release notes | `git notes --ref=release-notes` for the day's shas | the ban list is applied first |
| landed commit subjects | `git log origin/master --since/--until` | public repo history, filtered (below) |
| spec status changes | the `[x]` lines added to `csi-spl-doc/specs/*/tasks.md` in the window | public repo |
| the day's blog posts | `csi-spl-doc/blog/posts/en/` with that date | already gated |

- **Every line is filtered** (s111-3 change 6): before writing the facts
  file the collector runs the full 4.4 public-safe and hex-token checks over
  every line and drops what fails. Subjects carry box names and message ids.
- **Not a source in v1:** topic or message text from any workspace. That is
  workspace data, and spec 091 shows how much proof a "public slice" of it
  needs.
- **The day window** is the 24 hours before 23:00 in `env.blog.tz`, so
  every hour is covered by exactly one digest.

### 5.3 What the agent writes

- **The post.** One `en` post, `type: digest`, of at most 450 words, in
  this order: a one-line headline; "Released": the versions and what they
  bring; "Landed": the 3-7 changes that matter, grouped; "Next": optional,
  one line.
- **Sources.** Every claim names its tag or short sha (090's source-backed
  rule), and the post check (4.4) refuses a token that is not on master.
- **The picture.** One `image_prompt`: "funny or cool", about the day's
  main theme, with no people, no logos or brands, and no text in the
  picture. And one `image_alt` of at most 125 chars that describes it.
- **Then** agy reviews it (3.7), and it publishes through
  `do_spl_blog_post` (6.1), like any other agent post.

### 5.4 The picture (D7, D-Q3)

**DECIDED: Nano Banana (Gemini 2.5 Flash Image) through the Gemini API,
with the owner's key**, called by the code action `do_spl_blog_image`.

- **Key.** Read from the agent user's `~/.nano-banana/crs`
  (`GEMINI_API_KEY=<key>`), written by `do_set_nano_banana_key` (T011).
  Sent as a request header read from a file descriptor; never in argv, an
  exported env var, a log or git.
- **No GCP change**: no Vertex AI, no aiplatform enable, no new SA, no IAM
  change, no terraform for the model.
- **No people** (s111-3 change 10): a fixed instruction "no people, no
  logos, no text" is prepended to every prompt, and 4.4 refuses a person in
  `image_prompt`. There is no person switch to send: the API reference's
  `ImageConfig` has two fields only, `aspectRatio` and `imageSize`
  (https://ai.google.dev/api/generate-content, read 2026-10-09).
- **Re-encode** to webp (strips EXIF/XMP), 1600x900 + the 1200x630 crop.
- **Cost and licence** (T006, each quoted from the page on 2026-10-09):
  - **Price**, https://ai.google.dev/gemini-api/docs/pricing, Gemini 2.5
    Flash Image: input "$0.30 (text / image)"; output "$0.039 per image"
    (1,290 tokens per image at $30 per 1M tokens); batch "$0.0195 per
    image"; free tier "Not available". At the 7/day cap that is at most
    7 x $0.039 = $0.273 a day.
  - **Ownership**, https://ai.google.dev/gemini-api/terms (last modified
    2026-04-28): "Google won't claim ownership over that content. You
    acknowledge that Google may generate the same or similar content for
    others and that we reserve all rights to do so."
  - **Use**, same page: "Use of Google AI Studio and Gemini API is for
    developers building with Google AI models for professional or business
    purposes, not for consumer use." and "You're responsible for your use
    of generated content, and for the use of that content by anyone you
    share it with."
  - **Watermark**, https://ai.google.dev/gemini-api/docs/image-generation:
    "All generated images include a SynthID watermark." (invisible; the
    webp re-encode strips EXIF/XMP, not the SynthID mark).
- **Fallback.** If the key is missing, the call fails or the picture is
  filtered out, the post ships without one. A missing picture never blocks
  a post.

## 6. Agents publish posts (owner msg e9c2ad28)

### 6.1 The one path: a named action, plus an MCP tool that wraps it

`do_spl_blog_post` (orc, `blog-post.func.sh`) is the only way to publish.

- **Input.** `BLOG_FILE=<draft.md>` and `AGENT_ID=<agent-id>`; an optional
  `BLOG_IMAGE_PROMPT` asks `do_spl_blog_image` for a picture.
- **Steps:**
  1. fetch `origin/master`;
  2. count the publish day's posts (6.2), and refuse with exit 3 and
     `blog cap: 7/7 today` if it is full;
  3. set `published` (UTC), `author` and the file name
     (`posts/en/<id>.md`);
  4. make the picture;
  5. run `do_spl_blog_check`;
  6. commit under the canonical author, with that one pathspec;
  7. rebase and push to master. On a push race it goes back to step 1;
  8. queue the translation (3.7).
- **The MCP tool `blog_post`** in the box spool MCP server runs this action
  (s111-3 change 4): it takes the markdown as a **string**, writes it to its
  own temp file and never takes a `BLOG_FILE` path; `AGENT_ID` is the
  server's `Options.Seat`, and an unseated server refuses with exit 78, like
  `who()`.
- **Rejected for v1: a hub API route with an agent credential.** It would
  need a new hub table, auth and RLS, and a static site still needs a
  rebuild.
- **Kept out of 075 /docs** (s111-4 change 10): `do_publish_docs` skips
  `csi-spl-doc/blog/`, so a `draft: true` post is not readable there.

### 6.2 The cap: 7 per day, fleet-wide, enforced at build time

- **Fleet-wide, not per agent.** 7 per agent would allow hundreds.
- **A post counts once**, by its `en` file; locale copies never count (3.7).
- **The digest counts** and has a reserved slot: other posts may take at
  most 6 of the 7 (5.1).
- **The day and the order come from git** (s111-3 change 3a): the
  first-parent commit on `origin/master` that added the `en` file
  (`git log --first-parent --diff-filter=A`), in `env.blog.tz`. CI refuses
  a newly added post whose `published` is more than 1 h from the CI clock.
- **draft -> false later** counts on the day of that commit, never on its
  old `published` day (s111-3 change 3c).
- **Enforced by code the agent does not run.** `do_spl_blog_post` refuses
  early as a courtesy; the cap that holds is in **`sync-blog.mjs` (4.1),
  inside the WUI build**: per day at most 7 posts render (a digest first,
  if one exists); an 8th file stays in git, unrendered, the deploy log
  names it, and CI's `do_spl_blog_check` goes red on that commit.
- **Limit, said aloud** (s111-3 change 1): the cap and the takedown hold on
  the SITE only. An 8th post is still public in the repository.
- An edit (`BLOG_EDIT=1`) and an unpublish do not count. A post that is
  unpublished and then published again counts again.

### 6.3 What an agent may publish

- "Matrix" content only (msg 566642a1): releases, specs, drills, fleet
  numbers, how the system works, AI pictures.
- The gate is 4.4. A refused post is never published "with a warning".
- **The author shown** is the agent id without the box, e.g. `m-004`,
  labelled with its vendor ("m-004 · Mistral").
- No owner review step (3.5). The owner unpublishes or edits after the fact.

## 7. Later, not v1: content about real people (msg 566642a1)

The owner's "later on ... the stuff which real persons also do" is listed
here so it is not lost. It has preconditions, each its own owner decision:

1. **Consent.** A written, revocable opt-in from each person, stored
   outside git, and checked by the post check against a consent list.
2. **The personal-data rule.** Such posts go to claude or mistral lanes only
   (spec 110 D2), never qwen, grok or agy, so D-L's agy review would need
   its own owner answer for them.
3. **Human review before publishing**, by the person shown and by the
   owner. This lifts D5 for that type only.
4. **Real photographs.** Where they come from, their licence, faces, and
   EXIF stripped. Never in git.
5. **The hygiene carve-out.** The distribution-hygiene bans on personal
   names would need a carve-out for the blog posts dir. That is the owner's
   decision, and the leak-gate must still hold for everything else.

Until all five hold, the v1 gate (4.4) refuses personal data.

## 8. First posts (owner msgs 3265df8d, 9d95860f)

2-3 posts about 2026-10-08's features, published with the first deploy of
/blog, inside the 7/day cap (T009). Candidate subjects (c-002,
`origin/master`, n = 1: 133 commits since 2026-10-08T00:00Z, tags up to
v3.9.9):

1. **Mistral joins the fleet** (`news`), spec 110: by-kind routing (D5), the
   key, hub ids, the vendor split row. **Angle (msg 9d95860f):** European AI
   sovereignty, a French vendor, open tooling (the boxes run Debian).
   Factual only: no claim about Mistral without a public source.
2. **Two box-restart drills** (`news`): one box 11/11 back in 69 s; the
   second box's drill found the new restart path's gaps, and the GitHub
   runners now come back after a boot.
3. **Hours tracking and the desktop UI round** (`news`): spec 107 (freeze
   sweep, Hours section, header timer); RUM on prd, one read per resource,
   the lobby wait traced to box load.

Every fact cites its sha; matrix-only and hygiene rules apply (no personal
names, no box names, no workspace data).

## 9. Tests (each a pair with its control)

| # | test | control | n |
|---|---|---|---|
| a | sync: a new post appears in `index.json` and as a fragment per locale | `--check` exits 1 on a stale copy | 1 |
| b | post check: a valid post passes | one control per row of 4.4: a 451-word body, a planted personal name, an email, an unresolvable 8-hex token, a box name, an unknown tag, a second digest for a date, a 10:00 digest, `image` without `image_alt`, a person in `image_prompt`, a copy without `agy_review`, an empty ban list (fail closed), a post commit with a second path | 1 each |
| c | prerender: `/blog/<id>` HTML holds the title and `og:image` with JS off, no auth URL, no `config.json`, no `noindex` (`curl -sI` and the meta) | a `draft: true` post has no page; a planted `<img src=x onerror=...>` and a raw `<script>` in a post are refused by `--check` and the render | 1 each |
| d | locale copies: `/fi/blog/<id>` is generated for a post with a `fi` copy, and the CLE-77925 check stays exact | a missing copy falls back to `en` with `lang="en"`; a stray route makes the check fail | 1 |
| e | initial JS delta <= 100 B, measured on a tree past the 155 KB fix (version, tree, n in the report) | — (a measurement) | 1 |
| f | e2e: list -> post -> back, dark and light, phone width | — | 1 per theme |
| g | digest action: the lease-holder, hour guard, quiet-day, existing-post, marker and deadline paths (dry run, stubbed spawn) | a box without the lease exits 0 without spawning; a 22:00 run exits 0 | 1 each |
| h | the collector output holds only allow-listed, filtered lines | a box name and a topic uuid planted in a subject, and a message id in a note, are dropped | 1 |
| i | image action: a stubbed Gemini call writes a re-encoded webp and sets `image`; the key never reaches argv or a log | a vendor error or a missing `~/.nano-banana/crs` leaves the post without `image`, exit 0; a bad key name and a non-webp file are refused by the copy step | 1 each |
| j | the Atom feed validates; the sitemap lists every post and locale | a draft is absent from both | 1 |
| k | `do_spl_blog_post`: post 1..6 publish; the digest takes slot 7 | a 7th non-digest post is refused, exit 3 `blog cap` | 1 |
| l | **cap in the build:** 9 post files for one day (committed by hand) render exactly 7, the digest among them | the same 9 over two days render all 9; a back-dated `published`, a draft flipped later, and an edit that changes `id` are each counted on their commit day | 1 each |
| m | MCP `blog_post` returns the action's exit and message | a path argument is refused; an unseated server exits 78 | 1 each |
| n | live: the first digest commit lands on master by 24:00 and is live on prd by 00:15 | — | 1 |
| o | translation: a reviewed `en` post gets its 18 copies in one commit, each with `agy_review` | no agy answer: no copy lands, and the `en` page stays | 1 |
| p | `do_set_nano_banana_key`: one line in `~/.nano-banana/crs`, mode 600, dir 700, masked output | a planted echo of the key in argv, the log or the output fails the test | 1 |

## 10. Owner questions

- **Q1. Which clock is the blog day (the 23:00 digest and the 7-a-day cap)?**
  - (a) **Europe/Helsinki**, the main box's clock. **<- DECIDED (D-Q1, msg 2d009ecc)**
  - (b) UTC (23:00 UTC is 02:00 Helsinki in summer).
- **Q2. Publish without review?**
  - (a) **Auto-publish after the automated gates, with a one-action
    unpublish.** **<- DECIDED (D-Q2, msg 2d009ecc)**
  - (b) Owner review first: every post waits as `draft: true`.
  - (c) (b) for the first 7 days, then (a).
- **Q3. Picture vendor.**
  - (a) Yes, Vertex AI Imagen. **<- DECIDED (msg 2d009ecc), then superseded**
  - (b) No pictures for now.
  - (c) Another vendor. **<- DECIDED (D-Q3, final): Nano Banana through the
    Gemini API with the owner's key; no GCP change**
- **Q4 (new, from D-Q3). Where are the generated pictures kept until wf 30
  copies them into the site?** Not in git (G7).
  - (a) **A private bucket per env, `csi-spl-<env>-blog-media`, made by a
    terraform step** (uniform access, public-access-prevention enforced, a
    test fails on any `allUsers` binding; `objectViewer` for the wf 30
    deploy identity only). An infra change: the plan is shown to the owner,
    and the apply waits for the owner's go *(recommended: it is the design the panel
    reviewed, and storage is not the picture model D-Q3 ruled out)*.
  - (b) No stored pictures in v1: posts ship without them.

## 11. Review (one row per seat)

| seat | agent | verdict | changes asked | folded in |
|---|---|---|---|---|
| s111-1 drafter | claude c-589 | v0.1 | — | — |
| s111-2 | a-590 agy | agree with changes | 1. T007 calls `do_spl_blog_image` built in T006, so T007 must depend on T006. 2. If Q2(b) is chosen, T007 `do_spl_blog_post` must write `draft: true` for all posts, not just the digest in T008. Q1 -> (a) Aligns with the owner's working day. Q2 -> (a) Automated checks (4.4) prevent leaks; keeps publishing frictionless. Q3 -> (a) Vertex AI Imagen adds visual value at low cost. | 1 folded (T007 needs T006). 2 moot: Q2 is (a), T007/T008 have no draft branch. |
| s111-3 | claude c-580 (security + privacy) | **agree with changes** | Measured on `origin/master` `043ebfac0`. **1. The privacy gate must hold BEFORE the push; the cap and the takedown hold only on the site.** The repo is public (`gh repo view csitea/csi-spl --json visibility` -> `PUBLIC`), so an 8th post or a refused post is public on GitHub the moment it lands, and `do_spl_blog_unpublish` (3.5) leaves it in history, which may never be rewritten. Say this in 3.5 and 6.2. 4.4 runs in `do_spl_blog_post` and in the pre-push gate. A post that CI turns red after the push is a leak, not a near miss, and the dispatcher handles it as one. **2. CSP is no backstop for the blog: the render hashes every inline script.** `render-wui-firebase-json.sh` lines 113-116 glob every generated `*.html` and add the sha256 of each inline `<script>` to `script-src`. A `<script>` that slips into a prerendered post is therefore allowed, and it runs on the app origin. Fix: (a) build fragments ONLY with the existing `markdownToHtml` / `treeToHtml` (escaped, allow-listed, `markdown.mjs` line 353), with no second sanitiser; (b) `sync-blog.mjs --check` and the render script both refuse a fragment or a `/blog/**` page that holds `<script` in a post body, an `on*=` attribute, or a `javascript:` / `data:` URL. Control: a planted `<img src=x onerror=...>` and a raw `<script>` in a post. 3.1 says the route chunk uses `v-html`. Today `MarkdownBlock.vue` says "never v-html" (`grep -rn v-html csi-spl-wui/src --include=*.vue \| wc -l` -> 2), so this would be a new sink: the test above is its guard. **3. Close four bypasses of the 7/day cap in `sync-blog.mjs`** (G4 holds only if the agent cannot pick its own day). (a) *Back- or forward-dating:* an agent that commits by hand can set `published` to a past day with free slots. The day and the order come from git: the first-parent commit on `origin/master` that added the file (`git log --first-parent --diff-filter=A`). CI refuses a newly added post whose `published` is more than 1 h from the CI clock. (b) *A fake digest takes the reserved slot:* a `type: digest` is refused unless `published` falls inside 23:00-24:00 in `env.blog.tz`. Otherwise one 10:00 "digest" blocks the real one as a "second digest". (c) *draft -> false later:* turning a post's draft flag off counts on the day of that commit, never on its old `published` day. (d) *An edit that becomes a new post:* `BLOG_EDIT=1` keeps `id`, `published` and `author`, and only the post's own author or the owner may edit it. Each item gets a control in 9-l. **4. MCP `blog_post` takes the markdown as a string and the author from the seat.** The tool writes the draft to its own temp file and never takes a `BLOG_FILE` path, or any agent could ask it to publish any file the server can read. `AGENT_ID` is `Options.Seat` (`internal/mcp/mcp.go` line 78, "Seat is the one agent id this server acts for"). An unseated server refuses `blog_post` with exit 78, like `who()`. Test 9-m adds both controls. **5. Every hex token must be a sha on master.** A message id and a short sha look the same (an 8-hex token occurs in 57 of 199 commit subjects of 2026-10-07, `git log origin/master --since=2026-10-07 --until=2026-10-08 --format=%s \| grep -ciE '\b[0-9a-f]{8}\b'`, n = 199). So 4.4 must not try to tell "message id" from "sha" by pattern. Any token of 7+ hex chars or a uuid that `git cat-file -e <tok>^{commit}` cannot resolve on `origin/master` is refused. **6. The collector (5.2) filters commit subjects, not only notes.** Subjects carry box names (8 of the same 199 match the hygiene box-name list) and owner message ids. Before writing the facts file, the collector runs the full 4.4 public-safe check over every line and drops what fails. 9-h plants a box name and a topic uuid in a subject. **7. Treat the digest lane's input as hostile.** Commit subjects are written by every lane, and the digest lane runs with bypass permissions. So: (a) the brief template marks the facts file as data, never instructions; (b) CI refuses any commit that touches `csi-spl-doc/blog/posts/**` together with any other path (the action's pathspec is one file); (c) the lane-mix chain for `blog-digest` is **mistral -> claude only**, never agy, grok or qwen (110 D2). Its input is pre-publication text whose only filter is a deny list, and a deny list cannot prove absence. **8. The release-note ban list is a secret: fail closed and never echo it.** It is a Secret Manager slot (`grep -n RELEASE_NOTE_BANS csi-spl-cnf/csi-spl/all.env.yaml` -> line 523, `csi-spl-hub-release-note-bans`), not a plain env var. `do_spl_blog_check` reads it through the per-env SA and exits 1 when it is unreadable or empty, in CI and on the box alike. A refusal names the file and line, never the pattern that matched, because the pattern itself is the secret. **9. Pictures get a narrow identity, not the project owner key.** The per-env project SA holds `roles/owner` (`gcp-003-configure-proj-sa-permissions.func.sh` line 34). Using it from a nightly agent cron and from an MCP tool that every lane can call gives each of them owner on the project. T006 adds a `blog-media` SA: `roles/aiplatform.user` (or a custom role with `aiplatform.endpoints.predict` only, if the panel prefers) plus `objectCreator` on the bucket alone. Its key is minted out of band like the relay key (doc 6.3). The wf 30 deploy identity gets `objectViewer` on that bucket only. The bucket gets uniform bucket-level access and public-access-prevention `enforced`, and a test fails on any `allUsers` binding. **10. Make the picture checks mechanical.** `do_spl_blog_image` sends `personGeneration: dont_allow` on every Imagen call, so "no real person" is not left to a prompt regex. It re-encodes to webp, which strips EXIF/XMP. `image` must match `^<post-id>(-og)?\.webp$`. Before copying, the wf 30 copy step checks the RIFF/WEBP magic bytes and the 300 KB limit. A key like `../x` or `$(…)` never reaches a `gcloud storage cp`. **Accepted risk, said aloud:** a lane can still skip the action, override the pre-push hook (`SPL_PREPUSH_OVERRIDE`, `grep -c SPL_PREPUSH_OVERRIDE csi-spl-iac/src/bash/run/check-pre-push.func.sh` -> 1) and land a bad post. Every other file in the repo has the same exposure today. Change 1 makes such a push a reported leak, and the spec does not claim more. **Q1 -> (a) Europe/Helsinki**, with `published` stored in UTC (`Z`) and the day computed in `env.blog.tz`, so that a DST change cannot split a day differently on the box and in CI. **Q2 -> (a) auto-publish**, provided changes 1-3 hold. A human review would not protect the public repo anyway, because the post is public once it is pushed, whether or not the site renders it. **Q3 -> (a) yes**, with change 9's dedicated SA and change 10's `personGeneration: dont_allow`. Without the narrow SA, choose (b): ship with no pictures rather than give the project owner key to a cron lane. | 1, 2, 3 (a-d), 4, 5, 6, 8 folded (3.5, 4.1-4.4, 5.2, 6.1, 6.2, 9). 7: (a), (b) folded; (c) reconciled with D-L: mistral writes -> agy reviews (final word, never drafts, sees only gated draft text) -> claude fallback writer (3.7). 9 not folded: moot under D-Q3 (Nano Banana, Gemini API key, no SA, no IAM); its bucket hardening moved to Q4 (a). 10 folded except `personGeneration: dont_allow` (an Imagen field): a fixed no-people instruction + the 4.4 prompt check, T006 sends a switch if the API has one. Q1 UTC `published` folded. |
| s111-4 | claude c-581 (integration) | **agree with changes** | Read on tree `043ebfac0`. **1. Blog pages must not run the app's head scripts: today every prerendered document calls the hub.** The global `app.head` puts the session probe (`fetch` of the auth URL, credentials included) and the `/config.json` fetch into every document (`grep -c "buildEarlySessionScript\|buildEarlyConfigScript" csi-spl-wui/nuxt.config.ts` -> 4). So 3.1 "a visitor's browser makes no API call" is false as drafted, and every crawler hit becomes a Cloud Run request. T003 strips them from `/blog/**` documents in the `prerender:generate` hook (or the blog route gets its own head). Test 9-c adds: the blog HTML holds no auth URL and no `config.json`. **2. Blog pages are noindex today.** `X-Robots-Tag: noindex, nofollow` is set on `**` in three places: the `<meta name="robots">` and `routeRules` in `nuxt.config.ts` (`grep -c 'noindex, nofollow' csi-spl-wui/nuxt.config.ts` -> 2), and `render-wui-firebase-json.sh`, which writes the deployed `firebase.json` (`grep -c noindex csi-spl-orc/src/bash/scripts/render-wui-firebase-json.sh` -> 1). G1 and 3.3 (crawlers, sitemap) need a `/blog/**` override in all three. 9-c checks it with `curl -sI <post url>` and the meta tag; do not reason about Firebase header precedence. **3. A post commit does not deploy, and a committed copy breaks the 6.2 cap.** wf 30 has a path allow-list (`grep -c csi-spl-doc .github/workflows/30_wui-build-deploy.yml` -> 0). /help works because the copy is committed under the WUI (`git ls-files csi-spl-wui/src/public/help-md \| wc -l` -> 24). If `blog-md/` is committed like that, `do_spl_blog_post` step 6 (post file only) reddens the `--check` test on every post. And the deploy then ships the committed copy, so a hand-committed 8th post is still rendered. Change: `sync-blog.mjs` runs inside `pnpm run generate`, and `src/public/blog-md/` is git-ignored like `i18n/.split/`. wf 30 `paths` gains `csi-spl-doc/blog/posts/**`. The cap then holds in the build that ships. **4. One route file, not three.** Each page adds a record to the routes module in the initial JS (CLE-77925). Trunk is already 109 B over 155 KB, and lane c-579 is fixing it. I believe, unchecked, that three records cost tens of bytes gzip. Use one `pages/blog/[...slug].vue` for `/blog`, `/blog/page/<n>` and `/blog/<id>`. Measure 9-e only on a tree after c-579 lands, and report the version, tree and n. **5. Chrome in English literals, no i18n keys.** The 3.1 "keys in 19 locales" rule costs bytes either way. Keys that reach the first-screen core catalogue (`split-catalogue.mjs`, P3-06) are initial bytes. Keys left in `more` render as raw keys on a cold `/blog` until `i18n-more` loads. The body is English and there is no `/fi/blog`, so English chrome matches. No `i18n/locales/*.json` edit, so no collision with the 109/075 i18n lanes. **6. The "Blog" link goes on `/login`, not `/`.** `/` is the signed-in product home (`isProductScreen` in `src/utils/signed-out-redirect.mjs`), not a public landing page. A signed-out visitor is sent to `/login` before `/` renders. Also, 109 T003 -> T007 -> T008 own `pages/index.vue` in a chain (109 tasks.md line 35). Put the link in the login layout footer beside privacy/terms. 111 T003 must name `pages/index.vue` as do-not-touch. **7. `CRON_TZ` does not exist on these boxes.** Debian `cron 3.0pl1` runs every line in the daemon's zone (`man 5 crontab \| grep -c CRON_TZ` -> 0; its LIMITATIONS section says so). The `box-crons.manifest` row runs hourly at `0 * * * *`. The action proceeds only when `TZ=<env.blog.tz> date +%H` is `23`, so a box in another zone still fires once, at the right hour. T008 files: the manifest row (`csi-spl-orc/cnf/box-crons/box-crons.manifest`), not `install-box-crons.func.sh`. **8. The 23:55 close must not re-check the lease.** The orch lease can move between 23:00 and 23:55 (failover, a box restart), and `orch-rotate` runs at :05 every hour. The 23:00 run writes a per-date marker with the lane id. The 23:55 step runs on the box that holds the marker and closes that lane. A spawn refused at the 40-window ceiling is a missed day, reported as a `note`, never retried. The weekly restart window (brief f0be2877: about 04:00 and 04:30 box-local, one per box) does not overlap 23:00-24:00, so there is no collision. **9. Test 9-n splits "landed" from "live".** wf 30 success runs took 3.4 / 4.0 / 6.1 min (min / median / max), not counting runner queue time (`gh run list --workflow 30_wui-build-deploy.yml --status success -L 10`, n = 10, master `64963b526..0019d5790`). A digest landing at 23:57 is live after midnight. Pass = the commit lands by 24:00 and is live by 00:15. **10. Keep posts out of 075 /docs.** `do_publish_docs` uploads every tracked `*.md` (`git ls-files -s -- '*.md'`; `grep -c blog csi-spl-orc/src/bash/run/publish-docs.func.sh` -> 0). An unpublished `draft: true` post would stay readable in /docs. T007 adds a `csi-spl-doc/blog/` skip there, as one line in its own commit. **11. Canonical goes to the apex.** wf 30's header says the site is also served on `<tenant>.<fqdn>` and `<site>.web.app`. `canonical`, `og:image`, the feed and the sitemap use the absolute base from `NUXT_PUBLIC_SITE_URL` (cnf), never the request host. **Q1 -> (a)** with change 7: one zone for the cron guard, the day window and the cap. **Q2 -> (a)**, given changes 1 and 3: the cap holds in the shipped build, and a takedown is live in about 4 min (change 9). **Q3 -> (a)**, kept off the critical path: T009 ships without pictures. The wf 30 copy step needs bucket read for the deploy identity: the SA key path has it (roles/owner); the WIF Hosting-deploy SA path needs `storage.objectViewer` on the media bucket. | 1, 2, 3, 4, 6, 7, 8, 9, 10, 11 folded (3.1, 4.1, 5.1, 6.1, 9-c, 9-e, 9-n). 5 reduced (D-L, msg 296582df wins): English literals only until the locale chrome lands (T013), then translated, keys in a blog-only lazy catalogue. Q3 note: pictures off the critical path, deploy-identity read is Q4 (a). |
| s111-5 | mistral m-595 (docs + panel) | **agree with changes** | **1. Treat the digest lane's input as hostile.** The facts file is data, not instructions. The brief template must mark it as such, and the lane-mix chain for `blog-digest` must be **mistral -> claude only** (never agy, grok, or qwen). This aligns with spec 110 D2 and the security panel's change 7. **2. Enforce the 7/day cap in `sync-blog.mjs`.** The cap must hold at build time, not just at publish time. `sync-blog.mjs` must refuse to render an 8th post for a day, even if committed by hand. This aligns with the security panel's change 3. **3. Privacy gate must run before the push.** The gate (4.4) must run in `do_spl_blog_post` and the pre-push gate. A post that fails the gate must never land on `origin/master`, as the repo is public. This aligns with the security panel's change 1. **4. Blog pages must not run the app's head scripts.** The prerendered `/blog/**` pages must not include the session probe or `/config.json` fetch. This aligns with the integration panel's change 1. **5. Keep posts out of 075 /docs.** `do_publish_docs` must skip `csi-spl-doc/blog/posts/**` to avoid publishing draft posts. This aligns with the integration panel's change 10. **Q1 -> (a) Europe/Helsinki** aligns with the owner's working day and avoids DST splits. **Q2 -> (a) Auto-publish with a one-action unpublish** is frictionless and aligns with the owner's preference for consensus-then-build. The gates (4.4) prevent leaks, and the takedown is fast (~4 min). **Q3 -> (a) Nano Banana (Gemini 2.5 Flash Image)** via the agent user's `~/.nano-banana/crs` key, as the owner decided (msgs 54180139, bfbd0b75). No GCP change, no dedicated SA, and no Imagen. | 1 folded, reconciled like s111-3 change 7 (agy reviews, claude fallback writer). 2, 3, 4, 5 folded (same as s111-3 3, 1 and s111-4 1, 10). Q3 Nano Banana = D-Q3. |

Links: [075](../075-docs-section/spec.md), [090](../090-marketing-automation/spec.md),
[091](../091-public-dataset-export/spec.md), [065](../065-release-notes-table/spec.md),
[044](../044-spool-open-source/spec.md), [061](../061-agent-id-rename/spec.md),
[092](../092-box-power-loss/), [107](../107-hours-tracking/spec.md), [109](../109-desktop-ui-refactor/spec.md),
[110](../110-mistral-vendor/spec.md).

<!-- version: 1.0.0 · updated: 2026-10-08 · last-edit: 2026-10-08T20:30:00Z -->
