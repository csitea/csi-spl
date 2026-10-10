# Spec 127 review: seat s-claude-2 (claude)

Reviewed: `spec.md` v0.1 at 0caca00c4 (origin/master). Reviewer: c-929.
Every check below was run on that tree, 2026-10-10; the command is cited.
No real key, token, credential path or account id appears here; the only key
is the fake `sk-test-0000`.

Verdict up front: **change**. The direction is right (KMS envelope in
Postgres, admin only, dedicated boxes only, key only in the seat process),
but two isolation holes are real and measured: an operator path to a
customer key through `POST /v1/operator/invites` (C1), and a key on an
argv / in a tmux command string by the proposed `exec env` (C2). Both have a
concrete fix below. The rest are corrections of detail.

## 0. Summary of changes asked

| id | section | change | weight |
|---|---|---|---|
| C1 | 5.1, 6 | close the operator path: operator invite as `admin` -> join token -> own "dedicated" box -> lease | blocking |
| C2 | 5.2 step 5 | never `exec env VAR=<key>`: the key is on `env`'s argv and in the tmux command | blocking |
| C3 | 5.3 | `box_mode` is the box's own claim; say what really keeps fleet lanes out | blocking (text) |
| C4 | 5.3 | non-dumpable does not survive `execve`; use a hard core limit + core_pattern check | change |
| C5 | 5.3 | `sudo -n true` misses password sudo and `docker`-group root; check groups | change |
| C6 | 6 | add four leak paths: CLI state files, tmux start command, CLI telemetry, WUI RUM / visitor channels | change |
| C7 | 6 | L10 is false for the four env-var kinds; L13 must refuse, not warn | change |
| C8 | 3 | measured CLI facts (versions below); qwen must pin `--auth-type openai` | change |
| C9 | 4.2 | `set_at` in the AEAD additional data breaks on the pg microsecond round trip | change |
| C10 | 4.2 | use the `personal.profile` no-operator precedent and its test | agree + pointer |
| C11 | 7.1 | the byok price drops spec 122's measured own cost; use 122's formula, token term 0 | change |
| C12 | 7.2 | `key_source` must not default to `hub`; the hub derives it | change |
| C13 | 9 | add Q-4 (operator-created admin in a key-holding workspace) | change |

## 1. The owner's words: agree

Quotes match the brief verbatim; K1..K4 cover all three messages.

## 2. Today, measured: agree, one row to sharpen

Re-run on 0caca00c4:

- `git grep -liE 'vendor_key|api_key' -- csi-spl-rdb` -> nothing. Holds.
- `sed -n 8,12p .../spawn-mistral.sh` -> "Authentication is NOT the launcher's business". Holds.
- `grep -n 'SPOOL_AGENT_USER=' .../lib/spool-env.inc.sh` -> 273. Holds.
- `grep -n capture-pane csi-spl-orc/src/bash/run/spl-dispatch-lease.func.sh` -> 560. Holds.
- `git grep -nE 'ulimit -c|LimitCORE|hidepid|ptrace_scope|PR_SET_DUMPABLE' -- csi-spl-orc csi-spl-iac` -> nothing. Holds.
- `sed -n 165,168p internal/hub/agent_split.go` -> `routeAgentSplit`, PATCH at 167. Holds.
- `grep -n secret_vendors .../0163_tenant_agent_split_kind.sql` -> 20, 49. Holds.
- `sed -n 384,389p internal/hub/join_tokens.go` -> `JoinModePayload(..., req.BoxMode)` verified with the box's OWN key. Holds, and see C3.
- `sed -n 125,145p internal/rbac/rbac.go` -> `AgentsJoin` only in `Admin`; `MembersImpersonate` in both `BizOwner` and `Admin`. Holds.

Sharpen row "`box_mode` is `shared` or `dedicated`": add, from
`sed -n 16,20p csi-spl-rdb/src/sql/postgres/spool-hub/0170_box_join_switch.sql`,
"the mode a box declared, signed by its box key ... NULL on every root-key
pin ... read as shared". It is the box's declaration, not a property the hub
verifies (C3).

