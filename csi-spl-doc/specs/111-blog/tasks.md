# 111 Blog: tasks

Authority for what is built. `spec.md` holds the behaviour; this file
follows its sections 3-6. Each task names its layer, its dependency, the
files it owns, and a Done line with its test pair from `spec.md` section 9.
Status vocabulary: `../README.md` item 3 (`[x]` Implemented, `[~]` Partial /
in progress in a live lane, `[ ]` Planned).

Version **v0.1**: the draft. Build starts only after the review panel agrees
(consensus-then-build, one mistral seat per spec 110 D5).

**Path prefixes:**

- `WUI/` is `csi-spl-wui/`.
- `RUN/` is `csi-spl-orc/src/bash/run/`.
- `OT/` is `csi-spl-orc/src/bash/tests/`.
- `POSTS/` is `csi-spl-doc/blog/posts/`.

**Owner questions** (`spec.md` section 10) shape these tasks:

- **Q1 (the clock)** sets the cnf `env.blog.tz` value in T001.
- **Q2 (review)**: under (b), T008 writes `draft: true` and the owner flips
  it.
- **Q3 (picture vendor)** gates T006. Without it, posts ship with no
  picture.

## Order

1. T001 (cnf) first.
2. T002..T005 are independent lanes with disjoint files.
3. T006 needs Q3 and the owner's go for the API enable.
4. T007 (the post action + MCP) needs T004.
5. T008 (digest) needs T004, T007 and T001.
6. T009 (first posts) needs T002..T004 and T007 live on prd.
7. T010 (first live digest) is last.

## Tasks

- [x] T000 **doc** (c-589): `spec.md` + this file, v0.1.
- [ ] T001 **cnf** (needs Q1). Adds `env.blog.{tz, cap_per_day: 7,
  digest_reserved: 1, max_words: 450, digest_at: "23:00"}` and
  `env.blog.media_bucket`.
  - Files: `csi-spl-cnf/csi-spl/all.env.yaml`; the rendered `dev`/`prd`
    env json.
  - Done: `ENV=<env> ./run -a do_tpl_gen` + `git diff --exit-code`.
- [ ] T002 **wui sync** (needs T001). Builds `sync-blog.mjs` (4.1, 4.2):
  frontmatter validation, the cap of 7 per publish day, build-time render
  with the `MarkdownBlock.vue` sanitiser rules, `index.json` + fragments,
  and `--check`.
  - Files: `WUI/src/node/blog/sync-blog.mjs` (*new*),
    `WUI/tests/unit/blog-sync.test.mjs` (*new*), `WUI/src/public/blog-md/`
    (generated).
  - Done: 9-a and 9-l.
- [ ] T003 **wui pages** (needs T002). Builds `pages/blog/index.vue`,
  `pages/blog/[id].vue` and `/blog/page/<n>`. The prerender list is built
  from `index.json`, and blog routes are left out of the locale copies.
  Also: `useHead` Open Graph tags, chrome i18n keys in 19 locales, dark and
  light, and one `<a href="/blog">` on `/`.
  - Files: `WUI/src/pages/blog/**` (*new*), `WUI/nuxt.config.ts` (the
    prerender list only), `WUI/src/utils/locale-routes.mjs`,
    `WUI/i18n/locales/*.json`, `WUI/tests/e2e/blog.test.mjs` (*new*;
    extend an existing e2e file instead if the shard-pack control reddens).
  - Done: 9-c, 9-d, 9-e (the delta is in the report) and 9-f.
- [ ] T004 **orc check** (needs T001). Builds `do_spl_blog_check` (4.4), and
  makes the pre-push gate run it when `csi-spl-doc/blog/**` changes.
  - Files: `RUN/blog-check.func.sh` (*new*),
    `OT/blog-check.tst.sh` (*new*), the pre-push part table.
  - Done: 9-b, every control.
- [ ] T005 **feed + sitemap** (needs T002). Builds `/blog/feed.xml` (Atom),
  `/sitemap.xml` and `/robots.txt`, generated at build from `index.json`.
  - Files: `WUI/src/node/blog/feed.mjs` (*new*) and its unit test.
  - Done: 9-j.
- [ ] T006 **media** (needs Q3 + the owner's go). Covers:
  - the terraform step for `csi-spl-<env>-blog-media` (private);
  - the Vertex AI API enable and the SA role;
  - `do_spl_blog_image` (per-env SA, `--account`; webp 1600x900 + a
    1200x630 crop);
  - the wf 30 step that copies a post's pictures into
    `.output/public/blog/img/`;
  - quoting the price page and the licence terms into `spec.md` 5.4.
  - Files: `csi-spl-iac/src/terraform/<next>-gcs-blog-media/` (*new*),
    `RUN/blog-image.func.sh` (*new*), `OT/blog-image.tst.sh` (*new*), the
    wf 30 workflow (the copy step only).
  - Done: 9-i; `terraform plan` then apply with the owner's go, on dev and
    prd.
- [ ] T007 **post action + MCP** (needs T004). Builds `do_spl_blog_post`
  (6.1): the early cap refusal (exit 3), `published`/`author` stamping,
  the picture call, the check, commit and push, and a retry on a push race.
  Also `BLOG_EDIT=1` and `do_spl_blog_unpublish`. Adds the MCP tool
  `blog_post` to the box spool MCP server.
  - Files: `RUN/blog-post.func.sh`, `RUN/blog-unpublish.func.sh` (*new*),
    `OT/blog-post.tst.sh` (*new*), the MCP tool file in `csi-spl-api` (one
    new tool, its test).
  - Done: 9-k and 9-m.
- [ ] T008 **digest** (needs T001, T004 and T007). Builds:
  - `do_spl_blog_digest_collect` (5.2, allow-listed sources only);
  - `do_spl_blog_digest`: the lease guard, idempotency, quiet day, the
    spawn via `do_spl_lane_mix` kind `spec`, and the 23:55 deadline close;
  - the brief template;
  - the `blog-digest` entry in `do_install_box_crons`, with `CRON_TZ` from
    cnf.
  - Files: `RUN/blog-digest.func.sh`, `RUN/blog-digest-collect.func.sh`,
    `csi-spl-orc/src/bash/features/blog/blog-digest-brief.md` (*new*),
    `OT/blog-digest.tst.sh` (*new*), `RUN/install-box-crons.func.sh` (one
    entry).
  - Done: 9-g and 9-h; `DRY_RUN=0 BOX_CRONS_ONLY=blog-digest ./run -a
    do_install_box_crons` on each box.
- [ ] T009 **first posts** (needs T002-T004 and T007 on prd). Publishes
  the three candidates of `spec.md` section 8 through `do_spl_blog_post`.
  - Files: `POSTS/<yyyy-mm-dd>-*.md` (3 *new*).
  - Done: each one is on `https://<BASE_DOMAIN>/blog/<id>` with JS off.
- [ ] T010 **live digest** (needs T008 and the cron installed). Waits for
  the first night.
  - Done: 9-n. The post's sha and `do_release_note_link` are reported to the
    dispatcher.

<!-- version: 0.1.0 · updated: 2026-10-08 · last-edit: 2026-10-08T19:05:38Z -->
