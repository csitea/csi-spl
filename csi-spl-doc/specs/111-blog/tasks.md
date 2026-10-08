# 111 Blog: tasks

Authority for what is built. `spec.md` holds the behaviour; this file
follows its sections 3-6. Each task names its layer, its dependency, the
files it owns, a vendor and box hint, and a Done line with its test pair
from `spec.md` section 9. Status vocabulary: `../README.md` item 3 (`[x]`
Implemented, `[~]` Partial / in progress in a live lane, `[ ]` Planned).

Version **v1.0**: the panel (s111-2..s111-5) agreed with changes, the owner
answered, and the changes are folded (`spec.md` sections 0 and 11). Build
may start.

**Path prefixes:**

- `WUI/` is `csi-spl-wui/`.
- `RUN/` is `csi-spl-orc/src/bash/run/`.
- `OT/` is `csi-spl-orc/src/bash/tests/`.
- `POSTS/` is `csi-spl-doc/blog/posts/`.

**Owner answers** (`spec.md` sections 0 and 10):

- **D-Q1:** Europe/Helsinki is the blog day. T001 sets `tz: Europe/Helsinki`.
- **D-Q2:** auto-publish after the gates, `do_spl_blog_unpublish` takes a
  post down. No task has a review branch.
- **D-Q3:** Nano Banana (Gemini 2.5 Flash Image) through the Gemini API
  with the owner's key in `~/.nano-banana/crs` (T011). No GCP change for
  the model: no Vertex enable, no SA, no IAM, no terraform.
- **D-L:** every post in all supported locales; agy has the final word
  (T012, T013).
- **Q4 (open):** where pictures are stored. Until it is answered, posts
  ship without pictures (T006b waits).

