# 173 Developing and tracking different software projects per workspace

Version: v0.1 (2026-11-09), analysis only: nothing below is built, and no
build issue is filed. Epic SPL-5152 · Issue SPL-5150 · Class feature · Kind specs_and_docs ·
Task `dispatch-07b2d7b2` · Placement slug
`c002-doc-multi-project-per-workspace-analysis` · Author c-486.

Number: `git ls-tree --name-only origin/master csi-spl-doc/specs/` ends at
`172-work-chain-enforcement`; the same listing over the 190 `origin/review/*`
and the `origin/wip/*` branches shows no `17[3-9]-*` or `18*-*` folder.

Tree: every claim about code was read on origin/master `c9a176a31`. Each
count is the output of the command beside it (n = 1 per command, static reads
of one tree). No prd read and no run of any lifecycle action on another repo
was made: **what happens at run time in another repo is judged from the code
unless a row says otherwise.**

Paths: `api/` = `csi-spl-api/src/go/spool-hub-api/internal/`, `orc/` =
`csi-spl-orc/src/bash/`, `sa/` = `orc/features/spawn-agents/`, `rdb/` =
`csi-spl-rdb/src/sql/postgres/spool-hub/`, `cnf` =
`csi-spl-cnf/csi-spl/all.env.yaml`. "Workspace" is the term here; "tenant"
appears only in code identifiers. `<WORKSPACE>` and `<ORG>` are placeholders.

## 1. The owner's words

HUM-10, prd t1 topic `07b2d7b2`, msg `7452bd8a` (2026-11-09 09:41:14Z),
verbatim: "now the spool-hub is fully integrated for the full lifecycle
development and tracking of the spool , but we need an analysis to find out
what everything we need to do to make it suitable for the development and
tacking of diferent software project per workspace - and create a separate
EPIC on that"

## 2. The answer in short

The spool can already **track a workspace's own issues and close them from
its own repo** (`lane-issue-and-docs.md` section 5), and specs 143 and 171
design the **read side** of commits, releases and deploys. Three things are
still missing, and no existing spec owns them:

1. **Nothing connects a registered project to the work.** The tables exist
   (`rdb/0266`), but no issue, discussion, lane or report names a project,
   and the box keeps a second, one-repo-per-workspace registry (G1).
2. **A lane cannot be launched into another repo by the normal path, and its
   seed would be wrong if it were** (G4).
3. **In another repo the quality chain does not run at all**: no pre-push
   gate, no CI, no required citation, no deploy record (G6, G7, G8, G10).

The rest is smaller, and section 5 orders it.

## 3. What already exists (not re-specified here)

| spec | covers | built on `c9a176a31`? | leaves open |
|---|---|---|---|
| 143 `releases-projects.md` | ER model workspace -> project -> repo, the projects drop box, report filters, access, six owner answers | B-1 only: `rdb/0266`, `0267`. `git grep -l 'repo_slug\|RepoSlug' origin/master -- 'csi-spl-api/src/go/*'` -> 2 test files, so the hub does not read it yet. B-2 is with other lanes | "Open work" (its Q6), issue to project link |
| 171 workspace-own-repo | one repo per workspace on the read side: ingest (poll, webhook, box push), GitHub credentials, scoped release and deploy tables, empty state | Only through 143 B-1. `git grep -c do_workspace_repo_register origin/master -- csi-spl-orc/src` -> nothing | Everything before the commit exists: how the code is written, gated and deployed |
| 074 operator workspace | one console to create and govern workspaces on an instance | In progress, per its header (not re-audited here) | Projects are not in it |
| 108 workspace-owned boxes | a workspace's own box and seats; OS-user isolation; switch `box_join_enabled`, default off | Described in its section 3.8 (not re-audited here) | Which project a box or seat works on |
| 113 workspace docs (qto) | per-workspace document tree in the hub, one-way md export | The actions `do_spl_doc_tree_check` and `do_spl_doctree_export_md` are on the tree (not re-audited further) | Docs per project; export into a project's repo (G12) |
| 172 work chain | discussion -> issue -> lane -> agent, no bare link | Evaluation only, per its header | A project as a link of that chain |

