# Spec 176: Full Offline AI Stack (local model servers, mixed with the cloud vendors)

Version **v0.1** (2026-11-13), the editor's draft for the panel. Editor: c-690
(claude seat). Placement slug `c002-4187ab15-offline-ai-panel-editor`.
Epic: **SPL-2402**. Issue: **SPL-5455** (wip). Kind: `specs_and_docs`.
Task: `dispatch-4187ab15`. Discussion: t1 topic `4187ab15-e3bc-4ae8-a4b2-c44bc9911b28`.

**Docs only.** This spec builds nothing, installs nothing, downloads no
model and changes no infra ([README.md](../README.md) section 2.4). Every
change it needs is written as a phase task (section 8). Claims about our
tree cite the command and its output, measured on `origin/master`
`f0d0efa4e`, n = 1 per command. Vendor and model facts cite a source and the
date it was read; a fact the editor could not confirm is marked
**unverified** and is a job for the panel.

## 0. The owner's words (HUM-10, t1 topic 4187ab15, 2026-11-13, verbatim)

| time (Z) | text |
|---|---|
| 14:08:18 | "Create first the architectural specification document for the following feature: The spool hub should also support local running of local models, meaning the server side of them, mixed with the current setup in which the models are run on the cloud of the AI vendor providers. It should support them being fully used within a client of that local model only by running local modeling for full stack." |
| 14:08:36 | "The feature could be called \"Full Offline AI Stack.\"" |
| 14:09:19 | "And the requirement should be such that our current implementation will provision the infra and everything else in the Google Cloud Platform. Of course, the specification should be flexible enough to specify that the whole stack will be runnable on-premises." |
| 14:09:59 | "Gather a panel of experts from each AI coin ... They should reach a consensus." |
| 14:10:34 | "Store the document as both a QTO document and as part of the MD documentation. If you figure out that this architecture specification is not enough, ask me some more questions to find out what kind of documentation artifacts will be needed, because maybe this is not good enough." |

Poll `b866f988` (14:15:03Z): the panel is one seat per vendor (agy, claude,
grok, mistral, codex); start now; agy joins when its quota is back and signs
last.

### 0.1 What the words require

| id | requirement | from |
|---|---|---|
| R1 | Local model **servers** (the server side, our own hardware or VMs) serve models to the fleet's agents | 14:08:18 |
| R2 | **Mixed mode**: local models run next to today's cloud vendors, in one fleet | 14:08:18 |
| R3 | **Full offline mode**: a client uses local models only, for the whole stack (hub, WUI, agents) | 14:08:18 |
| R4 | Our implementation provisions it **on GCP**, by our existing path | 14:09:19 |
| R5 | The same design is **runnable on-premises** | 14:09:19 |
| R6 | A five-vendor panel reaches **consensus** on this document | 14:09:59, poll b866f988 |
| R7 | The document lives **in Qto and in the md docs** | 14:10:34 |
| R8 | The editor **asks the owner** which further documentation artifacts are needed | 14:10:34 |

## 1. Goals and non-goals

### 1.1 Goals

| id | goal | measured by (when built) |
|---|---|---|
| G1 | A **model server** is a named, provisioned part of the stack: one or more GPU (or CPU) hosts serving open-weight models over an OpenAI-compatible and an Anthropic-compatible HTTP API | `do_check_model_endpoint` (section 8) returns 0 against both APIs |
| G2 | **Mixed mode**: `do_spl_lane_mix` can place a lane on a local model for a task kind, by the same weights, backup and 2-try rule as a cloud vendor (spec 115) | a lane-mix journal row with vendor `local` |
| G3 | **Full offline mode**: hub, WUI, sign-in, agents and model serving run with **no outbound traffic** beyond the stack's own network | an egress-deny test: a lane completes with every non-stack destination blocked (section 3.3) |
| G4 | **GCP first**: every piece is a terraform step in the tf-runner plus named `./run` actions, per-env SAs, dev leads prd | the step plans clean in dev |
| G5 | **On-premises**: the same images, ansible roles and actions run on a Debian host the operator owns, with no GCP API call | the on-prem install guide (section 9) replayed on a box outside GCP |
| G6 | **Quality is measured, not assumed**: no kind routes to a local model until it passes the per-kind evaluation of section 4.8 | the evaluation report, per kind and model |

