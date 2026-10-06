# 075 Repo Docs Edit: Panelist Opinion (agy)

**Feature ID**: `075-docs-section/repo-edit` · **Milestone**: M3 · **Status**: Panelist Proposal & Review
**Panelist**: `a-382` (agy, independent) · **Role**: Spec Panelist · **Topic**: t1 `2e20d6d4-16b7-4be2-b7d7-45c4f1fbf56e`
**Draft Reviewed**: `csi-spl-doc/specs/075-docs-section/repo-edit/spec.md` at commit `6f91653fb` (by `c-380`)
**Authority**: [`../spec.md`](../spec.md) for Docs section architecture; this document for panelist agy's independent evaluation and recommendations.

---

## 1. Executive Summary & Core Architectural Position

The owner's directives (t1 messages `100bc0a2`, `6ebd86b6`, `d968b50a`) mandate enabling end users to edit markdown documentation from the web application, saving changes immediately to object storage (GCS docs bucket), and asynchronously pushing the commits to GitHub via a dedicated system committer while preserving the editing user as the Git commit author.

**Panelist agy's Core Stance**:
1. **Low-Latency Storage-First UX**: The immediate bucket save (<100ms) is essential. Users must not block on GitHub network I/O, Git tree manipulation, or CI pipelines. Serving unlanded edits via an explicit bucket overlay prefix (`.edits/`) prevents race conditions against concurrent deployments.
2. **Minimal Infrastructure Footprint**: The queue belongs in Postgres (`repo_doc_edits`), processed by a dedicated worker goroutine in the Hub process using advisory locks. External queues (Pub/Sub, Cloud Tasks) introduce unwarranted operational surface and Terraform dependencies.
3. **Direct to Master on Trunk**: Edits must push directly to `master` (fast-forward only) using GitHub's Git Data API. Branch + PR workflows introduce intolerable delay (5–15 minutes) and notification noise for simple documentation fixes.
4. **Mandatory CI Protection**: Pushing directly to `master` must NOT trigger expensive full-stack build/test CI runs. A strict documentation-only path filter or job skip in GitHub Actions workflow 10 is mandatory before enabling this feature on `master`.
5. **Rigorous Abuse & Injection Defense**: Universal editing must never grant write access to agent system instructions (`CLAUDE.md`, `AGENTS.md`, `GEMINI.md`) or executable code/workflows (`.github/**`, `csi-spl-*/**`). Editable paths must be strictly confined to `csi-spl-doc/**` and root informational documents.

---

## 2. Independent Proposal: Answers to Open Questions Q1–Q7

### Q1. Flow & Queue Architecture
- **Concrete Proposal**:
  1. **Save Step**: The browser issues `PUT /v1/docs/{path}` with the updated markdown and `If-Match: <base_blob_sha>`. The Hub validates authorization (`docs.write` and workspace switch), path safety, content size, hygiene, and secrets.
  2. **Storage Write**: Hub synchronously writes the draft to `gs://<docs-bucket>/.edits/<path>/<edit_id>.md`.
  3. **Queue Enqueue**: In the same database transaction, Hub inserts a record into the `repo_doc_edits` table with `status = 'queued'`. Hub returns HTTP 200 `{edit_id, status: "queued"}`.
  4. **Worker Execution**: An in-hub background worker goroutine, single-flighted across hub instances via `pg_try_advisory_lock(0x50757368)` ("Push"), drains the queue using `SELECT ... FOR UPDATE SKIP LOCKED` ordered by `created_at ASC`.
  5. **Retries & Backoff**: Exponential backoff for transient network or GitHub 5xx/429 errors (5s, 15s, 45s, 2m, 5m, 15m; max 6 attempts). Permanent validation failures or non-rebasable conflicts transition immediately to terminal `failed` or `conflict`.
  6. **Coalescing**: Only unstarted (`status = 'queued'`) rows for the same file path and the same author are coalesced into the newest revision; rows already in `pushing` are immutable.
  7. **User Status**: WUI displays responsive status chips on the document header:
     - `queued` / `pushing`: "Saved · syncing to GitHub"
     - `pushed`: "Pushed · <sha7>" (linked to commit on GitHub)
     - `published`: No badge (overlay removed after publish sync)
     - `conflict`: "Conflict · resolve required"
     - `failed`: "Sync failed · retry"
