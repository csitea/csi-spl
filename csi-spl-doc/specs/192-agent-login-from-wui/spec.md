# Spec 192: log in, log out and renew each agent vendor's login on a workspace's boxes, from Settings, admins only

**Feature ID**: `192-agent-login-from-wui` · **Status**: Decided v0.2
(Q-1..Q-5 answered by the owner, section 9) · **Epic**: SPL-2398 · **Issue**: SPL-6374 ·
**Created**: 2026-11-24 · **Lead**: c-747 · **Placement slug**:
`c002-agent-login-from-wui-spec` · **Class**: feature
**Discussion**: t1 topic `4781ca4e-f43b-43f0-a86d-0dc37ea19d0a`
**Authority**: this file for logging the agent vendors' CLIs in and out on
the boxes a workspace has, from the web UI. Status vocabulary:
[README.md](../README.md) §2.3. Docs only: this spec builds nothing.

Next-free check, on origin/master `dbd127c96` and every `origin/review/*`
branch (fetched 2026-11-24):
`git ls-tree --name-only origin/master csi-spl-doc/specs/ | sort | tail -3`
-> `190-qto-doc-media`, `191-a2ui-evaluation`, `README.md`; the same
listing over every `origin/review/*` branch names no folder above `191`.
`192` is free.

Builds on, and does not repeat:

- [181 private workspace VM](../181-buy-private-workspace-vm/spec.md) row
  B11 (gap G11, owner Q-5, Q-14 A): the web-UI sign-in relay to a CLI's
  terminal login, one switch per vendor, default off, the input sealed to
  the box and stored nowhere. Built as SPL-6345 on
  `review/c002-s181-b11-signin-relay` (`e614ff9b5` api, `0ebd2d69a` orc,
  `a83b81c83` wui), **not on master yet**. This spec reuses that relay as
  it is (section 4) and does not specify it again.
- [159 BYO AI keys](../159-byo-ai-keys/spec.md) v0.3: who may manage a
  vendor's credentials (3), what each vendor's terms allow (4.1, 4.2), the
  claude self sign-in and its rule that the hub, the WUI and the desk never
  see the token (4.3).
- [132 fleet login self-heal](../132-fleet-login-selfheal-3-boxes/spec.md)
  and the [060 add-on, claude account failover](../060-role-rotation/claude-account-failover.md):
  how the fleet's claude login is checked, renewed, copied and failed over
  today (section 3).
- [108 workspace-owned boxes](../108-workspace-owned-boxes/spec.md): a box
  enrolled into a workspace (its pin), its OS user (3.5), `shared` and
  `dedicated` boxes (3.8).
- [127 workspace vendor keys](../127-workspace-vendor-keys/spec.md): the
  API-key path (Agent keys page), unchanged here.

`<W>` (a workspace), `<box>`, `<kind>` (claude, grok, agy, mistral, qwen)
and `<agent user>` (the box's `SPOOL_AGENT_USER`, or `<W>`'s own OS user on
a `dedicated` box) are placeholders. No credential, token, login input,
key path, account email or OS user name appears in this file.

## 1. The owner's words

Owner HUM-10, t1 `4781ca4e`, verbatim:

> "we need to enable the login and logout per agent type as well as the
> renewing of the tokens which happen in the terminal , when the weekly
> limits are not avialable for claude to be possible to be one via the web
> interface , only the admin of a workspace gets to do those"
> (msg `7c6e3169-8a94-43cb-a7c6-f43c67a99422`)

> "and the new logins should be replicated automatically to all ofthe boxes
> to which the workspace has access to"
> (msg `37775465-cc18-4cbc-9d98-7137003e2a13`)

> "should be done via the Settins , there should be ai vendors section in
> the settings up next from the vendor split"
> (msg `a330682c-105a-4b56-a538-2b04fa88c9b6`, with a screenshot of Settings)

So:

| # | requirement | section |
|---|---|---|
| N1 | log in, log out and renew each vendor's CLI login from the web UI, not the terminal | 5 |
| N2 | the case that drives it: a vendor's weekly limit is hit, the admin switches that vendor to another account | 6 |
| N3 | workspace admins only | 2 |
| N4 | a login made once reaches every box the workspace has, automatically, including a box added later | 7 |
| N5 | a new **AI vendors** section of workspace Settings, right after the vendor split | 8 |

## 2. Who and where (N3)

