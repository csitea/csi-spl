# Spec 127: Workspace vendor keys (bring your own keys)

Version **v1.4** (2026-10-27): folded in [spec 159](../159-byo-ai-keys/spec.md)
(BYO AI keys on shared GCP hosts, owner HUM-10 msg `87578f3a`, decisions Q-1..Q-4):
sections 5.1, 5.3 and 8 point at spec 159 (N1, N3), and a pointer at section 3
(N2); K3 and L2 are amended as spec 159 sections 5.1 and 6 say, citing owner
msg `2e9d03be`.

Changelog:
- v1.4 (2026-10-27): folded in [spec 159](../159-byo-ai-keys/spec.md) (BYO AI keys
  also on our shared GCP hosts, owner HUM-10 msg `87578f3a`). Points sections 5.1,
  5.3 and 8 at spec 159 (N1: `biz_owner` may add keys; N3: keys run on fleet boxes
  as per-workspace OS users), and a pointer at section 3 (N2: subscriptions in
  addition to API keys); amends K3 (§1.1) and L2 (§6) as spec 159 §5.1 and
  §6 say, citing owner msg `2e9d03be`.
- v1.3 (2026-10-11): owner answer Q-5 A folded in (msg c8593f0f, topic
  bdc65df6); section 9.2 is now a decision with requirements R5.1..R5.5 and
  the B0c gate; sections 3, 5.4, 8 and 10 point to it. Also recorded as
  decided, not done: "Yes, apply the Terraform step 057 as well" (msg
  29297bf6), the I1 step `057-gcp-kms-vendor-keys` (6afbfe865), applied by
  c-001 (10).
- v1.2 (2026-10-11): B0 (0a368f0c2) and B0b (d8a7ad43d) folded in. grok: a
  stored login beats `XAI_API_KEY`, so the seat runs with no `auth.json`, its
  log counts as key-bearing, never `GROK_AUTH_PROVIDER_COMMAND` (3, L14).
  agy: the workspace credential is a Google service-account JSON, not
  `GEMINI_API_KEY`; how the file reaches the seat (5.4), leak row L18, what
  W1 asks the admin for (8), Q-5 (9.2). claude: interactive + env leaves the
  last 20 chars in `.claude.json`, so `apiKeyHelper` in every mode (3, 5.2).
  Telemetry switches per CLI (L16).
- D1 (2026-10-11, dispatch-bdc65df6 msg 7da7b68a): `usage_events.key_source` lands expand then contract (rdb 0174 with DEFAULT 'hub', the hub insert names it, a later migration drops the default); no end-state change to 7.2.
- v1.1 (2026-10-11): owner answers Q-1 A, Q-2 A, Q-3 A, Q-4 A folded in
  (msg 316dd655); section 9.1 added.
- v1.0 (2026-10-11): signed by all three seats at 64b24b396.

v1.0 (2026-10-11): the editor c-928 (claude) folded the two seat
reviews in [reviews/](reviews/), s-claude-2 (c-929) and s-mistral (m-930),
into v0.1 (0caca00c4). Section 11 records what each seat changed.
**Signed**: v1.0 at 64b24b396 by all three seats (section 11.2). This status
line and 11.2 were the only edits before v1.1; the four owner questions of
section 9 went to the owner as one blocker and are answered (9.1).

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
| K3 | Isolation: a key is used only by seats working for its own workspace. Never another workspace, the fleet's own lanes, the operator, a log, a core dump, a pane capture, a transcript or the desk mirror (amended for fleet boxes by [spec 159](../159-byo-ai-keys/spec.md) §5.1, owner msg `2e9d03be`: holds against fleet lanes only as far as they do not use sudo) | 29fd4b3c |
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
is built). B0 and B0b measured it on 2026-10-11 with fake keys
([b0-cli-measure.md](b0-cli-measure.md), n per cell there); the
"authenticates by" column below now reads as measured.