- **One-Line Why**: Storing the queue in Postgres alongside transactional metadata provides zero-dependency durability, restart safety, and instant UI polling without external messaging infrastructure.
- **Risks & Mitigations**:
  - *Risk*: Multiple Hub replicas could attempt concurrent pushes to GitHub.
  - *Mitigation*: Hub instances acquire a Postgres advisory lock; only the lock holder runs the worker loop.
  - *Risk*: Hub process crash leaves a row stuck in `pushing`.
  - *Mitigation*: Heartbeat timestamp on `pushing` rows; stale locks older than 5 minutes are reclaimed by the worker.

---

### Q2. Push Target: Direct to Master vs Branch + PR
- **Concrete Proposal**:
  - **Production (`prd`)**: Push **directly to `master`** via GitHub Git Data API (fast-forward ref update).
  - **Development (`dev`)**: Push to a dedicated integration branch `docs-edit-dev` to validate the end-to-end flow without altering shared repo trunk.
  - **CI Gate Requirement**: GitHub Actions workflow 10 (`ci-quality`) must be updated with an early path-filter step (`paths-ignore: ['csi-spl-doc/**', 'README.md', 'CONTRIBUTING.md', 'DEPLOY.md', 'CODE_OF_CONDUCT.md']` or a fast exit script when `git diff` shows only markdown paths under `csi-spl-doc/`) before this feature is enabled in production.
- **One-Line Why**: Direct push honors the owner's trunk-based continuous delivery model and eliminates the 5–15 minute latency and PR inbox spam of automated pull requests.
- **Risks & Mitigations**:
  - *Risk*: Direct commits to `master` trigger heavy CI pipelines, exhausting GitHub Actions concurrency and slowing agent development.
  - *Mitigation*: Restrict push paths to documentation, and implement light-path skips in workflow 10 so markdown-only commits run only linting, not full Docker builds.

---

### Q3. Conflict Handling
- **Concrete Proposal**:
  - The client provides `base_blob_sha` from when the document was loaded.
  - When the worker runs:
    1. Read the current `head_blob_sha` of the target branch on GitHub.
    2. If `head_blob_sha == base_blob_sha`: Commit directly with `head` commit as parent.
    3. If `head_blob_sha != base_blob_sha` (master moved): Perform a server-side 3-way merge (`diff3`) between `base`, `head`, and `edit`.
       - If merge is clean (non-overlapping line edits): Commit the merged content and record `merged_with: <head_sha>`.
       - If merge produces line conflicts: Set status to `conflict`, stop push execution, retain the user's overlay in GCS, and prompt the user in the WUI with a side-by-side diff resolution screen.
  - Sequential concurrent edits on the same document in the app must chain: if edit B arrives while edit A is `pushing`, edit B waits until edit A finishes, taking edit A's resulting commit blob as its new base.
- **One-Line Why**: Automated 3-way line merges resolve the vast majority of non-competing document edits seamlessly, while strict refusal on genuine line conflicts prevents repository corruption.
- **Risks & Mitigations**:
  - *Risk*: A silent merge could alter markdown table formatting or code block syntax.
  - *Mitigation*: The commit message explicitly notes `Merged with <sha7>`; full diff history is preserved in database and Git history.

---

### Q4. Author Mapping & Commit Hygiene
- **Concrete Proposal**:
  - **Git Committer**: The system GitHub App bot identity (e.g. `spool-doc-bot[bot] <bot@users.noreply.github.com>`).
  - **Git Author Resolution (3-Tier Cascade)**:
    1. *Direct Map*: Explicit mapping configured in `repo_doc_authors` table (`human_id -> git_name, git_email`) for team members with known preferred Git signatures.
    2. *History Match*: Verified sign-in email matched against `.mailmap` or historical Git commit log authors (`repo_doc_known_authors`).
    3. *Noreply Fallback*: For workspace members with no repository commit history, use `Display Name <<human_id>@users.noreply.<BASE_DOMAIN>>` (or their GitHub noreply address if OAuth-linked).
  - **Hygiene & Leak Gate**:
    - Commit message format: `docs(<path>): update via workspace docs [skip ci]` with explanatory body.
    - **Strictly No AI Trailers**: Explicit regex filter rejecting `Co-Authored-By:`, `Generated with`, `Claude-Session:`, or similar automated agent trailers.
    - Agents (which hold `docs.write` in RBAC) are prohibited from using the user-facing Repo Docs edit route in v0.1; they must use dedicated agent workspace channels and direct worktree mechanics.
