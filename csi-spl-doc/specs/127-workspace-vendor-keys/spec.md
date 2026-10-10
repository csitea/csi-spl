# Spec 127: Workspace vendor keys (bring your own keys)

Version **v1.0** (2026-10-11): the editor c-928 (claude) folded the two seat
reviews in [reviews/](reviews/), s-claude-2 (c-929) and s-mistral (m-930),
into v0.1 (0caca00c4). Section 11 records what each seat changed. Signed when
all three seats sign one sha (section 11).

Doc only. Nothing here is built; the code named below is what exists on
origin/master at 0caca00c4. No real key, token, credential path or account id
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
| no seat limits core dumps, hides `/proc` or sets ptrace scope | `git grep -nE 'ulimit -c\|LimitCORE\|hidepid\|ptrace_scope\|PR_SET_DUMPABLE' -- csi-spl-orc csi-spl-iac` -> nothing |
| the hub never stores private key material of spool keys (006 FR-014, amended by 017 SEC-03) | `grep -n FR-014 csi-spl-doc/specs/006-spool-hub-rental/spec.md` -> 214 |
| the vendor split per task kind is a Workspace setting, `tenant_agent_split_kind` (rdb 0163), `PATCH /v1/agent-split` under `rbac.TenantSettings` | `sed -n 165,168p internal/hub/agent_split.go` -> PATCH at 167 |
| the `secret` kind admits only claude and mistral, in the table | `grep -n secret_vendors csi-spl-rdb/src/sql/postgres/spool-hub/0163_tenant_agent_split_kind.sql` -> 20, 49 |
| `box_mode` is the box's OWN declaration, signed by its own key, not a property the hub verifies; NULL on every root-key pin, read as shared | `sed -n 16,20p csi-spl-rdb/src/sql/postgres/spool-hub/0170_box_join_switch.sql`; `sed -n 384,389p internal/hub/join_tokens.go` |
| a workspace on a shared machine runs as its own OS user; root sees every workspace on it | spec 108 section 3.5 |
| FORCE RLS with `tenant_scope` + `operator_scope` on every tenant table; the operator scope reads every row | rdb 0163 tail; spec 108 section 3.6 |
| one precedent for a table with NO operator policy: `personal.profile` (rdb 0168), pinned by a catalogue test with red controls | `internal/store/personal_catalogue_test.go:171` ("policies are exactly") |
| the operator service account invites anyone into any workspace with any role | `sed -n 111,113p internal/hub/operator.go` -> `POST /v1/operator/invites {tenant, email, role?, ..., no_mail?}`; `sed -n 156,159p` -> `role := rbac.Legacy(...)`, no ceiling |
| an act-as session never holds an admin-only permission: the target is in the admin's own tenant and below the admin | `internal/auth/actas.go:33-39` |
| the metering ledger exists: `usage_events`, `model_prices`, `token_budgets` (rdb 0171, spec 121 T301) | `sed -n 1,40p csi-spl-rdb/src/sql/postgres/spool-hub/0171_usage_events.sql` |
| the per-env SAs cannot read GCP billing; spec 123 reads the BigQuery billing export with its own SA | spec 123 section 3, first row |
| roles: `admin` and `biz_owner` hold `tenant.settings`; `agents.join` is the admin's alone | `sed -n 133,140p internal/rbac/rbac.go` |

## 3. Kinds and how many keys

Five kinds, the five launchers. Measured by s-claude-2 on a fleet box, 2026-10-10
(each CLI's `--help`, plus a count of env-var names in the binary: that shows
the name exists, not that it authenticates; task B0 decides before anything
is built).