| kind | vendor | CLI version | the seat authenticates by | evidence |
|---|---|---|---|---|
| `claude` | Anthropic | 2.1.292 | `apiKeyHelper` via `--settings <seat file>` ONLY, interactive and `-p` alike; TTL by `CLAUDE_CODE_API_KEY_HELPER_TTL_MS`. Never `ANTHROPIC_API_KEY`: interactive + env writes the key's last 20 chars to `$HOME/.claude.json` `customApiKeyResponses`, on Yes AND on No, and shows them in the pane (L8, L14). The helper stored nothing (B0 2.2) | `claude --help` -> "Anthropic auth is strictly ANTHROPIC_API_KEY or apiKeyHelper via --settings"; B0 2.1 n=1 per answer |
| `grok` | xAI | 1.0.50 | `XAI_API_KEY`, but only as a fallback: **a stored login beats the key** (B0 2.5). So the seat runs with a `HOME` / `GROK_HOME` holding no `auth.json` (else it spends the box login); grok logs the key's last 12 chars to `logs/unified.jsonl` (`key_suffix`), so that log is key-bearing (L5, L14); never `GROK_AUTH_PROVIDER_COMMAND`, which writes the full token to `auth.json` | B0 2.1 n=2 per cell; grok's user guide: "the stored session token takes precedence" |
| `agy` | Google | 1.3.3 | **not an API key**: `GEMINI_API_KEY` and `GOOGLE_API_KEY` are ignored (B0 2.6, n=3). It takes a Google service-account JSON through `AGY_ADC_AUTH=1` + `GOOGLE_APPLICATION_CREDENTIALS` on a file (B0b 4.2, n=4); without `AGY_ADC_AUTH` the file is ignored (n=2); it also reads the gcloud well-known ADC file under `HOME`. The wrapper unsets `GEMINI_API_KEY`, `GOOGLE_API_KEY`, `GOOGLE_GENAI_USE_VERTEXAI`. Delivery: 5.4. Supported by owner decision Q-5 A (9.2), switched on only after the B0c gate passes; until then agy reads "not supported" | B0 2.6, B0b 4 |
| `mistral` | Mistral | vibe 2.26.0 | `MISTRAL_API_KEY`, which beats vibe's own env file (B0 2.3, code + n=3); the seat home holds no `.vibe/.env` (onboarding writes the key there) | `sed -n 8,12p spawn-mistral.sh` |
| `qwen` | an OpenAI-compatible endpoint | 0.24.6 | `OPENAI_API_KEY` + `OPENAI_BASE_URL`, launched with `--auth-type openai` pinned; never `--openai-api-key` (argv, L6) | `qwen --help` -> `--auth-type {openai, openai-responses, anthropic, qwen-oauth, gemini, vertex-ai}` |

qwen can also authenticate with an Anthropic or Gemini key (`--auth-type`).
Unpinned, a qwen seat whose environment carried another vendor's variable
would spend that key under the qwen kind; the pin plus the wrapper's unset of
every other vendor variable (L10) closes it. B0 confirmed the pin is needed:
unpinned, qwen followed `settings.json` to the other vendor's key (2.4, n=1),
and the pin is not written back. `qwen` has one extra non-secret field,
`base_url` (https only).

For `agy` the "key" of this spec is the whole service-account JSON: it is
stored, leased and redacted as one secret (4.2, 5.4, L9), and `last4` is
the last 4 of its `private_key_id`.

> **Amended by [spec 159](../159-byo-ai-keys/spec.md) §4 (N2, owner msg `87578f3a`):**
> Subscriptions in addition to API keys: Claude self sign-in inside the unmodified
> CLI, behind a switch (spec 159 §4.3, owner Q-3 A msg `36279386`); terms status per
> kind in spec 159 §4.1–§4.2.

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

Prices confirmed by I1 (c-792) on 2026-10-11 from the GCP list price pages
`https://cloud.google.com/kms/pricing` and
`https://cloud.google.com/secret-manager/pricing` (USD, fetched that day):

| item | list price | so |
|---|---|---|
| KMS active symmetric key version, SOFTWARE | $0.000082192 / hour | about $0.06 / month per version |
| KMS cryptographic operation (encrypt, decrypt) | $0.03 / 10,000 | the free 10,000 / month is for Autokey keys only, not ours |
| KMS key rotation, admin operations, destroyed versions | free | |
| Secret Manager active secret version (per location) | $0.000082192 / hour after 6 free per billing account | about $0.06 / month per version |
| Secret Manager access operation | $0.03 / 10,000 after 10,000 free per billing account | |

