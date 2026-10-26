# Spec 159: workspace admins and business owners bring their own AI keys, also on our shared GCP hosts

**Feature ID**: `159-byo-ai-keys` · **Status**: Draft v0.1 (R7 PASS) ·
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
keys off fleet boxes, and why N3 needs a host of its own (5).

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
| `claude` | yes | **self sign-in only** (4.3): the person signs in with Anthropic's own flow, inside the seat's unmodified CLI. Neither the hub nor the WUI nor the desk ever sees the token. Off until Q-3 is answered. |
| `grok` | off until xAI confirms a host may run it on a customer key (owner action O2) | no |
| `mistral` | off until Mistral gives the written authorization (owner action O3) | no |
| `agy` | yes, the service-account JSON (127 9.2, still behind its B0c gate) | no |
| `qwen` | yes, with its provider's terms the customer's choice (127 3) | no |

"Off" means the kind's row on the Agent keys page reads "not available for
workspace keys: waiting for the vendor's terms" with the date of the last
check. Under 127 Q-1 A, that kind's tasks go to the backup vendor.

### 4.3 Claude self sign-in, the one subscription path

- The seat runs as the workspace's own OS user on a key host (5). Its
  `CLAUDE_CONFIG_DIR` is that user's own directory, mode 0700, not the
  fleet's login and not a shared one.
- The person (a `biz_owner` or `admin` of W, the subscriber) starts
  "Sign in with my Claude subscription" on the Agent keys page. The hub asks
  that workspace's desk on the key host to start the unmodified CLI's own
  login in a new seat.
- **Open (Q-3):** the CLI's login prints a vendor URL and waits for a code
  the person pastes back. That paste reaches the seat through our
  terminal relay. Whether relaying that one code counts as "intermediate
  Claude.ai credentials" is not answered by the page. Nothing is built past
  the design until the owner answers Q-3. O1 is his written question to
  the vendor.
- The token lives only in the CLI's own files in that directory. The desk
  mirror, the token-burn collector and every log exclude the directory, and
  the 127 L9 redaction covers the vendor's token shape (T8).
- One subscription is one person's. The page says so: the subscriber's own
  plan limits apply, and other members of W use it only through W's agents.
  Whether that use is "making your account available to anyone else" in the
  consumer terms is **unchecked**, and is part of O1.

## 5. Where a workspace key runs: on our hosts (N3, N4)

### 5.1 The options

| option | isolation from other workspaces | isolation from our fleet | cost |
|---|---|---|---|
| A. **key host pool**: VMs in our GCP that run only workspace seats, each workspace as its own OS user, and no fleet lane, no sudo for any seat user | 127 5.3 as written: no OS user reads another's processes | the fleet's lanes never run there | one small VM to start, then by load |
| B. the workspace's seats on a fleet box as its own OS user | uid separation | **none**: the fleet's agent user may use sudo (2), so every fleet lane can read the key | none |
| C. one dedicated VM per workspace | full | full | one VM per workspace |

**Pick: A**, and the owner chooses it in Q-1. 127 5.3 already allows several
workspaces on one machine when no OS user on it is root-equivalent. A is
that machine, hosted by us, so the desk start checks of 127 5.3 pass
unchanged. B breaks K3 of 127 ("nobody else uses those API keys"). C is A
with one workspace per VM, so a workspace that asks for it later is a
placement rule, not a new design.

### 5.2 How a key host joins

- A key host is a VM from a new terraform step (T2). It is built with
  `/proc` `hidepid=2`, `ptrace_scope >= 2`, `suid_dumpable = 0`, no swap and
  a tmpfs `/run/user` (127 5.3, 5.4). Its image has no fleet launcher, no
  fleet login and no sudoers entry for any seat user.
- Root access to a key host goes only through a named, audited action, as
  127 Q-2 A decided for hosted dedicated boxes.