### 1.2 Non-goals

- Training or fine-tuning models. Serving only.
- Replacing the cloud vendors. Mixed mode is the default; full offline is an
  option for a stack that needs it.
- Building a model client of our own. The fleet keeps using vendor CLIs
  (section 4.3); this spec only points them at a local endpoint.
- Any change to prd or the hub in this lane.

## 2. Today, measured

### 2.1 How the fleet runs AI now

| fact | command -> result |
|---|---|
| Spawnable agent kinds | `grep -n "SPOOL_SPAWN_KINDS=" csi-spl-orc/src/bash/features/spawn-agents/lib/spool-env.inc.sh` -> `529:SPOOL_SPAWN_KINDS='claude grok agy qwen mistral codex'` |
| One launcher per CLI | `ls csi-spl-orc/src/bash/features/spawn-agents/scripts/ \| grep -E '^spawn-(claude\|grok\|agy\|qwen\|mistral\|codex)\.sh$'` -> 6 files |
| Every CLI talks to its vendor's cloud; no local endpoint is configured anywhere | `grep -rnE 'ollama\|vllm\|llama' csi-spl-orc/src csi-spl-api/src csi-spl-cnf` -> 0 lines |
| The flat split | `csi-spl-cnf/csi-spl/all.env.yaml` lines 1359-1365: `claude: 60, grok: 0, agy: 20, qwen: 0, mistral: 20` |
| The split by kind (spec 115) | `all.env.yaml` lines 1416-1423, e.g. `specs_and_docs: { agy: 80, mistral: 15, claude: 5, backup: claude }`, `secret: { claude: 100, backup: grok }` |
| A vendor is skipped on a box without its login | `all.env.yaml` lines 1367-1374: `auth_marker` per vendor (e.g. `codex: .codex/auth.json`) |
| Mistral may not code or touch UI | `all.env.yaml`: `mistral_ui_allowed: false` (1380), `mistral_coding_allowed: false` (1387) |
| Pinned CLI versions | `all.env.yaml`: `mistral_vibe.version: 2.26.0` (1434), `openai_codex.version: 0.166.0` (1447) |
| Launchers already switch off telemetry and updates for two CLIs | `spawn-mistral.sh:63` `VIBE_ENABLE_TELEMETRY=false VIBE_ENABLE_UPDATE_CHECKS=false VIBE_ENABLE_AUTO_UPDATE=false`; `spawn-codex.sh:60` `-c analytics.enabled=false -c check_for_update_on_startup=false` |
| The hub calls no model API | `grep -rnoE 'https://[a-z0-9.-]*(anthropic\|openai\|mistral\|x\.ai)' csi-spl-api/src/go csi-spl-wui/src` -> 0 lines; spec 161 1.2: "the hub Cloud Run API does not call Cursor or Codex directly; execution is local to agent boxes" |
| Workspace keys already carry an endpoint, not only a key | `csi-spl-api/src/go/spool-hub-api/internal/keyexec/env.go:101`: qwen gets `OPENAI_API_KEY` and `OPENAI_BASE_URL` from the lease; line 98 refuses a base URL that is not `https://` |
| `ANTHROPIC_BASE_URL` and `OPENAI_BASE_URL` are stripped from every seat before its own kind's are set | `keyexec/env.go:29,32` (`vendorVars`) |

Read for this section: specs [110](../110-mistral-vendor/spec.md),
[115](../115-vendor-split-by-task-kind/spec.md),
[127](../127-workspace-vendor-keys/spec.md),
[159](../159-byo-ai-keys/spec.md),
[161](../161-cursor-codex-vendors/spec.md).

### 2.2 The hub/box split and the GCP estate