The pick holds. The KMS column's figure is per **version**: 90-day rotation
keeps the old versions enabled (older DEKs still unwrap), so the key adds
about 4 billed versions a year, about $0.24 / month per env after a year,
until a rewrap lets old versions be disabled. The Secret Manager column, 500
versions less the 6 free, is about $29.64 / month. The pepper is one version
per env, about $0.06 / month each.

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
  set or replace, one transaction with its audit row. 204. For `agy`,
  `key` is the service-account JSON as one string; the hub accepts it only
  when it parses, `type` is `service_account`, `private_key`,
  `private_key_id` and `client_email` are present and `token_uri` equals
  Google's standard token endpoint (a cnf value), else 422
  `bad_credential_shape`. A user credential (`authorized_user`) is refused:
  it carries a refresh token for a person, not a workspace.
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
  > **Amended by [spec 159](../159-byo-ai-keys/spec.md) §3 (N1, owner msg `87578f3a`):**
  > `vendor_keys.manage` is granted to both `biz_owner` and `admin` (replaces
  > "admin only"). An operator-made `biz_owner` is unconfirmed until a confirmed
  > admin or biz owner confirms it (same rule as Q-4 A below, closing path C1).
  > Every admin and biz owner is emailed on each set, replace, remove, and
  > key-box approval.
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
  case) is unaffected. Owner decision Q-4 A (9.1).

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
   never writes it to disk and keeps it only as long as the seat lives. The
   one file is agy's credential, written by the wrapper to memory-backed
   storage (5.4).
5. The CLI gets the key in its own process only:
   - claude: an `apiKeyHelper` that asks the desk socket, in the seat's own
     settings file passed by `--settings`, never in a shared settings file.
     The helper prints nothing on stderr. The key is never in an environment
     variable, so the CLI's Bash-tool children never inherit it. The CLI
     re-asks after its TTL or a 401. The same in `-p` mode: B0 found `-p` +
     env stored nothing (n=2), but one rule for every claude seat is the one
     a test can hold. B0 counted 6 helper calls in 40 s on a refused key
     (2.1): the desk answers the helper from the lease it holds in memory,
     never with a new hub lease per call.
   - grok, agy, mistral, qwen: the seat's command is a fixed wrapper,
     `spool-key-exec <kind> -- <cli> <args>`, with no key in it. The wrapper
     runs as the seat, asks the desk socket, puts the key in its OWN
     environment (`setenv`, no argv), unsets every other vendor's variable
     (L10), sets the hard core limit (5.3) and `execve`s the CLI. The key is
     never in a command string, a plan file (`launch.cmd`), tmux or an argv.
     (v0.1's `exec env VAR=<key>` put the key on `env`'s argv and in the tmux
     start command: s-claude-2 C2.)
   - grok, in addition: the wrapper sets `GROK_HOME` to the seat's own dir
     (5.4), refuses to start when that dir holds an `auth.json`, and unsets
     `GROK_AUTH_PROVIDER_COMMAND` and refuses a config naming an
     `auth_provider_command` (B0 2.5).
   - agy: no environment key; the wrapper writes the service-account file
     and sets `AGY_ADC_AUTH=1` + `GOOGLE_APPLICATION_CREDENTIALS` (5.4).
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