Also existing, and easy to miss: `lane-issue-and-docs.md` section 5 and
`sa/lib/workspace-repo.inc.sh` already carry a lane's **issue** through a
workspace's own repo (filing, closing from its commits, exit gate, live
proof). This spec builds on it.

## 4. Stage by stage

"Measured" is what the tree shows. "Needed" and "Size" are judgement. Size:
**S** one lane, **M** two or three lanes, **L** four or more lanes or a design
panel first. "Order" is the build order of section 5.

### G1 Project and repo registry (cross-cutting)

- **Measured.**
  - Two registries that do not know each other: hub `workspace_repos` and
    `software_projects` (`rdb/0266`), and the box file `workspace-repos.tsv`
    (`sa/lib/workspace-repo.inc.sh:14`).
  - The box file is one row per workspace: `wr_row` returns on the first row
    of a tenant (`workspace-repo.inc.sh:52-60`). The owner's ER model is many
    projects and many repos per workspace (143 msg `8262d099`).
  - `git grep -l project_slug origin/master -- csi-spl-rdb csi-spl-api/src
    csi-spl-wui/src csi-spl-orc/src` -> 3 files: the migration and two store
    tests. No orc script and no WUI file reads a project.
- **Gap.** A lane on a second repo of a workspace has no row to resolve to,
  and the hub's project is invisible to the box.
- **Needed.** The hub registry becomes the source; the box keeps only what is
  local to it (clone path, desk seat), keyed by repo. The box file stays
  private to the box, as `lane-issue-and-docs.md` section 5 requires.
- **Size M. Order 1.**

### G2 Idea and discussion