| fact | command -> result |
|---|---|
| Terraform steps | `ls csi-spl-iac/src/terraform` -> 30 steps, `000-gcp-remote-bucket` .. `120-github-general-secrets`; the hub is `030-cloud-run-hub`, the db `040-cloud-sql-postgres`, the vendor-key KMS `057-gcp-kms-vendor-keys`, the agent boxes `060-gcp-vm-satellite` and `061-gcp-vm-wine-box` |
| The agent box is a CPU VM, no GPU | `grep -rn 'guest_accelerator\|gpu' csi-spl-iac/src/terraform/060-gcp-vm-satellite csi-spl-iac/src/terraform/061-gcp-vm-wine-box` -> 0 lines; `prd.env.yaml:225` `machine_type: e2-standard-16` |
| The agent box lives in the estate project, one box for dev and prd | `prd.env.yaml` near line 217: `gcp_project: csi-spl-all`; `060-gcp-vm-satellite/03-vm.tf:1`: "ONE always-on agent box for dev and prd, ssh only" |
| Region | repo `CLAUDE.md`: `europe-north1` |
| **A private hub with no cloud dependency already exists** | [guides/local-hub.md](../../doc/md/guides/local-hub.md) 1: "hub, Postgres, the generated Web UI and a GCS emulator, all in Docker, with a local database and no cloud dependency. Nothing listens beyond `127.0.0.1`" |
| Its sign-in works without an outside identity provider | `csi-spl-api/.../internal/auth/local_hub_signin_test.go` header: "Native sign-in on, nothing delivers mail ... The owner's verified credential and seat come from the operator CLI (spool hub-provision-member --password-stdin)" |
| The generated WUI loads no third-party asset by URL | `grep -rnoE 'fonts\.(googleapis\|gstatic)\.com\|googletagmanager\|sentry' csi-spl-wui/nuxt.config.ts csi-spl-wui/src` -> 0 lines (a static grep; a served-bundle network trace is task T0.3) |

### 2.3 What is missing

1. No model server, no GPU host, no terraform step for one.
2. No vendor `local` in lane-mix, the cnf or the conf-validator.
3. No launcher passes a local endpoint to a CLI.
4. The private hub is one box, loopback only: no second box can reach it.
5. No mirror for CLI packages and model weights, so an offline stack cannot
   install or update anything.
6. No evaluation of any open-weight model on our own tasks.

## 3. The two modes

### 3.1 Mode A, mixed

Local model servers sit next to the cloud vendors. A local model is one more
**vendor** to lane-mix (`local`), with a weight per kind, a backup and the
2-try rule of spec 115. A lane on `local` is still run by a vendor CLI
(section 4.3); only its endpoint is ours. The hub, the WUI, sign-in, CI and
deploys stay as they are (Cloud Run, Firebase, GitHub). Traffic to the cloud
vendors continues for every lane not on `local`.

### 3.2 Mode B, full offline

Everything runs inside one network boundary (a GCP VPC with egress denied,
or an on-prem LAN): the private hub (2.2), the generated WUI, the model
servers, the agent boxes and the package and weight mirrors. No byte leaves
the boundary. The cloud vendors are not reachable and not configured.

### 3.3 What "offline" means, per part

| part | mode A (mixed) | mode B (full offline) | gap today |
|---|---|---|---|
| Hub | Cloud Run (step 030) | the private hub in Docker (guides/local-hub.md) | loopback only; multi-box needs a LAN bind + TLS from a local CA (FR-08) |
| Database | Cloud SQL (040) | Postgres in the private hub, encrypted at rest (local-hub 1.3) | none for one box |
| Files | GCS (050-054) | the GCS emulator of the private hub | weights do NOT go there (4.6) |
| WUI | Firebase Hosting (016, 019) | Caddy `wui-static` in the private hub | a served-bundle network trace (T0.3) |
| Sign-in | Google, Microsoft, Facebook, LinkedIn, xAI (`auth/config.go:41-42`) | native sign-in, members provisioned by the operator CLI | no mail delivery offline: password reset is an operator action |
| Vendor keys | KMS (057) + leases (spec 127) | not needed for local models; the endpoint needs only a stack-internal token | the lease's `https://` check (env.go:98) wants a local CA |
| Agent CLIs | vendor clouds | local endpoint only; telemetry, update checks and error reporting off | per CLI, section 4.3 |
| CLI install and update | npm, PyPI, vendor installers | a package mirror inside the boundary, pinned versions only | FR-09 |
| Model weights | downloaded once from a model hub into the weight store | carried in by the operator (disk or mirror), checksummed | FR-05, FR-09 |
| Telemetry | off where the CLI allows (2.1) | off **and** blocked by the egress-deny | the egress test (G3) is the proof, not the switches |
| Git and CI | GitHub, GitHub Actions | a git server inside the boundary; CI optional | **open question Q6** |
| Time, DNS | GCP / public | a local NTP and DNS | on-prem guide |

