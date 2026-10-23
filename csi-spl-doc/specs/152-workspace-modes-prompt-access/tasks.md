# 152 tasks: the configurable role x action list

Build rows for [spec.md](spec.md) v0.3. Nothing is built before the owner
has checked spec section 9; each row then gets its own issue (the
dispatcher files them), and an action the owner unticks is dropped from
every row. One small task per row. Paths as in the spec (`api/`, `hub/`,
`store/`, `rbac/`, `rdb/`, `wui/`).

| row | depends | files (only these) | does | proves (spec section 4) |
|---|---|---|---|---|
| B1 | - | `rdb/<NNNN>_tenant_role_grants.sql` (number taken at build time) | the 23 new `rbac_permissions` rows and their system grants = the "today" column of spec 3.1 (`demo_user` too for the five `agents.*` ids); the table `tenant_role_grants`, FORCE RLS with `tenant_scope` and `operator_scope` (as rdb 0214); applied on dev, then prd, before B3's hub rolls | - |
| B2 | - | `rbac/rbac.go` (ids, `Permissions`, `Defaults`), `rbac/lifecycle.go` (new: stages, the catalogue order, the four preset fills, the locked cells, `PresetMatch`), `rbac/lifecycle_test.go` (new) | the ids and catalogue; `TestListDefaultIsToday`'s frozen table; every preset fills all 39 cells and keeps the locked six true; agile = `Defaults` | R12 (rbac half) |
| B3 | B1, B2 | `store/role_grants.go`, `store/role_grants_memory.go`, `store/role_grants_postgres.go`, `store/role_grants_test.go` (all new), `store/humans_rbac_postgres.go` (`TenantRoles`, `:14-32` only) and its memory twin | read the rows inside `TenantRoles`; write a cell set and a preset in one transaction; refuse a locked cell; the tenant-isolation test; `TestRBACSeedMatchesDefaults` green on Postgres | R12, R14 (store half) |
| B4 | B3 | `hub/permissions.go`, `hub/permissions_test.go` (new) and their one route-registration line | `GET` / `PUT /v1/tenant/permissions`; `perms.edit`, plus `members.roles` for the administer stage; demo refused; `Invalidate(tenant)`; the change log line | R1, R2, R3, R14, R15, R21, R26 |
| B5 | B4 | `hub/wui.go` (`:769-770`, `:830-845` only), `hub/topic_reply.go` (`:26-28` only), `hub/prompt_action.go`, `hub/prompt_action_test.go` (new) | the five `agents.*` ids at the three prompting sites; the action of a send (the new-topic `EXISTS` probe, the mention-poke rule); `agents_skipped: permission` on the ack; send p95 on dev before and after, with n | R4-R11, R13, R22 |
| B6 | B4 | `hub/issues.go` (`issueWriter` `:866-888`, `mayDeleteIssue` `:939-944`, `:1003`, `:1056`, `:1087` only), `hub/blocker_issue_make.go` (`:38` only), `hub/issues_perm_test.go` (new) | the issue ids per PATCH field; `issues.blocker`; `issues.remove_others` | R16, R17 |
| B7 | B4 | `hub/topic_archive.go` (`:166-174` only), `hub/message_kind.go` (`:34` only), `hub/channel_ai_agents.go` (`:55-58` only), `hub/roadmap_switch.go` (`:82` only), `hub/calendar_sync.go` (`:83` only, if nothing else reads it), `hub/marketing_share.go` (`:245` only), `hub/marketing_posts.go` (`:31` only), `hub/embed_admin.go` (`:92` only), `hub/embed_staff.go` (`:63` only), `hub/reporting_sql.go` (`:333` only), `hub/role_name_sites_test.go` (new) | each role-name or owner-flag site asks its id; each with a test that today's roles still pass and one other role is refused, then passes once granted | R18, R19 |
| B8 | B5 | `hub/sender_acts.go`, `hub/sender_acts_test.go` (new), the box-delivery line it hooks (read at build time; not `hub/wui.go`'s B5 lines); the seed rule in the agent seed (the orc lane that owns `spawn-core.inc.sh` takes that line) | the `results.accept` and `ship.approve` bits on a person's box delivery, outside the signed inner object; the seed rule of spec 3.10 | R27 |
| B9 | B4 deployed | `wui/pages/tenant-settings/permissions.vue`, `wui/components/PermissionGrid.vue` (new), `wui/utils/tenant-settings-nav.ts` (one section row), `csi-spl-wui/tests/unit/permission-grid.test.mjs` (new), an existing tenant-settings e2e file (extend; no new e2e file), the 19 `csi-spl-wui/i18n/locales/*.json` (EVERY key of spec 3.11, the `composer.*` ones too, so B10 touches no locale) | the page: stages, grid, preset buttons, the match chip, locked cells, the archive row, the phone layout | R23, R25 |
| B10 | B9 | `wui/utils/send-failure.mjs`, the composer status component (read at build time), `csi-spl-wui/tests/unit/send-failure.test.mjs` | the refusal line, the skipped note, the pre-send hint from `/v1/view/me` | R24 |
| B11 | B10 | `csi-spl-doc/specs/044-spool-open-source/contracts/sender-allow-list.md`, a help page for the Settings section, this folder's `spec.md` (status v1.x) | "the list comes first" in the contract; the help page; spec marked built | - |
| B12 | B9, B10 | none (review only) | agy reviews the new keys in all 19 locales and the help page, the last step before B9, B10 and B11 ship | - |

B5, B6 and B7 touch different files and run in parallel after B4; B8 runs
after B5. Every other pair of rows shares no file. B1 is the only
migration.