- **Measured.** Discussions are per workspace (RLS). Nothing names a project
  (G1's grep).
- **Gap.** In a workspace with two projects a discussion cannot say which one
  it is about, so the dispatcher has nothing to route on.
- **Needed.** An optional project on a discussion or its channel, defaulting
  to the workspace's default project. Whether a project is a channel, a tag or
  a field is owner question 2.
- **Size S once decided. Order 3.**

### G3 Spec

- **Measured.**
  - The location is pinned: `git grep -hE 'csi-spl-doc/specs' origin/master
    -- csi-spl-orc/src | wc -l` -> 168 lines in 53 files, comments included.
  - `spl_issue_create_epic_spec` needs a spec folder on origin/master for a
    t1 issue, and returns early for a workspace with a box-map row
    (`orc/run/spl-issue-create.func.sh:71`), so **a workspace's spec is
    checked by nothing**. `li_brief_epic_spec` passes such a brief the same
    way (`sa/lib/lane-issue.inc.sh:186`).
  - `do_spl_spec_import_issues` defaults to `$APP_PATH/csi-spl-doc/specs`
    (`orc/run/spl-spec-import-issues.func.sh:48`); `SPEC_DIR` overrides it.
  - The next spec number is found by hand: 172's header shows the method, and
    `git grep -n 'next free' origin/master -- csi-spl-doc/specs/README.md
    csi-spl-orc/src/bash/run` -> nothing.
- **Gap.** No rule for where a project's spec lives, and the "no issue without
  a spec" order is not enforced outside csi-spl.
- **Needed.** A per-repo spec root in the registry (default a documented path
  in that repo, or none for a project that keeps specs in qto docs), and the
  existing check reading it instead of returning early.
- **Size S. Order 4.**

### G4 Lane spawn and worktree

- **Measured.**
  - The launcher itself is repo-neutral: the repo comes from the workdir
    (`sa/scripts/spawn-core.inc.sh:199`), the worktree is `<repo>-wt/<id>`
    (`:236`).
  - The placer is not: every queued lane launches with
    `${SPAWN_PLACE_WORKDIR:-$APP_PATH}` (`orc/run/spl-spawn-place.func.sh:1304`),
    the checkout the action runs from. `grep -cE '\bwr_[a-z_]+|Workspace:'
    orc/run/spl-spawn-place.func.sh` -> 0: a brief's `Workspace:` line does
    not choose the clone.
  - The seed is guarded only by "has a worktree" (`spawn-core.inc.sh:418`), so
    a lane in another repo is told `cd csi-spl-orc ... do_spl_push_master`
    (`:431`) and `cd csi-spl-iac ... do_check_pre_push` (`:438`), directories
    that repo does not have. Only the developer-guide line tests for the file
    (`:437`).
  - `do_spl_push_master` takes `PUSH_WORKTREE` or `$PWD`
    (`orc/run/spl-push-master.func.sh:64`), so the action can serve another
    repo, but the seed does not tell a lane how.
- **Gap.** The queue cannot place a lane in a project's repo, and a lane
  placed there by hand gets instructions that fail on their first `cd`.
- **Needed.** A `Project:` or `Repo:` brief line the placer resolves to a
  clone through G1; seed sections rendered from the target repo (fleet actions
  addressed by the fleet checkout path, `PUSH_WORKTREE` set; the repo's own
  guide and test command from G6's profile). A placement to a box without that
  clone is refused, as the map's desk rule already refuses.
- **Size M. Order 2.**

### G5 Issue and epic numbering

- **Measured.**
  - One prefix and one counter per workspace: `issue_counters` has
    `tenant_id` as primary key (`rdb/0047_issues.sql:27-31`).
  - The default prefix is `SPL`, in the table and in the store
    (`api/store/issues.go:77`), so a workspace that never set one writes
    `SPL-n` keys for a product that is not the spool.
  - No project on an issue (G1's grep; `git grep -n project origin/master --
    'csi-spl-rdb/src/sql/postgres/spool-hub/*issue*'` -> one comment line).
- **Gap.** Two projects in one workspace share a number line and cannot be
  filtered apart.
- **Needed.** `project_slug` on issues (nullable, default project on read).
  Whether each project also gets its own prefix and counter is owner
  question 1; it decides between a small column and a change to how every key
  is parsed.
- **Size S with a shared prefix, L with one prefix per project. Order 3.**

### G6 Review, push and the pre-push gate

- **Measured.**
  - `sa/hooks/pre-push:211-217`: with no `csi-spl-iac/run` in the tree the
    hook logs `SKIP not-the-spool-tree` and lets the push through. **So the
    deploy-gate and the guide ack do not run in another repo.** The non-ff
    refusal sits earlier, at `:78-85`.
  - `check-pre-push.func.sh` names its parts by csi-spl directory:
    `grep -cE 'csi-spl-[a-z]+'` on the file -> 80 lines.
  - Review: `do_spl_review_line_check` has `REVIEW_LINE_REPO`, and for another
    repo's worktree "only the commands are checked"
    (`spl-review-line-check.func.sh:45-46`); the e2e rule is for `csi-spl-wui/`
    only (`:61`). The R7 flow itself (`review/<slug>` branches,
    `do_spl_review_go`) reads the fleet's own brief store and was not traced
    through another repo.
- **Gap.** Another repo has no gate, and the review proof is weaker there.
- **Needed.** A small per-repo **gate profile** kept in that repo (build,
  test, lint commands; trunk; deploy targets). The hook runs the profile when
  there is one, and the fleet-wide checks that are not about csi-spl
  (identity, no AI trailers, secrets scan, issue citation) always. Whether a
  repo with no profile may be pushed to is owner question 3.
- **Size M. Order 2.**

### G7 CI

- **Measured.** `.github/workflows` holds 38 files; 36 name `csi-spl`; 2 use
  `workflow_call`, so there is no reusable pipeline for another repo.
  `GCP_KEY_CSI_SPL` appears on 83 workflow lines. The gate-history report
  takes its repo from the checkout's remote (`do_report_ci_gate`, its header),
  but only runs where someone runs it. No table or action found in this
  analysis records another repo's CI runs.
- **Gap.** Each project writes CI from nothing, and a red run there reaches no
  one in the spool.
- **Needed.** A CI template set a project copies or calls (its own secrets,
  never csi-spl's), and a per-repo CI status read through the GitHub App of
  spec 171 Q3. Runners are owner question 4.
- **Size M. Order 5.**

### G8 Deploy

- **Measured.**
  - `do_spl_deploy_record` requires `DEPLOY_COMPONENT` "hub or wui" and takes
    no workspace (`grep -n 'tenant\|workspace\|WORKSPACE'` on the file -> no
    line). `rdb/0267` has added `tenant_id` and `repo_slug` with a csi-spl
    default and dropped the component CHECK, so the table is ready and the
    writer is not.
  - `do_check_deploy_lag` works on `$APP_PATH` and reads workflow 30's paths
    (`check-deploy-lag.func.sh:78,101`).
  - The one non-spool deploy path found is `do_deploy_hosted_site` (static
    sites from cnf step 021). `do_spl_desk_live_proof` already takes
    `LIVE_REPO`.
- **Gap.** A project's deploy is unrecorded, so "done means deployed on dev
  and prd" cannot be proven for it, beyond the live-proof check.
- **Needed.** A deploy-report call a project's pipeline makes (repo, env,
  component, version, sha, per spec 171's box push pattern), and the lag check
  driven by that record instead of a workflow file.
- **Size M. Order 5.**

### G9 Release notes and versions

- **Measured.** Designed by 143 section 5 and 171 section 3.4, and not built
  beyond B-1 (section 3). `do_release_version` has `RELEASE_REMOTE` and
  `RELEASE_TRUNK`; per the header of `orc/run/release-version.func.sh` its
  callers are the deploy jobs of workflows 20 and 30.
- **Gap.** None new for the read side. Whether a project gets the minted
  odometer version or keeps its own tags: 143 section 5 says tags.
- **Needed.** Nothing beyond 143 B-2 to B-9. **Not re-specified.**
- **Size 0 here. Order: after 143.**

### G10 Commit links

- **Measured.**
  - The gate is one workspace, one prefix: cnf `commit_issue_tenant: t1` and
    `commit_issue_prefix: SPL` (`cnf:726-727`), run by workflow 25 on this
    repo only. The action already takes `COMMIT_LINKS_REPO`, `_TENANT` and
    `_PREFIX` (`orc/run/spl-commit-links-check.func.sh:41-44`).
  - Chat links use one instance-wide `repo_web_url` (`cnf:1583`); 143 section
    4.3 accepts primary-repo-only links as a v1 limit.
  - The closer already has a workspace mode (`lane-issue-and-docs.md` 5.4).
- **Gap.** Outside csi-spl the "every commit cites an issue" rule is not
  enforced. A hash from a non-primary repo links to the wrong repo (known).
- **Needed.** The check in the G6 profile, per repo. Whether it is mandatory
  for a project is owner question 3; 143 section 5 already made release-note
  trailers optional there, and that decision stands.
- **Size S after G6. Order 4.**

### G11 Status and reports

- **Measured.** Reporting tabs `issues`, `posts` and `lanes` are `ready:
  false` (`csi-spl-wui/src/utils/reporting-tabs.mjs:39-42`). `fleet_lanes` has
  a free-text `repo` (`rdb/0096_fleet_lanes.sql:20`) and no project. 143 Q6
  left open work out of v1 because nothing links an issue to a project.
- **Gap.** There is no per-project "what is open, who works on it, what
  shipped".
- **Needed.** After G5, a project filter on the issue and lane reads and one
  per-project status view. The 143 Q6 answer was "not yet", so this reopens
  it only when G5 lands.
- **Size M. Order 6.**

### G12 Docs

- **Measured.** The file export is driven by `csi-spl-doc/doc/md/qto-docs.tsv`
  (292 lines), and a workspace's export into a private repo is named in the
  public cnf (`docs.private_repos`, `cnf:906`), the place 143 section 4.5 says
  a customer's repo must not appear. Help links use one instance-wide
  `repo_help_path` (`cnf:1586`).
- **Gap.** Docs have no project, and exporting to a customer's repo needs a
  public-cnf entry.
- **Needed.** Move that mapping to the registry of G1; an optional project on
  a doc tree root.
- **Size S. Order 6.**

### G13 Agent instructions and access (cross-cutting)

- **Measured.** The fleet rule files are rendered from
  `orc/features/spool-install/assets/claude/claude-md/`, among them
  `10-push-and-deploy.md`. `landed_repos` in the public cnf (`cnf:1559`) lists
  three Csitea repos.
- **Judged.** A project with other conventions (PRs, one environment, another
  host) gets csi-spl's standing orders in every seed. Spec 108's switch keeps
  a workspace's own boxes off by default.
- **Needed.** The fleet rules split into "any repo" and "csi-spl only", and
  the G6 profile states the project's branching and deploy rules.
- **Size M. Order 4.**

## 5. Order

| order | gaps | why here |
|---|---|---|
| 1 | G1 registry | Everything else resolves through it |
| 2 | G4 placement and seed, G6 gate profile | Makes a lane in another repo possible and safe; one pilot project can start here |
| 3 | G5 issue project, G2 discussion project | Needs owner questions 1 and 2 |
| 4 | G3 spec root, G10 citation, G13 rules | Same chain as csi-spl's, read from the profile |
| 5 | G7 CI, G8 deploy | The heaviest; a pilot shows which template is right |
| 6 | G11 reports, G12 docs | Read side, last |
| parallel | G9 = spec 143 B-2..B-9 | Already in build, not this epic's |

Judged total: 13 gaps, one of them (G9) empty, roughly 15 to 25 lanes if
owner question 1 stays a shared prefix. This is an estimate from the sizes
above, not a measurement.

## 6. Measured against judged

- **Measured** (reproducible on `c9a176a31`): every `file:line`, every count,
  and section 3's built / not built column except where it says "not
  re-audited".
- **Judged**: every "Needed", "Size", "Order" and the total; the runtime
  behaviour in another repo, because nothing was executed there; and that the
  seed's `cd` would fail (read from the seed text and the fact that those
  directories are csi-spl's).
- **Not checked**: the two live rows of a box's `workspace-repos.tsv` beyond
  counting them, prd data, spec 074, 108 and 113 build state, and the R7 flow
  on another repo.

## 7. Questions only the owner can answer

1. **Issue keys**: does each software project get its own prefix and number
   line (`WEB-12`, `API-12`), or does a workspace keep one line with a project
   field? Recommended: one line per workspace with a project field; it is far
   smaller, and a workspace can already set its prefix.
2. **What is a project in the discussion rail**: a channel per project, a tag
   on a topic, or a field set by the dispatcher? Recommended: a field with a
   workspace default, so one-project workspaces see no change.
3. **How strict is the chain in a customer's repo**: must every commit there
   cite an issue and pass a gate (as csi-spl), or is it per project? Spec 143
   made release-note trailers optional there. Recommended: per project, on by
   default.
4. **Whose machines run a project's CI and whose credentials deploy it**: the
   fleet's runners, or GitHub-hosted runners and the workspace's own keys?
   Recommended: GitHub-hosted and the workspace's own keys; csi-spl's runners
   and keys stay csi-spl's.
5. **Branching**: may a project use pull requests or another branching model,
   or do all projects follow trunk-only? Recommended: the profile states it,
   trunk-only as the default.
6. **Who can start a lane on a project**: only the operator and the
   dispatcher as today, or the workspace's own admins, paying from which
   agent quota? Spec 143 kept registration operator-only. Recommended:
   operator only until a pilot has run.
7. **The pilot**: which real project goes first? Recommended: one of the
   repos already in a box map, since its issue flow already works.

<!-- version: 0.1 · updated: 2026-11-09 -->