Add a row (it carries C1):

| fact | command |
|---|---|
| the operator service account invites anyone into any workspace with any role | `sed -n 111,113p internal/hub/operator.go` -> `POST /v1/operator/invites {tenant, email, role?, ..., no_mail?}`; `sed -n 156,159p` -> `role := rbac.Legacy(body.Role)`, no ceiling |

## 3. Kinds and how many keys: change (C8)

One key per kind per workspace: **agree**, the reasoning holds.

The "reads" column, measured on this box (CLI help, plus a count of env-var
names in the binary, which shows the name exists, not that it authenticates;
B0 still decides):

| kind | version | evidence | replace the cell with |
|---|---|---|---|
| claude | 2.1.292 | `claude --help` -> "Anthropic auth is strictly ANTHROPIC_API_KEY or apiKeyHelper via --settings"; `grep -ao` count in the binary: `apiKeyHelper` 115, `CLAUDE_CODE_API_KEY_HELPER_TTL_MS` 7, `customApiKeyResponses` 11 | `apiKeyHelper` via `--settings <seat file>` ONLY; TTL by `CLAUDE_CODE_API_KEY_HELPER_TTL_MS`. Not `ANTHROPIC_API_KEY`: I believe, unchecked beyond the string count, that an approved env key leaves its tail in `customApiKeyResponses` in claude's per-user state JSON (a disk write, L14) |
| grok | 1.0.50 | `grok --help` shows only `--oauth` and `login`; binary: `XAI_API_KEY` 53 | `XAI_API_KEY` (binary has it, help silent: B0 confirms it beats a login) |
| agy | 1.3.3 | `agy --help` silent on auth; binary: `GEMINI_API_KEY` 12, `GOOGLE_API_KEY` 2, `GOOGLE_APPLICATION_CREDENTIALS` 1, `GOOGLE_GENAI_USE_VERTEXAI` 1 | `GEMINI_API_KEY`; the launcher also unsets `GOOGLE_API_KEY`, `GOOGLE_APPLICATION_CREDENTIALS`, `GOOGLE_GENAI_USE_VERTEXAI` |
| mistral | (vibe) | `sed -n 8,12p spawn-mistral.sh` -> an exported `MISTRAL_API_KEY` beats vibe's own env file | holds |
| qwen | 0.24.6 | `qwen --help` -> `--openai-api-key`, `--openai-base-url`, `--auth-type {openai, openai-responses, anthropic, qwen-oauth, gemini, vertex-ai}` | `OPENAI_API_KEY` + `OPENAI_BASE_URL`, launched with `--auth-type openai` pinned; never `--openai-api-key` (argv, L6) |

Add under the table: qwen can authenticate with an Anthropic or Gemini key
too (`--auth-type`). Without the pin, a qwen seat on a box whose environment
carries another vendor's variable would spend that key under the qwen kind;
`--auth-type openai` plus the `env -u` of L10 closes it, and B0 records it.

The paragraph on the fleet data rule: agree.

## 4. Storage

### 4.1: agree

KMS envelope in Postgres over Secret Manager: agree, for the RLS + same-
transaction audit argument. The list prices match what I believe (KMS
software key version about $0.06/month, $0.03 per 10k operations; Secret
Manager about $0.06 per active version per month), unchecked; I1 confirms.

### 4.2: change (C9, C10)

- **C9**, replace "the additional data `tenant_id|kind|set_at`" with:
  "the additional data `tenant_id|kind|key_id`, where `key_id` is a random
  UUID column of the row, new on every set or replace". Why: Go's
  `time.Now()` carries nanoseconds and `timestamptz` keeps microseconds, so
  an AAD built before the INSERT and rebuilt from the row after it differs
  and every open fails, unless every writer remembers to truncate. A UUID
  round-trips exactly and still binds a ciphertext to its row.
