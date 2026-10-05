# Refactor round 3, row 2: Keep the cause in combined `err != nil || cond` checks

Plan: `csi-spl-doc/doc/md/refactor-round-3-plan.md`, row 2. Owner topic `3e0809fe-16f6-46e3-a225-616ac6cd555b` (HUM-10, prd t1). Sites measured on trunk `755e86235`. Language: Go. Kind: stability. Risk: low. Run on: **sat**. Agent: **claude**. Batch: 1.

## 0. The owner's order, verbatim

1. msg 5461b323: "New refactoring for clean code round"
2. msg caa8f01c: "No more than two agents at a time. Keep all of the existing features. During the first checkout from the master, identify at least 30 best practices, and for each one of them, perform at least 5 changes on the source code. If you cannot find 5 candidates, then a smaller amount."
3. msg ab4a0356: "Do keep less than two agents per box for performing this refactoring round, and the aim is to improve the stability and to get cleaner code."
4. msg 2caccc14: "Also, if you find out that there is technical documentation missing or the comments of the code can be improved, do that as well."
5. msg f2b0afc0: "Should you find that testability for certain elements should be improved, do that as well."
6. msg a4930378 (later, relayed by c-001): "for the next 1hour you can increase the amount of the agents up till 8 agents working on this feature per box - have at least 2 groks per box as well ..."

This round: up to 8 round-3 lanes per box (owner msg a4930378), so other rows run while you do; that is why section 7 matters. Every existing feature stays: behaviour-preserving only, no new dependency.

## 1. The practice

`if err := readJSON(resp, &tok); err != nil || resp.StatusCode != 200 || ...` reports `token status 200` when the IdP answered 200 with a body that does not decode: the decode error is dropped and an IdP outage reads as a status mismatch in the logs. Split it: wrap `err` with `%w`, then test the condition. The sign-in outcome (non-nil error) is unchanged.

Apply it at the 5 site(s) below and nowhere else. If a site has moved, find it by the excerpt; if it is gone or already fixed on `origin/master`, say so in your result and do not substitute another site.

## 2. The sites

### 2.1 Site 1

`csi-spl-api/src/go/spool-hub-api/internal/auth/idp.go` lines 133-135 on `755e86235`:

```
	if err := readJSON(resp, &tok); err != nil || resp.StatusCode != http.StatusOK || tok.AccessToken == "" {
		return Identity{}, fmt.Errorf("%w: token status %d %s", errExchange, resp.StatusCode, tok.Error)
	}
```

Change: Google exchange; the same shape at :153, :213 and :242 (Facebook) in this file.

### 2.2 Site 2

`csi-spl-api/src/go/spool-hub-api/internal/auth/oidc.go` lines 70-72 on `755e86235`:

```
	if err := readJSON(resp, &tok); err != nil || resp.StatusCode != http.StatusOK || tok.AccessToken == "" {
		return Identity{}, fmt.Errorf("%w: token status %d %s", errExchange, resp.StatusCode, tok.Error)
	}
```

Change: generic OIDC token; same at :91 (userinfo).

### 2.3 Site 3

`csi-spl-api/src/go/spool-hub-api/internal/auth/microsoft.go` lines 186-188 on `755e86235`:

```
	if err := readJSON(resp, &tok); err != nil || resp.StatusCode != http.StatusOK || tok.IDToken == "" {
		return Identity{}, fmt.Errorf("%w: token status %d %s %v", errExchange, resp.StatusCode, tok.Error, tok.ErrorCodes)
	}
```

Change: Microsoft token exchange.

### 2.4 Site 4

`csi-spl-api/src/go/spool-hub-api/internal/auth/idtoken.go` lines 99-101 on `755e86235`:

```
	if err := readJSON(resp, &set); err != nil || resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("jwks: status %d", resp.StatusCode)
	}
```

Change: JWKS fetch: a truncated JWKS body is reported as "status 200" today.

### 2.5 Site 5

`csi-spl-api/src/go/spool-hub-api/internal/auth/password.go` lines 59-61 on `755e86235`:

```
	if _, err := fmt.Sscanf(parts[2], "v=%d", &version); err != nil || version != argon2.Version {
		return errors.New("auth: hash version mismatch")
	}
```

Change: VerifyPassword: split into "hash version parse: %w" and "hash version mismatch"; both stay non-nil.

## 3. Docs, comments and testability (same files, same lane)

- `csi-spl-api/src/go/spool-hub-api/internal/auth/idp.go:76`: `readJSON` has no doc comment; add "closes resp.Body; reads at most 1 MiB; a decode error is returned, never swallowed".
- `csi-spl-api/src/go/spool-hub-api/internal/auth/idtoken.go:84`: `fetchJWKS` has no doc comment; name the cache that calls it (TestMicrosoftJWKSCache) and the 1 MiB cap.
- Testability: extract `exchangeToken(ctx, hc, req) (tokenResp, error)` from `csi-spl-api/src/go/spool-hub-api/internal/auth/idp.go:132,212` (Google, Facebook and OIDC repeat it almost line for line) and unit test it with an httptest server; keep every func under the 80-line / depth-4 gate.
- NEW `TestExchangeKeepsDecodeError` in `internal/auth/oidc_flow_test.go`: a fake IdP answers 200 with `{`; assert `errors.Is(err, errExchange)` and that the message carries "unexpected EOF".

## 4. Tests: before and after

Run these BEFORE you edit and record the counts, then again AFTER. The counts must match, or grow by exactly the cases you add; every new test must pass on the refactored code (and, where it pins old behaviour, on the old code too). A count that drops is a regression, not a cleanup.

- `cd csi-spl-api/src/go/spool-hub-api && go test -count=1 ./internal/auth/ -run 'TestOIDC|TestSignInEachProvider|TestMicrosoft'` (11 PASS on 755e86235, n=1)
- `cd csi-spl-api/src/go/spool-hub-api && go test -count=1 ./internal/auth/ -run TestPassword` (3 PASS; TestPasswordRejectsBadInput covers :59)
- `cd csi-spl-api/src/go/spool-hub-api && go test -count=1 ./internal/auth/` whole package before = after, plus the new test

## 5. Gate (repo CLAUDE.md, for the trees this row touches)

- `cd csi-spl-iac && ./run -a do_check_dist_hygiene` (~1 s)
- `cd csi-spl-iac && ./run -a do_check_pre_push` before EVERY push and again after the mandatory rebase
- `bash csi-spl-api/src/bash/tests/run-all-tests.sh`
- the clean-code gate (SPL-1041): no new or grown Go func over 80 lines, nesting depth over 4 or over 8 params
- `gofmt -l` on every touched file prints nothing
- a store change runs on Postgres: `cd csi-spl-iac && PRE_PUSH_TIER=full ./run -a do_check_pre_push`

## 6. Deploy

This row touches the hub: **deploy dev+prd, prove live via build.json or /version** (the version minted for your commit by `do_release_version`). Watch `gh run list --commit <sha>` until green and deployed on both (`./run -a do_check_deploy_lag`); report `SHA=<sha> ENV=<env> ./run -a do_release_note_link` for dev and prd.

## 7. Files you must NOT touch

Every other row of this round owns these; the row running on the other box at the same time is among them. Also off limits: migrations, `internal/msg/msg.go`, `internal/store/fleet_*.go`, the rotation / lease / spawn / dispatch scripts.