- **Who.** A new permission `vendor_logins.manage`, given by rdb migration
  to `admin` and `biz_owner` [Q-1 A], the two roles that hold
  `vendor_keys.manage` today (
  `csi-spl-api/src/go/spool-hub-api/internal/rbac/rbac.go:272-281`). The hub
  checks it on every route of section 5; the WUI shows the section only when
  `/v1/view/me` lists it. Refused under an act-as session, and for an
  operator-made member until a confirmed manager confirms it, the same two
  rules as `vendor_keys.manage` (159 section 3, `rbac.go:82-89`). A member
  without it gets 403 and never sees the section.
- **Which boxes.** The workspace's enrolled boxes: its pins (108 3.2) whose
  desk is enrolled for sealed input (`pins.box_x25519`, rdb
  `0235_pins_box_x25519.sql`). A pin with no recipient is listed as
  "re-join needed" and gets nothing. A box outside `<W>` is never offered
  and never reached (red control R3).
- **Which OS user.** The box's agent user: on a fleet (`shared`) box the
  `SPOOL_AGENT_USER` of its box.env, on a `dedicated` box `<W>`'s own OS user
  (108 3.5). Never the human's own user: the fleet rule that every agent runs
  as the agent user holds
  (`csi-spl-orc/src/bash/features/spool-install/assets/claude/claude-md/05-agents-run-as-agent-user.md`),
  and the box side refuses any other user (R7).

## 3. How the fleet logs in today (measured)

On origin/master `dbd127c96`, 2026-11-24, n = 1 per read.

| piece | state | where |
|---|---|---|
| claude login of the agent user, checked every minute | Implemented | `csi-spl-orc/src/bash/run/spl-agent-login-check.func.sh:1-50` (cron row agent-login-check): scan panes for a dead login or a limit screen, `claude -p` probe (ok, expired, limited, unknown), repair stuck seats by stop + restore while the probe says ok |
| claude renewal | Implemented, by the CLI itself | the access token lives about 8 h and the CLI renews it only in its last minutes (060 add-on section 3: 56 renewals in 15 days on one box; 132 section 3); the check warns under 60 min to expiry, not renewed (`spl-agent-login-check.func.sh:44-48`) |
| claude login copied between boxes | Implemented, one refresher | the box naming `SPOOL_LOGIN_PEERS` pushes (and pulls) the credential over ssh, temp + mv, mode 600 (`spl-agent-login-check.func.sh:13-30`); the file ops are `csi-spl-orc/src/bash/scripts/agent-login-cred.sh:9-28` (`stat`, `probe`, `get`, `put`, `acct`; sha12 and an `acct-<8 hex>` label only, never content) |
| a second claude account per box (failover) | Built, off | cnf `env.box.claude_login_pool.enabled: false` (`csi-spl-cnf/csi-spl/all.env.yaml:1310-1320`); its rule D4: "The code never signs in, never logs out and never changes an account" (060 add-on line 29) |
| the claude sign-in action for a workspace user | Implemented, behind its switch | `csi-spl-orc/src/bash/run/spl-ws-claude-signin.func.sh`: `claude auth login --claudeai` in tmux (line 106), `auth logout` (line 141), status |
| grok login | file only | `~/.grok/auth.json` of the agent user, empty or missing = no sign-in (`csi-spl-orc/src/bash/run/spl-agent-identity-restore.func.sh:332-345`); how it is made: by a person at the terminal, flow not recorded in the repo |
| agy login | file only | the marker `.gemini/antigravity-cli/antigravity-oauth-token` (`csi-spl-orc/src/bash/features/spawn-agents/lib/spool-env.inc.sh:556`); made by a person, flow not recorded |
| mistral | API key, not a login | `<agent home>/.vibe/.env` `MISTRAL_API_KEY=`, read from a tty, a file or stdin, `TO_BOX=` over ssh stdin (`csi-spl-orc/src/bash/run/set-mistral-key.func.sh:3-20`) |
| qwen | settings file | "Auth is set once by a human in the agent user's `~/.qwen/settings.json`" (`csi-spl-orc/src/bash/features/spawn-agents/assets/commands/qwen-spawn.md:94`); the qwen.ai login's free tier ended 2026-04-15 (159 4.1) |
| weekly limit read | Implemented | claude's banner "You've used N% of your weekly limit" and grok's "Weekly limit left: N%" (`csi-spl-orc/lib/bash/funcs/spl-box-quota.func.sh:64-85`), claude's cached % (`spl_box_quota_cache_read`, line 202); agy's "Individual quota reached ... Resets in 13h53m38s" (`csi-spl-orc/src/bash/features/watchdog/situations/lib.inc.sh:53-55`) |
| per-vendor pause | Implemented | `lane_op fleet_load_pause {kind, until, reason}` pauses a kind for every box, at most `MaxKindPause` (8 days) ahead (`csi-spl-api/src/go/spool-hub-api/internal/hub/fleet_load.go:434-474`, `internal/store/fleet_load.go:60-68`); a nil entry lifts it (`mergePauses`, `internal/store/fleet_load.go:236-260`) |
| the queue's vendor swap | Implemented | lane mix: main, then backup, then claude (`csi-spl-orc/src/bash/run/spl-lane-mix.func.sh:14`); the placer's AGY OUT and coding-rule swaps (`csi-spl-orc/src/bash/run/spl-spawn-place.func.sh:116-145`) |
| the Settings sections | Implemented | `csi-spl-wui/src/utils/tenant-settings-nav.ts:28-40`: `split` (line 30, "vendor split", `tenant.settings`) then `agent-keys` (line 31, `vendor_keys.manage`) |