- **C10**, the no-`operator_scope` exception has a precedent and a test
  shape already: `personal.profile` (rdb 0168) refuses an `operator_scope`
  policy, `csi-spl-api/src/go/spool-hub-api/internal/store/personal_catalogue_test.go:171`
  ("policies are exactly") with its red controls at `:398-407`. Replace "The
  catalogue test that expects both policies gets this one table as a named
  exception" with "the table follows the `personal.profile` shape: the
  catalogue test gains `workspace_vendor_keys`, so adding an `operator_scope`
  policy turns it red".
- Add: the lease route reads the row in the PIN's tenant scope (`inTenant`
  of the pin's workspace), so a bug in the Go check of L1 still reads 0 rows.
  L1's red control then needs both removed, which is the point.
- Add: on a tenant delete the rows cascade; the audit keeps last4 only.

### 4.3: agree

Add one line: the hub encrypts before the INSERT, so a Postgres statement
log or slow-query log carries ciphertext only.

## 5. Who, and spawning on the key

### 5.1: change (C1, blocking)

The claim "the operator cannot read a key" does not hold today, measured:

1. The operator service account calls `POST /v1/operator/invites` with
   `{tenant: <victim>, email: <operator's>, role: "admin", no_mail: true}`
   (`operator.go:111-159`: any tenant, any role, no ceiling).
2. It accepts the invite: it is now an `admin` of the victim workspace,
   holding `agents.join` and, per this draft, `vendor_keys.manage`.