**Rule for the UI tasks (owner msg 38cb94ad, verbatim: "as the code already
exists in another project , it has to be only copy pasted and adapted
..."):** T003 and T005 port a sibling project's blog (spec 047/049) files
and adapt them to this spec; they do not redesign. Those lanes run on the
drafting box, where the sibling is readable (read-only). csi-spl files never
name the sibling, its paths or its hosts: say "a sibling project's blog
(spec 047/049)".

**Vendor hints** follow spec 110 D5/D2: doc and low-level coding are
mistral first; the hardest coding and anything with secrets is claude.
Multilingual text gets agy's review last (repo language rule).

## Order

1. T001 (cnf) first.
2. T002..T005 and T011 are independent lanes with disjoint files.
3. T006 needs T011.
4. T007 (the post action + MCP) needs T004 and T006.
5. T012 (translation) needs T004 and T007; T013 (locale chrome) needs T003.
6. T008 (digest) needs T001, T004, T007 and T012.
7. T009 (first posts) needs T002..T005, T007 and T012 live on prd.
8. T010 (first live digest) is last.
9. T006b waits for Q4.

## Tasks

- [x] T000 **doc** (c-589 v0.1, c-584 v1.0): `spec.md` + this file.
- [x] T001 **cnf** (needs D-Q1, given). Adds `env.blog.{tz: Europe/Helsinki,
  cap_per_day: 7, digest_reserved: 1, max_words: 450, digest_at: "23:00",
  locales_from: i18n}`.
  - Vendor: mistral. Box: any.
  - Files: `csi-spl-cnf/csi-spl/all.env.yaml`; the rendered `dev`/`prd`
    env json.
  - Done: `ENV=<env> ./run -a do_tpl_gen` + `git diff --exit-code`.
- [ ] T002 **wui sync** (needs T001). Builds `sync-blog.mjs` (4.1, 4.2):
  per-locale frontmatter validation; the cap of 7 per day with the day and
  order from git (6.2: back-dating, a fake digest, a late draft flip, an
  edit that changes `id`); fragments only through `markdownToHtml` /
  `treeToHtml`; `--check` refusing `<script`, `on*=`, `javascript:` and
  `data:` URLs; run inside `pnpm run generate`; `src/public/blog-md/`
  git-ignored; wf 30 `paths` gains `csi-spl-doc/blog/posts/**`; the same
  refusal in `render-wui-firebase-json.sh` for `/blog/**` pages.
  - Vendor: claude (sanitiser and cap are correctness-critical). Box: any.
  - Files: `WUI/src/node/blog/sync-blog.mjs` (*new*),
    `WUI/tests/unit/blog-sync.test.mjs` (*new*), `WUI/.gitignore`,
    `WUI/package.json` (the generate script), the wf 30 workflow (`paths`
    only), `csi-spl-orc/src/bash/scripts/render-wui-firebase-json.sh` (the
    blog refusal only).
  - Done: 9-a, 9-l and the 9-c script controls.
- [ ] T003 **wui pages** (needs T002). Ports the sibling project's blog
  pages (spec 047/049) into ONE route `pages/blog/[...slug].vue` for
  `/blog`, `/blog/page/<n>` and `/blog/<id>`, in every locale. Also: the
  prerender list from `index.json`; blog routes in the locale copies
  (CLE-77925 check exact); the `en` fallback with `lang="en"`; `useHead`
  Open Graph + canonical + hreflang from `NUXT_PUBLIC_SITE_URL`; the
  session-probe and `config.json` scripts stripped from `/blog/**` in
  `prerender:generate`; the `noindex` override in the meta, `routeRules`
  and `render-wui-firebase-json.sh`; dark and light; the "Blog" link in the
  `/login` layout footer. Chrome in English literals until T013.
  - Vendor: mistral (port and adapt). Box: the drafting box.
  - Files: `WUI/src/pages/blog/**` (*new*), `WUI/nuxt.config.ts` (prerender
    list, head strip, blog `routeRules`), `WUI/src/utils/locale-routes.mjs`,
    the login layout footer, `csi-spl-orc/src/bash/scripts/render-wui-firebase-json.sh`
    (the `/blog/**` header only), `WUI/tests/e2e/blog.test.mjs` (*new*;
    extend an existing e2e file instead if the shard-pack control reddens).
  - Do NOT touch: `WUI/src/pages/index.vue` (spec 109 owns it),
    `WUI/i18n/locales/*.json`.
  - Done: 9-c, 9-d, 9-e (measured on a tree past the 155 KB fix; version,
    tree and n in the report) and 9-f.
- [ ] T004 **orc check** (needs T001). Builds `do_spl_blog_check` (4.4):
  every row, including the hex-token resolve on `origin/master`, the
  fail-closed secret ban list that never echoes a pattern, the
  `agy_review` stamp, and the CI commit-shape check. The pre-push gate runs
  it when `csi-spl-doc/blog/**` changes.
  - Vendor: claude (reads a secret). Box: any.
  - Files: `RUN/blog-check.func.sh` (*new*), `OT/blog-check.tst.sh` (*new*),
    the pre-push part table.
  - Done: 9-b, every control.
- [ ] T005 **feed + sitemap** (needs T002). Ports the sibling project's
  feed (spec 047/049): `/blog/feed.xml` (Atom), `/sitemap.xml` with
  hreflang alternates, and `/robots.txt`, generated at build from
  `index.json`, absolute URLs from `NUXT_PUBLIC_SITE_URL`.
  - Vendor: mistral (port and adapt). Box: the drafting box.
  - Files: `WUI/src/node/blog/feed.mjs` (*new*) and its unit test.
  - Done: 9-j.
- [ ] T006 **picture** (needs T011). Builds `do_spl_blog_image`: the Gemini
  API call (Nano Banana) with the key from `~/.nano-banana/crs` passed as a
  header from a file descriptor; the fixed no-people/no-logo/no-text
  instruction (and a person switch, if the API has one); re-encode to webp
  1600x900 + the 1200x630 crop; `image` matching `^<post-id>(-og)?\.webp$`;
  a missing key or a vendor error leaves the post without a picture, exit
  0. Quotes the Gemini API price page and the generated-image terms into
  `spec.md` 5.4. No terraform, no GCP change.
  - Vendor: claude (uses a secret). Box: any box with the key.
  - Files: `RUN/blog-image.func.sh` (*new*), `OT/blog-image.tst.sh` (*new*).
  - Done: 9-i (stubbed vendor), plus one real picture on the drafting box.
- [ ] T006b **picture store + deploy copy** (waits for Q4). Under Q4 (a):
  the private per-env bucket by a terraform step (uniform access,
  public-access-prevention enforced, an `allUsers` test, `objectViewer`
  for the wf 30 deploy identity only); the plan shown to the owner, the
  apply only on the owner's go, through the make / tf-runner path. Then
  the wf 30 step that checks RIFF/WEBP magic bytes and the 300 KB limit and
  copies the pictures into `.output/public/blog/img/`.
  - Vendor: claude. Box: the main checkout's box (the one infra stack).
  - Files: `csi-spl-iac/src/terraform/<next>-gcs-blog-media/` (*new*), the
    wf 30 workflow (the copy step only), its test.
  - Done: 9-i copy controls; `terraform plan` on dev and prd, apply after
    the owner's go.
- [ ] T007 **post action + MCP** (needs T004, T006). Builds
  `do_spl_blog_post` (6.1): the early cap refusal (exit 3), UTC
  `published` and `author` stamping, `posts/en/<id>.md`, the picture call,
  the check, a one-path commit and push, a retry on a push race, and the
  translation queue. Also `BLOG_EDIT=1` (keeps `id`, `published`, `author`;
  author or owner only) and `do_spl_blog_unpublish` (every locale copy).
  Adds the MCP tool `blog_post` (markdown as a string, the author from
  `Options.Seat`, exit 78 unseated). Adds a `csi-spl-doc/blog/` skip to
  `do_publish_docs`, as one line in its own commit.
  - Vendor: claude. Box: any.
  - Files: `RUN/blog-post.func.sh`, `RUN/blog-unpublish.func.sh` (*new*),
    `OT/blog-post.tst.sh` (*new*), the MCP tool file in `csi-spl-api` (one
    new tool, its test), `RUN/publish-docs.func.sh` (one line).
  - Done: 9-k and 9-m.
- [ ] T008 **digest** (needs T001, T004, T007, T012). Builds:
  - `do_spl_blog_digest_collect` (5.2: allow-listed sources, every line
    filtered by the 4.4 public-safe and hex-token checks);
  - `do_spl_blog_digest`: the hourly `TZ=<env.blog.tz>` 23 guard, the lease
    guard, idempotency, quiet day, the per-date marker, the writer spawn
    (mistral, claude as the fallback writer), the agy review of the `en`
    post, and the 23:55 close on the marker's box;
  - the brief template, marking the facts file as data;
  - the `blog-digest` row in the box-crons manifest at `0 * * * *`.
  - Vendor: claude. Box: any (the lease decides where it runs).
  - Files: `RUN/blog-digest.func.sh`, `RUN/blog-digest-collect.func.sh`,
    `csi-spl-orc/src/bash/features/blog/blog-digest-brief.md` (*new*),
    `OT/blog-digest.tst.sh` (*new*),
    `csi-spl-orc/cnf/box-crons/box-crons.manifest` (one row).
  - Done: 9-g and 9-h; `DRY_RUN=0 BOX_CRONS_ONLY=blog-digest ./run -a
    do_install_box_crons` on each box.
- [ ] T009 **first posts** (needs T002..T005, T007, T012 on prd; owner msgs
  3265df8d, 9d95860f). 2-3 `news` posts about 2026-10-08's features
  (`spec.md` section 8), published with the first deploy of /blog through
  `do_spl_blog_post`, inside the 7/day cap. Post #1's angle: European AI
  sovereignty, a French vendor, open tooling (Debian); factual, every claim
  about the vendor backed by a public source. Every fact cites its sha.
  Matrix-only and hygiene rules apply (no personal names, no box names, no
  workspace data).
  - Vendor: mistral writes (doc kind, D5), agy reviews last. Box: any.
  - Files: `POSTS/en/<yyyy-mm-dd>-*.md` (2-3 *new*) and their locale
    copies from T012.
  - Done: each one is on `https://<BASE_DOMAIN>/blog/<id>` with JS off, and
    in every locale.
- [ ] T010 **live digest** (needs T008 and the cron installed). Waits for
  the first night.
  - Vendor: claude (watch and report). Box: the lease holder.
  - Done: 9-n. The post's sha and `do_release_note_link` are reported to the
    dispatcher.
- [ ] T011 **Nano Banana key** (D-Q3). A named action
  `do_set_nano_banana_key`, modelled on `do_set_mistral_key` (spec 110):
  reads the key from a file input (on the drafting box: the box user's
  `~/.gemini/.csi/api_key`; never a pane paste); writes the agent user's
  `~/.nano-banana/crs` as ONE line `GEMINI_API_KEY=<key>`, mode 600 in a
  700 dir, atomically; never in argv, an exported env var, a log or git;
  `TO_BOX=<box>` over ssh stdin; masked output only (length + last 4).
  - Vendor: claude (secret). Box: the drafting box.
  - Files: `RUN/set-nano-banana-key.func.sh` (*new*),
    `OT/set-nano-banana-key.tst.sh` (*new*).
  - Done: 9-p, with the planted-echo control.
- [ ] T012 **translation + agy review** (needs T004, T007; D-L). Builds
  `do_spl_blog_translate`: from an agy-reviewed `en` post, the writer
  (mistral, claude fallback) makes the 18 locale copies; an agy seat
  anywhere in the fleet (`LANE_MIX_KIND=i18n`) reviews and corrects them
  and stamps `agy_review`; the copies pass 4.4 and land as ONE commit with
  only that post's locale files. No agy answer: nothing lands, the `en`
  page stays. Not a publication (no cap count).
  - Vendor: claude builds the action; the texts are mistral + agy. Box: any.
  - Files: `RUN/blog-translate.func.sh` (*new*), `OT/blog-translate.tst.sh`
    (*new*).
  - Done: 9-o.
- [ ] T013 **locale chrome** (needs T003; D-L). Replaces T003's English
  chrome literals with keys in a blog-only lazy catalogue for all 19
  locales, loaded by the blog route chunk, never the first-screen core.
  agy reviews the texts last.
  - Vendor: mistral, then agy review. Box: any.
  - Files: the blog catalogue files (*new*), `WUI/src/pages/blog/**` (the
    literals only).
  - Done: 9-e stays <= 100 B; 9-f in two locales.

<!-- version: 1.0.0 · updated: 2026-10-08 · last-edit: 2026-10-08T20:30:00Z -->