> **Amended by [spec 159](../159-byo-ai-keys/spec.md) §5 (N3, owner msg `2e9d03be`):**
> Customer keys also run in our common GCP infra on shared fleet boxes. By
> owner decision Q-1 B (msg `2e9d03be`), workspace seats run on fleet boxes as
> a per-workspace OS user. The desk start checks run with one exception: spec 159
> §5.2 exempts the fleet agent user from the check below ("no workspace OS user on
> the machine is in sudo, wheel, admin, docker, lxd or disk"), because the fleet's
> agent user is root-equivalent. Any fleet lane with sudo can read keys on that box
> (spec 159 §5.4, accepted risk). K3 holds against non-sudo fleet lanes and between
> workspace seats.

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
  entries; that part is the machine root's word (Q-2 A, 9.1).
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
token, so this is that admin's choice, said in the UI. On a machine we host
our root can read the seats; the owner accepted that, stated in the plan's
terms, with root access by named, audited action only (Q-2 A, 9.1).

### 5.4 The seat's own dir, and agy's credential file

agy reads its workspace credential only from a file (B0b 4.2), so this is
the one place a customer secret is written down on the box. The design
keeps it in memory-backed storage, for the seat's life only, with three
deleters. The agy part is built (owner decision Q-5 A, 9.2) but stays
switched off until the B0c gate passes (R5.2); the seat dir serves grok
either way.

- **The seat dir.** `<runtime>/spool-seat/<seat-id>/`, where `<runtime>` is
  the workspace OS user's `/run/user/<uid>` (tmpfs; the desk enables
  lingering for its user at install so the dir exists with no login). Mode
  0700, owned by the workspace OS user. The desk refuses to start when
  `<runtime>` is not tmpfs (`stat -f -c %T`), and the no-plain-swap check
  (5.3) keeps tmpfs pages off a plain disk. The same dir is grok's
  `GROK_HOME`, so grok's key-bearing log (section 3) lives and dies with the
  seat.
- **The file.** `<seat dir>/adc.json`, the JSON exactly as leased, written
  by the wrapper under `umask 077` with `O_CREAT|O_EXCL|O_NOFOLLOW`, mode
  0400: it never exists with a wider mode, and an existing file or a
  symlink at that path refuses the start. Never rewritten in place.
- **The environment.** `AGY_ADC_AUTH=1`, `GOOGLE_APPLICATION_CREDENTIALS=`
  that path; unset `GEMINI_API_KEY`, `GOOGLE_API_KEY`,
  `GOOGLE_GENAI_USE_VERTEXAI`, `CLOUDSDK_CONFIG` and every other vendor
  variable (L10). The wrapper refuses to start when the seat `HOME` holds
  a gcloud well-known ADC file (`.config/gcloud/application_default_credentials.json`)
  or an agy login: agy reads the first (B0b, d runs), and whether a stored
  login beats ADC is unmeasured, so neither may be there to win over the
  customer's credential.
- **Lifetime: the seat's.** Created when the seat starts, gone when it ends.
  A replace or remove does not touch a running seat's file: the desk ends
  that kind's seats within one lease TTL (5.2) and the next seat gets the
  new JSON in a new file.
- **Who deletes it.** (1) The wrapper: for agy it does not `execve`; it
  forks the CLI, forwards signals, waits, removes the seat dir and exits
  with the CLI's code. (2) The desk, for a wrapper that was killed: it
  removes a seat's dir when it ends the seat, removes every seat dir whose
  seat process is gone on each lease tick, and empties `spool-seat/` at
  desk start. (3) A reboot clears tmpfs.
- **Who can read it.** The workspace OS user, so every seat of that
  workspace and their children, and the machine's root: the same set that
  can read an environment key through `/proc` (6, "What is NOT claimed").
  A service-account key may grant more than agy needs: W1 asks the admin
  for one that holds only agy's role (8).
- **Better, if measured.** If X2 measures that agy reads the credential
  once at start, the wrapper may pass it as a `memfd_create` fd
  (`/dev/fd/<n>`, no path on any file system) and keep the file as the
  fallback. That changes L18's test, not its guard.

## 6. Leak paths, guards and tests