- **One-Line Why**: Accurately credits the human creator in Git commit logs without leaking private member emails to a public repository, while preserving the single authorized system committer.
- **Risks & Mitigations**:
  - *Risk*: Leak of private corporate or personal email addresses to a public GitHub repo.
  - *Mitigation*: Unregistered users always map to synthetic `<human_id>@users.noreply.<BASE_DOMAIN>` addresses.

---

### Q5. Permissions, Path Restrictions & Abuse Control
- **Concrete Proposal**:
  - **Workspace Gate**: Feature flag `repo_docs_edit: true` disabled by default; enabled per workspace via environment configuration (`env.docs.repo_edit.workspaces`).
  - **Member Gate**: Authenticated member with `docs.write` permission.
  - **Strict Path Allow-List**: Edits are permitted **strictly** within:
    - `csi-spl-doc/**` (excluding `csi-spl-doc/specs/*/tasks.md` which is authority for build execution).
    - Root informational docs: `README.md`, `CONTRIBUTING.md`, `DEPLOY.md`, `CODE_OF_CONDUCT.md`.
  - **Strict Deny-List**:
    - Agent system prompt files: `CLAUDE.md`, `AGENTS.md`, `GEMINI.md` anywhere in the repo.
    - Infrastructure and code paths: `csi-spl-iac/**`, `csi-spl-api/**`, `csi-spl-orc/**`, `csi-spl-cnf/**`, `csi-spl-wui/**`.
    - Workflow and CI directories: `.github/**`.
    - Task execution trackers: `csi-spl-doc/specs/*/tasks.md`.
  - **Size & Rate Limits**: Max document size 1 MiB (`MaxWorkspaceDoc`); max 20 saves per user per hour; max 200 saves per workspace per day.
  - **Pre-Commit Text Hygiene**: Server-side validation before writing to GCS:
    - Distribution hygiene pattern check (no unmasked secrets, no forbidden personal names or internal hostnames).
    - Secret scanning regex for private keys, cloud service account JSON keys, and API tokens.
- **One-Line Why**: Prevents prompt injection attacks against the fleet, blocks accidental code/infrastructure tampering, and ensures compliance with distribution hygiene rules.
- **Risks & Mitigations**:
  - *Risk*: A compromised user account attempts to tamper with agent behavior or inject secrets.
  - *Mitigation*: Hard deny-list on all agent instruction files combined with synchronous secret scanning and audit logging of all edit attempts.

---

### Q6. The Bucket <-> Repository Reconciliation Loop
- **Concrete Proposal**:
  - **Storage Separation (Overlay Pattern)**:
    - The canonical bucket objects (`gs://<bucket>/<path>.md`) and `tree.json` represent deployed repository state from Git.
    - Live edits are written to `.edits/<path>/<edit_id>.md`.
    - When `GET /v1/docs/<path>` is called, the Hub checks for active unlanded edits (`queued`, `pushing`, `pushed`, or `conflict`) and serves the overlay; otherwise, it serves the canonical published file.
  - **Republish Trigger**:
    - A dedicated lightweight GitHub Actions workflow `32_docs-publish.yml` triggers upon pushes to `master` affecting `csi-spl-doc/**` and allowed root markdown files.
    - Workflow 32 runs `do_publish_docs` directly to update canonical bucket files and `tree.json` with the new commit SHA (no app builds, no container pushes).
  - **Overlay Cleanup**:
    - The Hub worker inspects `tree.json.sha`. Once `tree.json.sha` matches or is an ancestor of the edit's `commit_sha`, the status transitions to `published`, and the `.edits/` object is purged.
- **One-Line Why**: Decouples instant user viewing from Git sync, eliminates the risk of in-flight deploys overwriting uncommitted edits, and provides a clear convergence point when Git publishes back to GCS.
- **Risks & Mitigations**:
  - *Risk*: Frequent calls to GitHub Compare API during worker polling exhaust rate limits.
  - *Mitigation*: Worker primarily compares `tree.json.sha` against `commit_sha` locally; Compare API is invoked only on ambiguous branches with a cache.

---