- A workspace gets an OS user on a key host when its `biz_owner` or `admin`
  approves that host on the Agent keys page (127's key-box approval, with
  the host shown as "hosted by spool-hub"). The desk for that user enrols
  with a join token that this approval mints for that one host (073). An
  operator cannot approve: an operator-made admin or biz owner is
  unconfirmed (3).
- The hub treats a key host's pin like a `dedicated` pin of that workspace.
  127's lease checks hold: the pin's workspace equals the key's, the read
  runs in the pin's tenant scope, and the key is sealed to the box's X25519
  key.

### 5.3 A fleet lane working for a workspace (N4)

A brief with `Workspace: <W>` whose kind W holds a key for (or, for claude,
a signed-in subscription) is placed **on a key host where W has an OS user,
and runs as that user**:

- The placer (`do_spl_spawn_enqueue` and its placer) reads the brief's
  `Workspace:` line and asks the hub whether W has a usable key for the
  picked kind. The hub answers set or not set and the key host ids. It
  never sends the key.
- If W has a key, the lane runs on that key host, launched through 127's
  `spool-key-exec` (or the claude `apiKeyHelper`) as W's OS user, with W's
  worktree in W's home. It never runs on a fleet box. If W has no key, the
  brief runs on our login as today, with `key_source = hub` (7).
- If W has a key but no approved key host is online (none enrolled yet, or
  all offline), the placer holds the row as `waiting_key_host`: it never
  falls back to a fleet box (L19) nor to our login, and the task topic says
  why once. The row places when an approved host of W comes online.
- The fleet's own lanes (no `Workspace:` line) never run on a key host
  (L20).
- The lane still talks to the spool like any lane. The key host's desk
  relays it, and the lane-map shows the lane with its host.

## 6. New leak paths

127's L1..L18 hold on a key host as written. N1, N3 and N4 add these:

| # | leak path | guard | test | red control |
|---|---|---|---|---|
| L19 | a `Workspace: <W>` lane placed on a fleet box with W's key | the placer refuses a keyed kind off a key host; the lease refuses any pin that is not W's approved key host | enqueue a fake brief for W with a fake key set -> placed on the key host; lease from a fleet pin -> 403 `box_not_approved` | drop the placer check -> placed on a fleet box (the lease still refuses, which proves the second guard alone) |
| L20 | a fleet lane on a key host | the key host's image has no fleet launcher; the placer never picks a key host for a brief without `Workspace:` | a brief without `Workspace:` -> never placed on a key host | drop the placer rule -> placed |
| L21 | two workspaces on one key host | uid separation + 127 5.3 checks (hidepid, no root-equivalent group) | W1's seat reads W2's `/proc/<pid>/environ` and its tmpfs seat dir -> EACCES | mount `/proc` without `hidepid` -> the desk refuses to start |
| L22 | an operator-made `biz_owner` reaches a key | 3: unconfirmed until a confirmed admin or biz owner confirms | operator invite as `biz_owner` -> PUT a key -> 403 `admin_unconfirmed` | drop the confirmation -> 204 |
| L23 | the claude subscription token | 4.3: only in the CLI's own directory of W's OS user; excluded from mirror, collector and logs; L9 redacts its shape | a fake seat prints a fake token of the vendor's shape into a turn -> the hub stores the redacted text; grep the hub DB and logs -> 0 | redaction off -> the fake reaches the DB |

## 7. Cost attribution to the workspace