Every test plants the fake `sk-test-0000` (or a fake of the vendor's shape)
and states its red control: the same test with the guard off fails.

| # | leak path | guard | test | red control |
|---|---|---|---|---|
| L1 | another workspace's seat | lease: pin's workspace = key's workspace, read in the pin's tenant scope | lease as a pin of workspace B for A's key -> 403 | drop both the Go check and the scoped read -> 200 |
| L2 | the fleet's own lanes | 5.3 (a)-(c): no customer pin, no approval; desk refuses a root-equivalent user (amended on fleet boxes by [spec 159](../159-byo-ai-keys/spec.md) §5.1, §6, owner msg `2e9d03be`: desk start exempts the fleet user from root check; any lane with sudo can read keys, §5.4; holds against non-sudo lanes, L21) | lease from a pin with no approval -> 403 `box_not_approved`; desk start as a `docker` member -> refused | drop the approval check -> 200; drop the group check -> desk starts |
| L3 | the operator | no read route; no `operator_scope` on the key table; key-box approval; operator-made admins unconfirmed; KMS grant check | operator-scope SELECT -> 0 rows; operator invite as admin -> join -> dedicated box -> lease -> 403 `box_not_approved`; that admin PUTs a key -> 403 `admin_unconfirmed` | add the policy -> rows; drop approval -> 200; drop confirmation -> 204 |
| L4 | a hub log | routes on the no-body-log list; no key in any error; encrypt before INSERT | PUT `sk-test-0000`, grep the captured hub and pg logs -> 0 | the route off the list -> found |
| L5 | a box log | the desk and wrapper never print the key; dry run prints `<VENDOR_KEY>`; grok's `logs/unified.jsonl` (the key's last 12 chars, B0 2.5) is key-bearing: it lives in the seat dir (5.4), is never shipped, mirrored or collected, and goes with the seat dir | spawn dry run + desk log grep -> 0; after a grok seat ends, grep the box for the fake's last 12 chars -> 0 | a wrapper that prints the key -> found; `GROK_HOME` in the persistent home -> the suffix is found after the seat ends |
| L6 | an argv (`ps`) | key via helper or the wrapper's own `setenv`, never argv | spawn a fake CLI, read every `/proc/<pid>/cmdline` of the launch -> no key | the v0.1 `exec env` launch -> found |
| L7 | a core dump | hard `RLIMIT_CORE=0`, `suid_dumpable=0`, core_pattern checked | fake CLI aborts -> no core file | no hard limit -> core file appears |
| L8 | a pane capture | the key is never printed; the fleet lease tick never runs on a dedicated box | capture the fake seat's pane after start -> no key | a seat that echoes its env -> found |
| L9 | a transcript / the desk mirror | claude: no env var at all; the desk replaces the exact key it handed out with `[vendor key removed]` in every mirror and spool body; the hub fingerprints candidates (vendor-shape matches plus any run of >= 32 `[A-Za-z0-9_-]`) and redacts a match of that workspace's keys. agy's JSON: a private-key block or a JSON `private_key` field is redacted whoever's key it is, with no fingerprint needed; its `private_key_id` is fingerprinted like a key | the fake seat echoes its env into a turn: the hub stores the redacted text; an agy seat prints its fake service-account file (built at run time as B0b 4.1) into a turn -> the marker is not stored | redaction off -> the fake reaches the DB |
| L10 | another vendor's key in a seat | the wrapper unsets every other vendor variable; qwen `--auth-type openai`; claude's children see no key | a child of a grok seat runs `env` -> no OTHER vendor variable; a child of a claude seat -> none at all | the unset removed -> the child sees the other variable |
| L11 | a DB backup | ciphertext only; the KMS key is not in the backup | restore into lde without KMS -> the row does not open | the same restore with the KMS grant -> opens |
| L12 | the browser | password input, `autocomplete=new-password`, the value cleared from the store after PUT, never in localStorage | e2e: after save, the store and storage hold no `sk-test-0000` | the store not cleared -> found |
| L13 | swap | desk refuses plain swap (5.3) | desk start with plain swap -> refused | the check off -> desk starts |
| L14 | the CLI's own state files (claude's `customApiKeyResponses`, an auth step's settings, vibe's env file, grok's `auth.json`) | claude only by `apiKeyHelper`, interactive and `-p`; the others by environment only, never an auth subcommand; the seat home holds no key file and no `.vibe/.env`; grok: `GROK_HOME` = the seat dir with no `auth.json` (else the box login is spent, B0 2.5), `GROK_AUTH_PROVIDER_COMMAND` unset and refused | after a seat's run, grep the seat user's home for `sk-test-0000` and its last 20 chars -> 0; a grok seat with an `auth.json` planted in its `GROK_HOME` -> refused to start | start claude interactive with `ANTHROPIC_API_KEY` -> last 20 chars found in `.claude.json` (B0 2.2, confirmed n=2); grok with the provider command -> the full fake in `auth.json` (B0 2.5) |
| L15 | the tmux start command and the dry-run plan | the wrapper of 5.2 step 5 | `tmux list-panes -F '#{pane_start_command}'` and `launch.cmd` -> no fake | the `exec env` launch -> found |
| L16 | CLI telemetry and crash reports to the vendor or a third party | telemetry off per CLI, switches named by B0 (3): claude `DISABLE_TELEMETRY=1 DISABLE_ERROR_REPORTING=1`; vibe `VIBE_ENABLE_TELEMETRY=false` (also Sentry; as `spawn-mistral.sh:63` does); grok `GROK_TELEMETRY_ENABLED=false`; qwen a seat `settings.json` with `privacy.usageStatisticsEnabled: false` (default on, no env var); agy: no switch found, stated | a fake crash with telemetry off -> no report sent (needs a packet capture; B0 took none) | telemetry on -> the report carries the env |
| L17 | the WUI's RUM and error beacons; visitor and embed channels (spec 121); WebSocket fan-out; mail | beacons never carry request bodies; the hub redacts (L9) BEFORE the row is written and before any fan-out or mail | a failed PUT -> no beacon carries the fake; a seat posts the fake into a visitor channel -> the visitor sees `[vendor key removed]` | redaction after fan-out -> the visitor gets the fake |
| L18 | agy's service-account file (5.4) left behind, or readable by another user | tmpfs seat dir 0700, file 0400 by `O_EXCL\|O_NOFOLLOW` under `umask 077`; three deleters (wrapper, desk sweep, reboot); desk refuses a non-tmpfs runtime dir; no gcloud ADC file or agy login in the seat `HOME` | a fake agy CLI seat on a fake JSON (marker built at run time, B0b 4.1): `stat` -> 0400 in a 0700 dir; after a normal exit, and after `SIGKILL` of the wrapper plus one desk tick, `grep -rlF` the marker over the seat `HOME`, `<runtime>` and `/tmp` -> 0; another OS user's read -> EACCES | wrapper deletion off -> the file is found after exit; desk sweep off + `SIGKILL` -> found; write without `umask 077` -> 0644 seen |