- `csi-spl-api/src/go/spool-hub-api/internal/hub/view_dm_counts.go` (row 1)
- `csi-spl-api/src/go/spool-hub-api/cmd/spool/doc.go` (row 1)
- `csi-spl-api/src/go/spool-hub-api/internal/search/values.go` (row 1)
- `csi-spl-api/src/go/spool-hub-api/internal/auth/config.go` (row 1)
- `csi-spl-api/src/go/spool-hub-api/internal/action/action.go` (row 1)
- `csi-spl-api/src/go/spool-hub-api/internal/hub/perf_ingest.go` (row 3)
- `csi-spl-api/src/go/spool-hub-api/internal/payments/paypal_signature.go` (row 3)
- `csi-spl-api/src/go/spool-hub-api/internal/payments/paypal_payments.go` (row 3)
- `csi-spl-api/src/go/spool-hub-api/internal/hub/fileusage.go` (row 3)
- `csi-spl-api/src/go/spool-hub-api/internal/notify/queue.go` (row 3)
- `csi-spl-api/src/go/spool-hub-api/internal/hub/operator_workspaces.go` (row 4)
- `csi-spl-api/src/go/spool-hub-api/internal/hubclient/flush.go` (row 4)
- `csi-spl-api/src/go/spool-hub-api/internal/hub/rest.go` (row 4)
- `csi-spl-api/src/go/spool-hub-api/internal/action/pin.go` (row 4)
- `csi-spl-api/src/go/spool-hub-api/internal/invitemail/invitemail.go` (row 4)
- `csi-spl-api/src/go/spool-hub-api/internal/hubclient/hubclient.go` (row 5)
- `csi-spl-api/src/go/spool-hub-api/internal/hubclient/commit.go` (row 5)
- `csi-spl-api/src/go/spool-hub-api/cmd/spool/hub.go` (row 5)
- `csi-spl-api/src/go/spool-hub-api/internal/notify/notify.go` (row 5)
- `csi-spl-api/src/go/spool-hub-api/internal/store/migrate.go` (row 5)
- `csi-spl-wui/src/composables/useLive.ts` (row 6)
- `csi-spl-wui/src/composables/usePaletteItems.ts` (row 6)
- `csi-spl-wui/src/composables/useWorkspaceDocs.ts` (row 6)
- `csi-spl-wui/src/pages/docs.vue` (row 6)
- `csi-spl-wui/src/pages/help/[[page]].vue` (row 6)
- `csi-spl-wui/src/utils/fetch-timeouts.mjs` (row 6)
- `csi-spl-wui/tests/unit/fetch-timeouts.test.mjs` (row 6)
- `csi-spl-wui/src/utils/build-watch.mjs` (row 7)
- `csi-spl-wui/src/utils/build-stamp.mjs` (row 7)
- `csi-spl-wui/src/utils/avatar.mjs` (row 7)
- `csi-spl-wui/src/utils/tenant-host-boot.mjs` (row 7)
- `csi-spl-wui/src/utils/auth-client.mjs` (row 7)
- `csi-spl-wui/src/components/MergeConfirmDialog.vue` (row 8)
- `csi-spl-wui/src/components/TopicDeleteDialog.vue` (row 8)
- `csi-spl-wui/src/components/PersonActivityDialog.vue` (row 8)
- `csi-spl-wui/src/components/ActAsPicker.vue` (row 8)
- `csi-spl-wui/src/pages/archive.vue` (row 8)
- `csi-spl-wui/src/utils/latest-only.mjs` (row 8)
- `csi-spl-wui/tests/unit/latest-only.test.mjs` (row 8)
- `csi-spl-wui/tests/unit/topic-archive.test.mjs` (row 8)
- `csi-spl-wui/src/components/LanguageSetting.vue` (row 9)
- `csi-spl-wui/src/components/IssuesSortSetting.vue` (row 9)
- `csi-spl-wui/src/components/DisplayNameSetting.vue` (row 9)
- `csi-spl-wui/src/components/ViewPrefsSetting.vue` (row 9)
- `csi-spl-wui/src/components/MovePickerDialog.vue` (row 9)
- `csi-spl-wui/tests/unit/busy-finally.test.mjs` (row 9)
- `csi-spl-wui/src/utils/pane-collapse.mjs` (row 10)
- `csi-spl-wui/src/utils/hidden-cards.mjs` (row 10)
- `csi-spl-wui/src/utils/fleet-load.mjs` (row 10)
- `csi-spl-wui/src/utils/operator-console.mjs` (row 10)
- `csi-spl-wui/src/utils/card-clip.mjs` (row 10)
- `csi-spl-orc/lib/bash/funcs/spl-db-roles.func.sh` (row 11)
- `csi-spl-orc/lib/bash/funcs/gandi-api.func.sh` (row 11)
- `csi-spl-orc/src/bash/run/spl-db-health.func.sh` (row 11)
- `csi-spl-orc/src/bash/run/spl-checkout-fake-buy.func.sh` (row 11)
- `csi-spl-orc/src/bash/run/setup-app-inf.func.sh` (row 11)
- `csi-spl-orc/src/bash/tests/curl-time-bounded.tst.sh` (row 11)
- `csi-spl-orc/src/bash/scripts/verify-hub-endpoints.sh` (row 12)
- `csi-spl-iac/src/bash/run/measure-wui-edge-warm.func.sh` (row 12)
- `csi-spl-orc/src/bash/run/spl-hub-member-list.func.sh` (row 12)
- `csi-spl-orc/src/bash/run/spl-db-message-show.func.sh` (row 12)
- `csi-spl-orc/src/bash/run/spl-consumer-lag.func.sh` (row 12)
- `csi-spl-iac/lib/bash/funcs/gcp-project-apis.func.sh` (row 13)
- `csi-spl-iac/src/bash/run/gcp-bkp-state-bucket-create.func.sh` (row 13)
- `csi-spl-iac/lib/bash/funcs/export-json-section-vars.func.sh` (row 13)
- `csi-spl-iac/src/bash/run/gcp-003-configure-proj-sa-permissions.func.sh` (row 13)
- `csi-spl-iac/src/bash/run/gcp-004-project-apis-enable.func.sh` (row 13)
- `csi-spl-iac/src/bash/run/gcp-000-bootstrap-gcp-env.func.sh` (row 13)
- `csi-spl-iac/src/bash/run/tf-apply-local-step-bucket.func.sh` (row 13)
- `csi-spl-iac/src/bash/run/tf-destroy-local-step-bucket.func.sh` (row 13)
- `csi-spl-orc/src/bash/tests/desk-mirror-actions.tst.sh` (row 14)
- `csi-spl-orc/src/bash/tests/agent-mcp.tst.sh` (row 14)
- `csi-spl-orc/src/bash/tests/channel-agent-add-op.tst.sh` (row 14)
- `csi-spl-orc/src/bash/tests/desk-owners.tst.sh` (row 14)
- `csi-spl-orc/src/bash/tests/desk-welcome.tst.sh` (row 14)
- `csi-spl-orc/src/bash/tests/test-lib.inc.sh` (row 14)
- `csi-spl-orc/src/bash/tests/tests-hermetic.tst.sh` (row 14)
- `csi-spl-orc/src/bash/scripts/docker-init-tf-runner.sh` (row 15)
- `csi-spl-orc/src/bash/scripts/docker-init-tpl-gen.sh` (row 15)
- `csi-spl-orc/src/bash/scripts/docker-init-conf-validator.sh` (row 15)
- `csi-spl-orc/src/bash/tests/docker-init-scripts.tst.sh` (row 15)
- `csi-spl-orc/src/bash/run/spl-desk-rebox.func.sh` (row 16)
- `csi-spl-orc/src/bash/run/spl-m3-e2e.func.sh` (row 16)
- `csi-spl-orc/src/bash/features/mcp-bot/scripts/mcp-start-chrome.sh` (row 16)
- `csi-spl-orc/lib/bash/funcs/spl-newest-tenant-key.func.sh` (row 16)
- `csi-spl-orc/src/bash/tests/newest-tenant-key.tst.sh` (row 16)
- `csi-spl-api/src/go/spool-hub-api/internal/config/config.go` (row 17)
- `csi-spl-api/src/go/spool-hub-api/internal/payments/config.go` (row 17)
- `csi-spl-api/src/go/spool-hub-api/internal/cicdlogs/cicdlogs.go` (row 17)
- `csi-spl-api/src/go/spool-hub-api/internal/action/react.go` (row 17)
- `csi-spl-api/src/go/spool-hub-api/internal/store/answer_once.go` (row 17)
- `csi-spl-api/src/go/spool-hub-api/internal/store/memory.go` (row 18)
- `csi-spl-api/src/go/spool-hub-api/internal/store/id_lookup.go` (row 18)
- `csi-spl-api/src/go/spool-hub-api/internal/store/channel_humans.go` (row 18)
- `csi-spl-api/src/go/spool-hub-api/internal/store/agent_lifecycle.go` (row 18)
- `csi-spl-api/src/go/spool-hub-api/internal/store/perf_samples.go` (row 18)
- `csi-spl-api/src/go/spool-hub-api/internal/store/operator_flag.go` (row 19)
- `csi-spl-api/src/go/spool-hub-api/internal/store/agent_seats.go` (row 19)
- `csi-spl-api/src/go/spool-hub-api/internal/store/operator_workspaces.go` (row 19)
- `csi-spl-api/src/go/spool-hub-api/internal/store/humans_memory.go` (row 19)
- `csi-spl-api/src/go/spool-hub-api/internal/spool/retired.go` (row 19)
- `csi-spl-api/src/go/spool-hub-api/internal/store/postgres.go` (row 19)
- `csi-spl-wui/src/composables/useArchiveUndo.ts` (row 20)
- `csi-spl-wui/src/utils/read-sync-boot.ts` (row 20)
- `csi-spl-wui/src/plugins/0.boot-early.client.ts` (row 20)
- `csi-spl-wui/src/utils/flow-badge.mjs` (row 20)
- `csi-spl-wui/src/utils/early-session.mjs` (row 20)
- `csi-spl-wui/tests/unit/swallow-reasons.test.mjs` (row 20)
- `csi-spl-wui/src/utils/palette.mjs` (row 21)
- `csi-spl-wui/src/utils/side-hit-list.mjs` (row 21)
- `csi-spl-wui/src/utils/sidebar-row-menu.mjs` (row 21)
- `csi-spl-wui/src/components/LiveFeed.vue` (row 21)
- `csi-spl-wui/src/composables/useIssueColumnGrips.ts` (row 21)
- `csi-spl-wui/tests/unit/view-prefs.test.mjs` (row 21)
- `csi-spl-wui/src/utils/verbosity.mjs` (row 22)
- `csi-spl-wui/src/utils/slash-focus.mjs` (row 22)
- `csi-spl-wui/src/utils/font-size.mjs` (row 22)
- `csi-spl-wui/src/utils/theme.mjs` (row 22)
- `csi-spl-wui/src/utils/pane-widths.mjs` (row 22)
- `csi-spl-wui/tests/unit/util-docs.test.mjs` (row 22)
- `csi-spl-wui/src/utils/open-message.mjs` (row 23)
- `csi-spl-wui/src/utils/link-target.mjs` (row 23)
- `csi-spl-wui/src/utils/read-cursor.mjs` (row 23)
- `csi-spl-wui/src/utils/tenant-users-mock.mjs` (row 23)
- `csi-spl-wui/src/utils/perf-mark.mjs` (row 23)
- `csi-spl-wui/tests/unit/open-message.test.mjs` (row 23)
- `csi-spl-wui/src/components/IssueDescription.vue` (row 24)
- `csi-spl-wui/src/components/OmniboxGrip.vue` (row 24)
- `csi-spl-wui/src/composables/useDragReorder.ts` (row 24)
- `csi-spl-wui/src/utils/place-popover.mjs` (row 24)
- `csi-spl-wui/src/composables/useMsgShortcuts.ts` (row 24)
- `csi-spl-wui/tests/unit/place-popover-stop.test.mjs` (row 24)
- `csi-spl-wui/src/plugins/chunk-reload.client.ts` (row 25)
- `csi-spl-wui/src/plugins/preferred-locale.client.ts` (row 25)
- `csi-spl-wui/src/plugins/preferred-theme.client.ts` (row 25)
- `csi-spl-wui/src/plugins/event-log.client.ts` (row 25)
- `csi-spl-wui/src/plugins/lobby-warm.client.ts` (row 25)
- `csi-spl-wui/tests/unit/client-plugins-no-guard.test.mjs` (row 25)
- `csi-spl-wui/src/utils/move-mock.mjs` (row 26)
- `csi-spl-wui/src/utils/mock-merge.mjs` (row 26)
- `csi-spl-wui/src/utils/tenant-users.mjs` (row 26)
- `csi-spl-wui/src/utils/iso-seconds.mjs` (row 26)
- `csi-spl-wui/tests/unit/iso-seconds.test.mjs` (row 26)
- `csi-spl-orc/src/bash/features/spool-install/install.sh` (row 27)
- `csi-spl-orc/src/bash/run/spl-backfill-probe.func.sh` (row 27)
- `csi-spl-orc/src/bash/run/spl-desk-session-upload.func.sh` (row 27)
- `csi-spl-iac/lib/bash/funcs/parse-metadata.func.sh` (row 28)
- `csi-spl-iac/lib/bash/funcs/validate-params.func.sh` (row 28)
- `csi-spl-orc/lib/bash/funcs/validate-params.func.sh` (row 28)
- `csi-spl-iac/src/bash/run/tf-destroy-local-step-bucket.func.sh` (row 28)
- `csi-spl-iac/lib/bash/funcs/require-var.func.sh` (row 28)
- `csi-spl-orc/src/bash/tests/parse-metadata-nofork.tst.sh` (row 28)
- `csi-spl-iac/lib/bash/funcs/satellite.func.sh` (row 29)
- `csi-spl-orc/lib/bash/funcs/spl-hub-operator.func.sh` (row 29)
- `csi-spl-orc/lib/bash/funcs/spl-stripe.func.sh` (row 29)
- `csi-spl-orc/lib/bash/funcs/spl-cloud-cnf.func.sh` (row 29)
- `csi-spl-orc/src/bash/run/spl-desk-welcome.func.sh` (row 29)
- `csi-spl-orc/lib/bash/funcs/define-all-run-vars.func.sh` (row 30)
- `csi-spl-orc/src/bash/run/spl-tenant-host-provision.func.sh` (row 30)
- `csi-spl-orc/src/bash/run/tf-030-import-existing-cloud-run.func.sh` (row 30)
- `csi-spl-orc/lib/bash/funcs/parse-metadata.func.sh` (row 30)
- `csi-spl-iac/src/bash/run/gcp-sm-secrets-to-env-file.func.sh` (row 30)
- `csi-spl-iac/src/bash/tests/comment-refs-exist.tst.sh` (row 30)

