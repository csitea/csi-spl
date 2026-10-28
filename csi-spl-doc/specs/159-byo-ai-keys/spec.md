# Spec 159: workspace admins and business owners bring their own AI keys, also on our shared GCP hosts

**Feature ID**: `159-byo-ai-keys` · **Status**: Draft v0.2 (owner's Q-1..Q-4 answered, for R7) ·
**Epic**: SPL-2398 · **Issue**: SPL-3566 · **Created**: 2026-10-26 · **Lead**: c-298 ·
**Placement slug**: `c002-spec-byo-ai-keys`
**Authority**: this file for what the owner's ask of 2026-10-26 adds to, or
changes in, spec 127. Status vocabulary: [README.md](../README.md) §2.3. Docs
only: this spec builds nothing ([README.md](../README.md) §2.4).

Builds on, and does not repeat:

- [127 workspace vendor keys](../127-workspace-vendor-keys/spec.md) v1.3,
  signed and decided: storage (KMS envelope in Postgres, 4), the write-only
  API (4.3), the lease to a box (5.2), the desk start checks (5.3), the leak
  table L1..L18 (6), the `byok` plan and `key_source` (7), the Agent keys
  page (8), the owner's Q-1..Q-5 (9). Everything in 127 holds unless a
  section below says it changes.
- [108 workspace-owned boxes](../108-workspace-owned-boxes/spec.md)
  (per-workspace OS user on a machine, 3.5).
- [123 cost tracking](../123-cost-tracking/spec.md) and
  [140 token burn](../140-token-burn/spec.md) (fleet token rows, prices).
- [lane issue and docs](../../doc/md/lane-issue-and-docs.md) section 5 (a
  brief's `Workspace: <tenant>` line, SPL-3528).
- [secrets round 1](../../doc/md/secrets-round-1.md) (secret ages, no value
  printed).

`<tenant>`, `<W>`, `<kind>`, `<VENDOR_KEY>` and `sk-test-0000` are
placeholders. No real key, token, credential path, account id or host
appears here.

## 1. The owner's words

Owner HUM-10, prd t1 topic `f8f9dfcc-659a-480d-bc7f-1cffd5fb38b9`, msg
`87578f3a`, verbatim:

> we should enable the admins and the biz owners to add their own
> subscriptions and api tokens while using the cmd agents connected to the
> spool-hub for their own workspaces , even if they run in our common gcp
> infra and not on their own boxes ..

### 1.1 What it adds to spec 127

| id | requirement | 127 today | changes |
|---|---|---|---|
| N1 | **biz owners** may add keys, not only admins | 5.1: `vendor_keys.manage` is `admin` only; "a `biz_owner` who wants it makes themselves admin" | 3 |
| N2 | **subscriptions**, not only API tokens | 3: one API key (agy: a service-account JSON) per kind; no subscription login | 4 |
| N3 | **in our common GCP infra**, not only on the workspace's own boxes | 5.3: a key only on a `dedicated` box a confirmed admin approved, with no root-equivalent OS user on it | 5 |
| N4 | the agents are the **cmd agents connected to the hub** working for that workspace, which today includes our own fleet lanes doing a workspace's work (a brief with `Workspace: <tenant>`) | 5.3 (a): "fleet boxes ... not in any customer workspace": fleet lanes never get a key | 5, 6 |

The brief for this spec also asks for: cost attribution (7), rotation and
revocation (8), a key that runs out (9), vendor terms (4) and the WUI (10).

## 2. Today, measured

On origin/master `de9146ae8`, 2026-10-26, n = 1 per command.

| fact | command -> result |
|---|---|
| 127's storage is built: tables, `key_source`, its contract step | `git log --oneline origin/master --grep='spec 127 D1'` -> 06b3f2830 (rdb 0174), aa737c890, 30982e537 (rdb 0175) |
| 127's KMS key and pepper are built and applied | `git log --oneline origin/master --grep='spec 127 I1'` -> 6afbfe865 (step `057-gcp-kms-vendor-keys`), c4103d5c2, 80af99930, 7ef74e656 |
| no hub route, permission or wrapper of 127 exists yet | `git grep -c '/v1/vendor-keys' origin/master -- csi-spl-api csi-spl-wui` -> no match; `git grep -l 'spool-key-exec' origin/master` -> no match; `git grep -c vendor_keys.manage origin/master -- csi-spl-api` -> no match |
| no Agent keys page | `ls csi-spl-wui/src/pages/tenant-settings/` -> `agents channels fleet-load general hours index members performance split takeover` (.vue), no `agent-keys.vue` |
| `biz_owner` and `admin` both hold `tenant.settings` and `keys.manage` | `sed -n 217,226p csi-spl-api/src/go/spool-hub-api/internal/rbac/rbac.go` -> both rows list `TenantSettings, KeysManage` |
| a fleet lane already works for a customer workspace | `grep -n 'Workspace:' csi-spl-orc/src/bash/features/spawn-agents/lib/workspace-repo.inc.sh` -> line 9 (brief header `Workspace: <tenant>`), f1a5e2640 (SPL-3528) |
| a fleet lane authenticates with the box login of the one agent OS user; nothing tenant-scoped reaches a credential | `grep -n 'SPOOL_AGENT_USER' csi-spl-orc/src/bash/features/spawn-agents/lib/spool-env.inc.sh` -> one user per box (lines 409-410); `grep -n CLAUDE_CONFIG_DIR csi-spl-orc/src/bash/features/spawn-agents/scripts/spawn-core.inc.sh` -> 672-675, the only auth variable the launcher sets |
| the fleet's agent OS user may use sudo | every lane seed: "PACKAGES: ... you keep sudo" (`csi-spl-orc/src/bash/features/spawn-agents/scripts/spawn-core.inc.sh`) |
| fleet token rows carry no workspace | `grep -n tenant csi-spl-rdb/src/sql/postgres/spool-hub/0199_fleet_token_burn.sql` -> line 23, "Operator scope only: no tenant_id" |

So on a fleet box today, every lane runs as one OS user that can become
root. A workspace key placed there is readable by every other lane on the
box, including lanes working for other workspaces. That is why 127 5.3 kept
keys off fleet boxes. The owner chose to run workspace keys there anyway,
each workspace as its own OS user (Q-1 B, 5.1), knowing that risk (5.4).

## 3. Who may add a key (N1)

- `vendor_keys.manage` (127 5.1) goes to **`biz_owner` and `admin`**. This
  replaces 127's "admin only".
- The same rule as 127 Q-4 A holds for a **`biz_owner` the operator made**.
  A membership with `invited_by` = `operator` or `bootstrap`, in a workspace
  that holds a key, gets neither `vendor_keys.manage` nor key-host approval
  until a confirmed `admin` or `biz_owner` of that workspace confirms it.
  Without this, N1 reopens 127's C1 path (operator invite -> key) through
  the second role.
- Refused under an act-as session, as in 127 5.1.
- Every `admin` and `biz_owner` of the workspace is emailed on each set,
  replace, remove and key-host approval (127 emailed admins only).

## 4. Subscriptions and API keys: what each vendor allows (N2)

### 4.1 The vendors' own words

All pages were fetched on **2026-10-26**. A page's own date is given where
it shows one. "Host" means us, running the vendor's CLI on our machines for
a workspace.

| kind | subscription login run by a host | the workspace's own API key run by a host | source and quote |
|---|---|---|---|
| `claude` | **allowed only as the end user's own sign-in, through the vendor's flow, into the unmodified CLI.** We may not collect, store or pass on the token. | **allowed**: billed to the key's owner, not resold | `https://code.claude.com/docs/en/legal-and-compliance` (no date shown): "Each end user must authenticate with their own Anthropic API key, Claude subscription plan credentials, or 3P inference provider credential"; "Anthropic does not permit third-party developers to offer Claude.ai login into their own applications, or to route requests through Free, Pro, or Max plan credentials on behalf of their users."; "developers may not collect, store, or intermediate Claude.ai credentials or session tokens — sign-in to a Claude account must complete through Anthropic's own flow."; "Nor does it prevent an end user from signing in to the unmodified Claude Code binary with their own Claude subscription, including where a platform hosts Claude Code"; "Customers may not pay for, resell, or intermediate Claude usage on their end users' behalf." |
| `grok` | **forbidden** (consumer terms: credentials not shared) | **unclear**: the enterprise terms let a customer serve its end users, and are silent on a customer giving its key to a host | `https://x.ai/legal/terms-of-service` (last updated 2026-10-12): "You may not share your account credentials or make your account available to anyone else"; `https://x.ai/legal/terms-of-service-enterprise` (last updated 2026-08-14): "Customer will ensure that each Permitted User keeps its user credentials strictly confidential and does not share them with any unauthorized person." No page on a host running the grok CLI was found. |
| `mistral` | **forbidden** | **forbidden without Mistral's prior written authorization**, even on the customer's key | `https://legal.mistral.ai/terms/row-consumer-terms` (effective 2026-10-12): "You may not make your account credentials available to third parties"; `https://legal.mistral.ai/terms/commercial-terms-of-service` (effective 2026-09-25), 2.2: "(i) integrate or combine Vibe with your own products you offer to third-parties including any other software, hardware, or other technology, nor grant any third party access to the Mistral AI Products without our prior written authorization" |
| `agy` | **forbidden for third-party tools**; for the unmodified official CLI on a host's machine, **unclear** | **allowed** through the Gemini API or Vertex (a service account, as 127 5.4) | `https://github.com/google-gemini/gemini-cli/blob/main/docs/resources/tos-privacy.md` (last commit 2026-04-10): "Directly accessing the services powering Gemini CLI [...] using third-party software, tools, or services [...] is a violation of applicable terms and policies."; `https://antigravity.google/terms` (no date shown): "Using third party software, tools, or services to access the Service [...] is a breach of this Agreement."; `https://ai.google.dev/gemini-api/terms` (effective 2026-03-23): "You may only access the Services (or make API Clients available to users) within an available region." |
| `qwen` | **moot**: the qwen.ai login's free tier ended 2026-04-15; a coding-plan key is for its owner only | **depends on the endpoint's provider** (127 3: `OPENAI_BASE_URL`) | `https://github.com/QwenLM/qwen-code/blob/main/docs/users/support/tos-privacy.md` (last commit 2026-10-25): "free tier discontinued 2026-04-15"; "When using your own API key, you are subject to the terms and privacy policies of your chosen API provider" |

Checked by hand: the five `claude` quotes and the `mistral` 2.2 (i) quote
were re-read from the raw pages (`curl -sL` + `grep -o`, n = 1). The
Antigravity and Gemini API quotes came through a summarising fetch; the R7
reviewer (a-946, agy) then fetched all nine URLs of this table live and
matched every quote (n = 1, 2026-10-26). T9 makes this a monthly action.

### 4.2 What the hub offers per kind, then

| kind | API key (127, unchanged) | subscription |
|---|---|---|
| `claude` | yes | **self sign-in only** (4.3): the person signs in with Anthropic's own flow, inside the seat's unmodified CLI. Neither the hub nor the WUI nor the desk ever sees the token. Built behind a switch, off until Anthropic confirms in writing (Q-3 A, O1). |
| `grok` | off until xAI confirms a host may run it on a customer key (owner action O2) | no |
| `mistral` | off until Mistral gives the written authorization (owner action O3) | no |
| `agy` | yes, the service-account JSON (127 9.2, still behind its B0c gate) | no |
| `qwen` | yes, with its provider's terms the customer's choice (127 3) | no |

"Off" means the kind's row on the Agent keys page reads "not available for
workspace keys: waiting for the vendor's terms" with the date of the last
check. Under 127 Q-1 A, that kind's tasks go to the backup vendor.

### 4.3 Claude self sign-in, the one subscription path

- The seat runs as the workspace's own OS user on a fleet box (5). Its
  `CLAUDE_CONFIG_DIR` is that user's own directory, mode 0700, not the
  fleet's login and not a shared one.
- The person (a `biz_owner` or `admin` of W, the subscriber) starts
  "Sign in with my Claude subscription" on the Agent keys page. The hub asks
  that workspace's desk on a fleet box to start the unmodified CLI's own
  login in a new seat.
- **Open (Q-3):** the CLI's login prints a vendor URL and waits for a code
  the person pastes back. That paste reaches the seat through our
  terminal relay. Whether relaying that one code counts as "intermediate
  Claude.ai credentials" is not answered by the page. The owner answered
  Q-3 A (msg `36279386`): T8 builds it behind a switch that stays off until
  the vendor's written answer to O1.
- The token lives only in the CLI's own files in that directory. The desk
  mirror, the token-burn collector and every log exclude the directory, and
  the 127 L9 redaction covers the vendor's token shape (T8).
- On a fleet box, a fleet lane that uses sudo can read these files too
  (5.4). The page says so before the person signs in.
- One subscription is one person's. The page says so: the subscriber's own
  plan limits apply, and other members of W use it only through W's agents.
  Whether that use is "making your account available to anyone else" in the
  consumer terms is **unchecked**, and is part of O1.

### 4.4 Pilot: one customer workspace, `<PILOT>`

Owner HUM-10, t1 `f8f9dfcc`, msg `4abfa8c4-9e76-483f-b70a-7ab936ff0384`,
names one customer workspace whose biz owner has their own Claude
subscription as the pilot. This public spec calls it `<PILOT>`; its name is
in that message only (hidden-workspace rule, SPL-1874).

- **Who signs in**: the `biz_owner` of workspace `<PILOT>`, with their own
  Claude plan, through 4.3 in a `<PILOT>` seat run as `<PILOT>`'s OS user.
  Nobody else signs in for them, and no operator account is used.
- **When**: T8's switch turns on for `<PILOT>` only, and only after
  Anthropic's written OK (O1, Q-3 A). Until then `<PILOT>` uses API keys
  (4.2) like any workspace.
- **What is checked** after the sign-in and after one real turn: the L23
  grep finds the token's shape 0 times in the hub DB, the hub logs, the
  desk mirror and the token-burn rows; the sign-in files are mode 0600 in
  the seat's 0700 directory on tmpfs; the turn's usage row carries
  `<PILOT>` and `key_source = 'workspace'` (7).
- **Turning it off**: the switch is per workspace. Off ends `<PILOT>`'s
  claude seats within one lease TTL and deletes the CLI's credential files
  (8, sign-out); the biz owner can also revoke the session on the vendor's
  side. Any non-zero count in the checks above turns it off at once.
- T10 is the row.

## 5. Where a workspace key runs: on our fleet boxes (N3, N4)

### 5.1 The options and the owner's pick

| option | isolation from other workspaces | isolation from our fleet | cost |
|---|---|---|---|
| A. key host pool: VMs in our GCP that run only workspace seats, no fleet lane, no sudo for any seat user | 127 5.3 as written | the fleet's lanes never run there | one small VM to start, then by load |
| B. the workspace's seats on a fleet box as its own OS user | uid separation | **none against sudo**: the fleet's agent user may use sudo (2), so every fleet lane can read the key | none |
| C. one dedicated VM per workspace | full | full | one VM per workspace |

**The owner picked B** (Q-1, HUM-10, t1 `f8f9dfcc`, msg
`2e9d03be-99f7-4a3a-88c7-a9ef094f5da2`, confirmed in the form, msg
`45b1e8af-8f63-4057-a7bc-d4c188088251`), verbatim: "Answer 1: B — On our
fleet boxes as a per-workspace OS user: cheaper, but any fleet lane with
sudo could read the key". v0.1 recommended A. There is no key host pool and
no new VM.

**This amends 127 K3** ("a key is used only by seats working for its own
workspace. Never another workspace, the fleet's own lanes, the operator
..."). By the owner's decision above, for a workspace key held on a fleet
box, K3 holds against other workspaces' seats and against the fleet's lanes
**only as far as those lanes do not use sudo**. It no longer holds against
a fleet lane that uses sudo (5.4). 127 K3 holds unchanged for a key on a
workspace's own box. T0 writes this amendment into 127.

C remains a placement rule a workspace may ask for later; it is not
designed here.

### 5.2 How a fleet box takes a workspace

- A workspace gets an OS user on a fleet box when its `biz_owner` or
  `admin` turns on "run our agents on spool-hub's shared boxes" on the
  Agent keys page. The page shows the residual risk of 5.4 in plain words
  next to the toggle, before it can be turned on. An operator cannot turn
  it on: an operator-made admin or biz owner is unconfirmed (3).
- The named action of T3 then creates W's OS user on the fleet boxes the
  placer may use for W (a root write on each box: the owner's go per box,
  12.2), with no sudoers entry and in no root-equivalent group, and starts
  a desk for that user. The desk enrols with a join token minted for that
  one box and workspace (073).
- The desk start checks of 127 5.3 run as written, with **one exception by
  the owner's decision**: "no OS user on the box is root-equivalent" is not
  required on a fleet box, because the fleet's agent user is. Every other
  check stays and refuses the start when it fails: `/proc` `hidepid=2`,
  `ptrace_scope >= 2`, `suid_dumpable = 0`, no plain swap, a memory-backed
  tmpfs for the seat's credential files, and W's own user not
  root-equivalent. T2 measures each fleet box against those checks first
  and reports which ones fail; it changes nothing on a box without the
  owner's go.
- The hub treats W's desk on a fleet box like a `dedicated` pin of W.
  127's lease checks hold: the pin's workspace equals the key's, the read
  runs in the pin's tenant scope, and the key is sealed to that desk's
  X25519 key.

### 5.3 A fleet lane working for a workspace (N4)

A brief with `Workspace: <W>` whose kind W holds a key for (or, for claude,
a signed-in subscription) **runs as W's OS user** on a fleet box where W
has one, never as the fleet's agent user:

- The placer (`do_spl_spawn_enqueue` and its placer) reads the brief's
  `Workspace:` line and asks the hub whether W has a usable key for the
  picked kind. The hub answers set or not set and the boxes where W has a
  desk. It never sends the key.
- If W has a key, the lane runs on one of those boxes, launched through
  127's `spool-key-exec` (or the claude `apiKeyHelper`) as W's OS user,
  with W's worktree in W's home. If W has no key, the brief runs on our
  login as today, with `key_source = hub` (7); see 12.3 for what the
  owner's Q-4 means for that case.
- If W has a key but no box with W's desk is online (none enrolled yet, or
  all offline), the placer holds the row as `waiting_key_host`: it never
  runs the lane as the fleet's agent user with W's key (L19), nor on our
  login, and the task topic says why once. The row places when a box with
  W's desk comes online.
- The fleet's own lanes (no `Workspace:` line) keep running as the fleet's
  agent user and never as W's OS user (L20).
- The lane talks to the spool like any lane. W's desk relays it, and the
  lane-map shows the lane with its box and OS user.

### 5.4 The risk the owner accepted, and what still limits it

**Any fleet lane that uses sudo on a box can read every workspace key and
every claude sign-in held on that box**: the process environment of W's
seats, their memory, and their tmpfs credential files. This includes
fleet lanes working for other workspaces. No guard in this spec stops a
lane that is root.

What still limits it:

- A lane that does not use sudo cannot read W's key: per-workspace OS user,
  `hidepid=2`, `ptrace_scope >= 2`, mode 0700 seat directories (L21).
- Keys and sign-ins sit only in memory-backed tmpfs and the seat's process,
  never on disk or swap (127 5.3, 5.4).
- No key reaches a log, the desk mirror, a pane capture, a transcript or
  the token-burn collector (127 L1..L18, L23 below).
- Keys reach a box only through 127's lease, sealed to W's desk, for one
  lease TTL; revoking ends it (8).
- Every sudo use by a fleet lane is already recorded by the box's
  install action (`do_box_pkg_install`); this spec adds nothing there.

The page of 10 states the first paragraph of this section to the workspace
before it turns hosting on.

## 6. New leak paths

127's L1..L18 hold on a fleet box as written, except L2's "desk refuses a
root-equivalent user" for the fleet's agent user (5.2). N1, N3 and N4 add
these:

| # | leak path | guard | test | red control |
|---|---|---|---|---|
| L19 | a `Workspace: <W>` lane with W's key runs as the fleet's agent user | the placer launches a keyed kind only as W's OS user; the lease refuses any pin that is not W's desk | enqueue a fake brief for W with a fake key set -> runs as W's OS user; lease from the fleet desk -> 403 `box_not_approved` | drop the placer check -> runs as the fleet user (the lease still refuses, which proves the second guard alone) |
| L20 | a fleet lane (no `Workspace:`) runs as W's OS user | the placer never picks W's OS user for a brief without `Workspace: <W>` | a brief without `Workspace:` -> runs as the fleet user | drop the placer rule -> runs as W |
| L21 | a lane without sudo reads another OS user's key on the same box (another workspace's seat, or a fleet lane) | uid separation + the 127 5.3 checks kept in 5.2 (hidepid, ptrace, tmpfs) | W1's seat and a fleet lane without sudo read W2's `/proc/<pid>/environ` and its tmpfs seat dir -> EACCES | mount `/proc` without `hidepid` -> the desk refuses to start |
| L22 | an operator-made `biz_owner` reaches a key | 3: unconfirmed until a confirmed admin or biz owner confirms | operator invite as `biz_owner` -> PUT a key -> 403 `admin_unconfirmed` | drop the confirmation -> 204 |
| L23 | the claude subscription token | 4.3: only in the CLI's own directory of W's OS user; excluded from mirror, collector and logs; L9 redacts its shape | a fake seat prints a fake token of the vendor's shape into a turn -> the hub stores the redacted text; grep the hub DB and logs -> 0 | redaction off -> the fake reaches the DB |
| L24 | the metered fall-back (9) runs on our subscription login | the fall-back seat gets only our API key of that kind; the launcher refuses a fall-back with no API key | fall-back on, W's key exhausted, our API key unset -> the task waits with `no_metered_key`; set -> runs with `key_source = hub`, plan `metered` | let the fall-back use the box login -> it runs on our subscription |

A fleet lane **with** sudo reading a key is not a row here: it is the
accepted risk of 5.4.

## 7. Cost attribution to the workspace

- Every turn on W's key is W's: `usage_events.key_source = 'workspace'` (127
  7.2, built in rdb 0174/0175) for hub turns. For a lane run as W's OS user, the
  token-burn collector (140 2.5) reads W from the seat's OS user and the
  lane's `lifetime/issue-tenant`, and writes it with `key_source =
  'workspace'`. Today the fleet token rows carry no workspace (2). The
  per-workspace mapping belongs to lane `c002-costs-per-workspace` (brief:
  "reuse their lane-to-workspace mapping, do not build a second one"). T6
  adds only the `key_source` field and the key-host source to that mapping.
- W's Costs view shows those tokens at list price as "paid to your vendor",
  never as a charge (127 7.2). Our own cost view keeps them out of the
  fleet's subscription split (123 2.3).
- No VM is W's (5.1 B), so 127 7.1's "hosted box" line has nothing to
  bill. The `byok` formula itself is unchanged (13).
- A metered fall-back turn (9) is ours, not W's: `key_source = hub`, plan
  `metered`, billed to W under spec 121.

## 8. Rotation and revocation

127 4.3 (replace is one transaction) and 5.2 (the desk ends that kind's
seats within one lease TTL, default 15 min) hold. N1-N3 add:

- A replace or remove by a `biz_owner` works the same as one by an admin.
- **Turning hosting off** (the toggle of 5.2 off, or W's OS user removed
  from a box) stops all leases to W's desks at once. The desk ends W's seats
  within one lease TTL. A lane that was running there reports
  `key_revoked` on its task (9).
- **Claude subscription sign-out** on the page: the desk ends W's claude
  seats and deletes the CLI's credential files in that directory. The
  person can also revoke the session on the vendor's side. The page says
  how.
- **Membership end**: when the `biz_owner` or `admin` who set a key leaves
  W, the key stays (it is W's, not theirs), and every remaining admin and
  biz owner is emailed to rotate it. A subscription is the person's: when
  its subscriber leaves W, the sign-in is removed at once.
- Key age: 127's keys get the same 90-day age flag as our secrets
  (`env.secrets.max_age_days`, secrets round 1 §1). The page shows the flag.
  Nothing rotates a customer key by itself.

## 9. When a workspace's key runs out

"Runs out" means: the vendor refuses for credit, quota or a revoked key
(an HTTP 401, 402 or 429 with a quota reason, as each CLI reports it).
A plain rate limit (a 429 that clears by itself) does not count.

The owner picked **Q-2 B** (HUM-10, t1 `f8f9dfcc`, msg
`45b1e8af-8f63-4057-a7bc-d4c188088251`), verbatim: "Answer 2: B —
Per-workspace opt-in to fall back to spool-hub's metered agents, off by
default". So each workspace has one setting, **"fall back to spool-hub's
metered agents"**, which only a `biz_owner` or `admin` can change, and which
is **off** by default.

1. The wrapper (127 X2) classifies the CLI's exit or error line. The desk
   reports `key_exhausted <kind>` to the hub, without the vendor's message
   text (it can echo key fragments).
2. The hub marks W's key of that kind `exhausted`. New leases of that kind
   are refused until a `biz_owner` or `admin` replaces the key or presses
   "retry" on the page.
3. **Fall-back off** (the default): the running task waits, and its topic
   gets one line: "<kind> key of this workspace refused by the vendor (out
   of credit or quota); a workspace admin or business owner can replace it
   on Agent keys." 127 Q-1 A's picker treats an exhausted kind as "no
   key", so a task whose backup vendor has a usable key of W goes there.
4. **Fall-back on**: the task goes on with spool-hub's metered agents,
   charged as `metered` under spec 121, and its topic gets one line saying
   so. The metered agent runs **only on our API key** of that kind, never on
   our Pro or Max subscription logins (owner Q-4, 12.3; L24). With no API key
   of ours for that kind, the task waits as in 3, with `no_metered_key`.
5. Either way, every `admin` and `biz_owner` of W is emailed once per
   exhaustion.
6. **Our owner is not told.** It is the workspace's account. The operator
   sees the count of exhausted keys per day on Monitoring, never which
   workspace's.

### 9.1 Built: the box half (T5 increment 1, SPL-3738)

`spool key-exec <kind> -- <cli> [args...]` is 127 X2's wrapper and point 1
above. It asks the desk socket (`$SPOOL_KEY_SOCK`, one JSON line each way:
`{"op":"lease","kind":...,"seat":...}`, `{"op":"exhausted","kind":...,"seat":...,"task":...}`;
the server half is 127 X1, its own row) for a lease on **every** start, then
forks the CLI in the seat dir (`$SPOOL_SEAT_DIR`) and waits:

- `seat` is that seat dir: the desk records it against the caller's
  SO_PEERCRED pid and removes it once the pid is gone (127 5.4); a path
  outside its `<runtime>/spool-seat/` is refused `bad_seat`.
- claude's helper asks `{"op":"helper","kind":"claude"}`: answered only from
  the lease the desk already holds, never a new hub lease per helper call
  (127 5.2); with none held it is refused `no_lease` and the helper exits 1
  with nothing on stdout. Refusals are tokens only (`key_exhausted`,
  `no_key`, `no_lease`, `bad_seat`, `no_box_key`, `no_lease_route`,
  `bad_kind`, `bad_request`, ...). Agreed with X1 (c-128), 2026-10-27.

- The key is set in the CLI's environment only (grok `XAI_API_KEY` with
  `GROK_HOME` = the seat dir, mistral `MISTRAL_API_KEY`, qwen
  `OPENAI_API_KEY` + `OPENAI_BASE_URL` with `--auth-type openai`), never an
  argv. claude gets no key variable: a seat settings file (0600) names
  `spool key-helper --sock <path> claude` as its `apiKeyHelper`, passed by
  `--settings`. Every other vendor variable is removed, the hard core limit
  is 0, the telemetry switches of 127 L16 are off. agy is refused until
  127's B0c gate (127 9.2, R5.2).
- The classifier reads the CLI's exit code and the last 8 KiB of its
  stderr: an HTTP 401 or 402, a quota 429 (`insufficient_quota`, "exceeded
  your current quota"), a billing or credit line, or a revoked or invalid
  key is a refusal; a plain rate limit or overload is not. A refusal is
  reported as `exhausted <kind>`, with no vendor text, and the wrapper exits
  **79**. A desk lease refused with `key_exhausted` also exits 79 before the
  CLI runs, so a supervisor stops there; any other refusal exits 78.
- Not claimed: an interactive CLI that shows the refusal and stays open is
  not classified by the wrapper (it never exits); for claude the hub's 409
  on the helper's next lease is the guard.
- Tests: `csi-spl-api/src/go/spool-hub-api/internal/keyexec/` (the T5 red
  control `TestRedControlFake402`, L6, L7, L10, L14, L15) and
  `cmd/spool/key_exec_test.go`.

### 9.2 Built: the hub half, routes and state (T5 increment 2, SPL-3738)

The desk's client (`hubclient.VendorKeyHub`, 127 X1) calls two box routes
with its session's upload token; the box is the token's, never a body's:

- `POST /v1/vendor-keys/{kind}/lease`: the checks of 127 5.2 step 2, in
  this order: 403 `box_only` (a member's token), 503 `vendor_keys_off`, 400
  `bad_kind`, 409 `kind_not_available`, 403 `box_not_dedicated` (the pin's
  `box_mode` is not `dedicated`), 403 `box_not_approved` (no row in
  `workspace_vendor_key_boxes`), 409 `no_key`, 409 `key_exhausted`. The row
  is read in the pin's own tenant scope (127 L1). No refusal is a 404: the
  desk reads a 404 as `no_lease_route`. A lease that passes every check is
  answered sealed (9.3).
- `POST /v1/vendor-keys/{kind}/exhausted` (point 1): no vendor text; an
  optional body `{"task_id": "<task>"}` (9.4), none = a report with no
  task. The hub sets `workspace_vendor_keys.exhausted_at` (rdb 0235) and
  writes one `exhausted` audit row (kind, box); a second report of the same
  refusal answers `first: false` and writes nothing. From then on every
  lease of that kind, on every box of W, is 409 `key_exhausted` (point 2).
- `POST /v1/vendor-keys/{kind}/retry` (a manager, `vendor_keys.manage`,
  confirmed) clears it with a `retry` audit row; a PUT that replaces the
  key clears it too. `GET /v1/vendor-keys` shows `exhausted` and
  `exhausted_at` per kind.
- The switch of point 4: `PUT /v1/vendor-keys/settings
  {"metered_fallback": bool}` (a manager), stored in
  `workspace_vendor_key_settings` (no row = off, the default), audited
  `fallback_on` / `fallback_off`, read back as `metered_fallback` in GET.
- The mail of point 5: on the FIRST report of a refusal, every `admin`
  and `biz_owner` of W who is neither disabled nor suspended gets
  `vendor_key_exhausted` (19 locales; workspace, kind, last4 and when, what
  to do; no vendor text, no box, no link), through T1's
  `mailVendorKeyNotice`. A second report of the same refusal mails nobody.
  The locale text is a claude draft: agy reviews it LAST before it ships
  (the fleet's language rule).
- Tests: `internal/hub/vendor_key_lease_test.go` (the T5 red control
  `TestVendorKeyLeaseRedControl`: a report, then 409 `key_exhausted` on both
  boxes of W, retry clears it; with the exhausted check removed it goes
  red), `internal/store/vendor_key_lease_test.go` (Memory and Postgres).

Not built in T5:

- **The topic line of points 3 and 4** was its own row after T5 (dispatch
  holder c-003, msg `fabf51b2`): built in 9.4, SPL-4027.
- **The picker (127 Q-1 A) and what the fall-back switch does** (point 4
  with L24, our API key only) belong to the placer (T4): the hub stores the
  switch and shows an exhausted kind in GET; nothing reads them yet.

### 9.3 Built: the sealed lease (T5 increment 3, SPL-3738, with 127 H2)

127 5.2 step 3, so a TLS-terminating proxy sees ciphertext only:

- **The join field.** A dedicated `spool join` loads (or makes, 0600) the
  key desk's X25519 identity, `<hub dir>/desk-x25519.key`
  (`keydesk.IdentityPath`, the file the sidecar's desk opens leases with),
  and sends its recipient as `box_x25519` in `POST /v1/pins/join`, signed
  with the rest (`wire.JoinKeyPayload`: the canonical join bytes plus
  `box_x25519`; without it the bytes are exactly the old ones). The hub
  checks the shape (`age1...`) and the signature over it, and records it
  on the pin (rdb 0235 `pins.box_x25519`). Every join writes it, so a
  re-join without one clears it.
- **The answer.** The lease opens the row with T1's sealer (KMS), seals
  `keydesk.Payload` (kind, box, key_id, key, base_url, `ttl_s` 900) to the
  pin's recipient with age, writes the `lease` audit row (box, kind,
  last4) and only then answers `{"sealed": "<base64>"}`. The desk refuses
  an answer that names another kind or box. The hub logs tenant, box,
  kind and last4, never the key (127 L4).
- **A pin enrolled before the field** has no recipient and gets 409
  `box_key_not_enrolled` until it joins again with a fresh token.
- Tests: `TestVendorKeyLeaseRedControl` (box-b without a recipient is
  refused; box-a's desk opens the answer to `sk-test-0000`; another
  identity does not open it; the key in 0 log lines),
  `TestJoinRecordsDeskRecipient` (recorded, cleared by a re-join without
  it, a recipient outside the signature is 400 `bad_sig`, a malformed one
  400 `bad_json`), `internal/store/pin_x25519_test.go` (Memory and
  Postgres), `internal/action/join_test.go` (the join signs the desk's
  recipient; CONTROL: the bytes without it do not verify).

### 9.4 Built: the topic line (SPL-4027)

Point 3's line reaches the running task's topic. The task id rides the
chain the refusal already takes:

1. **The seat.** `SPOOL_TASK_ID` (`keyexec.TaskEnv`) in the seat's
   environment names its task. `spool key-exec` reads it into
   `keyexec.SockDesk.Task`; unset, the report is today's.
2. **The desk socket.** The exhausted ask carries it as `task`
   (`{"op":"exhausted","kind":...,"seat":...,"task":...}`, omitted when
   empty); `keydesk` passes it as it is to `Hub.Exhausted(ctx, kind, task)`.
3. **The hub.** `hubclient.VendorKeyHub.Exhausted` sends
   `{"task_id": "<task>"}` as the body of `POST
   /v1/vendor-keys/{kind}/exhausted`, and no body when there is no task.
   On the FIRST report of a refusal only (`first: true`), the hub posts
   ONE hub note (`HUB-0`, kind `note`) in that task's topic:
   "<kind> key of this workspace refused by the vendor (out of credit or
   quota); a workspace admin or business owner can replace it on Agent
   keys." The kind only: no vendor text, no key, no last4, no box. A
   repeat report (`first: false`) writes nothing.
4. **Workspace-scoped.** The topic's channel is looked up in the reporting
   box's own workspace (the token's tenant, under RLS). A task id of
   another workspace, an unknown one or a direct-message topic finds no
   channel, and nothing is posted anywhere. A body that does not parse, or
   a task id that is not a UUID (a topic's task id is one), reads as no
   task.
   The refusal is recorded, mailed and answered exactly as without a task.

What it does not do:

- **Point 4's line** ("the task goes on with spool-hub's metered agents")
  waits for the picker (T4): nothing switches a task to a metered agent
  yet, so the hub posts point 3's line whatever the switch says.
- **Who sets `SPOOL_TASK_ID`.** The seat launcher that starts `spool
  key-exec` for a workspace (127 X1, 5.3) must export it; a seat started
  without it reports with no task, and only the mail and the 409
  `key_exhausted` tell anyone.

Tests: `internal/hub/vendor_key_lease_test.go`
`TestVendorKeyExhaustedTopicLine` (one line after two reports of one
refusal; nothing for another workspace's task, a DM topic, a task id that
is not a UUID or no task;
CONTROL: the other workspace's own report of its own task gets its line).
Red controls, run by hand: with the first-only check removed it posts 2
lines; with the workspace lookup replaced by a fixed channel, another
workspace's task id gets a line. `internal/keydesk/keydesk_test.go`
`TestExhaustedPassesTheTask`, `internal/keyexec/keyexec_test.go`
`TestSockDeskExhaustedTask`.

## 10. The WUI: Agent keys page

127 W1's page (`csi-spl-wui/src/pages/tenant-settings/agent-keys.vue`)
with these changes:

- Visible to `vendor_keys.manage`, so `biz_owner` and `admin` (3).
- Per kind: a state of set, not set, exhausted (with the retry button, 9),
  not available (4.2, with the date of the last terms check) or
  unconfirmed (3).
- The claude row adds "Sign in with my Claude subscription" (4.3, hidden
  while T8's switch is off, which it is until Anthropic's written OK). It shows who signed in, when and on
  which box, and a sign-out button.
- The toggle "run our agents on spool-hub's shared boxes" (5.2), with the
  risk of 5.4 in plain words beside it, and the boxes where W has a desk,
  marked "shared spool-hub box", beside the workspace's own boxes.
- The toggle "fall back to spool-hub's metered agents" (9), off by default,
  with the line "charged as metered; runs on spool-hub's API keys".
- The usage line per kind (127 8.1) shows this month's tokens at list price
  "paid to your vendor" (7).
- All new text is translation keys in every locale file, and agy reviews
  it LAST (text only, no secrets).

## 11. Rows (each one small lane, with its red control)

T1..T8 change code, so each lands with its doc change. The rows of 127
(H1, H2, H3, W1, X1, X2, P1) are still unbuilt (2). T1, T5 and T7 amend
their briefs rather than adding parallel lanes. Kinds: per the fleet's
split; secrets work goes to claude (or grok, if it has quota).

| # | lane | task | red control |
|---|---|---|---|
| T0 | doc | spec 127 v1.4: point 5.1, 5.3 and 8 at this spec (N1, N3), and amend K3 and L2 as 5.1 and 6 say, citing msg `2e9d03be`; 127's editor or the integrator, not this lane | `grep -c '159-byo-ai-keys' csi-spl-doc/specs/127-workspace-vendor-keys/spec.md` -> >= 4 |
| T1 | hub (claude), with 127 H1 | `vendor_keys.manage` for `biz_owner` + `admin`; operator-made `biz_owner` unconfirmed; email to admins and biz owners | `biz_owner` PUT `sk-test-0000` -> 204 (403 on the grant removed); L22. Built: 11.1 |
| T2 | orc (claude) | a read-only check action: measure each fleet box against the 127 5.3 checks kept in 5.2 (hidepid, ptrace, suid_dumpable, swap, tmpfs) and report which fail. No terraform, no new VM; any change to a box is a separate owner go | a fake box with swap on -> reported as failing (127 L13); all checks pass -> reported clean |
| T3 | orc (claude), with 127 X1 | the named action that creates W's OS user (no sudoers, no root-equivalent group) and desk on a fleet box when W turns hosting on, a join token per box and workspace; the desk start checks with 5.2's one exception | the desk starts as W on a fleet box; W's user added to `sudo` or `docker` -> refused; `/proc` without `hidepid` -> refused |
| T4 | orc (claude) | placer: `Workspace: <W>` + a keyed kind -> a box with W's desk, as W's OS user, else `waiting_key_host`; a brief without `Workspace:` never as W | L19, L20 |
| T5 | box + hub (claude), with 127 X2/H2 | out of credit: classify the vendor refusal, `key_exhausted`, the hub state, the topic line, emails, picker as "no key", the per-workspace metered fall-back on our API key only (9, L24) | a fake CLI exits with a fake 402 -> the topic gets the line, the next lease -> 409 `key_exhausted`; classifier off -> the seat restarts in a loop on the dead key |
| T6 | orc (claude), after `c002-costs-per-workspace` | collector: workspace and `key_source = 'workspace'` for seats run as W's OS user (7) | a fake seat as W's OS user -> its token row carries W and `workspace`; the same seat as the fleet user -> `hub` |
| T7 | wui (claude), with 127 W1 | the page changes of 10; agy reviews the locale text LAST | e2e: a `biz_owner` sees the page, a `developer` does not; the exhausted state shows retry; the key cleared from the store after save (127 L12) |
| T8 | box (claude), behind a switch **off until Anthropic's written OK (O1)** | claude self sign-in in W's seat on a fleet box, sign-out, directory excluded from mirror, collector and logs; the hub's L9 redaction gains the token shape | L23; grep the hub DB, hub logs and the mirror for a fake token after sign-in -> 0 |
| T10 | box + hub (claude), after T8 and O1 | the `<PILOT>` pilot of 4.4: switch on for `<PILOT>` only, its biz owner signs in, run the checks of 4.4, report them in the spec 159 topic | the L23 grep -> 0 for the real token shape; switch off -> seats ended and credential files gone within one lease TTL |
| T9 | orc (mistral or agy: docs) | `do_spl_vendor_terms_check`: monthly, fetch the nine URLs of 4.1, compare the quoted sentences, open an issue when one changes or goes missing | a page fixture with one quote edited -> issue opened; the same fixture unchanged -> none |

### 11.1 T1 as built (SPL-3684, with 127 H1)

Hub and rdb only; the WUI page is T7's (with 127 W1), the lease and the
key-box approval are 127 H2's.

| piece | where |
|---|---|
| `vendor_keys.manage` for `biz_owner` and `admin` | rdb `0232_vendor_keys_manage.sql`, `internal/rbac/rbac.go` |
| the seal of 127 4.2: a fresh data key per row, AES-256-GCM under `tenant_id\|kind\|key_id`, the data key wrapped by Cloud KMS, the fingerprint an HMAC under the pepper | `internal/vendorkey/vendorkey.go` |
| `GET /v1/vendor-keys`: per kind `available`, `set`, `last4`, `set_at`, `set_by`, `base_url`, and the caller's `confirmed`; never the key, the ciphertext or the fingerprint | `internal/hub/vendor_keys.go` |
| `PUT /v1/vendor-keys/{kind}` `{"key", "base_url"?}` -> 204; `DELETE /v1/vendor-keys/{kind}` -> 204, 404 `not_set`; each writes its `set`, `replace` or `remove` audit row in the same transaction | same, `internal/store/vendor_keys.go` |
| `PUT /v1/vendor-keys/managers/{human_id}` -> 204: a confirmed manager confirms a member who holds `vendor_keys.manage`; the `admin_confirm` audit row names it in the new column `subject` | rdb 0232, same files |
| an operator-made manager (`admitted_by` `operator` or `bootstrap`) in a workspace that holds a key: PUT, DELETE and the confirm answer 403 `admin_unconfirmed` until an `admin_confirm` row names it, written at or after its membership began; GET stays open (read-only, 127 8) | same |
| every route refused under an act-as session, 403 `act_as_refused` (a store error reads as a clone) | same |
| the kinds that take a key today: `claude` and `qwen` (qwen with an https `base_url`, the others none); `grok`, `mistral` (4.2, O2 and O3) and `agy` (127 R5.2, B0c) answer 409 `kind_not_available` | `VendorKeyAvailable` in `vendor_keys.go` |
| each set, replace and remove mails every `admin` and `biz_owner` who is not disabled or suspended, last4 only; a relay failure is logged as `mail.Digest`, the change stays. The mail is `vendor_key_changed` (19 locales, agy reviews the text last): workspace, agent kind, the change, last4, who and when, no link; with no relay the hub logs `vendor_key.mail_off` and mails nobody | `mailVendorKeyNotice`; `internal/mail/templates/vendor_key_changed/`; `vendorKeyMailer` in `cmd/spool/hub_vendor_keys.go` |
| no body is logged: the handlers log tenant, kind, actor and last4 | test `TestVendorKeysNeverLogTheKey` (127 L4, hub half) |
| off until configured: `SPOOL_HUB_VENDOR_KEYS_KMS_KEY` and `SPOOL_HUB_VENDOR_KEYS_PEPPER` unset -> every route 503 `vendor_keys_off`, never an unsealed write | `cmd/spool/hub_vendor_keys.go` |

Tests (`internal/hub/vendor_keys_test.go`, Memory and Postgres;
`internal/vendorkey/vendorkey_test.go`; the store shape test gains the
`subject` rows): the T1 red control (a `biz_owner` PUTs `sk-test-0000` ->
204, 403 with the grant taken off `biz_owner`), L22 and 127 L3's confirm
half (403 `admin_unconfirmed`, 204 once confirmed; 204 with the check
dropped), the act-as refusal and 127 L4 (the fake in 0 log lines and 0
answers; 1 with a planted log line).

Not done here, each its own lane:

- **The hub's environment.** Step 030 does not yet inject the two variables
  above, so the routes answer 503 on dev and prd until an iac lane adds them
  from cnf `vendor_keys` (the KMS key name and the pepper secret of step 057).
- **The key-box list in GET** and the box approval routes: 127 H2.
- **One path the 127 Q-4 A rule makes slow, as written:** a workspace whose
  only managers the operator invited can set its first key, and then every
  one of them is unconfirmed. Today the way out is that one of them invites
  a second admin or biz owner from the WUI (that membership is confirmed)
  who confirms them. Whether the member who set the first key should count
  as confirmed is the 127 editor's call, not this row's.

## 12. What needs the owner

### 12.1 The owner's answers

The lease holder c-002 posted Q-1..Q-4 as one poll in t1 `f8f9dfcc`
(`05060643`). HUM-10's answers, verbatim:

| q | answer | msg | where |
|---|---|---|---|
| Q-1 where a key runs | "Answer 1: B — On our fleet boxes as a per-workspace OS user: cheaper, but any fleet lane with sudo could read the key" | `2e9d03be-99f7-4a3a-88c7-a9ef094f5da2`, form `45b1e8af-8f63-4057-a7bc-d4c188088251` | 5.1, 5.4 |
| Q-2 a key that runs out | "Answer 2: B — Per-workspace opt-in to fall back to spool-hub's metered agents, off by default" | `45b1e8af-8f63-4057-a7bc-d4c188088251` | 9 |
| Q-3 claude subscriptions | "Answer: A — Allow them: build the self sign-in behind a switch, on only after Anthropic confirms in writing (Q-3 A)" (replaces his earlier "Answer 3: C — API keys only, no subscriptions" in `45b1e8af`) | `36279386-d0f1-4aff-b3e3-bf9f6cfc1acf` | 4.3, T8 |
| Q-4 the 12.3 finding | "we will make the Customers use their own API Keys", refined to "we will try to get them to use their own subscriptions and api keys , not ours" | `26288821-e223-4f70-b37e-a7a71404a700`, `ee47ddde-d9d8-4097-805f-f8bb13a21e92` | 12.3 |

v0.1's options, for the record: Q-1 A was a key host pool (5.1 A); Q-2 A no
fall-back; Q-3 B turning the sign-in on from the page's text alone; Q-3 C
API keys only.

### 12.2 Actions only the owner can take

- **O1**: ask Anthropic in writing whether 4.3 (the person signs in inside
  the unmodified CLI on our host, and the code is pasted through our
  terminal) is allowed, and whether W's other members may use the
  subscriber's plan through W's agents.
- **O2**: ask xAI whether a host may run the grok CLI on a customer's API
  key. Until then, grok is "not available" (4.2).
- **O3**: ask Mistral for the written authorization of its commercial
  terms 2.2 (i). Until then, mistral is "not available" for workspace keys
  (4.2).
- **A go per fleet box** before T3 first creates a workspace's OS user
  there (a root write on the box), and before any change T2's report calls
  for. No new VM, so no IAM or billing go.

### 12.3 Customers on their own keys, not ours (Q-4)

The page quoted in 4.1 says "Customers may not pay for, resell, or
intermediate Claude usage on their end users' behalf". It also forbids
routing "requests through Free, Pro, or Max plan credentials on behalf of
their users". v0.1 reported this to the owner.

**The owner's decision** (Q-4, msgs `26288821` and `ee47ddde`, 12.1):
customer workspaces use **their own subscriptions and API keys, not ours**.
In this spec that means: a workspace's AI work runs on that workspace's own
keys (5.3) and claude sign-ins (4.3), and the one place this spec uses our
credentials for a customer, the metered fall-back of 9, runs only on our API
keys, never on our Pro or Max subscriptions (L24).

What it means elsewhere. This spec names these and changes neither; their
owners decide:

- **SPL-3528 fleet lanes doing customer work** (2, the `Workspace: <tenant>`
  brief line): today such a lane runs on our own subscription logins when W
  has no key (5.3). Under Q-4 that is the case to end.
- **Spec 121's `metered` plan**: under Q-4 it serves customer turns only
  from our API keys, never from a subscription.

## 13. Not in scope

- Building anything (docs only).
- More than one key per kind (127 3).
- Customer-run boxes. 127 covers them, and its rules do not change.
- The `byok` price formula (127 7.1, unchanged).
- Changing SPL-3528's lanes or spec 121 (12.3 names what Q-4 means for
  them).
- A key host pool or per-workspace VM (5.1 A and C, not picked).

## 14. Version log

- v0.1 (2026-10-26, c-298): first draft for an R7 cross-vendor review.
- v0.1, R7 PASS (2026-10-26, c-298): reviewer a-946 (agy) on 9bb008e43;
  folds its W1 (T9 fetches all nine URLs), W2 (5.3 `waiting_key_host` when
  W has a key but no online key host) and W3 (4.1 quotes all checked by
  hand). The owner's Q-1..Q-4 answers make v0.2.
- v0.2 (2026-10-26, c-298): the owner's answers (12.1). Q-1 B: keys run on
  fleet boxes as a per-workspace OS user; 5.1-5.3 rewritten, no key host
  pool, 127 K3 amended, residual risk in 5.4, L19-L21 reworded, T2 a
  read-only check. Q-2 B: per-workspace metered fall-back, off by default,
  on our API keys only (9, L24). Q-3 A: 4.3, T8 and O1 kept, the switch off
  until Anthropic's written OK. Q-4: 12.3 records the decision and names
  SPL-3528 and spec 121 without changing them. Pilot `<PILOT>` for the
  claude self sign-in (4.4, T10; msg `4abfa8c4`). For an R7 review.
- v0.2 + T1 (2026-10-27, c-330, SPL-3684): 11.1 records what row T1 (with
  127 H1) built in the hub and rdb 0232, and what it leaves to other rows.
- v0.2 + topic line (2026-10-28, c-415, SPL-4027): 9.4, the line of 9
  point 3 in the running task's topic (task id seat -> key-exec -> desk ->
  hub, first report only, workspace-scoped); 9.2's "Not built" points to it.

<!-- version: 0.2.0 · updated: 2026-10-28 · last-edit: 2026-10-28T13:50:00Z -->