What is NOT claimed:

- A seat of the workspace can read its own key (it is the workspace's own
  agent), and can ask the desk socket for the workspace's keys of every other
  kind (the socket answers its OS user, which every seat of that workspace
  is).
- The root of the machine it runs on can read it (5.3, Q-2 A).
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
  `metered`. The schema already allows a per-plan value. The rate is
  exactly 50% (owner decision Q-3 A, 9.1).
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
backup; neither with a key -> the task waits with "no key for <kind>"
(owner decision Q-1 A, 9.1). Split settings shows a "no key" mark per
vendor. The `secret` kind's claude/mistral rule is unchanged.

## 8. The WUI

Workspace settings -> **Agent keys** (`csi-spl-wui/src/pages/tenant-settings/`
gains `agent-keys.vue`, beside `split.vue`):

- one row per kind: set or not, last 4, set when, by whom; Set / Replace /
  Remove. The input is a password field, cleared after save.
- what the page asks the admin for, per kind: an API key for claude, grok,
  mistral and qwen (qwen also its https `base_url`). For agy (Q-5 A,
  9.2; until the B0c gate passes the row reads "not supported for workspace
  keys" and Q-1 A sends agy tasks to the backup vendor, R5.2): a **Google service-account key file
  (JSON)**, chosen as a file or pasted into a masked text area, read in the
  browser's memory only and cleared after save (L12). The row then shows the
  account (`client_email`) and the last 4 of `private_key_id`, never the
  key. The help text says: create a service account in your own Google
  Cloud project used for nothing else, grant it only the role agy's models
  need (named once B0c measures it), create a key for it, and replace or
  remove it here when you rotate; an organisation policy that forbids
  service-account keys stops this, and agy then stays on the backup vendor.
- the key-box list: the workspace's boxes, a "may use agent keys" toggle, the
  last lease, and "re-enrol needed" for a pin without an X25519 key.
- an unconfirmed admin (5.1) sees the page read-only, with who can confirm.
- visible to `vendor_keys.manage` only. New locale text in every catalogue,
  reviewed by agy LAST (text only, no secrets).

> **Amended by [spec 159](../159-byo-ai-keys/spec.md) §10 (N1, owner msg `87578f3a`):**
> The Agent keys page is visible to `biz_owner` as well as `admin` (`vendor_keys.manage`, N1).
> The additional UI controls and per-kind states for BYO AI keys on shared hosts are defined
> in [spec 159](../159-byo-ai-keys/spec.md) §10.

## 9. Owner questions

Real choices only; the dispatcher posted them as one blocker. Both seats
recommended A on every question. The owner chose A on all four (9.1). Q-5
came with v1.2; the owner chose A (9.2, v1.3).

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

### 9.1 Decisions (owner, msg 316dd655, "1a 2a 3a 4a")

| question | decision | where it applies |
|---|---|---|
| Q-1 Missing key | A: refuse that kind; the picker takes the backup vendor with a key; none -> the task waits with "no key for <kind>", visible in the topic. No fall-back to the box login. | 7.3, H1/H2 lanes |
| Q-2 Hosted dedicated boxes | A: accepted; our root's read of a hosted `byok` box is stated in the plan's terms; root access to such boxes only by a named, audited action; a customer who needs more runs its own box. | 5.3, 6, 7.1 |
| Q-3 Margin | A: exactly 50%, `price_plans.margin_pct = 50` for `byok`. | 7.1, P1 |
| Q-4 Operator-made admins | A: no `vendor_keys.manage` and no key-box approval until a confirmed admin of the workspace confirms; every admin is emailed. | 5.1, 8, H1 |

Q-1..Q-4 are decided here; Q-5 is decided in 9.2 (v1.3).

### 9.2 Q-5, decided A: agy on a workspace credential

**Decision (owner, msg c8593f0f-fd7b-4056-937d-d0a920ba35bd, topic
bdc65df6, 2026-10-11T08:47Z): A.** As asked: "support agy this way
[Google service-account file written on the box, in memory only, readable
by that seat alone, deleted when the seat ends], but switch it on only after
one check with your own service account: it must serve one prompt, and the
check names the smallest role it needs. Until then agy shows 'not
supported', and its tasks go to the backup vendor (Q-1 A)."

Requirements it adds:

- **R5.1 Build.** X2 builds 5.4's agy part (file, environment, three
  deleters, L18 wrapper half), X1 the desk half, H1 the agy shape check of
  4.3, W1 the file input of 8. Built behind one switch, off by default.