| kind | vendor | CLI version | the seat authenticates by | evidence |
|---|---|---|---|---|
| `claude` | Anthropic | 2.1.292 | `apiKeyHelper` via `--settings <seat file>` ONLY; TTL by `CLAUDE_CODE_API_KEY_HELPER_TTL_MS`. Never `ANTHROPIC_API_KEY` (L14) | `claude --help` -> "Anthropic auth is strictly ANTHROPIC_API_KEY or apiKeyHelper via --settings" |
| `grok` | xAI | 1.0.50 | `XAI_API_KEY` (help silent; B0 confirms it beats a login) | binary has `XAI_API_KEY`; help shows only `--oauth`, `login` |
| `agy` | Google Gemini | 1.3.3 | `GEMINI_API_KEY`; the wrapper also unsets `GOOGLE_API_KEY`, `GOOGLE_APPLICATION_CREDENTIALS`, `GOOGLE_GENAI_USE_VERTEXAI`. If B0 shows agy takes a Google login only, `agy` is "not supported" until it does | binary has those four names; help silent |
| `mistral` | Mistral | vibe 2.26.0 | `MISTRAL_API_KEY`, which beats vibe's own env file | `sed -n 8,12p spawn-mistral.sh` |
| `qwen` | an OpenAI-compatible endpoint | 0.24.6 | `OPENAI_API_KEY` + `OPENAI_BASE_URL`, launched with `--auth-type openai` pinned; never `--openai-api-key` (argv, L6) | `qwen --help` -> `--auth-type {openai, openai-responses, anthropic, qwen-oauth, gemini, vertex-ai}` |

qwen can also authenticate with an Anthropic or Gemini key (`--auth-type`).
Unpinned, a qwen seat whose environment carried another vendor's variable
would spend that key under the qwen kind; the pin plus the wrapper's unset of
every other vendor variable (L10) closes it. `qwen` has one extra non-secret
field, `base_url` (https only).

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
| cost, 100 workspaces x 5 kinds | one key: about $0.06/month per key version + $0.03 per 10k operations | 500 active versions x $0.06 = about $30/month + access ops |
| isolation | FORCE RLS on the row + the cross-tenant test the store already runs for every table | IAM only: the hub SA reads every secret, so isolation is Go code alone |
| audit | the audit row is written in the same transaction as the key | a second system to keep in step with the DB |
| backup | the DB backup carries ciphertext only, useless without the KMS key | outside the DB backup: a restore must restore both |
| rotation | KMS rotates the key version; a named action rewraps the row DEKs | a new version per secret |
| new infra | one key ring + one key per env (terraform step) | one secret per key, created at runtime by the hub (an IAM grant to create secrets) |

Prices are GCP list prices as both seats believe them, unchecked; task I1
confirms them.

**Pick: KMS envelope encryption in Postgres.** RLS, the audit row and the
backup stay in the one store the hub already guards and tests; the cost is
a few cents, not one line per workspace; and the hub needs no IAM to create
cloud resources at runtime.

### 4.2 The tables and the crypto

- Table `workspace_vendor_keys` (tenant_id, kind, key_id uuid, ciphertext
  bytea, wrapped_dek bytea, kms_key_version text, last4 text, fingerprint
  text, base_url text NULL, set_by text, set_at timestamptz), primary key
  (tenant_id, kind). `kind` CHECKs the five kinds of section 3. `key_id` is a
  random UUID, new on every set or replace.
- Per row a fresh 256-bit DEK; the key is sealed with AES-256-GCM, the
  additional data `tenant_id|kind|key_id`. A ciphertext copied into another
  workspace's row, another kind, or over a newer key fails to open. (Not
  `set_at`: Go's time carries nanoseconds and `timestamptz` keeps
  microseconds, so an AAD rebuilt from the row would differ.)
- The DEK is wrapped by Cloud KMS (`cryptoKeyEncrypterDecrypter` on the hub's
  runtime SA only, per env). The hub encrypts before the INSERT, so a
  Postgres statement or slow-query log carries ciphertext only. The
  plaintext key lives in hub memory for one request and is zeroed after use.
- `fingerprint` = HMAC-SHA256 of the key under a hub-held pepper (Secret
  Manager, one per env), never a bare hash: it lets the hub detect the key in
  text (L9) without anyone deriving it from the row.
- RLS: `tenant_scope` only, **no `operator_scope` policy**: the operator
  scope reads 0 rows. The table follows the `personal.profile` shape (rdb
  0168): the catalogue test gains `workspace_vendor_keys`, so adding an
  `operator_scope` policy turns it red.
- Table `workspace_vendor_key_boxes` (tenant_id, box_id, approved_by,
  approved_at), primary key (tenant_id, box_id): the boxes an admin approved
  for keys (5.1). Tenant RLS plus `operator_scope` (it holds no secret).
- Audit: `workspace_vendor_key_audit` (tenant_id, kind NULL, action in
  `set|replace|remove|lease|box_approve|box_revoke|admin_confirm`, actor, at,
  last4 NULL, box_id NULL), append-only in the 0171 shape, tenant RLS plus
  `operator_scope` (an operator may see that a key was set, never the key).
