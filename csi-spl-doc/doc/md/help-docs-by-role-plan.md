# Help docs by role: the plan

Owner request (HUM-10, t1 `5c430061`): "refactor the docs ... based on the
target audience for the docs on per human role basis". This file is Phase 1:
the roles, the audiences, the target tree, the page map and how the in-app Help
serves it. Phase 2 applies it to `csi-spl-doc/doc/help/` once the content
catch-up lane has landed. Every claim below was checked against origin/master
(`f7e190b3`); the code wins over any doc.

## 1. The roles (from the code)

The roles are rows seeded from `rbac.Defaults` in
`csi-spl-api/src/go/spool-hub-api/internal/rbac/rbac.go` (ids in `rbac.RoleIDs`).
The hub asks for a PERMISSION at each entry point, never for a role name, so an
audience is a set of permissions, not a list of names.

| role | permissions (`rbac.Defaults`) | reads help? |
|---|---|---|
| `biz_owner` | all 11, `TenantOwner: true` | yes |
| `admin` | all but `billing.manage` | yes |
| `product_owner` | `topics.read`, `notes.send`, `agents.command`, `channels.manage`, `audit.read` | yes |
| `developer` | `topics.read`, `notes.send`, `agents.command`, `channels.manage` | yes |
| `biz_customer` | same as `developer` (owner 2026-09-25, comment on the role consts) | yes |
| `regular_user` | same as `developer` (same comment) | yes |
| `tester` | `topics.read`, `notes.send` | yes |
| `pure_agent` | `topics.read`, `notes.send`, `agents.command` | no: an agent, not a reader |

Where each permission is enforced (`grep -rn 'rbac\.<Perm>' internal/hub`, tests excluded):

| permission | checked in | what a reader sees |
|---|---|---|
| `topics.read`, `notes.send` | `hub/view.go`, `hub/wui.go`, `hub/edit.go`, `hub/issues.go`, ... | reading and posting: every human role |
| `agents.command` | `hub/wui.go` (`allowed(... rbac.AgentsCommand)`) | sending work to an agent |
| `channels.manage` | `hub/channels.go`, `hub/channel_members.go` | creating channels, channel members |
| `members.invite` | `hub/members_admin.go`, `hub/tenant_settings.go` | Workspace settings, Members |
| `tenant.settings` | `hub/tenant_settings.go`, `hub/agent_lifecycle.go`, `hub/perf_summary.go`, `hub/issues.go` | Workspace settings: Agents, Vendor split, Channels, General, Performance |
| `members.roles` | `hub/rbac.go` | changing a member's role |
| `members.impersonate` | `hub/actas.go` | act as a member |
| `audit.read` | `hub/actas.go`, `hub/memberactivity.go`, `hub/box_stats.go` | another member's activity, box statistics |
| `billing.manage`, `keys.manage` | no hub route checks them yet (`grep -rn 'BillingManage\|KeysManage' --include=*.go` finds only `rbac.go`) | nothing yet: no help page until a screen exists |

The WUI gates the same way: `csi-spl-wui/src/utils/tenant-settings-nav.mjs`
(`TENANT_SETTINGS_SECTIONS`, each with its `perm`) shows a Workspace settings
section only when `/v1/view/me` lists its permission.

One more position is not a role: the **instance operator**, the `admin` of the
one operator workspace (`hub/operator_workspaces.go`, spec 074: the admin there,
not its `biz_owner`). Its few readers get a section on the admins' start page.

## 2. The audiences

Three audiences read different pages. A role reads every audience it qualifies for.

| audience | who qualifies (permission) | roles | what they do |
|---|---|---|---|
| **A. Everyone** | `topics.read` + `notes.send` | all seven human roles | sign in, read, post, reply in topics, search, issues, archive, settings, shortcuts |
| **B. People who run agents** | `agents.command` | `biz_owner`, `admin`, `product_owner`, `developer`, `biz_customer`, `regular_user` (not `tester`) | connect an agent, send it work, follow its task to a result, watch agents and boxes, write release notes |
| **C. Workspace admins and the owner** | `members.invite` or `tenant.settings` | `admin`, `biz_owner` (owner-only: `billing.manage`) | members and roles, Workspace settings, act as a member, the audit view; the instance operator |

`product_owner` is in A and B and also holds `audit.read`: their start page (B)
names the two screens that permission opens (member activity, box statistics).

Start page per role:

| role | start here | then |
|---|---|---|
| `tester` | `start-everyone` | the shared pages |
| `developer`, `biz_customer`, `regular_user`, `product_owner` | `start-running-agents` | `start-everyone` |
| `admin`, `biz_owner` | `start-workspace-admins` | `start-running-agents`, `start-everyone` |

## 3. The target help tree

The tree stays **flat**: `sync-help.mjs` copies only `^[a-z0-9-]+\.md$` from
the top of `doc/help/` (`helpFiles`, `readdirSync` with no recursion) and
`validHelpSlug` refuses a `/`. A sub-folder would vanish from the app with no
error. Audience shows in the index and the start pages, not in paths.

### 3.1 New pages (6)

| slug | audience | holds |
|---|---|---|
| `start-everyone` | A | the "start here" path: sign in, the screen, post, topics, search, settings, shortcuts, in reading order |
| `start-running-agents` | B | connect an agent, send it work, follow it, agents and boxes, release notes; the `product_owner` audit note |
| `start-workspace-admins` | C | members and roles, Workspace settings, act as a member, audit; owner-only section; instance operator section |
| `roles` | all | the role table from `rbac.Defaults` (section 1 above, in plain words), and how to see your own role |
| `workspace-settings` | C | split out of `user-settings` section 9: every `TENANT_SETTINGS_SECTIONS` section |
| `members-and-roles` | C | invite, edit, remove members, change a role, act as a member (Members section, `members.*` permissions) |