- Every turn on W's key is W's: `usage_events.key_source = 'workspace'` (127
  7.2, built in rdb 0174/0175) for hub turns. For a lane on a key host, the
  token-burn collector (140 2.5) reads W from the seat's OS user and the
  lane's `lifetime/issue-tenant`, and writes it with `key_source =
  'workspace'`. Today the fleet token rows carry no workspace (2). The
  per-workspace mapping belongs to lane `c002-costs-per-workspace` (brief:
  "reuse their lane-to-workspace mapping, do not build a second one"). T6
  adds only the `key_source` field and the key-host source to that mapping.
- W's Costs view shows those tokens at list price as "paid to your vendor",
  never as a charge (127 7.2). Our own cost view keeps them out of the
  fleet's subscription split (123 2.3).
- A key host's VM cost is W's "hosted box" line of the `byok` price (127
  7.1), split by seat-hours when several workspaces share it (123 2.4,
  agent-hours).

## 8. Rotation and revocation

127 4.3 (replace is one transaction) and 5.2 (the desk ends that kind's
seats within one lease TTL, default 15 min) hold. N1-N3 add:

- A replace or remove by a `biz_owner` works the same as one by an admin.
- **Revoking a key host** (the toggle off, or the workspace's OS user
  removed) stops all leases to it at once. The desk ends W's seats on it
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

Recommended (Q-2 A): **no fall-back to our login.** That matches 127 Q-1 A
for a missing key.

1. The wrapper (127 X2) classifies the CLI's exit or error line. The desk
   reports `key_exhausted <kind>` to the hub, without the vendor's message
   text (it can echo key fragments).
2. The hub marks W's key of that kind `exhausted`. New leases of that kind
   are refused until a `biz_owner` or `admin` replaces the key or presses
   "retry" on the page.
3. The running task waits, and its topic gets one line: "<kind> key of this
   workspace refused by the vendor (out of credit or quota); a workspace
   admin or business owner can replace it on Agent keys." Every `admin` and
   `biz_owner` of W is emailed once per exhaustion.
4. 127 Q-1 A's picker treats an exhausted kind as "no key", so a task whose
   backup vendor has a usable key goes there.
5. **Our owner is not told.** It is the workspace's account. The operator
   sees the count of exhausted keys per day on Monitoring, never which
   workspace's.

Q-2 B would add a per-workspace setting, "fall back to spool-hub's
metered agents", off by default, charged as `metered` under spec 121.

## 10. The WUI: Agent keys page

127 W1's page (`csi-spl-wui/src/pages/tenant-settings/agent-keys.vue`)
with these changes:

- Visible to `vendor_keys.manage`, so `biz_owner` and `admin` (3).
- Per kind: a state of set, not set, exhausted (with the retry button, 9),
  not available (4.2, with the date of the last terms check) or
  unconfirmed (3).
- The claude row adds "Sign in with my Claude subscription" (4.3, hidden
  until Q-3 is answered and T8 is on). It shows who signed in, when and on
  which key host, and a sign-out button.
- The key-host list shows our hosted key hosts beside the workspace's own
  boxes, marked "hosted by spool-hub", with the same approve toggle.
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
| T0 | doc | spec 127 v1.4: point 5.1, 5.3 and 8 at this spec (N1, N3) after the owner's GO; 127's editor or the integrator, not this lane | `grep -c '159-byo-ai-keys' csi-spl-doc/specs/127-workspace-vendor-keys/spec.md` -> >= 3 |
| T1 | hub (claude), with 127 H1 | `vendor_keys.manage` for `biz_owner` + `admin`; operator-made `biz_owner` unconfirmed; email to admins and biz owners | `biz_owner` PUT `sk-test-0000` -> 204 (403 on the grant removed); L22 |
| T2 | iac (claude) | terraform step for the key host pool: VM template, hidepid, ptrace, no swap, tmpfs runtime, no sudoers, the audited root action. **Apply needs the owner's go** | `terraform plan` shows the hardening; a key host booted with swap on -> the desk refuses (127 L13) |
| T3 | orc (claude), with 127 X1 | key host enrolment: a per-workspace OS user and desk on approval, a join token per host; the named root action | the desk start checks of 127 5.3 pass on a key host and fail on a fleet box (the agent user may use sudo -> refused) |
| T4 | orc (claude) | placer: `Workspace: <W>` + a keyed kind -> W's key host as W's OS user; never a fleet box; a brief without `Workspace:` never on a key host | L19, L20 |
| T5 | box + hub (claude), with 127 X2/H2 | out of credit: classify the vendor refusal, `key_exhausted`, the hub state, the topic line, emails, picker as "no key" (9) | a fake CLI exits with a fake 402 -> the topic gets the line, the next lease -> 409 `key_exhausted`; classifier off -> the seat restarts in a loop on the dead key |
| T6 | orc (claude), after `c002-costs-per-workspace` | collector: workspace and `key_source = 'workspace'` for key host seats (7) | a fake seat as W's OS user -> its token row carries W and `workspace`; the same seat as the fleet user -> `hub` |
| T7 | wui (claude), with 127 W1 | the page changes of 10; agy reviews the locale text LAST | e2e: a `biz_owner` sees the page, a `developer` does not; the exhausted state shows retry; the key cleared from the store after save (127 L12) |
| T8 | box (claude), **off until Q-3** | claude self sign-in in W's seat on a key host, sign-out, directory excluded from mirror, collector and logs; the hub's L9 redaction gains the token shape | L23; grep the hub DB, hub logs and the mirror for a fake token after sign-in -> 0 |
| T9 | orc (mistral or agy: docs) | `do_spl_vendor_terms_check`: monthly, fetch the nine URLs of 4.1, compare the quoted sentences, open an issue when one changes or goes missing | a page fixture with one quote edited -> issue opened; the same fixture unchanged -> none |

## 12. What needs the owner

### 12.1 Questions (one poll form, posted by the lease holder)

- **Q-1 Where a workspace key runs on our infra.**
  - A (recommended): only on a **key host pool** in our GCP (5.1 A): no
    fleet lane runs there, no seat user has sudo, each workspace runs as its
    own OS user. A fleet lane working for W with W's key runs there as W.
  - B: on our fleet boxes as a per-workspace OS user. Cheaper, but every
    fleet lane, which may use sudo, can read the key. This breaks 127 K3.
- **Q-2 A key that runs out.**
  - A (recommended): no fall-back. The task waits, its topic says why, and
    W's admins and biz owners are emailed (9).
  - B: a per-workspace opt-in, "fall back to spool-hub's metered agents",
    off by default, charged as `metered`.
- **Q-3 Claude subscriptions.**
  - A (recommended): build the self sign-in (4.3) behind a switch, and turn
    it on only after the vendor confirms in writing that relaying the
    sign-in code through our terminal is its "own flow" (O1). API keys work
    meanwhile.
  - B: turn it on from the page's text alone ("including where a platform
    hosts Claude Code").
  - C: API keys only; no subscriptions.

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
- **GO on T2's apply** (a new VM: an IAM and billing change).

### 12.3 A finding beyond this spec, for the owner

The page quoted in 4.1 also says "Customers may not pay for, resell, or
intermediate Claude usage on their end users' behalf". It also forbids
routing "requests through Free, Pro, or Max plan credentials on behalf of
their users". Two things today may fall under that, and nobody has checked
them against these terms:

- fleet lanes on our own subscriptions doing a customer workspace's work
  (2, SPL-3528);
- spec 121's `metered` plan, if it serves customer turns from a
  subscription rather than an API key.

This spec changes neither. It is reported so the owner can decide whether
to open a review topic.

## 13. Not in scope

- Building anything (docs only).
- More than one key per kind (127 3).
- Customer-run boxes. 127 covers them, and its rules do not change.
- The `byok` price formula (127 7.1, unchanged).

## 14. Version log

- v0.1 (2026-10-26, c-298): first draft for an R7 cross-vendor review.
- v0.1, R7 PASS (2026-10-26, c-298): reviewer a-946 (agy) on 9bb008e43;
  folds its W1 (T9 fetches all nine URLs), W2 (5.3 `waiting_key_host` when
  W has a key but no online key host) and W3 (4.1 quotes all checked by
  hand). The owner's Q-1..Q-4 answers make v0.2.

<!-- version: 0.1.1 · updated: 2026-10-26 · last-edit: 2026-10-26T15:45:00Z -->