- A tenant delete cascades the key rows; the audit keeps last4 only.

### 4.3 The API: write only

- `PUT /v1/vendor-keys/{kind}` `{"key": "<VENDOR_KEY>", "base_url": ...}`:
  set or replace, one transaction with its audit row. 204.
- `DELETE /v1/vendor-keys/{kind}`: remove, audited. 204.
- `GET /v1/vendor-keys`: per kind `{set, last4, set_at, set_by}`, and the
  key-box list. Never the key, the ciphertext or the fingerprint.
- `PUT|DELETE /v1/vendor-keys/boxes/{box_id}`: approve or revoke a box for
  keys (5.1), audited.
- No route answers the key back. The only decrypt is the lease route of
  section 5.2, which answers a box, never a browser.
- The request body is never logged: the routes sit on the hub's no-body-log
  list, and a test sends `sk-test-0000` and greps every log line the hub wrote
  for it (red control: the same test with the route off the list fails).

## 5. Who, and spawning on the key

### 5.1 Who may set a key, and why the operator cannot get one

- A new permission `vendor_keys.manage`, held by `admin` only (it follows the
  `agents.join` exception in `rbac.Defaults`). A `biz_owner` who wants it
  makes themselves admin.
- Refused under an act-as session. An act-as session cannot hold an
  admin-only permission anyway (`internal/auth/actas.go:33-39`); the refusal
  is cheap defence in depth.

**The operator path, as v0.1 left it open** (s-claude-2 C1): the operator SA
calls `POST /v1/operator/invites {tenant: <victim>, role: "admin", no_mail:
true}` (any tenant, any role), accepts it, mints a join token, joins a box it
runs declaring `dedicated`, and leases the key. `box_join_enabled` does not
stop it: only the operator workspace writes that switch. Two guards close it:

- **Key-box approval.** A pin gets leases only after an admin of the
  workspace marks its box "may use agent keys" on the Agent keys page
  (`workspace_vendor_key_boxes`). Every admin of the workspace is emailed on
  each approval and on the first lease from a box.
- **Operator-made admins are unconfirmed.** An admin membership created by an
  operator invite (`invited_by` = `operator` or `bootstrap`, rdb 0006/0084) in
  a workspace that holds a vendor key gets neither `vendor_keys.manage` nor
  key-box approval until another, confirmed admin of the workspace confirms
  it (`admin_confirm` audit row). A workspace with no key (the bootstrap
  case) is unaffected. The choice is Q-4.

So the operator cannot read a key through the hub: no route returns it
(4.3), the operator scope reads 0 rows (4.2), and a lease needs a box a
confirmed admin approved. What remains is the GCP project owner, who can grant
themselves KMS decrypt and read the DB: stated, not hidden. Guard: KMS Data
Access audit logs on, and a daily named check that the decrypt grant names
only the hub runtime SA, alerting otherwise.

### 5.2 Delivery to a seat

A seat gets its workspace's key from its box's desk, which fetches it from
the hub when the seat starts and, for claude, again when the CLI asks.

1. The seat's wrapper (step 5) asks the desk over the desk's local socket
   (owned by the workspace's OS user, mode 0600) for `kind`. The desk checks
   the caller with `SO_PEERCRED` (uid = the desk's own OS user), not only the
   file mode.
2. The desk calls `POST /v1/vendor-keys/{kind}/lease`, signed by the box key
   like every desk call. The hub answers only when the pin is live, belongs to
   the key's workspace, is `dedicated`, and its box is approved (5.1). It
   reads the key row in the PIN's tenant scope (`inTenant` of the pin's
   workspace), so a bug in the Go check still reads 0 rows: L1's red control
   needs both removed. It writes a `lease` audit row (box, kind, last4).
3. The hub seals the key to the box: the answer is encrypted to an X25519
   key the box registers at join beside its Ed25519 key (the join payload
   grows one field, signed with the rest). TLS alone would leave the key in
   the clear in any TLS-terminating proxy. A pin enrolled before that field
   exists has no X25519 key and gets no lease until it re-enrols; the key-box
   list says so.
4. The desk opens it in memory and hands it to the wrapper on the socket. It
   never writes it to disk and keeps it only as long as the seat lives.
5. The CLI gets the key in its own process only:
   - claude: an `apiKeyHelper` that asks the desk socket, in the seat's own
     settings file passed by `--settings`, never in a shared settings file.
     The helper prints nothing on stderr. The key is never in an environment
     variable, so the CLI's Bash-tool children never inherit it. The CLI
     re-asks after its TTL or a 401.
   - grok, agy, mistral, qwen: the seat's command is a fixed wrapper,
     `spool-key-exec <kind> -- <cli> <args>`, with no key in it. The wrapper
     runs as the seat, asks the desk socket, puts the key in its OWN
     environment (`setenv`, no argv), unsets every other vendor's variable
     (L10), sets the hard core limit (5.3) and `execve`s the CLI. The key is
     never in a command string, a plan file (`launch.cmd`), tmux or an argv.
     (v0.1's `exec env VAR=<key>` put the key on `env`'s argv and in the tmux
     start command: s-claude-2 C2.)
6. The box login stays untouched for the fleet's own lanes.

"One turn" in the brief: today's seats are long-lived interactive CLIs, not
one process per turn, so the unit is the seat's life. claude re-asks on its
TTL; a removed key or a revoked box stops the next lease, and the desk ends
the workspace's seats of that kind within one lease TTL (default 15 min,
cnf).