### Q7. Secret Management & Infrastructure
- **Concrete Proposal**:
  - **Identity**: A dedicated **GitHub App** installed on repository `csitea/csi-spl` with minimal permissions: `Contents: write` and `Metadata: read`. Webhooks disabled.
  - **Secret Storage**: GitHub App private key stored in Google Cloud Secret Manager as `spool-hub-github-app-key` in each environment's GCP project.
  - **Hub Runtime Access**: The Hub runtime service account receives Secret Manager Secret Accessor IAM permission via Terraform step `030-cloud-run-hub`. The key is exposed via the existing `secret_environment_variables` mechanism as `SPOOL_GITHUB_APP_KEY`.
  - **Token Lifecycle**: Hub generates a short-lived (1-hour) installation access token dynamically using JWT RS256 signing; tokens are cached in memory for 50 minutes and never persisted to disk.
  - **Lifecycle Automation**: Dedicated shell actions `do_put_github_app_key` and `do_rotate_github_app_key` for zero-downtime key rotation.
- **One-Line Why**: GitHub Apps provide fine-grained repository scoping, short-lived tokens, distinct bot commit attribution, and native private key rotation without human account dependencies.
- **Risks & Mitigations**:
  - *Risk*: Private key leakage grants write access to repo master.
  - *Mitigation*: Key resides strictly in Secret Manager; GitHub App permissions are scoped exclusively to `Contents: write` on the specific repository.

---

## 3. Review of Draft Spec (`spec.md` at commit `6f91653fb`)

Draft `spec.md` prepared by `c-380` provides a solid baseline. Panelist agy's specific evaluations per section are detailed below:

### Review of Section 3 (Q1 Flow & Queue)
- **Verdict**: **Agree with refinement**.
- **Assessment**: The `repo_doc_edits` table with `pg_try_advisory_lock` and in-hub worker is well-conceived.
- **Concrete Replacement/Refinement for §3**:
  Clarify coalescing boundary: *Only rows in state `queued` may be superseded.* Once a row transitions to `pushing`, its commit payload is locked and cannot be coalesced. A new edit during `pushing` must create a distinct subsequent `queued` row to prevent race conditions with in-flight Git Data API calls.

### Review of Section 6 (Q2 Target: Master vs Branch/PR)
- **Verdict**: **Agree with mandatory condition**.
- **Assessment**: Direct fast-forward push to `master` for production and `docs-edit-dev` for development is correct.
- **Concrete Replacement/Refinement for §6**:
  Lane L7 (CI skip of heavy jobs in workflow 10 for `*.md`-only pushes) must be classified as a **prerequisite blocker (P0)**, not an optional item. Direct doc pushes will otherwise trigger heavy CI runs on every edit, causing runner queue saturation.

### Review of Section 8 (Q3 Conflicts & Merging)
- **Verdict**: **Agree with chaining requirement**.
- **Assessment**: 3-way merge on `base`, `head`, and `edit` with fallback to `conflict` status is robust.
- **Concrete Replacement/Refinement for §8**:
  Add explicit sequential chaining for concurrent in-app edits: If user B edits a document while user A's edit is in state `pushing`, user B's save cannot use user A's unpushed overlay as a Git base. The worker must sequence these edits: after user A's commit lands, the worker automatically rebases user B's edit onto user A's new Git blob SHA before attempting the push.

### Review of Section 4 (Q4 Author Mapping)
- **Verdict**: **Strong Agree**.
- **Assessment**: The 3-tier resolution (`repo_doc_authors` table -> known author history match -> `<human_id>@users.noreply.<BASE_DOMAIN>`) cleanly balances credit with privacy. Committer as `<app-slug>[bot]` meets standard GitHub practice. Strict prohibition of AI trailers maintains distribution hygiene.

### Review of Section 5 (Q5 Permissions & Abuse Control)
- **Verdict**: **Agree with expanded deny-list**.
- **Assessment**: Workspace feature toggle, `docs.write` check, and distribution hygiene validation are essential.
- **Concrete Replacement/Refinement for §5**:
  Expand the deny-list to explicitly include all non-documentation module roots: `csi-spl-iac/**`, `csi-spl-api/**`, `csi-spl-orc/**`, and `csi-spl-cnf/**`. Repo docs editing must be strictly restricted to `csi-spl-doc/**` and root informational files.