### 3.2 The index

`index.md` keeps its slug (it is `/help`). It becomes short: one paragraph on
what Spool is, then a "Start here" table (role -> start page, section 2), then
the shared pages grouped under A, B and C. The big ASCII layout diagram moves
to `interface-overview`. `sync-help.mjs` orders the left list by the index's
link order, so the start pages come first with no code change.

## 4. The page map (every current page)

All 20 current slugs stay. No page is deleted or renamed, so no redirect is needed.

| current page | audience | action | where its content goes |
|---|---|---|---|
| `index` | all | keep, rewrite | short intro + start-here table + grouped page list; ASCII diagram -> `interface-overview` |
| `getting-started` | A | keep, split | section 3 (roles) -> `roles`; the heading stays with one line linking `roles` |
| `interface-overview` | A | keep | gains the index's layout diagram |
| `omnibox-and-navigation` | A | keep | - |
| `channels-and-direct-messages` | A | keep | "Managing Channels" names `channels.manage` (not `tester`); the admin Channels list is in `workspace-settings` |
| `message-levels-and-topics` | A | keep | - |
| `message-actions-and-formatting` | A | keep | - |
| `global-search` | A | keep | - |
| `keyboard-shortcuts` | A | keep | - (`msg-shortcuts.mjs` and its unit test read its "Message shortcuts" section) |
| `how-to-post` | A (humans and agents) | keep | - (linked from the repo `CLAUDE.md` and 30 other places) |
| `issues` | A | keep | - |
| `archive` | A | keep | - |
| `events` | A | keep | - |
| `people` | A | keep | - |
| `user-settings` | A | keep, split | sections 1-8 stay; section 9 -> `workspace-settings`; the heading stays with one line linking it |
| `connect-an-agent` | B | keep | - (linked from `ConnectAgentGuide.vue`, 18 places, `help-connect-agent.tst.sh`) |
| `agent-collaboration` | B | keep | - |
| `agents` | B | keep | the list is visible to all; listed under B |
| `boxes` | B | keep | box statistics need `audit.read`: say so |
| `release-notes` | B (humans and agents) | keep | - |

Wrong today and fixed by the split (the code wins): `getting-started` section 3
says `product_owner` has "full system governance, billing" and lists no
`biz_customer` or `regular_user`; in `rbac.Defaults` `biz_owner` holds every
permission and `product_owner` holds five. `roles` is written from the code.

## 5. How the app serves it

| part | file | change |
|---|---|---|
| copy into the WUI | `csi-spl-wui/src/node/help/sync-help.mjs` | none: new flat pages are picked up; run it, then `--check` |
| page order | `helpFiles()` ranks by the index's `](./x.md)` order | none: the index order is the nav order |
| route | `csi-spl-wui/src/pages/help/[[page]].vue`, `/help/<slug>` | none for the tree |
| links | `csi-spl-wui/src/utils/help.mjs` `helpHref` | none; note: it drops `#anchor` in-app (`route(m[1])`), so a link into a section lands at the page top |
| coverage guard | `csi-spl-wui/tests/unit/help-settings-coverage.test.mjs` | reads `user-settings.md` for `TENANT_SETTINGS_SECTIONS`: point that half at `workspace-settings.md` |
| optional (2.3) | `[[page]].vue` index view | a "your start page" line from `/v1/view/me` permissions (`normalizeMe`, `utils/access.mjs`), only if small |

### 5.1 Links and anchors that must keep working

- Every slug stays, so every `/help/<slug>` and every repo path
  `csi-spl-doc/doc/help/<slug>.md` keeps working (most linked:
  `how-to-post` 30, `connect-an-agent` 18, `release-notes` 4,
  `getting-started` 3; counted with
  `grep -rnoE 'doc/help/[a-z0-9-]+\.md'` over the repo, help-md excluded).
- No link anywhere uses an anchor into a help page
  (`grep -rnoE 'help/[a-z0-9-]+\.md#'` -> 0), so a split keeps the old heading
  as a one-line stub only for readers, not for links.
- Tests that pin pages: `tests/e2e/help.test.mjs` (`/help/getting-started`
  link from the index, `/help/no-such-page`), `tests/e2e/help-two-panes.test.mjs`
  (`help-nav-archive`, at least 12 nav links), `tests/unit/help.test.mjs`,
  `tests/unit/msg-shortcuts.test.mjs` (`keyboard-shortcuts`),
  `csi-spl-iac/src/bash/tests/help-connect-agent.tst.sh`
  (`connect-an-agent`, `getting-started`). The index must keep linking
  `./getting-started.md`.

## 6. Phase 2 steps

1. Wait for the content lane (`help-docs-catchup-20261004.md` done, no
   `doc/help/` commit for 15 min), fetch, rebase.
2. Write `roles`, `workspace-settings`, `members-and-roles`, then the three start pages.
3. Split `getting-started` and `user-settings`; move the diagram; rewrite `index`.
4. Point `help-settings-coverage.test.mjs` at `workspace-settings.md`.
5. `node src/node/help/sync-help.mjs`, `pnpm run typecheck`, the unit help
   tests, `BASE_URL=<generated bundle> pnpm run test:e2e` for the help specs,
   `./run -a do_check_dist_hygiene`.