What is missing: no web path logs a fleet box's vendor CLI in or out; a
dead or limited login needs a person at that box's terminal (132 section 5).

## 4. What this spec adds on top of 181 B11

B11 relays ONE sign-in: one kind, one box (the workspace's dedicated VM),
from Agent keys, as `<W>`'s OS user, claude wired only (`no_login` for
grok and mistral in `do_spl_ws_signin_relay`, `0ebd2d69a`). Reused as it
is: `POST /v1/signin-relay`, the input sealed to the box's desk recipient
inside the input handler, the relay in memory for 10 min, nothing in a
table or a log, the per-vendor hub switch `SPOOL_HUB_SIGNIN_RELAY_KINDS`
and box switch `env.box.signin_relay_kinds`, both off by default.

This spec adds:

| # | addition |
|---|---|
| A1 | every enrolled box of `<W>`, shared fleet boxes included, not only a dedicated VM; the agent user of each (section 2) |
| A2 | log out and renew, not only log in (section 5) |
| A3 | the login flows of grok and agy on the box side; mistral and qwen stay on Agent keys (section 5.2, Q-5 B) |
| A4 | the fan-out to every box, its per-box state, and a box added later (section 7) |
| A5 | the state per kind and box, with no secret: signed in or not, account label, expiry, weekly % and reset (section 5.3) |
| A6 | the weekly-limit switch: lift the pause, restart every seat of the kind on the new account (section 6) |
| A9 | the login copied box-to-box over the ssh peer path, per-box sign-in where no peer reaches (section 7) |
| A10 | the relay on for the operator workspace now, every wired vendor; customer workspaces keep the per-vendor gate (section 4.1) |
| A7 | a new permission and the **AI vendors** section of Settings (sections 2, 8) |
| A8 | an audit table for every op (section 10) |

### 4.1 The switch per workspace [Q-3 B]

B11's hub switch `SPOOL_HUB_SIGNIN_RELAY_KINDS` is one list for the whole
instance. This spec splits it: the **operator workspace** (the owner's own
fleet, his own accounts on his own boxes, through the unmodified CLI) is on
now for every kind with a wired login (claude; grok and agy once row L4
wires them); every **customer workspace** keeps the per-vendor gate, on only
after that vendor's written OK (O1 Anthropic, O2 xAI, O3 Mistral; 159 4.3,
181 Q-14 A). The box switch `env.box.signin_relay_kinds` is set on the fleet
boxes for the same kinds. The owner's reading of the 159 4.1 quote: "Nor
does it prevent an end user from signing in to the unmodified Claude Code
binary with their own Claude subscription, including where a platform hosts
Claude Code".

## 5. Log in, log out, renew (N1)

### 5.1 The ops

| op | what the box does, as the agent user | when the admin uses it |
|---|---|---|
| **log in** | starts the unmodified CLI's own login (5.2) in a fresh tmux session; the relay shows its URL; the admin's input goes in by `tmux load-buffer -` (stdin, never argv, env or log, as B11) | a box with no login, or a switch to another account (6) |
| **log out** | stops new seats of that kind on that box (a pause for that box, 6.2), runs the CLI's own logout, removes its login files | an account leaves the workspace |
| **renew** | a log in to the **same** account (the box checks the label of 5.3 after it, and reports `other_account` when it differs) | the box's login is `expired`: the CLI's own refresh failed (132 section 1). A live login is never "renewed" by hand: the CLI renews itself |