Your own files: `csi-spl-api/src/go/spool-hub-api/internal/auth/idp.go`, `csi-spl-api/src/go/spool-hub-api/internal/auth/oidc.go`, `csi-spl-api/src/go/spool-hub-api/internal/auth/microsoft.go`, `csi-spl-api/src/go/spool-hub-api/internal/auth/idtoken.go`, `csi-spl-api/src/go/spool-hub-api/internal/auth/password.go`. Before you start, `bash /opt/csi/csi-spl-desk-cron/csi-spl-orc/src/bash/features/spawn-agents/scripts/lane-map.sh --check csi-spl-api/src/go/spool-hub-api/internal/auth/idp.go,csi-spl-api/src/go/spool-hub-api/internal/auth/oidc.go,csi-spl-api/src/go/spool-hub-api/internal/auth/microsoft.go,csi-spl-api/src/go/spool-hub-api/internal/auth/idtoken.go,csi-spl-api/src/go/spool-hub-api/internal/auth/password.go --agent <you>` must exit 0.

## 8. Commit and report

- Commit as the owner identity on the `Commits:` line of the repo CLAUDE.md (name + csitea.net address; the hygiene sweep bans the literal name in shipped files, so it is not spelled out here), no AI trailers (no `Co-Authored-By:`, `Generated with`, `Claude-Session:`). Explicit pathspecs on `git add`.
- Subject: `refactor(r3-02): Keep the cause in combined `err != nil || cond` checks` (one commit per site is fine; push each at once).
- Land on `origin/master` (`git merge-base --is-ancestor HEAD origin/master` exits 0).
- Send ONE result to the orchestrator on task `3e0809fe-16f6-46e3-a225-616ac6cd555b`: the sha(s), each site done / moved / skipped (why), the doc, comment and testability items done, and the before/after test counts.
