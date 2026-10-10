# Spec 127: Workspace vendor keys (bring your own keys)

Version **v0.1** (2026-10-10), draft by the editor seat c-928 (claude). Not
signed. Review seats: one more claude and one mistral (data rule: this is
secrets work, no agy, grok or qwen seat). Each writes only
`reviews/s-<seat>.md`; v1.0 folds them (section 11).

Doc only. Nothing here is built; the code named below is what exists on
origin/master at 254fbc6ad. No real key, token, credential path or account id
appears here: keys are `<VENDOR_KEY>` or the obvious fake `sk-test-0000`.

## 1. The owner's words

Workspace csitea, topic bdc65df6, HUM-10, verbatim.

- msg df10a44e: "We must enable, for each kind of agent, the people to use the admin to set the API keys for each kind of agent in the admin interface of its own workspace."
- msg 6ad93fae: "In this way, there will also be an option to buy the workspace just as a service, and we will not count tokens or anything like that. The customers will just use agents as a service and just pay some kind of a portion of the costs of the G Cloud, with some margin, which should be a little bit bigger, something like 50%."
- msg 29fd4b3c: "We must gain the functionality to be able to spawn every kind of agent with the APIs of the customer and make sure that nobody else uses those API keys or API tokens of the customers."

The plan told to the owner: [74c1943b](https://spool-hub.ai/m/74c1943b-27aa-4ab9-9b4a-d484f46be07c).

### 1.1 What they add up to

| id | requirement | from |
|---|---|---|
| K1 | A workspace admin sets, replaces and removes one API key per agent kind, in Workspace settings of that workspace | df10a44e |
| K2 | Every launcher (claude, grok, agy, mistral, qwen) can start a seat on the workspace's key instead of the box login | 29fd4b3c |
| K3 | Isolation: a key is used only by seats working for its own workspace. Never another workspace, the fleet's own lanes, the operator, a log, a core dump, a pane capture, a transcript or the desk mirror | 29fd4b3c |
| K4 | A plan "workspace as a service": the customer brings the keys, pays a share of the GCP cost + about 50% margin, no per-token charge | 6ad93fae |

## 2. Today, measured

Paths under `csi-spl-api/src/go/spool-hub-api/` unless named.

| fact | the command that shows it |
|---|---|
| no per-workspace vendor key storage exists | `git grep -liE 'vendor_key\|api_key' -- csi-spl-rdb` -> no file |
| seats authenticate per box: each CLI's own login in the agent user's home; the launcher passes no key | `sed -n 8,12p csi-spl-orc/src/bash/features/spawn-agents/scripts/spawn-mistral.sh` -> "Authentication is NOT the launcher's business" |
| the mistral launch drops an exported key so the box's `.vibe/.env` wins | `grep -n 'env -u MISTRAL_API_KEY' csi-spl-orc/src/bash/features/spawn-agents/scripts/spawn-mistral.sh` -> line 63 |
| one OS user runs every seat of a box (`SPOOL_AGENT_USER`) | `grep -n 'SPOOL_AGENT_USER=' csi-spl-orc/src/bash/features/spawn-agents/lib/spool-env.inc.sh` -> 273 |
| the fleet lease tick captures every seat's pane | `grep -n capture-pane csi-spl-orc/src/bash/run/spl-dispatch-lease.func.sh` -> 560 |
| every launcher installs the terminal mirror (spec 036), which sends the seat's turns to the hub | `sed -n 6,20p csi-spl-orc/src/bash/features/spawn-agents/lib/spool-mirror-hooks.inc.sh` |
| no seat limits core dumps or hides `/proc` | `git grep -nE 'ulimit -c\|LimitCORE\|hidepid' -- csi-spl-orc csi-spl-iac` -> nothing |
| the hub never stores private key material of spool keys (006 FR-014, amended by 017 SEC-03) | `grep -n FR-014 csi-spl-doc/specs/006-spool-hub-rental/spec.md` -> 214 |
| the vendor split per task kind is a Workspace setting, `tenant_agent_split_kind` (rdb 0163), `PATCH /v1/agent-split` under `rbac.TenantSettings` | `internal/hub/agent_split.go:167`, `handlePatchAgentSplit` |
| the `secret` kind admits only claude and mistral, in the table | `grep -n secret_vendors csi-spl-rdb/src/sql/postgres/spool-hub/0163_tenant_agent_split_kind.sql` |
| a box joins one workspace; `box_mode` is `shared` or `dedicated` (rdb 0170), the box's Ed25519 key signs the join | spec 108 sections 3.2, 3.5, 3.8; `internal/hub/join_tokens.go:384-389` |
| a workspace on a shared machine runs as its own OS user; root sees every workspace on it | spec 108 section 3.5 |
| FORCE RLS with `tenant_scope` + `operator_scope` on every tenant table; the operator scope reads every row | rdb 0163 tail; spec 108 section 3.6 |
| the metering ledger exists: `usage_events`, `model_prices`, `token_budgets` (rdb 0171, spec 121 T301) | `sed -n 1,40p csi-spl-rdb/src/sql/postgres/spool-hub/0171_usage_events.sql` |
| the per-env SAs cannot read GCP billing; spec 123 reads the BigQuery billing export with its own SA | spec 123 section 3, first row |
| roles: `admin` and `biz_owner` hold `tenant.settings`; `agents.join` is the admin's alone | `internal/rbac/rbac.go:133-140` |

## 3. Kinds and how many keys

Five kinds, the five launchers. The vendor names the env var the CLI reads;
those marked (unchecked) are what I believe each CLI reads and are measured
by task B0 (section 10) before anything is built.

| kind | vendor | the CLI reads | extra non-secret field |
|---|---|---|---|
| `claude` | Anthropic | `apiKeyHelper` in settings, or `ANTHROPIC_API_KEY` | none |
| `grok` | xAI | `XAI_API_KEY` (unchecked) | none |
| `agy` | Google Gemini | `GEMINI_API_KEY` (unchecked; agy may accept only a Google login, then `agy` is "not supported" until it does) | none |
| `mistral` | Mistral | `MISTRAL_API_KEY` | none |
| `qwen` | an OpenAI-compatible endpoint | `OPENAI_API_KEY` + `OPENAI_BASE_URL` (unchecked) | `base_url` (https only) |

**One key per kind per workspace.** One key is one account, one bill and one
spend limit on the customer's vendor console, which is the cap that holds.
Several keys per kind would buy rate-limit spreading, at the cost of a key
picker and of a usage split nobody asked for. A replace is atomic (section
4.3), so rotation needs no second slot. More keys per kind is a later,
additive change (a `slot` column in the primary key).

The data rule of the fleet (qwen's endpoints run by a provider we do not
use for secrets) is about OUR secrets. A customer's qwen key goes to the
endpoint the customer chose; the `secret` task kind of spec 115 still admits
only claude and mistral (rdb 0163), whatever keys a workspace holds.

## 4. Storage

### 4.1 Cloud KMS envelope in Postgres vs Secret Manager per workspace

| | KMS envelope, ciphertext in a Postgres row | Secret Manager, one secret per (workspace, kind) |
|---|---|---|
| cost, 100 workspaces x 5 kinds | one key: about $0.06/month per key version + $0.03 per 10k decrypts | 500 active versions x $0.06 = about $30/month + access ops |
| isolation | FORCE RLS on the row + the cross-tenant test the store already runs for every table | IAM only: the hub SA reads every secret, so isolation is Go code alone |
| audit | the audit row is written in the same transaction as the key | a second system to keep in step with the DB |
| backup | the DB backup carries ciphertext only, useless without the KMS key | outside the DB backup: a restore must restore both |
| rotation | KMS rotates the key version; a named action rewraps the row DEKs | a new version per secret |
| new infra | one key ring + one key per env (terraform step) | one secret per key, created at runtime by the hub (an IAM grant to create secrets) |

Prices are GCP list prices as I believe them, unchecked; task I1 confirms them.

**Pick: KMS envelope encryption in Postgres.** RLS, the audit row and the
backup stay in the one store the hub already guards and tests; the cost is
a few cents, not one line per workspace; and the hub needs no IAM to create
cloud resources at runtime.

### 4.2 The table and the crypto

- Table `workspace_vendor_keys` (tenant_id, kind, ciphertext bytea,
  wrapped_dek bytea, kms_key_version text, last4 text, fingerprint text,
  base_url text NULL, set_by text, set_at timestamptz), primary key
  (tenant_id, kind). `kind` CHECKs the five kinds of section 3.
- Per row a fresh 256-bit DEK; the key is sealed with AES-256-GCM, the
  additional data `tenant_id|kind|set_at`. A ciphertext copied into another
  workspace's row, or another kind, fails to open.
- The DEK is wrapped by Cloud KMS (`cryptoKeyEncrypterDecrypter` on the hub's
  runtime SA only, per env). The plaintext key lives in hub memory for one
  request and is zeroed after use.
- `fingerprint` = HMAC-SHA256 of the key under a hub-held pepper (Secret
  Manager, one per env), never a bare hash: it lets the hub detect the key in
  text (section 6, L9) without anyone deriving it from the row.
- RLS: `tenant_scope` only. **No `operator_scope` policy on this table**: the
  operator scope reads 0 rows. The catalogue test that expects both policies
  gets this one table as a named exception, and a test that the operator
  scope reads 0 rows of it.
- Audit: `workspace_vendor_key_audit` (tenant_id, kind, action in
  `set|replace|remove|lease`, actor, at, last4, box_id NULL), append-only in
  the 0171 shape, tenant RLS plus the usual `operator_scope` (the audit holds
  no secret: an operator may see that a key was set, never the key).

### 4.3 The API: write only

- `PUT /v1/vendor-keys/{kind}` `{"key": "<VENDOR_KEY>", "base_url": ...}`:
  set or replace, one transaction with its audit row. 204.
- `DELETE /v1/vendor-keys/{kind}`: remove, audited. 204.
- `GET /v1/vendor-keys`: per kind `{set, last4, set_at, set_by}`. Never the
  key, the ciphertext or the fingerprint.
- No route answers the key back. The only decrypt is the lease route of
  section 5.2, which answers a box, never a browser.
- The request body is never logged: the route sits on the hub's no-body-log
  list, and a test sends `sk-test-0000` and greps every log line the hub wrote
  for it (red control: the same test with the route off the list fails).

## 5. Who, and spawning on the key

### 5.1 Who may set a key

- A new permission `vendor_keys.manage`, held by `admin` only (the brief:
  "workspace admin only"; it follows the `agents.join` exception in
  `rbac.Defaults`). A `biz_owner` who wants it makes themselves admin.
- Refused under an impersonation session (`members.impersonate`): an admin
  acting as someone else never sets a key, and an operator who impersonates
  never reaches one either.
- The operator cannot read a key: no route returns it (4.3), the operator
  scope reads 0 rows (4.2), and the lease route answers only a dedicated pin
  of the same workspace (5.2), and only that workspace's admin can mint its
  join tokens (spec 108 3.8). What remains is the GCP project owner, who can
  grant themselves KMS decrypt and read the DB: that is stated, not hidden.
  Guard: KMS Data Access audit logs on, and a daily named check that the
  decrypt grant names only the hub runtime SA, alerting otherwise.

### 5.2 Delivery to a seat

A seat gets its workspace's key from its box's desk, which fetches it from
the hub when the seat starts and, for claude, again when the CLI asks.

1. The launcher asks the desk over the desk's local socket (owned by the
   workspace's OS user, mode 0600) for `kind`.
2. The desk calls `POST /v1/vendor-keys/{kind}/lease`, signed by the box key
   like every desk call. The hub answers only when the pin is live, belongs to
   the key's workspace, and has `box_mode = dedicated` (rdb 0170). It writes a
   `lease` audit row (box, kind, last4).
3. The hub seals the key to the box: the answer is encrypted to an X25519
   key the box registers at join beside its Ed25519 key (the join payload
   grows one field, signed with the rest). TLS alone would leave the key in
   the clear in any TLS-terminating proxy.
4. The desk opens it in memory and hands it to the launcher on the socket.
   It never writes it to disk and keeps it only as long as the seat lives.
5. The launcher starts the CLI with the key in that process only:
   - claude: an `apiKeyHelper` in the seat's own settings that asks the desk
     socket; the key is never in an environment variable, so the CLI's Bash
     tool children never inherit it. The CLI re-asks after its TTL or a 401.
   - grok, agy, mistral, qwen: the env var of section 3, set by `exec env`
     in the launcher's last step, never on an argv (`ps` shows argv), never in
     a file. The launcher keeps the existing `env -u` for every other
     vendor's variable, so a seat never carries two keys.
6. The box login stays untouched for the fleet's own lanes.

"One turn" in the brief: today's seats are long-lived interactive CLIs, not
one process per turn, so the unit is the seat's life. claude re-asks on its
TTL; a removed key stops the next lease, and the desk ends the workspace's
seats of that kind within one lease TTL (default 15 min, cnf).

### 5.3 The hard case: a machine running several workspaces' seats

Options:

- **per-seat OS user**: isolates seats of one workspace from each other,
  which K3 does not ask for: they share the key by design.
- **env only in the seat process**: necessary, not sufficient: the same OS
  user, and root, read `/proc/<pid>/environ` and memory.
- **no shared machines**: simplest proof, costs one VM per workspace.

**Pick: customer keys only on a `dedicated` box (spec 108 3.8) whose
workspace OS user has no sudo, with the key only in the seat process.** It is
spec 108's per-workspace OS user, plus three rules a fleet box breaks today:

- no seat on that machine has sudo, of any workspace: a fleet lane with sudo
  reads every process's memory. Fleet boxes (where lanes run
  `sudo -u <box user>`) therefore never receive a customer key, and the hub
  enforces it: a shared-mode pin is refused at the lease route, and the
  desk refuses to start when its OS user can sudo (`sudo -n true` succeeds).