- **R5.2 Off until the gate.** While the switch is off, the agy row of 8
  reads "not supported for workspace keys", no agy credential is accepted
  or leased, no file is written, and Q-1 A sends agy tasks of a `byok`
  workspace to the backup vendor.
- **R5.3 The gate, B0c.** Run by c-001 with the owner's own service
  account, through 5.4's file and `AGY_ADC_AUTH`: (a) one agy prompt is
  served; (b) the check names the smallest role that serves it (by trying
  narrower roles first, recording each refusal); (c) L16 for agy by packet
  capture. The record names the CLI version, the tree (sha) and n. It never
  carries the key, its path or the account id (org-neutral, 6).
- **R5.4 Switch on.** Only after B0c passes, by a commit that cites the B0c
  record; the role it named goes into 8's help text in that commit.
- **R5.5 Fail closed.** B0c failing, or no role short of a broad one
  serving the prompt, keeps agy "not supported" (R5.2) and goes back to the
  owner as a new question; nothing is switched on in the meantime.

"Readable by that seat alone" is the question's shorthand. The exact set is
5.4's "Who can read it": the workspace OS user (every seat of that workspace)
and the machine's root (Q-2 A), the same set that can read an environment key.

The question as asked (v1.2):

B0 and B0b showed agy takes no API key, only a Google service-account JSON
through `AGY_ADC_AUTH` (section 3). Supporting it means writing a customer
secret to a file on the box, which no other kind needs (5.4), and a
service-account key can carry more power than agy needs. Whether a real
service account serves an agy prompt, and with which least role, is not
measured: that needs the owner's credential (B0c, 10).

- **A (recommended): support agy by the service-account file of 5.4**,
  switched on only after B0c passes: the owner's own service account serves
  one prompt through `AGY_ADC_AUTH`, and B0c names the least role. Until
  then the agy row reads "not supported" and Q-1 A routes agy tasks to the
  backup vendor. Cost: L18 and its tests, the shape check of 4.3, the file
  input of 8. Why: K2 asks for every launcher, and the file stays on tmpfs,
  0400, for the seat's life, readable by the same set that reads an
  environment key.