### 5.3 The hard case: a machine running several workspaces' seats

Options:

- **per-seat OS user**: isolates seats of one workspace from each other,
  which K3 does not ask for: they share the key by design.
- **env only in the seat process**: necessary, not sufficient: the same OS
  user, and root, read `/proc/<pid>/environ` and memory.
- **no shared machines**: simplest proof, costs one VM per workspace.

**Pick: customer keys only on a `dedicated` box (spec 108 3.8) that a
confirmed admin approved, whose workspace OS users hold no root path, with the
key only in the seat process.** It is spec 108's per-workspace OS user, plus
rules a fleet box breaks today.

**What keeps the fleet's lanes out** (s-claude-2 C3). `box_mode` is the box's
own signed declaration (rdb 0170:16-20): a box that wants a key says
"dedicated", so refusing shared pins only refuses an honest shared box. The
real guards are hub-side: (a) fleet boxes are root-key pins of the operator
workspace (`box_mode` NULL, read as shared, and not in any customer
workspace); (b) a pin of workspace W exists only from a join token W's admin
minted; (c) W's confirmed admin approved that box for keys (5.1). The desk's
start checks below are the honest box's self-test, not a hub-side proof.

The desk's start checks (it refuses to start otherwise):

- no workspace OS user on the machine is in `sudo`, `wheel`, `admin`,
  `docker`, `lxd` or `disk` (`/etc/group`, readable by all: each of these is
  root-equivalent and reads every process), and its own user has no sudoers
  grant (`sudo -n -l` lists nothing). It cannot read another user's sudoers
  entries; that part is the machine root's word (Q-2).
- `/proc` mounted `hidepid=2` with no `gid=` exemption naming a seat user,
  and `kernel.yama.ptrace_scope >= 2` (same-user defence in depth; the
  cross-workspace guard is the uid separation).
- `fs.suid_dumpable = 0` and `kernel.core_pattern` a file path or
  systemd-coredump. The wrapper sets a HARD `RLIMIT_CORE = 0` (`ulimit -Hc
  0`): it survives `execve` and an unprivileged process cannot raise it.
  (`PR_SET_DUMPABLE` is reset by `execve`, so the launcher cannot set it for
  the CLI: s-claude-2 C4.) Whether a piped core_pattern collector honours
  the limit is unchecked; X1 measures it.
- no swap, or encrypted swap: the CLI's heap (node, bun, python) holds the
  key and is not `mlock`ed.

Several customer workspaces may share one such machine, each as its own OS
user (spec 108 3.5), because no OS user on it can read another's processes.
The machine's root reads all of them, so a customer-run machine should host
only that customer's workspaces; each workspace's admin mints its own join
token, so this is that admin's choice, said in the UI. Who the root is on a
machine we host is Q-2.

## 6. Leak paths, guards and tests