Every op is a dry run on the box unless the hub frame says otherwise, as
B11's sidecar passes `DRY_RUN=0`.

### 5.2 The terminal flow per vendor

| kind | what the CLI does | how the relay drives it | state |
|---|---|---|---|
| claude | `claude auth login --claudeai` prints an https URL and waits for a code the person pastes (`spl-ws-claude-signin.func.sh:106`) | the box reports the URL, the WUI shows it as a link (https only, B11's `signinSafeUrl`), the admin pastes the code once, the box types it in | built on the review branch (B11) |
| grok | a sign-in that writes `~/.grok/auth.json` | **unchecked**: whether it prints a URL + code, a device code, or needs a local browser redirect is not recorded in the repo. Row L4 measures it on a test account first and drives it the same way only if it prints a URL and reads a pasted code or completes on a device code; a local-redirect-only flow is reported `no_relay` and stays at the terminal | open |
| agy | an OAuth sign-in that writes the marker file of section 3 | **unchecked**, as grok; the same rule | open |
| mistral | no login: an API key | not relayed: the key is set on Agent keys (spec 127, as today: the hub keeps it sealed and leases it to the boxes); AI vendors shows its state per box and links there [Q-5 B] | decided |
| qwen | no login since 2026-04-15: a provider key in its settings | as mistral [Q-5 B] | decided |

### 5.3 The state shown, with no secret

Per kind and box, read on the box and sent as a box fact (the shape of
`agent-login-cred.sh stat` and `acct`):

- **signed in**: yes, no, expired, limited (the probe of section 3);
- **account**: the label `acct-<8 hex>` (sha256 of the CLI's own account
  id, 060 add-on 4.1), plus a name the admin may give that label in the page
  (stored on the hub; it is not a secret and holds no email);
- **plan kind** where the CLI's own status shows one; none is read from a
  token;
- **expires**: the access token's `expiresAt` (claude); "renews itself" is
  shown beside it;
- **weekly limit**: used % and the reset time, from the readers of
  section 3; "unknown" when the box has none.

Never shown, sent or stored: the token, the pasted code, the vendor URL
after the relay ends, any email. The credential's sha12 stays on the box,
as today.

## 6. The weekly limit (N2)

### 6.1 What the admin does

The AI vendors section shows the kind's weekly % per box and its reset
time. When it reads 100% (or the pause of section 3 is on), the admin
presses **Switch account** for that kind: it is a log in (5.1) on every box
of the workspace (section 7) with the other account, which the admin signs
into in the vendor's page.

### 6.2 What happens to seats and the queue [Q-4 B]

1. **Before**: the kind's pause (section 3) already holds new seats of that
   kind; the lane mix and the placer already swap them to the backup vendor
   (section 3). Nothing changes there.
2. **During**: the box writes the new login through the same temp + mv as
   `agent-login-cred.sh put`, so a reader never sees half a file. Running
   seats are not touched until the new login works.
3. **After**, when the new login probes `ok` on that box: the box lifts its
   own pause entry for that kind (a nil entry, `mergePauses`), then
   **restarts every seat of that kind on the box at once** on the new
   account, stuck or not: each seat is stopped (its pane wrapper, then its
   own pid, as step 4 of `do_spl_agent_login_check` does) and brought back
   by `do_spl_agent_identity_restore`, which resumes its session from its
   transcript. The self-heal's cool-down does not hold these restarts back.
   A seat the restore cannot bring back (no session, worktree, adapter or
   transcript) is not stopped and is reported by id in the box's answer.
   The cost the owner accepted: a turn in flight in a working seat is cut
   and replayed from the transcript. Queued rows swapped to the backup
   vendor stay swapped; new rows go to the kind again.
4. Today's pause is one entry per kind for every box (`fleet_load.go:434-441`).
   Row L5 adds the box to it, so a box whose login was switched does not lift
   a pause another box still needs: a kind is paused on a box until that box
   lifts it.
5. A **log out** sets that box's pause for the kind with reason
   `logged out`, bounded by `MaxKindPause` (8 days); the box re-sets it on
   each check while there is no login, so it never runs out silently.

The second-account failover of the 060 add-on (slot 2, off) is untouched:
this spec writes slot 1 (the agent user's main login) only. Its rule D4
("the code never signs in ... never changes an account") still holds in its
sense: a person signs in, in the vendor's own page, and the code relays the
person's input. The place the owner swaps accounts moves from the terminal
to the web UI.

## 7. One login, every box (N4)

### 7.1 How each box gets it [Q-2 B]

**Sign in once, then copy the login box-to-box over the existing ssh peer
path; per-box sign-in where no peer reaches.**

1. **One sign-in.** A "log in" on the page starts ONE B11 relay, on the
   source box: the enrolled box of `<W>` that reaches the most of the
   others over its peer path (its `SPOOL_LOGIN_PEERS` in box.env), else the
   first one online. The admin opens the vendor's URL and pastes the code
   once.
2. **The copy.** When the new login probes `ok` on the source box, it copies
   the login to each peer of `<W>` it reaches, the way
   `do_spl_agent_login_check` does today: `agent-login-cred.sh get | ssh
   <peer> ... put` (only ever a pipe; temp + mv; the old file kept as
   `.bak-login-<UTC>`; mode 600; sha12 and label only in any output). The
   peer probes it and answers `ok` or `failed`. A peer is copied to only
   when the hub lists it as an enrolled pin of `<W>` (R3); a peer line naming
   any other box is skipped and reported.
3. **Boxes no peer reaches** (a customer's boxes have no ssh to each other;
   a box behind NAT is reached one way only,
   `spl-agent-login-check.func.sh:28-29`): the page opens one per-box
   sign-in for each, as the relay does for the source box.
4. **Today's copy is claude only** (`agent-login-cred.sh` reads and writes
   claude's credential and `.claude.json`). Row L8 adds the grok and agy
   login files to its ops before those kinds are copied; until then they get
   per-box sign-in.

Neither path copies a login through the hub: the hub carries the sealed
code of the one sign-in and the per-box results, never a login file.

**Risks the owner accepted with Q-2 B**, kept here so the build guards them:

- **claude's terms**: "developers may not collect, store, or intermediate
  Claude.ai credentials or session tokens" (159 4.1). The copy moves the
  owner's own login between the owner's own boxes; for a customer workspace
  the copy stays behind the per-vendor gate of 4.1.
- **the shared-renewal risk**: 19 of 19 stuck-login episodes fell within
  15 min of a renewal of a credential shared by two boxes (060 add-on
  section 3, n = 19, one box), and on 2026-10-25 a peer's renewal killed
  the older copy (n = 1). The guard is today's: the source box is the one
  refresher for that login and keeps the copies converged on each renewal
  (`spl-agent-login-check.func.sh:13-30`); the expiry warning of
  section 3 tells the admins when it is silent.
- **spec 132 section 2** ("End copying a login between boxes") is
  superseded for logins made from the web UI (section 13).

### 7.2 Per-box status in the page

Each box's row reads one of: `done` (signed in, label shown, and `copied
from <box>` or `signed in here`), `waiting for code`, `failed` (with the
box's reason word: `no_relay`, `other_account`, `switch_off`, `timeout`,
`copy_failed`), `offline`, `re-join needed` (no recipient).

### 7.3 A box offline, or added later

- A box **offline** when the op starts: its row stays `offline`. When its
  desk is back (its hello), a box of `<W>` that reaches it copies the
  current login to it, with no person needed. Only when no peer reaches it
  does the hub post **one** notice to the workspace's
  `vendor_logins.manage` holders: "`<box>` is back: `<kind>` needs a
  sign-in there", with a link to the section.
- A box **added later** (a new pin): the same, for every kind another box
  of `<W>` has signed in: a peer copy, else the one notice.
- **Log out and renew fan out the same way**: one relay per box, the per-box
  rows above. A log out needs no input, so it runs at once on every box
  online, and on an offline box when it is back, with no person needed (the
  hub keeps "logged out, pending on `<box>`", never a secret).

## 8. The AI vendors section of Settings (N5)

- A new entry in `TENANT_SETTINGS_SECTIONS`
  (`csi-spl-wui/src/utils/tenant-settings-nav.ts:28`), **between `split`
  (line 30) and `agent-keys` (line 31)**:
  `{ id: 'ai-vendors', label: 'tenant_settings.ai_vendors', perm: 'vendor_logins.manage' }`,
  page `csi-spl-wui/src/pages/tenant-settings/ai-vendors.vue`. A member
  without the permission sees no entry (the nav filters on `/v1/view/me`,
  `tenant-settings-nav.ts:58-72`), and the hub answers 403 on a direct call.
- The page: one card per kind (claude, grok, agy, mistral, qwen; a kind the
  workspace's split weighs at 0 is folded), each with a row per box (7.2)
  showing the state of 5.3 and the buttons **Log in**, **Switch account**
  (with a confirm that names the running seats it restarts, 6.2),
  **Renew** (only on `expired`), **Log out** (with a confirm that names the
  boxes and the running seats of that kind).
- A kind whose switch is off (B11's per-vendor switch) shows "not switched
  on for this vendor" and no buttons, as Agent keys does on the review
  branch.
- B11's panel on Agent keys stays for the dedicated VM until this section
  is built; then Agent keys links here for sign-ins (row L6).
- Every string is a translation key in every locale, checked with the
  language check before it ships (repo CLAUDE.md, the language rule).

## 9. The owner's decisions

Owner HUM-10 answered form `2728652b` in t1 `4781ca4e`, msg
`4379dd90-b3f7-4ac9-80af-611c70f5549b` (2026-11-24), relayed verbatim by
the dispatch holder c-002@sat (msg `7cd4319b`). v0.1 recommended A on Q-2
and Q-4; the owner chose B on both.

| # | question | decision | where |
|---|---|---|---|
| Q-1 | who may log the vendors in and out | **A**: workspace admins and the business owner | 2 |
| Q-2 | how a login made once reaches every box | **B**: sign in once, then copy the login file box-to-box over the existing ssh peer path where boxes reach each other; per-box sign-in elsewhere; fully automatic where it works | 7 |
| Q-3 | does 159's per-vendor gate hold the operator's own fleet | **B**: on for the operator workspace now, through the unmodified CLI; customer workspaces keep the per-vendor gate | 4.1 |
| Q-4 | running seats after Switch account | **B**: every seat of that vendor on the box restarts on the new account at once | 6.2 |
| Q-5 | where mistral and qwen keys are set | **B**: on Agent keys, as today; the hub keeps the key sealed; AI vendors shows their state and links there | 5.2 |

## 10. Audit, with no secret

A new table `workspace_vendor_login_audit` (tenant_id, kind, box, op
`login|logout|renew|switch`, actor, at, result word, account label; RLS like
every tenant table, developer guide 2.6.4). One row per box per op, written
by the hub when the box answers. No column holds a token, code, URL or
email; the label is a hash prefix. Shown in the section as "who did what,
when".

## 11. Red controls

| # | control | planted defect -> the test fails |
|---|---|---|
| R1 | a relayed input (code or key) found in any hub table, the audit table included, or any hub or box log | the input written to the audit row's result -> the table walk on Postgres finds it (B11's walk, extended to the new table) |
| R2 | a member without `vendor_logins.manage` | `GET` / `POST /v1/vendor-logins/...` -> 403; the section is absent from the nav; the permission check removed -> the test sees 200 |
| R3 | a box outside `<W>` | a fan-out for `<W>` that reaches a pin of another workspace -> the test fails; a frame for `<W>` opened by another box's desk -> refused (sealed to another recipient) |
| R4 | the switch off (hub or box) | a log in -> 403 `signin_relay_off` and the box reports `switch_off`; the switch check removed -> 201 and the test fails |
| R5 | the copy stays inside `<W>` and off the hub [Q-2 B] | a source box whose peer list names a box that is not a pin of `<W>` -> 0 copies to it, reported; the pin check removed -> the copy reaches it and the test fails; a login file's bytes (or its sha beyond 12 hex) found in a hub table, frame or log -> fails |
| R9 | every seat of the kind restarts after a switch [Q-4 B] | 3 seats of the kind on the box (1 stuck, 2 working), the new login probes ok -> 3 stops and 3 restores, other kinds' seats untouched; the restart limited to stuck seats -> 1 restore and the test fails; the new login probing `expired` -> 0 stops |
| R6 | act-as | a log in under an act-as session -> 403; the check removed -> 201 |
| R7 | the OS user | the box op run for a user other than the agent user -> refused; the refusal removed -> the test sees the op start |
| R8 | the weekly switch lifts only its own box | box A switched, box B still at the limit -> B's pause stays; the lift written for every box -> the test fails |

## 12. Rows for the build

Each row is one small lane with its red control. Paths under `internal/`
are in `csi-spl-api/src/go/spool-hub-api/`.

| # | lane | task | red control | waits on |
|---|---|---|---|---|
| L0 | hub + orc + wui (claude) | land 181 B11 (SPL-6345) | B11's own | its R7 review |
| L1 | rdb + hub (claude) | `vendor_logins.manage` (rdb migration, number from `do_rdb_migration_next`) to `admin` and `biz_owner` [Q-1 A]; act-as and operator-made refusals as `vendor_keys.manage`; the relay switch per workspace: the operator workspace on for every wired kind, customer workspaces on the per-vendor list (4.1) [Q-3 B] | R2, R4, R6 | L0 |
| L2 | rdb + hub (claude) | the fan-out: `POST /v1/vendor-logins/{kind}` `{op}` picks the source box, opens its B11 relay, asks it to copy to the peers of `<W>` it reaches, and opens a per-box relay for each box no peer reaches (7.1); `GET /v1/vendor-logins` the state per kind and box (5.3, from box facts); the audit table (10); the offline and new-box copy or notice (7.3) | R1, R3, R5 | L0, L1 |
| L3 | orc (claude) | box side: `do_spl_ws_signin_relay` runs for the agent user of a shared box too (section 2), ops in, out, renew, status; status as a box fact with the label, expiry, weekly % and reset (5.3), never content | R1, R7 | L0 |
| L4 | orc (claude) | grok and agy logins on the box side: measure each CLI's flow on a test account, wire it when it prints a URL and reads a pasted code or a device code, else `no_relay` | a `no_relay` kind offered a Log in button -> fails | L3 |
| L5 | hub + orc (claude) | the pause per box: `KindPause` keyed by kind and box; the switch lifts its own box's entry; a log out sets one; after a switch, every seat of the kind on the box restarts at once through `do_spl_agent_identity_restore` (6.2) [Q-4 B] | R8, R9 | L3 |
| L6 | wui (claude) | the AI vendors section (8), locale texts, language check last; Agent keys links here for sign-ins | the section shown to a member without the permission -> e2e fails; a code left in any input, page text, Pinia or storage after send -> e2e fails (B11's e2e step) | L2 |
| L7 | doc (agy) | `csi-spl-wui/src/public/help-md/user-settings.md`: the AI vendors section; the 159 4.3, 132 section 2 and 060 add-on D4 notes as section 13 says | `grep -c 'ai-vendors' csi-spl-wui/src/public/help-md/user-settings.md` -> 0 fails | L6 |
| L8 | orc (claude) | the box-to-box copy [Q-2 B]: the source box copies the new login to every peer of `<W>` it reaches (7.1, `agent-login-cred.sh get \| put`), checked against the hub's pin list; the grok and agy login files added to `agent-login-cred.sh`'s ops | R5 | L3, L4 |

## 13. What this spec changes in other specs

- **159 4.3** ("the hub, the WUI and the desk never see the token"):
  **kept**. The relay carries the person's code sealed to one box; no token
  reaches the hub or the WUI. 159's per-vendor gate (O1, O2, O3) is kept for
  customer workspaces; it does not hold the operator workspace, which is on
  now [Q-3 B] (4.1). Row L7 records this in 159 4.3.
- **060 add-on D4**: kept in its sense (a person signs in, never the code);
  the place moves to the web UI (6.2).
- **132 section 2** ("End copying a login between boxes"): **superseded**
  for logins made from the web UI: they are copied box-to-box over the peer
  path [Q-2 B] (7.1). Today's refresher copy stays and carries those
  copies.
- **181 B11**: reused, widened to every enrolled box and the agent user
  (section 4).

## 14. History

- v0.1 (2026-11-24, c-747, SPL-6374): first draft for the panel, from the
  owner's three messages in t1 `4781ca4e`; Q-1..Q-5 open.
- v0.2 (2026-11-24, c-747, SPL-6374): Q-1..Q-5 decided by the owner (msg
  `4379dd90`): Q-1 A, Q-2 B, Q-3 B, Q-4 B, Q-5 B. Section 7 now copies the
  login box-to-box over the peer path (per-box sign-in only where no peer
  reaches); 6.2 restarts every seat of the kind at once after a switch; new
  4.1 (the switch per workspace); 5.2 mistral and qwen on Agent keys; red
  controls R5 rewritten, R9 added; rows L1, L2, L5, L7, L8 updated; 13 marks
  132 section 2 superseded for web-UI logins.