### Review of Section 7 (Q6 Bucket <-> Repo Loop)
- **Verdict**: **Agree with rate-limit optimization**.
- **Assessment**: The `.edits/` overlay prefix cleanly shields in-flight edits from `do_publish_docs` rsync purges.
- **Concrete Replacement/Refinement for §7**:
  To protect GitHub API quotas, the worker should not poll GitHub Compare API on every cycle. Instead, workflow `32_docs-publish.yml` must write `DOCS_COMMIT_SHA` into `tree.json`. The worker checks if `tree.json.sha` matches the edit's `commit_sha` or queries a locally cached commit graph.

### Review of Section 9 (Q7 Identity, Secret & Infra)
- **Verdict**: **Strong Agree**.
- **Assessment**: GitHub App with `contents: write`, private key in Secret Manager (`spool-hub-github-app-key`), dynamic JWT exchange for 1-hour tokens, and terraform integration in step `030-cloud-run-hub` is the optimal, production-grade architecture.

---

## 4. Architectural Evaluation & Scores (1–5)

Comparison between Panelist agy's proposal and Draft `spec.md` (v0.1, commit `6f91653fb`):

| Dimension | agy Proposal | Draft `spec.md` (`6f91653fb`) | Assessment & Rationale |
|---|:---:|:---:|---|
| **Simple** | **4 / 5** | **4 / 5** | Uses existing Postgres database, Go worker goroutine, and GCS bucket; introduces no external message queues or brokers. |
| **Safe (secrets + abuse)** | **5 / 5** | **4 / 5** | agy tightens the deny-list to exclude all module root paths, enforces server-side hygiene/secret scanning, and leverages GitHub App with short-lived tokens. |
| **Robust (conflicts, failures)** | **4 / 5** | **3 / 5** | agy adds sequential chaining for concurrent in-app edits and avoids GitHub Compare API polling exhaustion; both handle 3-way merges and network retries gracefully. |
| **Fast for the user** | **5 / 5** | **5 / 5** | Immediate GCS overlay save delivers sub-100ms user response; async worker isolates user interaction from Git network roundtrips and CI runs. |

### Rationale Details:
- **Simple**: Both designs score 4/5 by eschewing external message brokers (Pub/Sub) in favor of Postgres transactional queueing and standard Git Data APIs.
- **Safe**: agy scores 5/5 by closing potential code/infra editing vectors (locking all module roots) and ensuring agent prompt files (`CLAUDE.md`, etc.) are completely untouchable.
- **Robust**: agy scores 4/5 by addressing sequential edit chaining and GitHub API quota management; the draft scores 3/5 due to potential race conditions on in-flight overlays and polling overhead.
- **Fast**: Both score 5/5 because end users experience zero lag during document saves.

---

## 5. Summary Matrix & Consensus Checklist

| Question | agy Position | Draft `c-380` (`6f91653fb`) | Consensus Status | Action Required |
|---|---|---|:---:|---|
| **Q1 Flow** | Postgres queue + in-hub worker + `.edits/` GCS overlay | Same | **AGREE** | Clarify coalescing boundary (`queued` only). |
| **Q2 Target** | Direct to `master` (prd), `docs-edit-dev` (dev) | Same | **AGREE** | Make workflow 10 light-path skip mandatory (P0). |
| **Q3 Conflicts** | 3-way merge; sequential chaining on overlays; refuse on line conflict | 3-way merge; side-by-side resolve | **AGREE** | Formalize sequential edit chaining in spec. |
| **Q4 Author** | 3-tier cascade; App bot committer; no AI trailers | Same | **AGREE** | Adopt as written. |
| **Q5 Abuse** | Strict allow-list (`csi-spl-doc/**` + root docs); lock all module roots | Deny-list (CLAUDE, wui, tasks.md) | **AMEND** | Expand deny-list to cover all module roots (`csi-spl-*/**`). |
| **Q6 Loop** | `.edits/` overlay; workflow 32; check `tree.json.sha` | Same with Compare API poll | **AMEND** | Optimize publish check to avoid GitHub API rate limits. |
| **Q7 Secret** | GitHub App (`contents: write`); Secret Manager; short-lived JWT | Same | **AGREE** | Adopt as written. |

<!-- agy-opinion: feature 075-docs-section/repo-edit · panelist a-382 · 2026-10-06 -->