Every test plants the fake `sk-test-0000` (or a fake of the vendor's shape)
and states its red control: the same test with the guard off fails.

| # | leak path | guard | test | red control |
|---|---|---|---|---|
| L1 | another workspace's seat | lease: pin's workspace = key's workspace, read in the pin's tenant scope | lease as a pin of workspace B for A's key -> 403 | drop both the Go check and the scoped read -> 200 |
| L2 | the fleet's own lanes | 5.3 (a)-(c): no customer pin, no approval; desk refuses a root-equivalent user | lease from a pin with no approval -> 403 `box_not_approved`; desk start as a `docker` member -> refused | drop the approval check -> 200; drop the group check -> desk starts |
| L3 | the operator | no read route; no `operator_scope` on the key table; key-box approval; operator-made admins unconfirmed; KMS grant check | operator-scope SELECT -> 0 rows; operator invite as admin -> join -> dedicated box -> lease -> 403 `box_not_approved`; that admin PUTs a key -> 403 `admin_unconfirmed` | add the policy -> rows; drop approval -> 200; drop confirmation -> 204 |
| L4 | a hub log | routes on the no-body-log list; no key in any error; encrypt before INSERT | PUT `sk-test-0000`, grep the captured hub and pg logs -> 0 | the route off the list -> found |
| L5 | a box log | the desk and wrapper never print the key; dry run prints `<VENDOR_KEY>` | spawn dry run + desk log grep -> 0 | a wrapper that prints the key -> found |
| L6 | an argv (`ps`) | key via helper or the wrapper's own `setenv`, never argv | spawn a fake CLI, read every `/proc/<pid>/cmdline` of the launch -> no key | the v0.1 `exec env` launch -> found |
| L7 | a core dump | hard `RLIMIT_CORE=0`, `suid_dumpable=0`, core_pattern checked | fake CLI aborts -> no core file | no hard limit -> core file appears |
| L8 | a pane capture | the key is never printed; the fleet lease tick never runs on a dedicated box | capture the fake seat's pane after start -> no key | a seat that echoes its env -> found |
| L9 | a transcript / the desk mirror | claude: no env var at all; the desk replaces the exact key it handed out with `[vendor key removed]` in every mirror and spool body; the hub fingerprints candidates (vendor-shape matches plus any run of >= 32 `[A-Za-z0-9_-]`) and redacts a match of that workspace's keys | the fake seat echoes its env into a turn: the hub stores the redacted text | redaction off -> the fake reaches the DB |
| L10 | another vendor's key in a seat | the wrapper unsets every other vendor variable; qwen `--auth-type openai`; claude's children see no key | a child of a grok seat runs `env` -> no OTHER vendor variable; a child of a claude seat -> none at all | the unset removed -> the child sees the other variable |
| L11 | a DB backup | ciphertext only; the KMS key is not in the backup | restore into lde without KMS -> the row does not open | the same restore with the KMS grant -> opens |
| L12 | the browser | password input, `autocomplete=new-password`, the value cleared from the store after PUT, never in localStorage | e2e: after save, the store and storage hold no `sk-test-0000` | the store not cleared -> found |
| L13 | swap | desk refuses plain swap (5.3) | desk start with plain swap -> refused | the check off -> desk starts |
| L14 | the CLI's own state files (claude's `customApiKeyResponses`, an auth step's settings, vibe's env file) | claude only by `apiKeyHelper`; the others by environment only, never an auth subcommand; the seat home holds no key file | after a seat's run, grep the seat user's home for `sk-test-0000` -> 0 | start claude with `ANTHROPIC_API_KEY` -> found (B0 confirms) |
| L15 | the tmux start command and the dry-run plan | the wrapper of 5.2 step 5 | `tmux list-panes -F '#{pane_start_command}'` and `launch.cmd` -> no fake | the `exec env` launch -> found |
| L16 | CLI telemetry and crash reports to the vendor or a third party | telemetry off per CLI (as `spawn-mistral.sh:63` does for vibe), measured by B0 | a fake crash with telemetry off -> no report sent | telemetry on -> the report carries the env |
| L17 | the WUI's RUM and error beacons; visitor and embed channels (spec 121); WebSocket fan-out; mail | beacons never carry request bodies; the hub redacts (L9) BEFORE the row is written and before any fan-out or mail | a failed PUT -> no beacon carries the fake; a seat posts the fake into a visitor channel -> the visitor sees `[vendor key removed]` | redaction after fan-out -> the visitor gets the fake |

What is NOT claimed:

- A seat of the workspace can read its own key (it is the workspace's own
  agent), and can ask the desk socket for the workspace's keys of every other
  kind (the socket answers its OS user, which every seat of that workspace
  is).