**Proof of offline.** A switch list can only show what someone thought to
switch off; it cannot prove that nothing leaves ("a control that can only
detect what someone guessed in advance cannot prove absence"). So the G3
proof is an **egress-deny** boundary (a VPC firewall that denies all egress,
or an on-prem firewall) plus a logged count of denied packets, which must be
0 for a full lane run. A denied packet names the leak.

## 4. Architecture

### 4.1 Overview

```text
            +------------------ stack boundary (mode B: egress denied) ----------------+
            |                                                                           |
  browser --+--> WUI (Firebase | Caddy) --> hub (Cloud Run | private hub) --> Postgres  |
            |                                     ^                                     |
            |                     spool / desk    |                                     |
            |   agent box: tmux lanes  -----------+                                     |
            |     claude | codex | mistral | qwen CLI                                  |
            |        |  base URL + stack token                                          |
            |        v                                                                  |
            |   model gateway (optional, P2)  --->  model server(s): vLLM on GPU        |
            |                                       llama.cpp on CPU (small, lde)       |
            |   weight store (disk) <-- mirror <-- operator carry-in                    |
            +---------------------------------------------------------------------------+
  mode A only:  agent CLIs on vendor lanes --> vendor clouds (unchanged)
```

### 4.2 Model serving layer

| candidate | APIs (source, read 2026-11-13) | fit | verdict |
|---|---|---|---|
| **vLLM** | OpenAI-compatible server; Anthropic `/v1/messages` added by PR #22627, merged 2025-10-22 (github.com/vllm-project/vllm/pull/22627) | GPU, batching across many lanes, tool-call parsers, the engine Mistral recommends for Devstral (docs.mistral.ai/vibe/code/cli/offline-models) | **primary** on GPU hosts |
| **llama.cpp** (`llama-server`) | OpenAI-compatible; Anthropic Messages API (huggingface.co/blog/ggml-org/anthropic-messages-api-in-llamacpp) | CPU or one small GPU, GGUF quantised weights, one static binary | **secondary**: CPU boxes, lde, small on-prem |
| Ollama | OpenAI-compatible; Anthropic Messages API since January 2026 (docs.ollama.com/integrations/claude-code; Habr article 988538) | easy for one developer; pulls from its own registry by default | **lde only**; not on a stack host (its registry pull is a hidden egress) |
| SGLang, LMDeploy | OpenAI-compatible; LMDeploy also lists `/v1/messages` (lmdeploy.readthedocs.io) | alternatives to vLLM | panel to weigh; not chosen in v0.1 |

One engine family per host role keeps the images, the health check and the
flag contract to two (vLLM, llama.cpp).

**Gateway.** vLLM and llama.cpp each speak both APIs, so phase 1 needs no
gateway. A gateway (LiteLLM proxy or similar) earns its place in phase 2,
when there are several model servers to route between, per-lane token
accounting (specs 123, 140) and one stack token to rotate. Its choice is a
decision record (section 9.2, D-1).

### 4.3 The client side: which CLI can talk to a local endpoint

| CLI | local endpoint | how (source, read 2026-11-13) | fleet status |
|---|---|---|---|
| Claude Code (`c-`) | yes, Anthropic Messages API | `ANTHROPIC_BASE_URL` + `ANTHROPIC_AUTH_TOKEN` (docs.ollama.com/integrations/claude-code) | spawnable; **client terms with a non-Anthropic model are open question Q7** |
| Codex CLI (`o-`) | yes, OpenAI API | `--oss` with `oss_provider`, or `[model_providers.<id>] base_url` in `config.toml` (developers.openai.com/codex/config-advanced) | spawnable, off by weight (spec 161 2.2.6) |
| Mistral Vibe (`m-`) | yes, OpenAI-compatible | a `local` provider + model preset in `config.toml`; "the CLI does not contact `mistral.ai` or any other external service" (docs.mistral.ai/vibe/code/cli/offline-models) | spawnable; no coding (cnf, 2.1) |
| Qwen Code (`q-`) | yes, OpenAI-compatible | `--auth-type openai` + `OPENAI_BASE_URL` (our own `keyexec/env.go:101-102`) | spawnable, weight 0 everywhere |
| Grok CLI (`g-`) | **unverified**: no documented local endpoint found | the grok seat to confirm | spawnable |
| agy (`a-`) | **unverified**: no documented local endpoint found | the agy seat to confirm | spawnable |

So four of six CLIs can run a lane on a local model with a config change and
no code of ours beyond the launcher. The **client** of a local lane is a cnf
choice (`env.box.local_ai.client`), not hard-wired.

### 4.4 Routing and fallback

- **A new vendor key `local`** in `agent_split` and every
  `agent_split_by_kind` row, weight 0 by default, validated by the
  conf-validator like any vendor. lane-mix picks `local` by weight; the
  launcher of the configured client starts with the local endpoint.
- **Skip on absence**, like `auth_marker`: a box where
  `do_check_model_endpoint` fails (no server, server down, model not loaded)
  skips `local`, and its share falls to the row's backup at once, with no
  2-try wait (spec 115 G4).
- **Backup**: a cloud vendor in mode A; in mode B the backup is another
  local model (a second `local:<model>` entry) or nothing, and the lane waits.
- **Data rule** (global "Spawn an agent" rule): a local model on our own
  hardware sends nothing to a third party, which is the concern the data
  rule exists for. Whether `local` may hold weight in `secret` and
  `orchestration` is the owner's call (**Q3**); until then it is 0 there and
  the conf-validator refuses it.
- **Agent id letter**: a local lane is run by some client CLI, so either it
  keeps the client's letter (`o-`, `c-`, ...) with a `model=local:<name>`
  tag in its registry row, or it gets its own letter (`l-NNN`). **Q2.**

### 4.5 Model classes and sizing

Weights in GB are roughly parameters (billions) times bytes per parameter
(FP8 = 1, 4-bit = 0.5), plus the KV cache, which grows with context and with
the number of parallel lanes. The table is that arithmetic, rounded, not a
measurement; P0 measures it (T0.2).

| class | example open-weight families (sources in 10) | total params | weights FP8 / 4-bit | host shape |
|---|---|---|---|---|
| S | Devstral Small 2 (24B), Qwen3-Coder 30B-A3B, gpt-oss-20b | 20-32B | ~24-32 / ~12-16 GB | 1 GPU of 48-96 GB, or CPU + 64 GB RAM at low speed |
| M | Devstral 2 (123B), gpt-oss-120b | 100-130B | ~120-130 / ~60-65 GB | 1 x 96 GB GPU at 4-bit, 2 at FP8 |
| L | Qwen3-Coder 480B-A35B, DeepSeek, GLM, Kimi class | 400B-1T (MoE) | 400 GB-1 TB / 200-500 GB | one 8-GPU node (8 x B200) |

**GPU availability in our region** (docs.cloud.google.com/compute/docs/gpus/gpu-regions-zones,
read 2026-11-13): `europe-north1-a` and `-b`: **G4** (NVIDIA RTX PRO 6000,
96 GB); `europe-north1-c`: **A4** (8 x B200) and G4. No L4 (G2), A100 or H100
in `europe-north1`; those are in `europe-west4`. So classes S and M fit G4 in
our own region; class L needs A4 (zone c) or another region (**Q5**).

Model choice is **not** made in this spec. Published benchmarks disagree and
move monthly (the editor's search of 2026-11-13 found SWE-bench figures for
the same model families differing widely between sources); the P0
evaluation on our own tasks decides, per kind.

### 4.6 Model storage and updates

- Weights live on a **dedicated data disk** of the model server (a pd on
  GCP, a local disk on-prem), never in git, never in the hub's GCS buckets.
- A weight set is pinned in cnf by **name, revision and sha256** of every
  file (`env.local_ai.models[]`), like the CLI pins; an unpinned or mismatched
  file refuses to load.
- Updates are a cnf edit + `do_model_pull` (mode A: from the model hub or a
  GCS mirror bucket; mode B: from operator-carried media into the mirror),
  then `do_model_server_up` restarts on the new revision. Dev first.
- **Licence gate**: each pinned model carries its licence id in cnf; the
  conf-validator refuses a licence not on the owner's allow-list (**Q8**).

### 4.7 Security and data boundaries

| boundary | rule |
|---|---|
| Endpoint exposure | the model server listens on the stack's private network only (VPC-internal IP on GCP, LAN on-prem); never a public IP; admin by IAP / ssh like the agent boxes |
| Auth to the endpoint | one stack token per env, minted out of band like every key, delivered to the seat by the launcher's env (never argv, never a pane), rotated by an action |
| Transport | TLS from a stack-internal CA (needed anyway by env.go:98's `https://` check) |
| Prompts and outputs | not logged by the server beyond counts (tokens, latency, status); request bodies are never logged |
| Tenancy | one model server may serve many workspaces only if no state crosses tenants (prefix-cache sharing across tenants: **open for the panel**, P-1) |
| Supply chain | engine images pinned by digest; weights by sha256; packages from the mirror at pinned versions only |

### 4.8 Evaluation (the quality gate)

A kind routes to `local` only after a model passes, for that kind, the
**replay set**: N past lanes of that kind with a known landed answer, re-run
on the candidate (client + model), judged by the same cross-vendor review the
fleet uses. The report records version, tree and n (the fleet's "cross-lane
finding states three fields" rule). The pass bar per kind is an owner choice
made from the first report, not fixed here.

## 5. Infrastructure

### 5.1 On GCP, by our existing path

| piece | how | new or existing |
|---|---|---|
| Model server VM | new terraform step **`062-gcp-vm-model-server`**, shaped as `060-gcp-vm-satellite` (VM + separate data disk + IAP + ansible playbook), plus `guest_accelerator` and `on_host_maintenance = TERMINATE` | new |
| Its project | the estate project of the agent boxes (`csi-spl-all`), like 060/061, or per env: **Q9** | decision |
| Weight store | its data disk; optional mirror bucket in a new GCS step | new |
| Egress deny (mode B on GCP) | a firewall rule set in the step, off in mode A | new |
| Start / stop | `do_model_server_up`, `do_model_server_down` (scheduled business hours if the owner picks it, Q4) | new actions, csi-spl-iac |
| Health | `do_check_model_endpoint` (both APIs, the pinned model loaded); the watchdog reads it | new action + watchdog situation |
| Budget | a budget alert like steps `058-gcp-wine-box-budget` / `059-gcp-satellite-budget` | new |
| Sizes and pins | cnf `env.local_ai.*` in `all.env.yaml`, overridden per env | new cnf |

Every rule of the repo holds: terraform only in the tf-runner, the per-env
SA key, `--account` on every gcloud call, the owner's go for every apply,
dev applied before prd.

### 5.2 On-premises: what changes, what stays

| stays | changes |
|---|---|
| the container images (vLLM, llama.cpp, the private hub) | no terraform: the host exists; the ansible playbook of step 062 runs against an inventory the operator writes (as `061-gcp-vm-wine-box/inventory.example.ini` already does) |
| the cnf model pins, the licence gate, the evaluation | GPU driver and container toolkit install are an operator step in the guide |
| the `./run` actions (`do_model_*`, `do_check_model_endpoint`) | no IAP: ssh on the LAN |
| the private hub (guides/local-hub.md) | the hub binds the LAN with a local-CA certificate (FR-08) |
| lane-mix, launchers, routing | no Cloud KMS: the private hub's at-rest encryption (local-hub 1.3) and file keys |

### 5.3 Costs (rough, monthly, 730 h)

| option | unit price (source, read 2026-11-13) | always on | business hours (220 h) |
|---|---|---|---|
| G4 `g4-standard-48`, 1 x RTX PRO 6000 96 GB (class S/M) | ~$4.50/h on-demand, region column not confirmed (cloud.google.com/products/compute/pricing/accelerator-optimized via search; vpsbenchmarks.com); spot ~$0.86-2.34/h (gcloud-compute.com) | ~$3,300 | ~$1,000 |
| A4 `a4-highgpu-8g`, 8 x B200 (class L) | ~$34.24/h on-demand **us-central1**, third-party (devzero.io, spheron.network; Google publishes no static A4 table) | ~$25,000 | ~$7,500 |
| CPU llama.cpp on an existing agent box (class S, slow) | $0 extra; takes cores from lanes | $0 | $0 |
| Data disk for weights, 500 GB pd-balanced | **unverified**, to price in the calculator (T0.4) | - | - |
| On-prem 1 x 96 GB GPU workstation | capex **unverified** | power only | - |

The europe-north1 prices must be read from the pricing calculator before a
budget is asked (task T0.4); the figures above are directional.

## 6. Requirements (status)

| id | requirement | status |
|---|---|---|
| FR-01 | A model server serves pinned open-weight models over OpenAI and Anthropic APIs on a private network | Planned |
| FR-02 | Vendor `local` in cnf, conf-validator, lane-mix, journal and the WUI split page | Planned |
| FR-03 | Launchers start the configured client CLI against the local endpoint with the stack token, telemetry/update/error reporting off | Planned |
| FR-04 | `local` is skipped at once when its endpoint check fails | Planned |
| FR-05 | Weights pinned by revision and sha256, with a licence gate | Planned |
| FR-06 | Step `062-gcp-vm-model-server`, dev first | Planned |
| FR-07 | The same playbook installs on an on-prem host from an inventory | Planned |
| FR-08 | The private hub serves a LAN with a local-CA certificate | Planned |
| FR-09 | Package and weight mirror inside the boundary | Planned |
| FR-10 | Egress-deny proof: a full lane run with 0 denied packets | Planned |
| FR-11 | Per-kind evaluation report gates any non-zero `local` weight | Planned |
| FR-12 | The private hub with no cloud dependency, one box | **Implemented** (guides/local-hub.md; `local_hub_signin_test.go`) |

## 7. Risks

| risk | mitigation |
|---|---|
| Open models do worse than the cloud vendors on our lanes | the per-kind gate (4.8); mode A keeps the cloud backup |
| A GPU VM left on burns money | scheduled stop; budget alert like steps 058/059 |
| A CLI calls home despite its switches | egress-deny proof (3.3); a denied packet is a defect |
| A client's terms forbid a non-vendor model | Q7 before that client gets weight |
| GPU capacity in europe-north1 runs out | Q5 (another region) |

## 8. Phasing

| phase | content | exit |
|---|---|---|
| **P0 measure** | T0.1 replay-set harness (4.8); T0.2 run 2-3 class S/M models on a G4 dev VM (**only with the owner's go**), or on CPU for class S; T0.3 served WUI network trace; T0.4 europe-north1 prices | evaluation report per kind |
| **P1 mixed, one client** | FR-01 (vLLM), FR-02, FR-03 for the Q1 client, FR-04, FR-05, FR-06 in dev | one kind at a small `local` weight in dev, journal rows |
| **P2 mixed, all clients** | FR-03 for every capable CLI, gateway decision D-1, token accounting | `local` in the owner's chosen kinds |
| **P3 full offline on GCP** | FR-08, FR-09, FR-10 in a dev project with egress denied | G3 proof |
| **P4 on-prem** | FR-07, the on-prem guide, replayed on a non-GCP host | G5 proof |
| **P5 prd** | prd after dev, per the owner's go | live |

## 9. Open questions for the owner (poll-ready) and further documents

### 9.1 Questions

| key | question | options |
|---|---|---|
| Q1 | Which CLI runs the first local lanes? | `cdx` Codex (OpenAI API, `--oss`), `cla` Claude Code (Anthropic API), `mis` Mistral Vibe (docs only, per cnf), `qwn` Qwen Code |
| Q2 | Agent id of a local lane | `cli` keep the client's letter + a model tag, `l` new letter `l-NNN` |
| Q3 | May `local` take secret and orchestration work (data stays on our hardware)? | `yes`, `no`, `aft` after the P0 report |
| Q4 | GPU budget envelope for P0-P1 | `on` G4 always on (~$3.3k/mo), `biz` business hours (~$1k/mo), `spt` spot only, `cpu` no GPU until P0 on CPU |
| Q5 | Region for GPUs | `n1` europe-north1 only (G4, A4), `w4` europe-west4 allowed too |
| Q6 | Full offline scope first | `one` one box (private hub + model server), `lan` multi-box with git server and local CA |
| Q7 | Who is full offline for? | `flt` our own fleet, `cus` a customer workspace (on-prem product), `bot` both |
| Q8 | Model licence allow-list | `osi` Apache-2.0 / MIT only, `opn` any open-weight licence the panel reviews per model |
| Q9 | Where does the model server live? | `all` the estate project with the agent boxes, `env` one per env (dev, prd) |

### 9.2 Further documentation artifacts (the editor's proposal, R8)

An architecture spec alone does not carry this feature. Proposed, each its
own file under this folder unless said otherwise:

1. **Decision records** (`adr/`): D-1 gateway or none; D-2 serving engine;
   D-3 agent id of a local lane; D-4 model licence policy.
2. **Model evaluation report** (P0): per kind and model, version, tree, n.
3. **Threat model and data-flow diagram** for modes A and B.
4. **Cost model**: the calculator figures for europe-north1, per option.
5. **On-prem install and operator guide**: extends
   [guides/local-hub.md](../../doc/md/guides/local-hub.md) with the model
   server and the mirror.
6. **Model update runbook**: pin, pull, verify, roll back.
7. **tasks.md**: the build tasks of section 8, one issue each.

## 10. Sources (read 2026-11-13)

- Ollama, Claude Code integration: docs.ollama.com/integrations/claude-code; Ollama blog: registry.ollama.ai/blog/claude; Habr 988538 (Anthropic API in Ollama, January 2026).
- OpenAI Codex advanced configuration: developers.openai.com/codex/config-advanced.
- Mistral Vibe offline models: docs.mistral.ai/vibe/code/cli/offline-models.
- vLLM Anthropic Messages endpoint: github.com/vllm-project/vllm/pull/22627 (merged 2025-10-22); issue 21313.
- llama.cpp Anthropic Messages API: huggingface.co/blog/ggml-org/anthropic-messages-api-in-llamacpp.
- LMDeploy Anthropic-compatible endpoints: lmdeploy.readthedocs.io/en/stable/llm/api_server_anthropic.html.
- GCP GPU regions and zones: docs.cloud.google.com/compute/docs/gpus/gpu-regions-zones.
- GCP accelerator pricing: cloud.google.com/products/compute/pricing/accelerator-optimized; vpsbenchmarks.com (g4-standard-48); gcloud-compute.com/g4-standard-48.html (spot range); devzero.io/instances/gcp/a4-highgpu-8g and spheron.network (A4, us-central1).
- Open-weight coding model families (families only, no score relied on): modal.com/resources/best-open-source-models-swe-bench-coding-agents; morphllm.com/best-ai-model-for-coding.

## 11. Panel and consensus

| seat | vendor | findings folded | PASS on sha |
|---|---|---|---|
| editor c-690 | claude | v0.1 author | - |
| grok seat | grok | - | - |
| mistral seat | mistral | - | - |
| codex seat | codex | - | - |
| agy seat (signs last) | agy | - | - |

### 11.1 Changelog

- v0.1 (2026-11-13): editor's draft from its own research of brief items 1-5.

<!-- version: 0.1.0 · updated: 2026-11-13 · last-edit: 2026-11-13T15:30:00Z -->