3. It mints a join token, joins a box it runs, declaring `box_mode =
   dedicated` (the box's own signed claim, C3), and the desk checks pass on a
   box it built for that.
4. `POST /v1/vendor-keys/{kind}/lease` answers: live pin, same workspace,
   dedicated. The key is out, with one `lease` audit row the victim may
   never read.

`box_join_enabled` does not stop it: only the operator workspace writes it
(`sed -n 8,13p .../0170_box_join_switch.sql`).

Impersonation is not the hole: act-as needs the target in the admin's own
tenant and below the admin (`internal/auth/actas.go:33-39`), so an act-as
session never holds an admin-only permission. Keep the refusal (cheap), but
move the weight to the invite path. Replace the "The operator cannot read a
key" bullet with:

> The operator cannot read a key through the hub. No route returns it (4.3),
> the operator scope reads 0 rows (4.2), and the lease needs a box approved
> for keys by a confirmed admin:
> - **Key-box approval.** A pin gets leases only after an admin of the
>   workspace marks it "may use agent keys" on the Agent keys page
>   (`workspace_vendor_key_boxes (tenant_id, box_id, approved_by, at)`,
>   tenant RLS, audited). Every admin is emailed on each approval and on the
>   first lease from a box.
> - **Operator-made admins are unconfirmed.** An admin membership created by
>   an operator invite (`invited_by` in `operator|bootstrap`) in a workspace
>   that holds a vendor key gets neither `vendor_keys.manage` nor key-box
>   approval until another, confirmed admin confirms it. A workspace with
>   no key (the bootstrap case) is unaffected. Real choice: Q-4.
> - What remains is the GCP project owner (KMS grant + DB read), stated,
>   with the KMS Data Access log and the daily grant check of the draft.

Tests (red control): the four steps above in a store test end with 403
`box_not_approved`; control: drop the approval check -> 200. An operator
invite as admin into a key-holding workspace, then PUT a key -> 403
`admin_unconfirmed`; control: drop the check -> 204.

`vendor_keys.manage` admin-only: agree.

### 5.2: change (C2, blocking)

Step 5, "the env var of section 3, set by `exec env` in the launcher's last
step, never on an argv" contradicts itself: `exec env MISTRAL_API_KEY=<k>
vibe` puts `MISTRAL_API_KEY=<k>` on the argv of `env` (readable in
`/proc/<pid>/cmdline` until `env` execs vibe). Worse, seats start as a tmux
window command, so a key written into that command string sits in the tmux
server's memory and in `tmux list-panes -F '#{pane_start_command}'`, and the
dry-run plan (`launch.cmd`, which `test-spawn-dry-run.sh:95-97` already
guards) would carry it to disk.

Replace step 5's second bullet with:

> - grok, agy, mistral, qwen: the seat's command is a fixed wrapper,
>   `spool-key-exec <kind> -- <cli> <args>`, with no key in it. The wrapper
>   runs as the seat, asks the desk socket, puts the key in its OWN
>   environment (`setenv`, no argv) and `execve`s the CLI. The key is never
>   in a command string, a plan file, tmux or an argv. The wrapper also does
>   the `env -u` of every other vendor variable (L10) and sets the hard core
>   limit (C4).

Also in step 1: the desk checks the caller with `SO_PEERCRED` (uid = the
desk's own OS user), not only the socket's file mode.

For claude: the helper must print nothing on stderr (claude may surface a
helper's stderr in its UI), and the seat's settings file holding the helper
command is passed by `--settings`, never written into a shared settings
file.

Step 3, the X25519 sealing: agree. Add: pins enrolled before the join field
exists have no X25519 key and get no lease until re-enrolled; the WUI's
key-box list says so.

### 5.3: change (C3, C4, C5)

The pick (customer keys only on dedicated, sudo-free boxes; key only in the
seat process) is right; I sign it with three corrections.

- **C3** (text). `box_mode` is the box's declaration, signed by the box's
  own key (`0170_box_join_switch.sql:16-20`; `join_tokens.go:388`). A box
  that wants a key says "dedicated". So "the hub enforces it: a shared-mode
  pin is refused" proves only that an honest shared box is refused. What
  keeps the fleet's lanes out is that (a) fleet boxes are root-key pins of
  the operator workspace (`box_mode` NULL, read as shared), (b) a pin of
  workspace W comes only from a join token W's admin minted, and (c) after
  C1, W's admin approved that box for keys. Say so; the desk's start checks
  are the honest box's self-test, not a hub-side proof.
- **C4.** "the seat runs ... not dumpable": `PR_SET_DUMPABLE` is reset on
  `execve`, so the launcher cannot set it for the CLI; only the CLI itself
  could, and none does (unchecked per CLI; B0 records it). Replace with:
  "the wrapper sets a HARD `RLIMIT_CORE = 0` (`ulimit -Hc 0`; an
  unprivileged process cannot raise it, and it survives exec); the desk
  refuses to start unless `fs.suid_dumpable = 0` and `kernel.core_pattern` is
  a file path or systemd-coredump". I believe, unchecked, that a piped
  core_pattern collector receives the dump whatever `RLIMIT_CORE` says and
  that systemd-coredump honours the limit while other collectors may not;
  X1 measures it. Cross-workspace reads of `/proc/<pid>/environ` are blocked
  by the separate uid plus `hidepid=2` (no `gid=` exemption naming a seat
  user), not by dumpability.
- **C5.** "`sudo -n true` succeeds" misses a user with password sudo, and
  misses root-equivalent groups: a member of `docker`, `lxd` or `disk` reads
  every process on the machine. Replace with: "the desk refuses to start when
  any workspace OS user on the machine is in `sudo`, `wheel`, `admin`,
  `docker`, `lxd` or `disk` (`/etc/group`, readable by all), or its own user
  has any sudoers grant (`sudo -n -l` lists something)". It cannot read
  another user's sudoers entries; that part is root's word, which is Q-2.
- `ptrace_scope >= 2`: keep, as same-user defence in depth; the cross-
  workspace guard is the uid separation.

"Several customer workspaces may share one such machine": agree, given
spec 108 section 2 (one OS user, one key and one pin per workspace on a
machine: `grep -n "enrols once per workspace" csi-spl-doc/specs/108-workspace-owned-boxes/spec.md` -> 19).
Add: that machine's root reads all of them, so a customer-run machine
should host only that customer's workspaces; the join token is minted by
each workspace's admin, so this is that admin's choice, said in the UI.

## 6. Leak paths: change (C6, C7)

The table is the strongest part. Asked changes:

- Every row writes its red control in the test column, as L1 and L3 do.
  Missing today in L2, L5..L8, L10..L13. The controls:
  L2 drop the shared-mode check -> 200, and the sudo check off -> desk starts;
  L5 a launcher that prints the key -> grep finds it;
  L6 the old `exec env` launch -> `cmdline` holds the fake;
  L7 no hard limit -> core file appears;
  L8 a seat that echoes its env -> capture finds it;
  L10 the `env -u` removed -> the child sees the other vendor variable;
  L11 the same restore WITH the KMS grant -> the row opens;
  L12 the store not cleared -> e2e finds the fake;
  L13 plain swap -> desk starts (should refuse).
- **C7, L10** "a child runs `env` -> no vendor variable" is false for grok,
  agy, mistral and qwen: their own key IS in the seat's environment and every
  Bash-tool child inherits it. Replace the test with: "a child sees no OTHER
  vendor's variable; for claude, none at all". It is the workspace's own
  agent reading its own key, already in "what is NOT claimed".
- **C7, L13**: the CLI's heap (node, bun, python) holds the key too and is
  not `mlock`ed, so "plain swap -> warning" is not a guard. Replace with
  "plain swap -> the desk refuses to start".
- **C6**, add rows:

| # | leak path | guard | test (red control) |
|---|---|---|---|
| L14 | the CLI's own state files (claude's `customApiKeyResponses`, qwen settings written by an auth step, vibe's own env file) | claude only by `apiKeyHelper`; the others by environment only, never an auth subcommand; the seat's home holds no key file | after a seat's run, grep the seat user's home for `sk-test-0000` -> 0; control: start claude with `ANTHROPIC_API_KEY` -> found (B0 confirms) |
| L15 | the tmux start command and the dry-run plan | the wrapper of C2; no key in a command string | `tmux list-panes -F '#{pane_start_command}'` and `launch.cmd` -> no fake; control: the `exec env` launch -> found |
| L16 | CLI telemetry and crash reports to the vendor or a third party | telemetry off per CLI (as `spawn-mistral.sh:63` already does for vibe), measured by B0 per CLI | B0 records each CLI's switch; a fake crash with telemetry on shows the env in the report payload (control), off -> none |
| L17 | the WUI's RUM and error beacons; a visitor or embed channel (spec 121) and the live WebSocket fan-out | beacons never carry request bodies; the hub redacts (L9) BEFORE the row is written and before any fan-out, including visitor channels and mail | e2e: a failed PUT of `sk-test-0000` -> no beacon carries it; a seat posts the fake into a visitor channel -> the visitor receives `[vendor key removed]`; control: redaction after fan-out -> the visitor gets the fake |

- L9 detail: HMAC every token in every body is costly and needs a token
  rule. Say: candidates are vendor-shape matches plus any run of at least 32
  `[A-Za-z0-9_-]`; only those are fingerprinted.
- L3 gains the C1 test.

"What is NOT claimed": agree, add "a seat of the workspace can also ask the
desk socket for the workspace's keys of every other kind" (the socket
answers its OS user, which every seat of that workspace is).

## 7. Workspace as a service

### 7.1: change (C11)

The formula drops a cost. Spec 122's price is "(measured own cost +
fixed-cost slice + tokens x (1 + token buffer)) x 1.29"
(`sed -n 383,384p csi-spl-doc/specs/122-capacity-scale-out/spec.md`), with
the hosts the workspace runs on counted (`sed -n 366,372p`, owner
b6a56949), and spec 121's "other own cost" is agent seats and storage
(`sed -n 350,351p csi-spl-doc/specs/121-sales-channel/spec.md`). A byok
workspace still uses seats and storage. Replace the formula with:

`monthly price = (measured own cost + fixed-cost slice + the hosts it runs on) x (1 + margin_pct/100)`, margin_pct = 50

that is, spec 122's formula with the token term at 0 and the plan's margin.
One formula, two plan parameters, no second pricing model. The bill lines
become "hub share", "own use" and "hosted box". The "why the slice"
paragraph: agree for the fixed part, and note 122's M2 already gives the
measured own cost.

Margin `price_plans.margin_pct = 50` for `byok`: agree; spec 121 says the
schema already allows a per-plan value (`sed -n 352,354p`).

Pricing gate (409 `pricing_not_ready`): agree.

### 7.2: change (C12)

`key_source` defaulting to `hub` makes the unsafe value the silent one: a
byok turn whose writer forgets the field becomes chargeable. Replace with:
"`key_source text NOT NULL` with a CHECK, NO default; the hub sets it from
its own state, `workspace` when the turn's seat runs on a pin with a live
lease of that kind, never from the box's report". The rest: agree (list-price
estimate shown, draw-down and charges sum only `hub`; budgets as a self-limit).

### 7.3: agree

Small: `do_spl_lane_mix` is the fleet's picker; a customer workspace's pick
is `internal/hub/agent_split.go`. Name the one that runs for byok seats.

## 8. The WUI: agree, one addition

Add the key-box approval list of C1 to the Agent keys page (boxes of this
workspace, "may use agent keys" toggle, last lease). Password field, cleared
after save, agy reviews the locale text LAST: agree. Path checked:
`ls csi-spl-wui/src/pages/tenant-settings/` -> `split.vue` present.

## 9. Owner questions

- **Q-1**: A (refuse; picker takes the backup with a key; else the task waits, visible).
- **Q-2**: A (accept; root on our hosted dedicated boxes by named action only, audited; stated in the plan terms).
- **Q-3**: A (50%).
- **Q-4 (new, from C1).** An admin the operator created (operator invite) in a workspace that holds vendor keys:
  - A (recommended): gets no `vendor_keys.manage` and cannot approve a box for keys until a confirmed admin of the workspace confirms it; every admin is emailed.
  - B: same powers as any admin, audited only. This leaves the operator a path to a customer key (5.1), against K3.

## 10. Lane plan: change

- B0 first: agree. Add to it: telemetry switch per CLI (L16), whether each
  CLI writes the key to its state (L14), qwen `--auth-type` pin, the
  core_pattern behaviour (C4).
- H1 gains the operator-invite confirmation (C1) and its test.
- H2 gains the key-box approval table and check (C1); its DDL goes into D1.
- X2: the `spool-key-exec` wrapper of C2 (no `exec env`), hard core limit;
  L6, L7, L10, L15.
- X1: the group check of C5, `SO_PEERCRED`, swap refusal (L13).
- W1: the key-box list (section 8) and the RUM check of L17.
- Seats claude or mistral only: agree.

## 11. Panel: agree

Seats are now named: s-claude-2 (this file, c-929) and the mistral seat.

**Verdict: change. I sign v1.0 once C1, C2 and C3 are folded (or answered
with a reason); C4..C13 are corrections I expect folded but would not block
on. Owner answers: Q-1 A, Q-2 A, Q-3 A, Q-4 A (new).**

## 12. Sign: v1.0

Checked v1.0 at 64b24b39636ad374179c861db26acd88a8d2f02e against this review:
C1 (5.1 key-box approval + unconfirmed operator-made admins, L3, Q-4), C2
(5.2 step 5 `spool-key-exec`, L6, L15) and C3 (5.3 "What keeps the fleet's
lanes out") are folded as asked; C4..C13 are in the places section 11.1
names. New fact checked: `invited_by` provenance lives in rdb 0006 and 0084
(`grep -ln invited_by .../0006_*.sql .../0084_*.sql` -> both). Nothing blocks.

SIGNED s-claude-2 (c-929, claude) spec 127 v1.0 at 64b24b39636ad374179c861db26acd88a8d2f02e. Owner answers: Q-1 A, Q-2 A, Q-3 A, Q-4 A.