- The root of the machine it runs on can read it (5.3, Q-2).
- L9 catches the exact key and its fingerprint, not a transformed copy
  (base64, split): that is a seat of the workspace leaking its own key, and
  the local transcript stays on the workspace's own OS user.

## 7. Workspace as a service (K4)

### 7.1 The plan

A new plan kind `byok` beside spec 121's `metered`. One formula, spec 122's,
with the token term at 0 and the plan's margin (s-claude-2 C11):

`monthly price = (measured own cost + fixed-cost slice + the hosts it runs on) x (1 + margin_pct/100)`, `margin_pct = 50`

- **Measured own cost**: what the workspace itself uses, agent seats and
  storage (spec 121 7 "other own cost"; spec 122 M2 measures it).
- **Fixed-cost slice**: spec 122 section 9 (`estate_fixed_month / W_max`,
  owner 2d9490e7), read from the billing export as spec 123 section 3 reads
  it (its own SA; the per-env SAs cannot read billing).
- **The hosts it runs on** (owner b6a56949): a dedicated box we host is added
  whole (label `box=<box_id>`); a customer's own box costs us nothing and adds
  nothing.
- **Why the slice for the fixed part**: the estate is mostly the always-on
  hub (spec 121 7, spec 123), which no request-level number splits fairly
  yet; the slice is what spec 122 already measures and the owner already
  chose for the fixed cost.
- **Margin**: 50% ("something like 50%", 6ad93fae) as
  `price_plans.margin_pct = 50` for `byok`; spec 121's 29% stays for
  `metered`. The schema already allows a per-plan value. The exact rate is
  Q-3.
- **The bill** (spec 006 payments, spec 121 8): the card checkout as today;
  `byok` is a monthly card charge of the price above, shown as "own use",
  "hub share" and "hosted box" (when there is one). No token line.
- **No price before the measurements**: spec 121's pricing gate (409
  `pricing_not_ready`) holds for `byok` too.

### 7.2 Metering still records, never charges

- spec 121's `usage_events` rows are still written for every turn of a
  `byok` workspace, so the customer sees use per agent and kind (the 8.1
  counter) and we see capacity.
- A new column `usage_events.key_source text NOT NULL` with a CHECK (`hub` |
  `workspace`) and **no default** (s-claude-2 C12: a default of `hub` would
  make a forgotten field chargeable). The hub sets it from its own state,
  `workspace` when the turn's seat runs on a pin with a live lease of that
  kind, never from the box's report.
- `workspace` rows still copy `unit_cost_micros` from `model_prices`, so the
  counter can show "about EUR x at list price, paid to your vendor"; the
  balance draw-down and every charge sum only `key_source = 'hub'`.
- `token_budgets` do not apply to `byok` turns; the customer's vendor console
  is their cap. A workspace may still set a budget as a self-limit.

### 7.3 With spec 115's split