- `/proc` mounted `hidepid=2` and `kernel.yama.ptrace_scope >= 2`, checked by
  the desk at start (refuses otherwise).
- the seat runs with `RLIMIT_CORE = 0` and is not dumpable.

Several customer workspaces may share one such machine, each as its own OS
user (spec 108 3.5), because no OS user on it can read another's processes.
The machine's root still can; who that root is decides whether the operator
is out of reach (section 9, Q-2).

## 6. Leak paths, guards and tests

Every test plants the fake `sk-test-0000` (or a fake of the vendor's shape)
and has a red control: the same test with the guard switched off fails.

| # | leak path | guard | test (red control) |
|---|---|---|---|
| L1 | another workspace's seat | lease route: pin's workspace = key's workspace; RLS | lease as a pin of workspace B for A's key -> 403; control: drop the check -> 200 |
| L2 | the fleet's own lanes | lease route refuses `box_mode = shared`; the desk refuses to run with sudo | lease from a shared pin -> 403; desk start as a sudo-capable user -> refused |
| L3 | the operator | no read route; no `operator_scope` on the table; KMS grant check | operator-scope SELECT -> 0 rows; control: add the policy -> rows |
| L4 | a hub log | route on the no-body-log list; no key in any error | PUT `sk-test-0000`, grep the captured hub log -> 0 |
| L5 | a box log | the desk and launchers never print the key; the launcher dry run prints `<VENDOR_KEY>` | spawn dry run + desk log grep -> 0 |
| L6 | `ps` argv | key only via helper or `exec env` | spawn a fake CLI, read its `/proc/<pid>/cmdline` -> no key |
| L7 | a core dump | `RLIMIT_CORE=0`, non-dumpable | fake CLI aborts -> no core file |
| L8 | a pane capture | the key is never printed; the fleet lease tick never runs on a dedicated box | capture the fake seat's pane after start -> no key |
| L9 | a transcript / the desk mirror | claude: no env var at all; the desk replaces the exact key it handed out with `[vendor key removed]` in every mirror and spool body it sends; the hub replaces any token whose HMAC fingerprint matches a key of that workspace, and vendor key shapes | the fake seat echoes its env into a turn: the hub stores the redacted text; control: redaction off -> the fake reaches the DB |
| L10 | another seat's child process | `env -u` of every other vendor variable; claude's Bash children have no key | a child runs `env` -> no vendor variable |
| L11 | a DB backup | ciphertext only; the KMS key is not in the backup | restore into lde without KMS -> the row does not open |
| L12 | the browser | password input, `autocomplete=new-password`, the value cleared from the store after PUT, never in localStorage | e2e: after save, the store and storage hold no `sk-test-0000` |
| L13 | swap | the desk `mlock`s the key buffer; dedicated boxes run without swap or with encrypted swap (desk start check) | desk start with plain swap -> warning in its health |

What is NOT claimed: a seat of the workspace can read its own key (it is the
workspace's own agent), and the root of the machine it runs on can (5.3).
L9's redaction catches the exact key and its fingerprint, not a transformed
copy (base64, split): that is a seat of the workspace leaking its own key,
and the local transcript stays on the workspace's own OS user.

## 7. Workspace as a service (K4)

### 7.1 The plan

A new plan kind `byok` beside spec 121's `metered`:

`monthly price = (fixed-cost slice + the hosts the workspace runs on) x 1.50`

- **Share of GCP cost**: the fixed-cost slice of spec 122 section 9
  (`estate_fixed_month / W_max`, owner 2d9490e7), read from the billing
  export as spec 123 section 3 reads it (its own SA; the per-env SAs cannot
  read billing). If the workspace's dedicated box is one we host, its VM
  cost (label `box=<box_id>`) is added whole. A customer's own box costs us
  nothing and adds nothing.
- **Why the slice, not measured CPU per workspace**: the estate is mostly the
  always-on hub (spec 121 7, spec 123), which no request-level number splits
  fairly yet; the slice is what spec 122 already measures and the owner
  already chose for the fixed cost. A measured per-workspace share is a later
  change once spec 122's capacity numbers name the cost per workspace.
- **Margin**: 50% ("something like 50%", 6ad93fae) as `price_plans.margin_pct
  = 50` for `byok`; the 29% of spec 121 stays for `metered`. The exact rate
  is Q-3.
- **The bill** (spec 006 payments, spec 121 8): the card checkout as today;
  the `byok` plan is a monthly card charge of the price above, shown as two
  lines, "hub share" and "hosted box" (when there is one). No token line.
- **No price before the measurements**: spec 121's pricing gate (409
  `pricing_not_ready`) holds for `byok` too, since the slice needs `W_max`.

### 7.2 Metering still records, never charges

- spec 121's `usage_events` rows are still written for every turn of a
  `byok` workspace, so the customer sees use per agent and kind (the 8.1
  counter) and we see capacity.
- A new column `usage_events.key_source` (`hub` | `workspace`, default `hub`,
  additive DDL) marks rows run on the workspace's key. Their
  `unit_cost_micros` is still copied from `model_prices`, so the counter can
  show "about EUR x at list price, paid to your vendor"; the balance draw-down
  and every charge sum only `key_source = 'hub'`.
- `token_budgets` do not apply to `byok` turns; the customer's vendor console
  is their cap. A workspace may still set a budget as a self-limit.
- A seat on a box login inside a `byok` workspace (only if Q-1 = B) writes
  `key_source = 'hub'` and is charged as `metered`.

### 7.3 With spec 115's split

The picker (`do_spl_lane_mix`, `hub/agent_split.go`) treats a vendor with no
key as weight 0 in a `byok` workspace: the main without a key hands to the
backup; neither with a key -> Q-1. Split settings shows a "no key" mark per
vendor. The `secret` kind's claude/mistral rule is unchanged.

## 8. The WUI

Workspace settings -> **Agent keys** (`csi-spl-wui/src/pages/tenant-settings/`
gains `agent-keys.vue`, beside `split.vue`). One row per kind: set or not,
last 4, set when, by whom; Set / Replace / Remove. The input is a password
field, cleared after save. Visible to `vendor_keys.manage` only. New locale
text in every catalogue, reviewed by agy LAST (text only, no secrets).

## 9. Owner questions

Real choices only; the dispatcher posts them as one blocker.

- **Q-1 Missing key.** A `byok` workspace starts a seat of a kind with no key:
  - A (recommended): refuse that kind; the picker takes the backup with a key;
    none -> the task waits with "no key for <kind>", visible in the topic.
  - B: fall back to the box login, charged as `metered`.
- **Q-2 Hosted dedicated boxes.** When WE host a `byok` workspace's
  dedicated box, our root can read its seats' memory:
  - A (recommended): accept, stated in the plan's terms; root access to such
    boxes is by named action only and audited; a customer who needs more runs
    its own box.
  - B: customer keys only on customer-run boxes; we host no `byok` seat.
- **Q-3 Margin.** "something like 50%": A (recommended) 50% exactly; B another
  rate.

## 10. Lane plan

Each a small task with tests and a red control; claude or mistral seats only
(secrets work). DDL lands on dev AND prd before the hub that reads it.

| # | lane | task |
|---|---|---|
| B0 | box (claude) | measure what each CLI reads (section 3 "unchecked"): an env var, a helper, or login only; record the version |
| D1 | rdb (claude) | `workspace_vendor_keys` (tenant_scope only) + `workspace_vendor_key_audit` + `usage_events.key_source`; cross-tenant and operator-0-rows tests |
| I1 | iac (claude) | KMS key ring + key per env, decrypt grant to the hub runtime SA only; HMAC pepper secret; the daily grant check action |
| H1 | hub (claude) | `vendor_keys.manage`, PUT/DELETE/GET, audit, no-body-log, impersonation refusal; L3, L4 tests |
| H2 | hub (claude) | the lease route: dedicated pin, same workspace, sealed to the box X25519 key; join payload field; L1, L2 tests |
| H3 | hub (mistral) | inbound redaction by fingerprint and vendor shapes; L9 hub half |
| W1 | wui (mistral) | Agent keys page, L12 e2e; locale text then agy review LAST |
| X1 | box (claude) | desk socket, lease, seal open, mlock, start checks (no sudo, hidepid, ptrace, swap), outbound redaction; L5, L8, L9, L13 |
| X2 | box (claude) | launchers: claude `apiKeyHelper`, `exec env` for the others, `env -u` of the rest, core limit; L6, L7, L10 |
| P1 | hub (claude) | `byok` plan kind, price lines, `key_source` in the draw-down; after spec 122's gate |

## 11. Panel and consensus

- Editor: c-928 (claude), writes only this file.
- Seats: to be named (one claude, one mistral), each only `reviews/s-<seat>.md`.
- Consensus: all three sign one sha. v1.0 records what each seat changed.