- **B: keep agy unsupported for workspace keys.** No file is ever written;
  5.4's agy part, L18, the agy shape check and the file input are not
  built; agy tasks of a `byok` workspace always go to the backup vendor
  (Q-1 A). Revisit if agy gains an API-key path. Cost: K2 is met for four
  kinds of five.

## 10. Lane plan

Each a small task with tests and red controls; claude or mistral seats only
(secrets work). DDL lands on dev AND prd before the hub that reads it.

| # | lane | task |
|---|---|---|
| B0 | box (claude) | measure per CLI: what authenticates (env var, helper, login only), the telemetry switch (L16), whether it writes the key to its state (L14), qwen `--auth-type` pin; record each version. Done: [b0-cli-measure.md](b0-cli-measure.md) (grok: a stored login beats `XAI_API_KEY`; agy: Google login only for API keys), 0a368f0c2; B0b (section 4, d8a7ad43d): agy takes a service-account JSON via `AGY_ADC_AUTH`. Folded in v1.2 |
| B0c | box (c-001) | the Q-5 A gate (9.2, R5.3): the owner's own service account serves one agy prompt through 5.4's file; name the smallest role; L16 for agy by packet capture. Needs the owner's credential. Until it passes, agy stays "not supported" (R5.2) |
| D1 | rdb (claude) | `workspace_vendor_keys` (tenant_scope only, `personal.profile` shape), `workspace_vendor_key_boxes`, `workspace_vendor_key_audit`, `usage_events.key_source` (no default); cross-tenant and operator-0-rows tests |
| I1 | iac (claude) | KMS key ring + key per env, decrypt grant to the hub runtime SA only; HMAC pepper secret; the daily grant check action; confirm the list prices. Step `057-gcp-kms-vendor-keys` (6afbfe865); apply decided by the owner (msg 29297bf6), c-001 applies it; decided, not done at v1.3 |
| H1 | hub (claude) | `vendor_keys.manage`, PUT/DELETE/GET, audit, no-body-log, act-as refusal, operator-made admin confirmation (Q-4 A); L3, L4 tests |
| H2 | hub (claude) | the lease route: dedicated pin, approved box, read in the pin's tenant scope, sealed to the box X25519 key; join payload field; key-box approve/revoke; L1, L2 tests |
| H3 | hub (mistral) | redaction by fingerprint and candidate shapes, before write and fan-out; L9 hub half, L17 hub half |
| W1 | wui (mistral) | Agent keys page with the key-box list, L12 and L17 e2e; the agy row per Q-5 A (8, R5.2: "not supported" until B0c passes); locale text then agy review LAST |
| X1 | box (claude) | desk socket with `SO_PEERCRED`, lease, seal open, start checks (groups, sudoers, hidepid, ptrace, suid_dumpable, core_pattern, swap, tmpfs runtime dir), helper answers from the held lease, seat-dir sweep (5.4), outbound redaction; L5, L8, L9, L13, L18 desk half; measure piped core_pattern |
| X2 | box (claude) | `spool-key-exec` wrapper (setenv, unset other vendors, hard core limit, execve), claude `apiKeyHelper` via `--settings` in every mode, grok with `GROK_HOME` = seat dir and no provider command, telemetry switches (L16), agy's file per Q-5 A (5.4, R5.1, off until B0c); L6, L7, L10, L14, L15, L18 wrapper half |
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

### 11.2 Signatures on v1.0 (64b24b39636ad374179c861db26acd88a8d2f02e)

| seat | where the sign line is | owner answers recommended |
|---|---|---|
| editor c-928 (claude) | this file, v1.0 | A, A, A, A |
| s-claude-2 (c-929, claude) | `reviews/s-claude-2.md` section 12, 32aa17eff | A, A, A, A |
| s-mistral (m-934, mistral) | `reviews/s-mistral.md` section 5, 516aa15dd | A, A, A, A |

m-930's review (2d1db3885, never on master) is void: m-930 retired before it
landed, and c-001 replaced the seat with m-934.