For a customer workspace the pick is the hub's, `internal/hub/agent_split.go`
(`do_spl_lane_mix` is the fleet's own picker). In a `byok` workspace it
treats a vendor with no key as weight 0: the main without a key hands to the
backup; neither with a key -> Q-1. Split settings shows a "no key" mark per
vendor. The `secret` kind's claude/mistral rule is unchanged.

## 8. The WUI

Workspace settings -> **Agent keys** (`csi-spl-wui/src/pages/tenant-settings/`
gains `agent-keys.vue`, beside `split.vue`):

- one row per kind: set or not, last 4, set when, by whom; Set / Replace /
  Remove. The input is a password field, cleared after save.
- the key-box list: the workspace's boxes, a "may use agent keys" toggle, the
  last lease, and "re-enrol needed" for a pin without an X25519 key.
- an unconfirmed admin (5.1) sees the page read-only, with who can confirm.
- visible to `vendor_keys.manage` only. New locale text in every catalogue,
  reviewed by agy LAST (text only, no secrets).

## 9. Owner questions

Real choices only; the dispatcher posts them as one blocker. Both seats
recommend A on every question.

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
- **Q-3 Margin.** "something like 50%": A (recommended) 50% exactly; B
  another rate.
- **Q-4 Operator-made admins.** An admin the operator created (operator
  invite) in a workspace that holds vendor keys:
  - A (recommended): gets no `vendor_keys.manage` and cannot approve a box for
    keys until a confirmed admin of the workspace confirms it; every admin is
    emailed.
  - B: same powers as any admin, audited only. This leaves the operator a
    path to a customer key (5.1), against K3.

## 10. Lane plan

Each a small task with tests and red controls; claude or mistral seats only
(secrets work). DDL lands on dev AND prd before the hub that reads it.

| # | lane | task |
|---|---|---|
| B0 | box (claude) | measure per CLI: what authenticates (env var, helper, login only), the telemetry switch (L16), whether it writes the key to its state (L14), qwen `--auth-type` pin; record each version |
| D1 | rdb (claude) | `workspace_vendor_keys` (tenant_scope only, `personal.profile` shape), `workspace_vendor_key_boxes`, `workspace_vendor_key_audit`, `usage_events.key_source` (no default); cross-tenant and operator-0-rows tests |
| I1 | iac (claude) | KMS key ring + key per env, decrypt grant to the hub runtime SA only; HMAC pepper secret; the daily grant check action; confirm the list prices |
| H1 | hub (claude) | `vendor_keys.manage`, PUT/DELETE/GET, audit, no-body-log, act-as refusal, operator-made admin confirmation (Q-4); L3, L4 tests |
| H2 | hub (claude) | the lease route: dedicated pin, approved box, read in the pin's tenant scope, sealed to the box X25519 key; join payload field; key-box approve/revoke; L1, L2 tests |
| H3 | hub (mistral) | redaction by fingerprint and candidate shapes, before write and fan-out; L9 hub half, L17 hub half |
| W1 | wui (mistral) | Agent keys page with the key-box list, L12 and L17 e2e; locale text then agy review LAST |
| X1 | box (claude) | desk socket with `SO_PEERCRED`, lease, seal open, start checks (groups, sudoers, hidepid, ptrace, suid_dumpable, core_pattern, swap), outbound redaction; L5, L8, L9, L13; measure piped core_pattern |
| X2 | box (claude) | `spool-key-exec` wrapper (setenv, unset other vendors, hard core limit, execve), claude `apiKeyHelper` via `--settings`; L6, L7, L10, L14, L15 |
| P1 | hub (claude) | `byok` plan kind, the three price lines, `key_source` in the draw-down; after spec 122's gate |

## 11. Panel and consensus

- Editor: c-928 (claude), writes only this file.
- Seats: s-claude-2 (c-929, claude) and s-mistral (m-930, mistral), each
  only its own file under `reviews/`.
- Consensus: all three sign one sha.

### 11.1 What each seat changed

| seat | change | where |
|---|---|---|
| s-claude-2 | C1: the operator invite path to a key; key-box approval + unconfirmed operator-made admins; Q-4 | 2, 4.2, 4.3, 5.1, 6 L3, 8, 9, 10 |
| s-claude-2 | C2: no `exec env`; the `spool-key-exec` wrapper; `SO_PEERCRED`; claude helper by `--settings`, silent stderr | 5.2, 6 L6, L15 |
| s-claude-2 | C3: `box_mode` is the box's own claim; what really keeps fleet lanes out | 2, 5.3 |
| s-claude-2 | C4: hard `RLIMIT_CORE`, `suid_dumpable`, core_pattern, not `PR_SET_DUMPABLE` | 5.3, 6 L7 |
| s-claude-2 | C5: root-equivalent groups and `sudo -n -l`, not `sudo -n true` | 5.3, 6 L2 |
| s-claude-2 | C6: leak rows L14..L17; the L9 candidate rule | 6 |
| s-claude-2 | C7: L10 restated (no OTHER vendor variable); L13 refuses, not warns; every row has its red control | 6 |
| s-claude-2 | C8: measured CLI versions and auth; qwen `--auth-type openai`; agy's Google variables | 3 |
| s-claude-2 | C9: `key_id` in the AAD, not `set_at` | 4.2 |
| s-claude-2 | C10: the `personal.profile` precedent and its catalogue test | 2, 4.2 |
| s-claude-2 | C11: byok price is spec 122's formula with token term 0 | 7.1 |
| s-claude-2 | C12: `key_source` NOT NULL, no default, set by the hub | 7.2 |
| s-claude-2 | lease read in the pin's tenant scope; pre-X25519 pins re-enrol; the WUI key-box list; picker named | 5.2, 7.3, 8 |
| s-mistral | agreed every section; recommended A on Q-1..Q-3 | 9 |
