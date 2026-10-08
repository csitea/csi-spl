# 073 agent join tokens: tasks

Authority for what is built (`spec.md` holds the behaviour). Each task names
its lane, the files it owns and its done check. Status vocabulary:
`../README.md` §2.3. Owner decisions are `spec.md` section 8 (Q1-Q4, msg
`b30cc1ef`). Tasks build those decisions.

- [x] T001 **spec** (c-179, spec 072 T012 / L17): `spec.md` and this file.
      Decisions folded in v0.2 (g-242).
- [x] T002 **rdb** (c-231, rdb `0119_agent_join_tokens.sql`): the `agent_join_tokens` migration (next free prefix),
      including `for_human` (spec 4.2), RLS, `pins_history.reason` += `join`,
      `wui-revoke`, `membership-end`, and the `agents.join` permission granted
      to `admin` only (spec 4.7; `rbac.Permissions` and `rbac.Defaults` in the
      same commit). Done: the migration lint and the postgres store tests are
      green, including `TestRBACSeedMatchesDefaults`.
- [x] T003 **hub** (c-547, after T002): store methods, the five routes of spec 4.3
      gated as that table (`agents.join` on the four session routes, not
      `keys.manage`), `wire.JoinPayload`, the refusal table, the redeem
      window, `config.Hub.JoinTokenTTL` (`SPOOL_HUB_JOIN_TOKEN_TTL`,
      `envDefault` `1h`, bounds in `checkLimits`, spec 4.1) and the cnf key
      `env.hub.env.SPOOL_HUB_JOIN_TOKEN_TTL: "1h"` in
      `csi-spl-cnf/csi-spl/all.env.yaml` (then `ENV=dev` and `ENV=prd`
      `./run -a do_tpl_gen` with `git diff --exit-code`). No duration literal
      in the mint handler. Done: AC1-AC7, AC10 and AC12 green on postgres
      (`PRE_PUSH_TIER=full ./run -a do_check_pre_push`).
      Built: `internal/hub/join_tokens.go`, `internal/store/join_tokens*.go`,
      `wire.JoinPayload` (signs `{box_id,op:"join",pubkey,token_hash,ts}`).
      Checks: `internal/hub/join_tokens_test.go` (AC1-AC7, AC10, the refusal
      table, and spec 108 3.1 / 3.2 pairs (b) and (c): a key live in one
      workspace is `pin_conflict` in another, enforced on the join path) and
      `internal/config/join_token_ttl_test.go` (AC12), green on memory and
      postgres. A revoked pin is re-seated by a new token; the root-key
      `POST /v1/pins` is unchanged (FR-007) and does not check (c).
- [ ] T004 **CLI** (after T003): `spool join`, token from env / stdin, usage
      line. Done: a CLI test against a test hub seats a box with no root key.
- [ ] T005 **orc** (after T004): `do_spl_desk_pin` join mode and its test in
      `desk-pin.tst.sh`; then `install.sh --join` with the lane that holds the
      installer. Done: hermetic suite seats via a stub `spool join`.
- [~] T006 **WUI** (after T003): New join token, optional `for_human`, open
      tokens list, Revoke seat. Shown only when the session holds
      `agents.join` (spec 4.6). The connect guide is T009, not this task.
      Done: typecheck + e2e for mint / copy / revoke, and a `biz_owner`
      session does not see the controls; then AC8 live on dev and prd.
      **Built** db323e02b (c-563, spec 108 T010), WUI v3.6.6 on dev + prd:
      `JoinTokensPanel.vue` (lazy), typecheck rc 0, e2e
      `tenant-settings.test.mjs` 8g..8l + 17 35/35 on the mock bundle
      (control `PROVE_RED=biz-sees-join` -> 17 FAIL). Live n=1 each: dev t1
      `developer` and prd e2e `biz_owner` see the Agents list and no
      join-token control. **AC8 open**: needs T004 `spool join` (108 T003)
      and an admin test session on dev / prd e2e (both test members lack
      `agents.join`).
- [ ] T007 **close 037 T005** and 072 A5 once AC8 is green.
- [ ] T008 **membership end** (after T003): spec 4.8. On `RemoveMember`, in
      that transaction, revoke open tokens and seated pins with this
      `for_human` (`pins_history.reason = membership-end`) and close those
      boxes after commit. On `access_until` at or before now, the same revoke
      runs in the PATCH that writes a past time, and on the join-token
      sweeper when a future `access_until` passes. A null `for_human` is not
      touched. Disable is not a trigger. Done: AC11 green on postgres.
- [ ] T009 **connect guide** (after T004): spec 4.9. Default steps are the
      join line; the root-key line is only inside a closed Advanced
      disclosure ("Advanced: I hold the tenant root key"). Owns
      `csi-spl-wui/src/components/ConnectAgentGuide.vue`,
      `csi-spl-wui/src/utils/connect-agent.mjs`,
      `csi-spl-doc/doc/help/connect-an-agent.md` and the help-md copy
      (`node src/node/help/sync-help.mjs` in `csi-spl-wui`). Does not edit
      `README.md`. Done: AC13; `help-sync` and
      `csi-spl-iac/src/bash/tests/help-connect-agent.tst.sh` green.

<!-- version: 0.2.1 · updated: 2026-10-08 · last-edit: 2026-10-08T16:30:00Z -->
