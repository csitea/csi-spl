# Spec 157: Dispatch Automation — Deterministic Execution of Mechanical Dispatch Procedures

**Feature ID**: `157-dispatch-automation` · **Status**: Draft v0.6 · **Epic**: SPL-2398 · **Issue**: SPL-3392  
**Created**: 2026-10-25 · **Updated**: 2026-10-25 (incorporating cross-vendor review feedback from `c-220@sat` resolving Z1–Z3) · **Lead**: a-213 · **Placement slug**: `c002-spec-157-dispatch-automation`  
**Related Specs & Docs**:  
- [SPEC-spool-fleet-roles.md](../../doc/md/SPEC-spool-fleet-roles.md) (Fleet roles, 3-minute SLA, routing rules, lease failover, owner go gates, and asks ledger)  
- [spec 060 Role Rotation](../060-role-rotation/spec.md) (Hourly rotation, standby states, handoff files)  
- [developer-guide.md](../../doc/md/developer-guide.md) (Trunk branching, deploy lag, coding standards)  
- [rounds-rulebook.md](../../doc/md/rounds-rulebook.md) (R7 review line verification, cross-vendor requirements § 2.7.2, red controls)  
- [how-to-post.md](../../doc/help/how-to-post.md) (Post rules, poll forms, Rule 14 served ancestor, Rule 15 in-progress, Rule 16 Live proof, Section 4 clock times)  
- [lane-integration-rules.md](../../doc/md/lane-integration-rules.md) (Exit-clean ACCEPTED gate, git workflow)  

**Authority**: This document defines the architectural specifications, deterministic safety predicates, refusal invariants, execution topologies, red-control test suites, and build task decomposition for automating the mechanical dispatching actions identified by the owner and the dispatch team on 2026-10-25. Docs only; this specification introduces no immediate code, cron, or infrastructure mutations.

---

## 1. Context & Owner Mandate

### 1.1 The Owner's Direct Words
In topic `99ffa592-3717-4b9e-8a80-62c70456ceff` (`#spool-hub-ops`, prd tenant `t1`, HUM-10):
- **msg `a99676b7`**: *"Also, I would expect some kind of suggestions for improvements on the whole dispatching process. What could be automated to be done without any intelligence?"*
- **msg `1c8a754e`**: *"If he has not done that till now"* (addressing Grok's dispatching performance).
- **poll `6de8b12d`**: Asked whether to (A) grade Grok's 58 hours and build rules 1–6, (B) only grade Grok's 58 hours, or (C) build a 10-hour shadow mode.
- **msg `c9213bd2` (Answer A)**: The owner explicitly voted **Answer A**: *"Grade grok's 58 hours, and build rules 1-6"*.

### 1.2 Empirical Baseline: The 2026-10-25 Shift Measurement
On 2026-10-25, the active dispatcher (`c-002@sat`, post `6de8b12d`) recorded approximately **30 purely mechanical interventions** performed manually over a single operating shift:
1. Manually reading reviewer result messages, checking that the verdict was `PASS` and the git branch head had not moved, and sending a manual `GO` task to the author.
2. Manually inspecting landed commits on `origin/master`, diffing added/removed lines against the reviewed commit to detect rogue rebase modifications, checking GitHub Actions CI status, checking served `/version` (Cloud Run) and `/build.json` (Firebase Hosting) endpoints, and sending an `ACCEPTED` result to allow the lane to exit.
3. Reading newly placed reviewer seat briefs, extracting target author IDs and branches, and manually sending notification messages to each author lane.
4. Manually collecting commit SHAs, deployment proofs across dev/prd, and testing evidence to assemble the `**Live**` proof table demanded by `how-to-post.md` Rule 16.
5. Manually replying with acknowledgments when the owner clicked poll options in active discussions.
6. Manually typing UTC timestamps into status posts, which repeatedly resulted in human/model timezone transposition errors (e.g. typing local EET as UTC).

In parallel, `c-003@sat` (standby dispatcher, message `604472ca` / `17:17:10Z`) documented seven additional mechanical frictions:
- Standby seats being woken by unaddressed channel messages and routine test alerts that could be auto-archived.
- Lanes sending final reports to hardcoded dispatcher IDs rather than dynamically querying the live lease holder.
- Cross-box brief path fragmentation between `sat` and `<box-far>`.
- Repetitive ask bookkeeping (`ask_put`, `ask_ack`, `ask_close`) where task completion could deterministically close the ask.
- Manual drafting of standby handoff text when the queue, ask ledger, and hold notes already contain the complete state.
- Redundant and varied manual checks across lanes to determine if work is done.

### 1.3 The Problem: Cognitive Burden and Model Churn
LLM agents serving as dispatchers (`c-002`, `g-002`, `a-002`) are provisioned to make context-dependent evaluations: understanding human questions, breaking down ambiguous requests into specced work, assigning appropriate lane vendors, and handling unpredicted operational failures.

When dispatchers are forced to spend context tokens, prompt turns, and execution time executing static binary checks (e.g. `is git commit X an ancestor of master?`, `does diff line count match?`, `is CI status == success?`), three systemic failure modes emerge:
1. **Context Window Exhaustion**: A dispatcher's context window rapidly fills with git diffs, curl outputs, and repetitive notification logs, accelerating session degradation and triggering premature rotation.
2. **Turn Latency & Missed Pokes**: The dispatcher becomes occupied executing bash scripts for simple checks, delaying responses to inbound human posts beyond the mandatory 3-minute SLA ([SPEC-spool-fleet-roles.md](../../doc/md/SPEC-spool-fleet-roles.md) § 3).
3. **Model Hallucination & Transcription Errors**: LLMs regularly misread hex SHAs, omit trailing whitespace, or botch timezone calculations (as seen on 2026-10-25 when `c-002` typed incorrect UTC hours).

**Design Principle**: Anything that can be evaluated as a deterministic predicate on disk or via API must be executed by a shell script or daemon. Model intelligence is strictly reserved for judgment, ambiguity, and human conversation (owner: *"the less intelligence, the better"*).

---

## 2. Architecture & Existing Foundation (State on origin/master)

```mermaid
flowchart TD
    subgraph ReviewAndLanding["1. Review & Landing Flow"]
        Rev[Reviewer Lane] -->|review line| R1[Rule 1: Review Watcher]
        R1 -->|Checks: cross-vendor, PASS rx, reviewer lifetime brief, owner-go keyword scan, branch tip| R1Check{All Predicates Pass?}
        R1Check -->|Yes: PASS & Valid| GoMsg[Send GO to Author & Append to automation.log]
        R1Check -->|FAIL verdict / Moved branch / Owner-go needed / remote log / docs no-test| Esc1[Hold: Escalate to Dispatcher]
        
        Author[Author Lane] -->|Pushes to master| R2[Rule 2: Accepted Closer]
        R2 -->|Reads msg_id & sha from automation.log| R2CheckLog{Review entry found?}
        R2CheckLog -->|No| Esc2[Hold: Escalate to Dispatcher]
        R2CheckLog -->|Yes| R2Recheck[Re-verify original review msg & journal transcript]
        R2Recheck --> R2CheckBranch[Verify all commits on lane worktree branch match reviewed patch-id set]
        R2CheckBranch -->|Extra unreviewed commit landed| Esc3[Hold: Escalate to Dispatcher]
        R2CheckBranch -->|All patches match, no extras, CI green, served| AccMsg[Send ACCEPTED auto... from Dispatch Holder]
    end

    subgraph QueueAndProof["2. Queue & Owner Interaction Flow"]
        QP[Seat Placer spl-spawn-place.func.sh:584] -->|Places reviewer seat| R3[Rule 3: Review Notifier]
        R3 -->|Parses brief: decorated cells & registry| AuthNotif[Notify Authors across boxes]
        
        OwnerPoll[Owner votes on Poll] -->|Spool delivery to dispatcher| R5[Rule 5: Poll Ack Daemon]
        R5 -->|Matches ^Poll: msg-id| AckPost[Post '**In progress**: noted.' & wake topic owner]
        
        DeployVerif[Landed Change + LIVE_CHECKED + LIVE_NOT_CHECKED] -->|Empirical record| R4[Rule 4: Live Proof Builder]
        R4 -->|Validates dev/prd ancestor + shas| LiveTable[Post **Live** table to Owner]
        
        AnyPost[Outbound Desk Post] -->|Pre-post filter| R6[Rule 6: Machine Time Injection]
        R6 -->|Token expansion & Section 4 syntax| FormattedPost[Post with Exact UTC Time]
    end
```

### 2.1 Existing Infrastructure on origin/master

The codebase already contains substantial verification primitives that Rules 1–6 must leverage and compose rather than rebuild:

| Component | Path on origin/master | Existing Capabilities | Missing Automation Gap |
|---|---|---|---|
| **R7 Review Line Check** | `csi-spl-orc/src/bash/run/spl-review-line-check.func.sh` | Strictly validates format of `review: <id>@<box> <vendor> PASS <40-hex sha> ran: ... \| read: ... \| log: <id>@<box>:<path>`. Requires test names in `ran:` (`_spl_review_line_names`). Reads reviewer session transcript and proves each test named in `ran:` was executed. Returns exit 2 if log is on a remote box (never fetched locally). Exits non-zero (exit 1 syntax fail / exit 3 missing) for docs-only reviews naming no module tests. | Invoked manually by dispatcher and called by `spl-done-claim-check.func.sh`. (Pre-push and push-master run `_spl_push_master_review_why`, which checks format, 40-hex sha, and log tag, not journal commands). Does not automatically trigger on inbound review messages, nor does it check branch head immutability, reviewer lifetime brief assignments, or cross-vendor rules. |
| **Lane Served Checker** | `csi-spl-orc/src/bash/run/check-lane-served.func.sh` | Evaluates lane landing and deployment: proves commit is on trunk (`git merge-base --is-ancestor`), author/committer identity (`%ae %ce`), absence of AI trailers (`Co-Authored-By:`, `Claude-Session:`), and served status on dev and prd via `do_check_deploy_lag`. Does NOT check commit subject issue key (`SPL-XXXX`). | Standalone read-only checker. Does not verify review branch patch-id equivalence against original reviewed commits, does not check issue keys, and does not emit `ACCEPTED`. |
| **Done Claim Checker** | `csi-spl-orc/src/bash/run/spl-done-claim-check.func.sh` | Checks lane done claims against repository trunk; uses `git cherry` patch-id comparison (`git cherry -`) to verify that rebased review-branch SHAs landed on trunk. | Periodic cron audit; does not check for unreviewed extra commits landed alongside reviewed patches, and does not emit `ACCEPTED`. |
| **Trunk Push Action** | `csi-spl-orc/src/bash/run/spl-push-master.func.sh` | Detached background worker (`do_spl_push_master`). Enforces author identity, verifies R7 review line format on round rows (`_spl_push_master_review_why`), rejects unreviewed commits, handles fetch-and-rebase loops. | Does not verify semantic range-diff parity between reviewed SHA and rebased SHA after rebase conflicts. Does not emit `ACCEPTED`. |
| **Exit-Clean Gate** | `csi-spl-orc/src/bash/features/spawn-agents/scripts/kill-your-self-report.sh` | The `--gate` flag inspects `$SPOOL_ROOT/<id>/{inbox,archive}`. Performs case-sensitive prefix matching `[[ "$body" == ACCEPTED* ]]` (line 173) from an authorized sender: a role seat (`c-001..003` / `lease.conf` `LEASE_*`), the lane's spawner/reporter, or `HUM-n`. | The `ACCEPTED` message is manually authored and sent by a human or model dispatcher typing into a terminal. |
| **Desk Live Proof Validator** | `csi-spl-orc/src/bash/run/spl-desk-live-proof.func.sh` | Evaluates posts opening with `**Live**`. Enforces commit existence on `origin/master`, checks deployment lag via `_spl_served_env` on `dev` and `prd` (`git merge-base --is-ancestor <sha> <served>` per `how-to-post.md` Rule 14), and verifies presence of `checked:` and `not checked:` clauses per Rule 16. | Purely a validator/linter that rejects invalid posts. Cannot synthesize or format the Live proof markdown table from git, CI, and deployment state. |
| **Deploy Lag Checker** | `csi-spl-orc/src/bash/run/check-deploy-lag.func.sh` | `do_check_deploy_lag` queries live Cloud Run `/version` and Firebase Hosting `/build.json`. Accurately determines if a commit is served. | Queried manually by dispatchers during shift work. |
| **Unanswered Post Sweep** | `csi-spl-orc/src/bash/run/spl-unanswered-sweep.func.sh` | Sweeps active channel topics on an interval, classifying unanswered owner posts and escalating to the dispatch holder. | Standing cron sweep on interval; does not provide immediate sub-minute acknowledgment to poll answers. |
| **Seat Placer & Launcher** | `csi-spl-orc/src/bash/run/spl-spawn-place.func.sh` | `do_spl_spawn_place` reads the queue from the hub DB (`do_spl_spawn_queue`) and launches lane containers/tmux panes via `spawn-window.sh` inside `spl_spawn_place_launch` at line 584. | Does not notify target authors when their designated reviewer seat is placed and launched. |

---

## 3. The Six Core Automation Rules

### Rule 1: Automated GO After Review Approval

> **Objective**: When a designated cross-vendor reviewer approves a lane's work with `PASS`, immediately append an audit entry (`PASS <ts> <msg_id> <task_id> <author_id> <reviewer_id> <sha>`) into `$SPOOL_ROOT/dispatch/automation.log` and emit the authorization token (`GO <sha>`) to the author lane without human or model intervention, provided the code has not changed since the review, the reviewer is confirmed via `$SPOOL_ROOT/<reviewer-id>/lifetime/brief.md`, and the author brief contains no unapproved owner-go keywords.

```mermaid
sequenceDiagram
    participant R as Reviewer Lane
    participant S as Spool Inbox
    participant W as Rule 1 Watcher
    participant G as Git Remote / Local Repo
    participant L as automation.log
    participant A as Author Lane
    participant D as Dispatcher

    R->>S: Result msg: review: ... PASS <sha> ran: ... log: ...
    W->>S: Inbound review message detected
    alt Verdict != PASS (e.g. FAIL)
        W->>D: Escalate FAIL verdict to Dispatcher (no GO, no automated REJECT)
    else Verdict == PASS
        W->>W: Validate cross-vendor (§ 2.7.2)
        alt Same vendor
            W->>D: REFUSE: Reviewer shares vendor with author
        else Cross-vendor OK
            W->>W: Verify reviewer brief at $SPOOL_ROOT/<reviewer-id>/lifetime/brief.md
            alt Unplaced reviewer or author not in brief table
                W->>D: REFUSE: Reviewer unplaced or author not assigned in brief
            else Reviewer Validated
                W->>W: Scan author brief for Owner-Go keywords (apply, do-provision, do-tf-apply, PROBE_PRD_GO, DRY_RUN=0, ENV=prd, IAM, billing, service account key, /etc/)
                alt Protected keyword found without verified Owner-go token
                    W->>D: REFUSE: Requires Owner Go per SPEC-spool-fleet-roles § 1.2
                else Safe Task Scope
                    W->>W: Run do_spl_review_line_check
                    alt Remote box log / check failure / docs-only (no test in ran:)
                        W->>D: REFUSE: Log check failed, remote log, or docs-only no-test
                    else Journal Check PASS
                        W->>G: Resolve branch origin/review/<slug> (or author branch)
                        alt Branch HEAD != <sha> (Author pushed changes)
                            W->>D: REFUSE: Branch moved past reviewed commit
                        else Branch HEAD == <sha>
                            W->>L: Append: PASS <ts> <msg_id> <task_id> <author_id> <reviewer_id> <sha>
                            W->>A: spool-send --kind task --body "GO <sha>"
                            W->>D: Audit log: Automated GO sent to author
                        end
                    end
                end
            end
        end
    end
```

#### 1. Trigger
- An incoming spool message of kind `result` or `note` arrives in the dispatch holder's inbox (or dedicated review task) containing an R7 review line matching regex:  
  `^review:[[:space:]]+([acgmq]-[0-9]{3,})@([A-Za-z0-9._-]+)[[:space:]]+([a-z]+)[[:space:]]+(PASS|FAIL)[[:space:]]+([0-9a-f]{40})[[:space:]]+ran:[[:space:]]+(.*)[[:space:]]+\|[[:space:]]+read:[[:space:]]+(.*)[[:space:]]+\|[[:space:]]+log:[[:space:]]+([^[:space:]@]+)@([^[:space:]:]+):(/[^\s]+)$`

#### 2. Exact Deterministic Checks (Safe for zero intelligence)
1. **Verdict & Non-PASS Predicate**:
   - The verdict field must literally equal `PASS`.
   - **Critical**: `_spl_review_line_syntax` accepts `PASS` or `FAIL` (a `FAIL` must name at least one defect `W<n>`, else `SYNTAX FAIL`; SPL-4251), so a reviewer can write the verdict it means. If the verdict is `FAIL` (or anything other than `PASS`), the script MUST NOT execute `do_spl_review_line_check`, and MUST NOT emit a `GO` or send an automated `REJECT`/send-back. It immediately logs the failure and escalates directly to the dispatcher (judgment preserved).
2. **Cross-Vendor Verification**:
   - The reviewer's vendor (derived from reviewer ID prefix or registry record) must strictly differ from the author's vendor per `rounds-rulebook.md` § 2.7.2 (`same vendor = 0`). If author and reviewer share the same vendor, refuse and escalate to the dispatcher.
3. **Placed Reviewer Seat Verification (Resolves N5, X5, Y3)**:
   - Author briefs do not name a specific reviewer ID (they specify only requirements such as "a claude seat reviews it").
   - To strictly verify that the reviewer was legitimately placed for this specific review duty, Rule 1 reads the placed reviewer's brief directly from disk:  
     `$SPOOL_ROOT/<reviewer-id>/lifetime/brief.md`.
   - **Provenance & File Mode**: This brief copy is written by `spawn_record_brief` in `csi-spl-orc/src/bash/features/spawn-agents/scripts/spawn-core.inc.sh:398-404` (invoked during `_spawn_brief_step` in `csi-spl-orc/src/bash/features/spawn-agents/scripts/spawn-core.inc.sh:423`) with permissions mode `0664` (owned by the repo OS user, group `spool-agents`).
   - **Threat Model**: Because the brief file is mode `0664` and writable by group `spool-agents`, it provides reliable seat evidence against misconfigurations, stale sessions, and unassigned reviews, rather than cryptographic immunity against same-UID tampering. (The hub queue DB record `placed: <ID>@<box>` provides the secondary canonical placement record).
   - Rule 1 verifies that `$SPOOL_ROOT/<reviewer-id>/lifetime/brief.md` exists, is non-empty, and contains the author `<author-id>` in its target review table row (`| author | branch | sha | task |`).
   - If the file is missing or the author is not listed, REFUSE: `REFUSED: unplaced reviewer or author not assigned in reviewer brief` and escalate.
4. **Owner-Go Keyword Scan & Verification (Resolves N5, X1, Y5, Z2)**:
   - In the fleet, `spl-spawn-enqueue.func.sh:60` strictly restricts classes to `^(ci|refactor|bug|feature)$`. Real tasks that touch infrastructure, apply Terraform steps, or mutate production are classified under `bug`, `feature`, or `refactor` (measured on sat: 129 briefs mentioning `terraform apply` or `ENV=prd` belong to classes `bug`, `feature`, or `refactor`).
   - **Empirical Measurement & False Positive / False Negative Elimination (Y5, Z2)**:
     - Broad unanchored tokens like bare `prd` (matching 1,082 briefs due to "deployed dev AND prd") or bare `key` (matching 869 briefs due to "issue key") cause an unacceptable 77% false positive lockdown (1,447 of 1,888 briefs).
     - Conversely, overly narrow tokens (such as lowercase `terraform apply` alone or restricted `ENV=prd ./run`) fail open on genuine infrastructure runs—such as `c001-tf-030-gcal-env-apply.md` ("terraform step 030-cloud-run-hub APPLY, dev then prd ... OWNER GO in hand", executed via `make do-provision`), causing 6 of 32 `do-provision` briefs and 57 of 149 `ENV=prd` briefs to be missed without triggering an owner-go check.
     - Rule 1 applies a comprehensive operational filter matching both canonical provisioning commands and production environment flags:
       `(?i:apply)`, `do-provision`, `do-tf-apply`, `PROBE_PRD_GO`, `DRY_RUN=0`, `ENV=prd`, `IAM`, `billing`, `service account key`, `/etc/`.
     - **Empirical Measurements Over 1,888 Fleet Author Briefs**:
       - `case-insensitive apply`: 213 briefs
       - `do-provision`: 32 briefs
       - `do-tf-apply`: 0 briefs
       - `PROBE_PRD_GO`: 1 brief
       - `DRY_RUN=0`: 163 briefs
       - `ENV=prd`: 149 briefs
       - `IAM`: 46 briefs
       - `billing`: 17 briefs
       - `service account key`: 10 briefs
       - `/etc/`: 21 briefs
       - **Total unique matched briefs**: 463 out of 1,888 (24.5%).
       - **Miss rate on `do-provision` briefs**: 0 out of 32 (0.0% miss rate; 100% captured).
       - **Miss rate on `ENV=prd` briefs**: 0 out of 149 (0.0% miss rate; 100% captured).
     - This fails closed with 0% miss rate on all real infrastructure provisioning, apply operations, production runs, IAM/billing changes, SA key minting, and root filesystem edits, while leaving 75.5% (1,425 of 1,888 briefs) of routine bug, feature, and refactor tasks eligible for automated GO.
   - If ANY of these keywords match in the author brief:
     - The task is classified as requiring owner-go authorization.
     - Rule 1 checks if an explicit `Owner-go: <msg-id>` line exists in the author brief, and verifies that `<msg-id>` represents an authentic authorization message from human owner `HUM-<n>`.
     - **Default Refusal Invariant**: If protected keywords match and no verified `Owner-go:` line is present, Rule 1 strictly REFUSES: `REFUSED: task contains owner-go keywords without verified Owner-go token` and hands off to the dispatcher.

5. **Review Line & Journal Execution Check (Resolves Minor item)**:
   - For `PASS` lines, execute `do_spl_review_line_check REVIEW_LINE="<line>"`.
   - **Remote Log Handling**: If the reviewer's log is on another box (e.g. `<box-remote>` while check runs on `sat`), `do_spl_review_line_check` returns exit code 2 (`REFUSED the log is on box...`). Remote logs are never fetched locally. The check must either be dispatched to run on the reviewer's box or refused and escalated to the dispatcher. It must never attempt to read remote paths locally.
   - **Docs-Only Reviews with No Tests**: `do_spl_review_line_check` requires test names in `ran:` (`_spl_review_line_names`). A documentation or specification review (such as a review of `spec.md`) runs commands like `git diff` or hygiene checks without `.tst.sh` test files, returning `SYNTAX FAIL no test names found in ran:` (or exit 3 if missing). Therefore, docs-only reviews exit non-zero and automatically escalate to the dispatcher (judgment preserved). Automated `GO` applies strictly to reviews containing verified module test executions.
   - For local logs with tests, exit code must be 0 (confirming syntax, log ownership, and that all tests named in `ran:` were executed).
6. **Git Branch Immutability Check**:
   - Resolve author branch ref on `origin` (e.g. `origin/review/<slug>` or worktree branch).
   - Fetch fresh ref: `git fetch -q origin <branch>`.
   - Resolve tip commit: `git rev-parse origin/<branch>`.
   - The resolved commit SHA must exactly match the 40-hex `<sha>` from the review line.
7. **Author Liveness Check**:
   - Author lane must exist and be active in `$SPOOL_ROOT/<author-id>` or the fleet registry `$SPOOL_ROOT/registry.tsv`.
8. **Authoritative Review Record Emission (Resolves N1, X2)**:
   - Upon successful verification of all predicates 1–7, Rule 1 appends an authoritative audit entry to `$SPOOL_ROOT/dispatch/automation.log`:  
     `PASS <timestamp> <msg_id> <task_id> <author_id> <reviewer_id> <40-hex-sha>`  
   - This log entry records the exact review message ID `<msg_id>` and verified SHA consumed by Rule 2.

#### 3. Refusals & Escalations (Model/Human Judgment Preserved)
- **Verdict == `FAIL`**: The script logs `REVIEW FAIL for author <id>` and escalates to the dispatcher. It sends NO `GO` and NO automated `REJECT`.
- **Same-Vendor Review**: Refuses auto-GO (`REFUSED: reviewer shares vendor with author`). Escalates to dispatcher.
- **Unassigned or Unplaced Reviewer (X5)**: Refuses auto-GO (`REFUSED: unplaced reviewer or author not assigned in brief`). Escalates to dispatcher.
- **Owner-Go Keyword Match Lacking Token (X1)**: Refuses auto-GO (`REFUSED: task touches protected scope without Owner-go token`). Hands off to dispatcher.
- **Branch Head Divergence**: If `git rev-parse origin/<branch>` != `<sha>`, author pushed additional commits during/after review. Script logs `REFUSED: branch moved past reviewed sha` and halts. Re-review is mandatory.
- **Journal Check Failure, Remote Log, or Docs-Only No-Test**: If `do_spl_review_line_check` exits non-zero, refuse auto-GO and alert dispatcher.

#### 4. Execution Location & Cron Installation (Resolves N10, X6)
- Named action `do_spl_review_go` in `csi-spl-orc/src/bash/run/spl-review-go.func.sh`, executed on a 60-second cron on the active dispatch box or invoked upon spool inbox review results.
- **Cron Installation**: Installed by `csi-spl-orc/src/bash/run/spl-review-go-install-cron.func.sh` under the OS user configured by `env.box.box_agent_user` (defined in `csi-spl-cnf/csi-spl/prd.env.yaml:242` and `prd.env.json:316`).
- The action queries `do_spl_dispatch_lease show` (read-only); if the local machine does not hold the dispatch lease, it exits 0 immediately without mutating state. Does NOT modify or touch `spl-dispatch-lease*`.

#### 5. Test Plan & Red Controls
- **Test File**: `csi-spl-orc/src/bash/tests/spl-review-go.tst.sh`
- **Red Controls**:
  1. *FAIL verdict*: Feed review message with `FAIL` -> script exits 1, asserts no `GO` emitted, asserts no `REJECT` emitted, asserts escalation logged.
  2. *Same vendor*: Feed review line where author and reviewer are both `claude` -> script exits 2, asserts no `GO` emitted, logs `REFUSED: same vendor`.
  3. *Unassigned reviewer (X5)*: Feed review line where author is not listed in reviewer brief table -> script exits 3, asserts no `GO` emitted, logs `REFUSED: unassigned reviewer`.
  4. *Owner-go keyword without token (Resolves X1, Y5, Z2)*: Feed review for brief matching `c001-tf-030-gcal-env-apply.md` (`APPLY`, `do-provision`, `ENV=prd`) lacking `Owner-go:` line -> script exits 4, asserts no `GO` emitted, logs `REFUSED: task touches owner-go scope`.
  5. *Branch head moved*: Branch ref points to commit different from `<sha>` -> script exits 5, asserts no `GO` emitted, logs `REFUSED: branch moved`.
  6. *Remote box log*: Reviewer log path on remote box -> script exits 6, asserts no local file read attempted, logs remote execution requirement.
- **Green Pass**: Valid cross-vendor `PASS` from assigned reviewer on immutable branch with verified journal and no unapproved owner-go keywords -> script exits 0, writes `PASS ... <sha>` to `automation.log`, and executes `spool-send.sh --kind task --body "GO <sha>"`.

#### 6. As built (row B4, SPL-4101)
- **Where the review is read**: the dispatch holder's spool `$SPOOL_ROOT/<holder>/{inbox,archive}` (reviewer briefs say "send to the author, cc the dispatch lease holder"), messages of kind `result` or `note` newer than `REVIEW_GO_MAX_AGE` (60 min), whose `from` (bare id) is the reviewer the `review:` line names. A relayed or quoted copy from anyone else is not read. `REVIEW_GO_MSG=<file>` checks one message and returns its exit code.
- **The author** is not in the review message: it is the `author` cell of the reviewer's `$SPOOL_ROOT/<reviewer>/lifetime/brief.md` table row (`| author | review branch | sha | ... | task |` and its variants) whose sha / head / commits cell abbreviates the reviewed sha, else whose task cell is the message's task. The same row gives the branch and the task the GO is sent on.
- **A retired reviewer, a prose brief** (measured on sat 2026-10-28, n=61 review messages in 12 h: the table-only reader planned 0 GO, 47 rc 3): a retired seat's `lifetime/` dir is gone, so the brief is `dispatch/briefs/<slug>.md`, the slug being the `title` of its live `agents/<id>.json` or its newest `agents/retired/<id>.<spawned>.json`. Placement briefs name the author in prose (`Author c-805@<box> (claude)`, `Branch `review/<slug>``): with no table row, the brief must name exactly one author and hold an abbreviation of the reviewed sha or the message's task (ids are reused across boxes and over time: a brief naming neither is another seat's, rc 3). An author on another box has no `lifetime/` brief here: the reviewer brief's `Author brief: $SPOOL_ROOT/dispatch/briefs/<slug>.md` line is read instead (no other path), else rc 7. The same 61 messages then planned 2 GO (both reviewed PASS lanes whose brief has that line), 17 rc 7 (an author on another box, no `Author brief:` line), 24 rc 3 (reviewers on another box, ids reused).
- **A FAIL is a FAIL wherever it is written** (SPL-4251): until the line check took `FAIL` in the header, g-161 had to send `grok PASS <sha> ... read: JUDGMENT FAIL W1 ...` (msg 95d5ed90, spec 155 B5). A `PASS` header whose `read:` says FAIL as a verdict (`JUDGMENT|VERDICT|OVERALL|REVIEW FAIL`, or `FAIL W<n>`) is rc 1 like a `FAIL` header. A count is no verdict: measured on one box over 242 `PASS` lines since 2026-10-22, the bare word `FAIL` outside a count was in 36 (red controls), the verdict form in 1: g-161's message of 2026-10-29T01:04:50Z (that box's copy: msg 37b6d545).
- **Every required review seat, then one GO** (SPL-4251): a web UI row with new locale strings is placed with two reviewers for the same sha, the cross-vendor code R7 and an agy review of the strings (fleet language rule: agy has the final word on multilingual text), e.g. `c002-s155-b5-grok-reviewer.md` and `c002-s155-b5-agy-strings.md`, both naming `Author c-049@<box>` and branch `review/s155-b5-wui-shell` at `cf7ac03c1271...`. A verified PASS therefore sends the GO only when no other review seat waits: every other `dispatch/briefs/<slug>.md` (not the reviewer's own by slug or content) whose row, matched by the reviewed sha only, names the same author must already have its verified PASS recorded as `WAIT <ts> <msg_id> <task_id> <author_id> <reviewer_id> <sha> <slug>`. While one has none, this PASS is written as such a WAIT line (rc 10; the message is then seen, the holder told once) and the last seat's PASS sends the one GO and the one `PASS` record (Rule 2 reads only `PASS` rows). A seat placed or queued counts as soon as its brief is in `dispatch/briefs`. It fails closed: a sibling seat that never sends a PASS checkable on this box (its log on another box: rc 6; a seat replaced by a new one of another slug) keeps the GO with the dispatcher, whose hold note names the waiting slugs. A re-review of a new sha needs briefs naming the new sha.
- **A reviewer on another box** (the `PLAN HOLD msg a148700d (rc 3)` of a reviewer on box B seen from the holder's box A): intended, holder box only. Its identity record and lifetime brief are on its own box, and even with the brief found its session log is there too, so the journal check is rc 6 (never fetched). Such a review stays with the dispatcher.
- **Exit codes**: 1 not PASS (or no R7 line, or a `read:` that says FAIL), 2 same vendor, 3 unplaced reviewer or author not in the brief, 4 owner-go keyword without a verified `Owner-go:`, 5 branch moved, 6 log on another box, plus 7 (the author's brief is not on this box: the keyword scan cannot run, fails closed), 8 (`do_spl_review_line_check` failed: a docs-only `ran:`, a test the log never ran), 9 (the GO send failed: nothing logged, retried next run) and 10 (verified, but another review seat for the same author and sha has no PASS yet: WAIT, no GO).
- **Branch immutability** reads `git ls-remote origin refs/heads/<branch>` (read only) instead of a fetch, so the shared checkout's refs are never moved.
- **The record** (what Rule 2 reads): `PASS <ts> <msg_id> <task_id> <author_id> <reviewer_id> <sha>`, bare ids, `task_id` = the review message's own. A refusal is logged as `<ts> review-go <msg_id> action=refused rc=<n> ...` and told to the holder once (spool note, task `review-go`); a message already in the log is never checked again.
- **`Owner-go:`** is verified by a message with that id from `HUM-<n>` in the holder's spool or its desk spools under the running user's state dir. Run as `box_agent_user`, the desk spools are usually not readable, so a brief with an owner-go keyword is in practice refused and handed to the dispatcher (fails closed).
- **Cron**: `do_spl_review_go_install_cron` (tag `<org>-<app>:review-go`, every minute, flock), installed as `box_agent_user`; its live install waits for the dispatch holder's go.

---

## Rule 2: Automated ACCEPTED After Landing Verification

> **Objective**: When an author lane lands changes on `origin/master`, compose `do_check_lane_served` and `do_spl_done_claim_check` to re-verify the original review message from `automation.log`, verify that every commit on the author's worktree branch matches a patch-id in the reviewed set (with zero extra unreviewed commits), verify that no logic was altered during rebase, that CI is completely green, and that the change is actively served on dev and prd. Upon passing, emit `ACCEPTED (auto, spec 157 rule 2, automation.log <id>): on master <sha>` from the active dispatch role seat, enabling `/exit-clean`.

```mermaid
flowchart TD
    Start[Author reports Landing or Lease Tick] --> ReadLog[1. Read automation.log for author & task_id]
    ReadLog --> CheckLog{PASS entry found in automation.log?}
    CheckLog -->|No: Unreviewed row or bypass| RefuseLog[REFUSE: No verified PASS in automation.log - Dispatcher Review]
    CheckLog -->|Yes: Extract msg_id & sha| Reverify[2. Re-verify review msg & reviewer journal transcript]
    Reverify -->|Journal check fails| RefuseJournal[REFUSE: Journal re-verification failed - Tamper Alert]
    Reverify -->|Journal PASS| GetBranch[3. Read lane worktree branch from registry.tsv col 4]
    GetBranch --> CheckExtras{Any commit on lane branch NOT in reviewed patch-id set?}
    CheckExtras -->|Yes: Extra unreviewed commit landed| RefuseExtra[REFUSE: Unreviewed extra commit landed - Dispatcher Review]
    CheckExtras -->|No: All branch commits in reviewed set| DoneClaim[4. Compose do_spl_done_claim_check: git cherry patch-id]
    DoneClaim --> PatchMatch{All reviewed patches on origin/master?}
    PatchMatch -->|No: Missing patch or empty commit| RefusePatch[REFUSE: Incomplete landing or empty commit]
    PatchMatch -->|Yes| RangeDiff[5. Check git range-diff vs reviewed commits]
    RangeDiff --> HunkCheck{Any code hunk modified during rebase?}
    HunkCheck -->|Yes: Modified logic| RefuseHunk[REFUSE: Rebase conflict altered logic - Dispatcher Review]
    HunkCheck -->|No: Clean rebase| LaneServed[6. Compose do_check_lane_served]
    LaneServed --> ServedCheck{Landed, Identity %ae %ce, No AI Trailers, Served dev+prd?}
    ServedCheck -->|Lagging| DeferDeploy[DEFER: Wait next tick for deploy propagation]
    ServedCheck -->|Failed| RefuseServed[REFUSE: Identity / Trailer / Trunk failure]
    ServedCheck -->|PASS| KeyCheck[7. Check SPL-XXXX key in commit subject or Closes trailer]
    KeyCheck -->|Missing Key| RefuseKey[REFUSE: Missing tracked issue key]
    KeyCheck -->|Valid Key| CICheck[8. Verify gh run list --commit SHA: success or skipped]
    CICheck -->|Pending / Cancelled| DeferCI[DEFER / Escalate after 3 ticks if cancelled]
    CICheck -->|Failed| RefuseCI[REFUSE: CI Red - Lane must fix]
    CICheck -->|All Green / Skipped| SendAcc[9. Send ACCEPTED auto... from active dispatch role seat]
```

#### 1. Trigger
- Author lane sends result message on task `dispatch-<slug>` citing landed SHA, or periodic dispatch cron execution (`spl-accepted-close.func.sh`).

#### 2. Exact Deterministic Checks (Safe for zero intelligence)
1. **Authoritative Reviewed Commit Resolution (Resolves N1, X2)**:
   - Do NOT attempt to read reviewed SHAs from the author lane's brief (author briefs name only `review/<slug>` branches, not 40-hex SHAs, and branch tips can move after review; briefs may also cite other lanes' foreign branches).
   - Rule 2 reads the verified entry from `$SPOOL_ROOT/dispatch/automation.log` for that `<task_id>` / `<author_id>` to extract `<msg_id>` and `<sha>`.
   - **Invariable Refusal**: If no `PASS` entry exists in `automation.log` for that task/author, automated acceptance is strictly REFUSED: `REFUSED: no verified PASS record in automation.log`. Judgment remains with the dispatcher.
2. **Journal Re-Verification & Threat Model (Resolves X2, Y2, Minor)**:
   - Because `automation.log` is located in `$SPOOL_ROOT/dispatch/` (group-writable by `spool-agents`), Rule 2 treats `automation.log` as a pointer rather than an unverified truth source.
   - Rule 2 locates the original review message `<msg_id>` in `$SPOOL_ROOT/<dispatch-holder>/archive/` (or inbox).
   - **Strict Field Equality (Y2)**: Rule 2 strictly verifies that every field in `automation.log` (`task_id`, `author_id`, `reviewer_id`, and `sha`) exactly matches the corresponding field in the archived review message. If any field mismatches, execution immediately halts with `REFUSED: journal transcript re-verification failed`.
   - Rule 2 re-executes `do_spl_review_line_check` against that review message, verifying the reviewer's private session transcript.
   - **Honest Threat Model & Residual Risk (Y2, Minor)**:
     - On the local box, all agent processes (across both Claude and Agy seats) execute under the single shared OS user configured by `env.box.box_agent_user`. The mode-700 transcript directories are owned by that shared agent user, and `$SPOOL_ROOT` is mode 2770 in group `spool-agents` (unsigned and group-writable). Similarly, push status and `pushes.log` are writable by group `spool-agents`.
     - Therefore, this re-verification mechanism does NOT claim tamper-proof security against an active adversarial same-UID agent that deliberately crafts both a forged spool message and a forged journal transcript (the `m-857` class of agent failure).
     - Instead, re-verification provides robust deterministic protection against:
       (a) accidental file corruption, truncation, or write collisions in `automation.log` and push records;
       (b) stale or orphaned log entries left over from prior sessions;
       (c) bogus log injections where no reviewer session or journal ever existed.
     - **Residual Risk Retention**: To guard against same-UID forgery, residual risk remains explicitly with the human dispatcher: every automated `ACCEPTED` emits an audit notification note to the dispatch holder containing `<msg_id>`, `<task_id>`, `<author_id>`, `<reviewer_id>`, and `<sha>` for dispatcher oversight.
     - Note: Whether the central spool hub server enforces an authenticated sender identity for cross-box relayed review messages is **not checked** by this spec.
3. **Anti-Extra Guard Across All Pushed Commit Ranges (Resolves N2, X3, Y1, Z1, Z3)**:
   - **The Post-Land Invalidation Problem (Y1)**: Evaluating `git rev-list $(git merge-base origin/master <branch>)..<branch>` after landing is vacuous: once the lane has landed and pushed, `<branch>` HEAD is on `origin/master`, so the merge-base is HEAD itself and the commit list evaluates to empty (0 commits), allowing unreviewed extra commits pushed on top of trunk to slip past unnoticed.
   - **The Single-Status Overwrite Vulnerability (Z1)**: Lane seeds instruct agents to push continuously ("every commit at once, never more than ONE unpushed"). Because `_spl_push_master_end` overwrites `$PUSH_STATE/status` with `mv -f` on each push, relying on a single status file captures only the final push. If an unreviewed commit was pushed in push 1 and the reviewed commit in push 2, checking only the final push status completely misses the unreviewed commit in push 1, erroneously sending `ACCEPTED`.
   - **Push-Time Append-Only Range Logging (Z1, Z3)**:
     - To capture all pushes, Build Row B5 will enhance `do_spl_push_master` (`csi-spl-orc/src/bash/run/spl-push-master.func.sh`):
       - Before the push attempt at line 313, it captures the pre-push remote trunk tip:  
         `pushed_base="$(git rev-parse "$remote/$branch")"`
       - Upon successful push verification, `_spl_push_master_end` (lines 180–188) appends an entry to an append-only log file:  
         `$PUSH_STATE/pushes.log` (and `$SPOOL_ROOT/<author-id>/lifetime/push-master/pushes.log`):  
         `<iso-timestamp> <pushed_base>..<landed-sha>`
   - In addition, to locate the lane worktree, Rule 2 queries `$SPOOL_ROOT/registry.tsv` (column 4: worktree path; note that column 3 is the tmux pane, and there is no dedicated branch column). The active branch is read via `git -C <col 4> rev-parse --abbrev-ref HEAD`.
   - **Cumulative Range Enumeration & Patch-ID Guard (Z1)**:
     - Rule 2 reads all pushed ranges recorded in `pushes.log` for the lane's active task lifetime.
     - For each recorded range `$pushed_base..$landed-sha`, Rule 2 enumerates every pushed commit:  
       `git rev-list "$pushed_base..$landed-sha"`
     - Rule 2 aggregates the full set of commits landed across all pushes by the lane.
     - Every single commit in this aggregated sequence MUST have its patch-id match a commit in the verified reviewed set resolved from `automation.log`. If any unreviewed commit exists across any of the lane's pushes (e.g. an unreviewed fixup in push 1 or push 2, even if it lacks an issue key), Rule 2 strictly REFUSES:  
       `REFUSED: unreviewed extra commit landed on master (<extra-sha>)`  
       and escalates to the dispatcher.
   - **Cherry Patch-ID Verification (`do_spl_done_claim_check`)**:
     - Run `git cherry origin/master <review-sha>`: must return `-` for every reviewed commit (proving that the exact patch-id is on trunk).
     - **Multi-Commit Coverage**: For multi-commit branches, every individual reviewed commit patch must be present on master. A partial landing (e.g. landing 1 of 3 commits) is REFUSED.
     - **Anti-Empty Guard**: Verify that the landed commit contains non-zero additions/deletions matching the touched deliverables (guarding against `m-689`'s empty commit and `T008`'s tasks.md-only tick).
4. **Semantic Parity via Range-Diff**:
   - Run `git range-diff <reviewed-sha>^..<reviewed-sha> <landed-sha>^..<landed-sha>` across each landed commit.
   - Diff hunks must contain zero substantive code changes (only commit SHAs and line offset numbers may vary).
5. **Lane Served Verification (`do_check_lane_served`)**:
   - Execute `do_check_lane_served SHA=<landed-sha> BASE=<parent>`:
     - *Trunk ancestry*: Verifies `git merge-base --is-ancestor <landed-sha> origin/master`.
     - *Committer identity*: Verifies `%ae %ce` match `LANE_EMAIL` (the canonical committer email per `developer-guide.md` § 2.9).
     - *Trailers*: Verifies absence of forbidden AI trailers (`Co-Authored-By:`, `Claude-Session:`).
     - *Served status*: Verifies `dev=served prd=served` via `do_check_deploy_lag` (or `dev=n/a prd=n/a` for docs/orc).
6. **Issue Key Verification (Resolves N6)**:
   - `do_check_lane_served` does NOT check the issue key.
   - Rule 2 (new code in B5) explicitly verifies that the commit subject cites `SPL-XXXX` or contains `Closes: SPL-XXXX` in the commit body. If missing, refuse acceptance.
7. **CI Quality Gate & Cancellation Handling (Resolves Minor items)**:
   - Query `gh run list --commit <landed-sha> --json name,status,conclusion`.
   - Every relevant workflow must have `status: "completed"`.
   - Workflow conclusions must be `success` or `skipped` (where `skipped` represents workflows not triggered by the commit's touched file paths).
   - If any workflow reports `failure`, REFUSE.
   - If any workflow is `in_progress` or `queued`, DEFER to the next tick.
   - If any workflow is `cancelled` (e.g. superseded deploy), DEFER for up to 3 ticks (3 minutes); if still cancelled with no newer succeeding workflow on trunk, escalate to the dispatcher (`HOLD: CI workflow cancelled`).

#### 3. Sender Identity & Message Body Architecture (Resolves N3, X4)
- **Honest Automated Attribution**:
  To prevent the `m-857` forged-ACCEPTED shape (where a script speaks in the persona of `c-002`), the emitted message body MUST explicitly state its automated origin:  
  `ACCEPTED (auto, spec 157 rule 2, automation.log <id>): on master <sha>`
- The exit-clean gate in `kill-your-self-report.sh` line 173 performs case-sensitive prefix matching `[[ "$body" == ACCEPTED* ]]`, so `ACCEPTED (auto...)` passes the gate cleanly.
- Both human dispatchers and automated audit scans can immediately distinguish automated acceptances from model-judged acceptances.
- **Process Architecture (Resolves N3, N10, X6)**:
  Rule 2 runs under the OS user configured by `env.box.box_agent_user` via named action `do_spl_accepted_close` in `csi-spl-orc/src/bash/run/spl-accepted-close.func.sh`, executed on a 60-second cron on the box holding the dispatch lease.
  It queries `do_spl_dispatch_lease show` (read-only); if this box does not hold the dispatch lease, it exits cleanly.
  It emits messages using `--from "$DISPATCH_HOLDER"`, operating within the authority of the active dispatch lease. It does NOT modify `kill-your-self-report.sh` or `spl-dispatch-lease*`.

#### 4. Refusals & Escalations (Model/Human Judgment Preserved)
- **No Reviewed Record**: If row lacks a verified `PASS` in `automation.log`, log `REFUSED: no verified PASS in automation.log` and escalate.
- **Journal Re-verification Failure (Resolves X2, Y2)**: If transcript check fails, or if any field (task_id, author_id, reviewer_id, sha) in automation.log does not strictly match the corresponding field in the archived review message, log `REFUSED: journal transcript re-verification failed` and escalate.
- **Unreviewed Extra Commit in Pushed Range (Resolves N2, X3, Y1)**: If the pushed commit range recorded by `spl-push-master` contains commits not present in the reviewed patch-id set, log `REFUSED: unreviewed extra commit landed on master (<sha>)` and escalate.
- **Substantive Rebase Conflict Resolution**: If `git range-diff` reveals modified code hunks, log `REFUSED: rebase altered code logic` and escalate.
- **Partial or Incomplete Landing**: If any reviewed patch is missing from master, or the commit is empty, log `REFUSED: incomplete landing` and escalate.
- **CI Failure / Persistent Cancellation**: If CI reports `failure`, emit an alert; lane cannot exit until fixed. If `cancelled` persists past 3 ticks, escalate.
- **Deploy Lag**: Defer execution to next tick.

#### 5. Execution Location & Cron Installation (Resolves N10, X6)
- Named action `do_spl_accepted_close` in `csi-spl-orc/src/bash/run/spl-accepted-close.func.sh`, executed on a 60-second cron on the active dispatch box.
- **Cron Installation**: Installed by `csi-spl-orc/src/bash/run/spl-accepted-close-install-cron.func.sh` under `env.box.box_agent_user`. Queries `do_spl_dispatch_lease show` (read-only); does NOT touch `spl-dispatch-lease*`.

#### 6. Test Plan & Red Controls
- **Test File**: `csi-spl-orc/src/bash/tests/spl-accepted-close.tst.sh`
- **Red Controls**:
  1. *Empty commit*: Fabricate landed commit with no file changes -> script exits 1, asserts no `ACCEPTED` emitted, logs refusal.
  2. *Partial landing*: 2-commit review branch where only 1 commit landed -> script exits 2, asserts no `ACCEPTED` emitted, logs missing patch.
  3. *Unreviewed extra commit across multiple pushes (Resolves N2, X3, Y1, Z1)*: In a test fixture with a bare origin and clone, lane executes `do_spl_push_master` twice: push 1 pushes commit A ("unreviewed fixup"), push 2 pushes commit B ("reviewed PASS commit"), appending both ranges to `pushes.log`. Rule 2 runs after the second real push, evaluates all ranges in `pushes.log`, detects commit A lacking review verification in `automation.log`, exits 3, asserts no `ACCEPTED` emitted, and logs `REFUSED: unreviewed extra commit landed on master`.
  4. *Forged log entry (Resolves X2)*: Append fake PASS line to `automation.log` without valid reviewer journal transcript -> script exits 4, asserts no `ACCEPTED` emitted, logs journal failure.
  5. *Rebase logic change*: Range-diff detects altered code hunk -> script exits 5, asserts no `ACCEPTED` emitted, logs hunk mismatch.
  6. *Unreviewed row (Resolves N1)*: No `PASS` entry in `automation.log` -> script exits 6, asserts no `ACCEPTED` emitted, logs unreviewed row.
  7. *CI red*: Workflow failed -> script exits 7, asserts no `ACCEPTED` emitted.
- **Green Pass**: All landed commits on branch match reviewed set in `automation.log`, journal re-verified, `do_check_lane_served` PASS, green/skipped CI -> script exits 0, executes `spool-send.sh --from "$DISPATCH_HOLDER" --to <lane> --kind result --body "ACCEPTED (auto, spec 157 rule 2, automation.log <id>): on master <sha>"`.

#### 7. As built (row B5, SPL-4102)
- `do_spl_accepted_close` (`csi-spl-orc/src/bash/run/spl-accepted-close.func.sh`), cron `do_spl_accepted_close_install_cron`; test `csi-spl-orc/src/bash/tests/spl-accepted-close.tst.sh`.
- `do_spl_push_master` appends `<iso-ts> <pushed_base>..<landed-sha>` to `<state>/pushes.log` on every `PUSHED` (the state dir is `$SPOOL_ROOT/<id>/lifetime/push-master` for a lane).
- **The reviewed set** is the reviewed sha back to the first pushed base, minus the landed sha of every push older than the PASS row's timestamp. Without that cut, a fixup pushed before the review and sitting under the reviewed tip would count as reviewed (red control 3 with the review built on top of push 1).
- **Pairing**: a landed commit matches a reviewed one by stable patch-id (`spl_done_claim_patch_id`). Otherwise it pairs by the same subject, and `git range-diff --creation-factor=100` decides: a changed inner `+`/`-` line outside `Metadata` / `Commit message` is exit 5, and a context or line-offset change passes. A landed commit that neither matches nor pairs is exit 3. A reviewed commit that `git cherry` does not find and nothing pairs with is exit 2.
- **The author** is re-derived with row B4's `_spl_review_go_row` on the reviewer's `lifetime/brief.md`. While B4 is not loaded, that check fails closed (exit 4).
- **Exit codes beyond section 6**: 8 = DEFER (not landed yet, a fetch failed, deploy lag, CI queued, running or not started, or a cancelled run inside the 3 ticks). 9 = a refusal with no number in section 6: an issue key is missing, `do_check_lane_served` FAILs, there is no lane worktree, the reviewed sha is unknown, or `HOLD: CI workflow cancelled`. A cancelled run passes when a newer successful master run of the same workflow contains the sha.
- A refusal is logged as `<ts> accepted-close <msg> action=refused rc=<n> ...` and sent to the holder once per message and code. It is judged again on every run, so a lane that fixes the cause is accepted later.
- **Known limit (box-local)**: `pushes.log`, `registry.tsv` and the lane worktrees live on the lane's own box, and the action runs only on the box holding the dispatch lease. So only lanes on that box are judged. A lane on another box gets no automatic ACCEPTED (it fails closed: no worktree, exit 9), and its ACCEPTED stays with the dispatcher.

---

## Rule 3: Automated Reviewer Notification to Author Lanes

> **Objective**: When the seat placer spawns and launches a reviewer seat, immediately and deterministically parse the reviewer brief and notify every referenced author lane across boxes, eliminating author idle time and dispatcher manual lookups.

#### 1. Trigger (Resolves N4, X4)
- The seat placer in `csi-spl-orc/src/bash/run/spl-spawn-place.func.sh` inside `spl_spawn_place_launch` at line 584 (`spawn-window.sh`) successfully places and starts a reviewer seat (`*-reviewer*`, `*-review`, or class `review`).

#### 2. Exact Deterministic Checks (Safe for zero intelligence)
1. **Brief Parsing**: Read the placed seat's brief file at `/var/spool-hub/dispatch/briefs/<slug>.md`.
2. **Robust Author Extraction**:
   - Scan for table rows matching markdown table syntax with decorated author cells:  
     `\|[[:space:]]*([acgmq]-[0-9]{3,})(@[A-Za-z0-9._-]+)?([[:space:]]*\([^)]+\))?[[:space:]]*\|`  
     (Correctly handles cells such as `| a-213@sat (agy) | ... |` and handles 3+ digit IDs).
   - Scan for explicit author headers:  
     `^Author:[[:space:]]*([acgmq]-[0-9]{3,})(@[A-Za-z0-9._-]+)?`
   - Extract `<author-id>` and optional `<box>`.
   - **As built (B6, SPL-4109)**: the author header is matched as a phrase, any case, colon optional, anywhere on a line (`Author: c-372@boxa`, `Author c-372@boxa.`, `(author c-418, vendor claude)`). Measured 2026-10-28 over the 352 `dispatch/briefs/*-reviewer.md` briefs on one box: the line-start `^Author:` form matched 0, the phrase form 130, the cell form 12. Role seats and the reviewer itself are left out. An author on this box counts as live when `registry.tsv` has a row for it that has not ended, or its spool dir exists (ids are reused, so an old retired row does not make a live id retired). An author on another box is sent through the relay, which refuses an id that box does not know. Action: `do_spl_spawn_review_notify` (`csi-spl-orc/src/bash/run/spl-spawn-review-notify.func.sh`); the placer's hook is `spl_review_notify_placed`. A failed send exits 1, and the placer goes on.
3. **Cross-Box Author Existence & Routing (Resolves N9, X4)**:
   - Check author lane existence via local `$SPOOL_ROOT/<author-id>` or fleet registry `$SPOOL_ROOT/registry.tsv` (and `$SPOOL_ROOT/registry.retired.tsv`).
   - (Note: `lane-map.sh --check` takes file path arguments, not agent IDs).
   - Route to the destination box `<box>` extracted directly from the reviewer brief cell (e.g. `a-213@sat` routes to `sat`, `c-168@<box-remote>` routes to `<box-remote>` via `spool-send.sh --to <id>@<box>`).

#### 3. Refusals & Escalations
- **Brief Lacks Author Identifiers**: If brief contains no extractable author IDs, log a warning to `dispatch/queue.log` and notify the dispatcher.
- **Retired Author (X4)**: If the extracted author lane has already retired in `$SPOOL_ROOT/registry.retired.tsv`, skip messaging that lane and log `SKIP: author <id> already retired`.

#### 4. Execution Location & Dependency (Resolves N4, X4)
- Post-spawn hook in `csi-spl-orc/src/bash/run/spl-spawn-place.func.sh`, invoked inside `spl_spawn_place_launch` immediately after successful seat launch at line 584 (`spawn-window.sh`).
- **Ordering Dependency**: Because `spl-spawn-place.func.sh` is touched by queued bug row `c002-bug-placer-brief-other-box` and `c-187`'s open change, Rule 3 (Row B6) touches `spl-spawn-place.func.sh` and **MUST be ordered AFTER `c002-bug-placer-brief-other-box`**.

#### 5. Test Plan & Red Controls
- **Test File**: `csi-spl-orc/src/bash/tests/spl-spawn-review-notify.tst.sh`
- **Red Controls**:
  1. *Malformed brief*: Brief with no author IDs -> hook logs warning, exits 1, sends 0 spool messages.
  2. *Decorated cell verification*: Brief with `| a-213@sat (agy) |` must NOT fail to match (red control asserts author `a-213` is successfully extracted).
  3. *Retired author (X4)*: Author marked retired in `registry.retired.tsv` -> hook skips send, logs skip notice.
- **Green Pass**: Reviewer brief referencing authors `a-213@sat` and `c-168@<box-remote>` -> hook exits 0, sends notifications to both lanes with reviewer ID and review branch.

---

## Rule 4: Automated Live Proof Table Generation for Owner Posts

> **Objective**: Programmatically construct the complete Markdown `**Live**` proof table adhering strictly to `how-to-post.md` Rule 14 (served ancestor check) and Rule 16 (`checked:` and `not checked:` must name measured test cases), eliminating manual markdown construction and post gate rejections.

```mermaid
flowchart LR
    Inputs[SHA + LIVE_CHECKED + LIVE_NOT_CHECKED] --> ValInput{LIVE_CHECKED & LIVE_NOT_CHECKED provided?}
    ValInput -->|No: Either missing or empty| RefuseCases[REFUSE: how-to-post.md Rule 16 requires measured cases]
    ValInput -->|Yes| GitCheck[1. Check Trunk Ancestry on origin/master]
    GitCheck --> DeployProbe[2. Probe Cloud Run & Firebase Hosting via _spl_served_env]
    DeployProbe --> CIProbe[3. Probe GitHub Actions Workflows]
    CIProbe --> FormatTable[4. Render Markdown Table with checked: and not checked:]
```

#### 1. Trigger (Resolves N7)
- Invoked via named action:  
  `./run -a do_spl_desk_live_proof_render SHA=<sha> LIVE_CHECKED="<measured cases>" LIVE_NOT_CHECKED="<not checked cases>"`

#### 2. Exact Deterministic Checks (Safe for zero intelligence)
1. **Mandatory Measured Cases Inputs (Resolves N7)**:
   - Per `how-to-post.md` Rule 16, `checked:` and `not checked:` MUST explicitly state the measured test and verification cases (the owner's *"every card"* requirement, SPL-2122).
   - Both `LIVE_CHECKED` and `LIVE_NOT_CHECKED` are **mandatory**. If either parameter is omitted or empty, the action REFUSES to generate a `**Live**` post:  
     `FATAL: LIVE_CHECKED and LIVE_NOT_CHECKED are required by how-to-post.md Rule 16 (pass literal 'none' to LIVE_NOT_CHECKED if all checked)`.
   - Defaulting `not checked:` to `none` without explicit caller input is strictly forbidden.
2. **Trunk Ancestry Check**:
   - Execute `git merge-base --is-ancestor <sha> origin/master`. Must return exit code 0.
3. **Component Touchpoints**:
   - Inspect files modified by `<sha>` via `git diff-tree --no-commit-id --name-only -r <sha>` to identify relevant targets (`hub`, `wui`, `iac`, `orc`, `doc`).
4. **Served Status Probing (`how-to-post.md` Rule 14)**:
   - Probe dev and prd using `_spl_served_env`.
   - **Crucial Rule 14 Implementation**: Served status requires that the commit served on Cloud Run (`/version`) and Firebase Hosting (`/build.json`) contains `<sha>` via `git merge-base --is-ancestor <sha> <served>` (not string equality).
5. **CI Status Probing**:
   - Validate workflow conclusions via `gh run list --commit <sha>`.
6. **Table Synthesis**:
   Assemble standard markdown table:
   ```markdown
   | target | commit / version | dev | prd | CI |
   |---|---|---|---|---|
   | hub | <short-sha> (`<version>`) | served | served | green |
   | wui | <short-sha> (`<version>`) | served | served | green |

   checked: <LIVE_CHECKED>
   not checked: <LIVE_NOT_CHECKED>
   ```

#### 3. Refusals & Escalations (Resolves N7)
- **Missing `LIVE_CHECKED` or `LIVE_NOT_CHECKED`**: Action halts with exit code 1 (`REFUSED: LIVE_CHECKED and LIVE_NOT_CHECKED required`).
- **Commit Not on Trunk**: If `<sha>` is not an ancestor of `origin/master`, halts with exit code 2.
- **Deploy Incomplete**: If deployment is lagging, formats table header as `**Landed, not live yet**` rather than `**Live**`, preventing `spl_desk_live_proof` FATAL errors.

#### 4. Execution Location
- Named action `do_spl_desk_live_proof_render` in `csi-spl-orc/src/bash/run/spl-desk-live-proof-render.func.sh`.

#### 5. Test Plan & Red Controls (Resolves N7)
- **Test File**: `csi-spl-orc/src/bash/tests/spl-desk-live-proof-render.tst.sh`
- **Red Controls**:
  1. *Omitted `LIVE_CHECKED`*: Action exits 1, asserts refusal, no table rendered.
  2. *Omitted `LIVE_NOT_CHECKED` (Resolves N7)*: Action exits 1, asserts refusal, no table rendered.
  3. *Unlanded SHA*: Action exits 2, logs `REFUSED: not on master`.
  4. *Lagging deploy*: Action renders `**Landed, not live yet**` and marks lagging environment.
- **Green Pass**: Deployed SHA with valid `LIVE_CHECKED` and `LIVE_NOT_CHECKED` -> action renders table, passes `spl_desk_live_proof` with exit code 0.

---

## Rule 5: Automated Acknowledgement of Owner Poll Answers

> **Objective**: Instantly reply to owner poll submissions with an immediate confirmation post ("**In progress**: noted."), assuring the human owner their input is received while dispatch logic is engaged.

#### 1. Trigger (Resolves N8, Minor item)
- An inbound spool message in the active dispatch holder's inbox (delivered from the hub via the desk delivery loop to `$SPOOL_ROOT/<id>/inbox/`) matching the WUI poll reply format. (Note: `do_spl_desk_poll_check` is the outgoing poll form validator before sending, not the incoming receiver).

#### 2. Exact Deterministic Checks (Safe for zero intelligence)
1. **Sender Authentication**:
   - Message author must match authorized human owner format: `HUM-<n>` (e.g. `HUM-10` in tenant `t1`).
   - Never check `env.gcp.gcp_account_owner_email` (which is a GCP bootstrap credential reserved exclusively for gcp-000..004 per repo `CLAUDE.md`).
2. **Deterministic Poll Message Matching (Resolves N8)**:
   - Match on the deterministic format emitted by the WUI poll component (`csi-spl-wui/src/utils/poll.mjs` line 201 `answerBody`):  
     Line 1: `^Poll:[[:space:]]*([0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12})`  
     Line 2: `^Answer([[:space:]]+[0-9]+)?:[[:space:]]+([A-Za-z0-9,]+)`  
   - Extract `<poll-msg-id>` from Line 1 and option key(s) from Line 2.
   - Confirm that `<poll-msg-id>` corresponds to an active poll in the topic.
   - Drops all subjective "explicit voting text" matching.
3. **De-duplication Check**:
   - Verify no agent reply has been posted in the topic since the owner's answer timestamp.
4. **Immediate Acknowledgment Body (`how-to-post.md` Rule 15)**:
   - The acknowledgment body must strictly adhere to `how-to-post.md` Rule 15:  
     `**In progress**: noted.` or `**In progress**: noted (<head>).`  
   - **Never** say "Acting on option (A)" before anyone acts! The model/dispatcher acts after being woken.
5. **Topic Owner Wakeup**:
   - Immediately send a spool poke/task to the topic owner or active dispatch lease holder, waking the agent to execute the substantive work.
6. **Relationship to `do_spl_unanswered_sweep`**:
   - Complements the standing `do_spl_unanswered_sweep` cron (which sweeps and escalates unanswered owner posts across topics on an interval) by providing sub-minute instant acknowledgment to satisfy human interactive responsiveness.

#### 3. Refusals & Escalations
- **Non-Owner Response**: If poll answer is from an agent or non-owner, ignore.
- **Already Answered**: If an agent reply exists, abort to avoid duplicate posts.
- **Closed Topic**: If topic is locked/closed, abort.

#### 4. Execution Location & Cron Installation (Resolves N10, X6)
- Named action `do_spl_desk_poll_ack` in `csi-spl-orc/src/bash/run/spl-desk-poll-ack.func.sh`, executed on a 60-second cron or inbox event hook on the active dispatch box.
- **Cron Installation**: Installed by `csi-spl-orc/src/bash/run/spl-desk-poll-ack-install-cron.func.sh` in the crontab of the user that runs it, which is the desk owner user (`env.steps."060-gcp-vm-satellite".box_owner_user`, the user that runs `do_spl_desk_up`), as for every other csi-spl cron line. It is NOT installed under `box_agent_user`: the action reads the holder's desk spools, and those belong to the desk owner (measured 2026-10-28 on the PC box: `~<owner>/.local/share/csi-spl/cloud/prd/desk` is mode 700 and owned by the owner user, the agent user's desk dir holds one unrelated seat, and all 40 csi-spl cron lines, the unanswered sweep included, are in the owner user's crontab). Under the agent user it would find no holder desk and do nothing (dispatch holder ruling, c-002 msg 0dac3b66). Queries `do_spl_dispatch_lease show` (read-only); does NOT touch `spl-dispatch-lease*`.
- **Known limit (accepted, fails closed)**: `hub-tail` serves only the messages the holder's desk box holds (measured 2026-10-28, csitea topic 26a21b5a: the box held the owner's answers, not the poll another box posted). So a poll posted from another box's desk gets no acknowledgement (the active-poll check fails, nothing is posted), and a reply posted from another box is not seen by the de-duplication check. No fix in row B3.

#### 5. Test Plan & Red Controls
- **Test File**: `csi-spl-orc/src/bash/tests/spl-desk-poll-ack.tst.sh`
- **Red Controls**:
  1. *Non-owner response*: Agent ID `c-168` voting on poll -> script exits silently 0, sends 0 posts.
  2. *Duplicate reply prevention*: Topic where reply was already sent -> script exits silently 0.
- **Green Pass**: Valid owner `HUM-10` vote with `Poll: <uuid>` -> script executes `do_spl_desk_reply` posting `**In progress**: noted.`, and pokes topic owner.

---

## Rule 6: Machine-Stamped ISO / UTC Clock Times in Posts

> **Objective**: Standardize and automate time generation across all dispatcher posts, eliminating manually calculated time strings and enforcing `how-to-post.md` Section 4 compliance.

#### 1. Trigger
- An agent or script prepares a post body containing time template tokens or invokes `do_spl_desk_reply` / `do_spl_desk_post`.

#### 2. Exact Deterministic Checks (Safe for zero intelligence)
1. **Machine Token Expansion**:
   - `{{NOW_UTC}}` -> Formatted as `HH:MM:SSZ` (e.g. `17:15:30Z`).
   - `{{TODAY_UTC}}` -> Formatted as `YYYY-MM-DD` (e.g. `2026-10-25`).
   - `{{NOW_ISO}}` -> Formatted as `YYYY-MM-DDTHH:MM:SSZ`.
   - **The 10-25 Defect Insight**: On 2026-10-25, an agent typed the wrong UTC hour WITH a `Z` suffix (typing local EET time as UTC). No syntax linter can detect an incorrect hour number when it is syntactically valid `Z`; only deterministic machine token expansion eliminates this error class entirely.
2. **Supported Time Grammar (`how-to-post.md` Section 4)**:
   - Accept short UTC times: `HH:MM:SSZ`, `HH:MMZ`, `10:4xZ` (x = "about"), and ranges `10:15-10:17Z`, `09:53Z..10:23Z`.
   - Accept ISO 8601 date-times with a zone: `Z` or timezone offset such as `+03:00` (which `how-to-post.md` Section 4 explicitly permits and translates for the reader).
3. **Refusal Invariant (No Guessing)**:
   - Do NOT attempt to "automatically convert" raw colloquial times (e.g. "at 3pm local"). Guessing the timezone can introduce severe errors. Unrecognized or ambiguous times must be REFUSED with a clear linter error.

#### 3. Refusals & Escalations
- **Ambiguous Relative Time**: If post body contains colloquial times without a timezone, pre-post linter halts with error.

#### 4. Execution Location
- Filter library `csi-spl-orc/src/bash/run/spl-post-time.func.sh`, integrated into `csi-spl-orc/src/bash/run/spl-desk-reply.func.sh` and `csi-spl-orc/src/bash/run/spl-desk-post.func.sh`.
- **Built (row B1, SPL-4023)**: `spl_post_time_apply` runs first in both actions, right after the body is read (FATAL, nothing sent). One clock reading per post fills all three tokens; any other `{{NOW_*}}` / `{{TODAY_*}}` token is refused. Refused as colloquial: an am/pm hour (`3pm`, `9 a.m.`), a clock time with no zone (`10:45`), one with a named zone (`13:45 EEST`) and an ISO date-time with no zone. Text in `code` or a fenced block is not read, so a log line or a duration that is no clock time goes there. Try a draft without posting: `cd csi-spl-orc && POST_TIME_BODY='Taken at {{NOW_UTC}}' ./run -a do_spl_post_time` (no body: the three stamps). `how-to-post.md` section 4 is a Qto export; its token paragraph is written in the Qto doc, not here.

#### 5. Test Plan & Red Controls
- **Test File**: `csi-spl-orc/src/bash/tests/spl-post-time.tst.sh`
- **Red Controls**:
  1. *Ambiguous time*: Body containing `at 3pm today` without zone -> linter rejects with error.
- **Green Passes**:
  1. Draft containing `Taken at {{NOW_UTC}}` -> expands to exact current machine UTC time.
  2. Draft containing valid Section 4 forms (`10:4xZ`, ISO with `+03:00`) -> passes unaltered.

---

## 4. Analysis of Secondary Mechanical Steps & Queued Bug Rows

In message `604472ca`, standby dispatcher `c-003@sat` highlighted seven candidate friction points. Here we evaluate their disposition and confirm disjointness against queued bug rows:

| # | Candidate Mechanical Step | Operational Problem | Proposed Solution & Architecture | Fit & Disposition |
|---|---|---|---|---|
| **C1** | **Standby Inbox Auto-Archive** | Standby dispatcher (`c-003` while `c-002` holds lease) receives pokes for broadcast messages and channel copies, waking model needlessly. | Daemon monitors `$SPOOL_ROOT/<standby-id>/inbox/`. When in `STANDBY`, auto-archives unaddressed copies. | **Accepted**: Extension row B7 (`spl-standby-archive.func.sh`). |
| **C2** | **Dynamic Dispatch Holder Routing** | Lanes send final reports to hardcoded `c-002`, failing when `c-003` holds lease. | Route to active lease holder. Queued bug row `c002-bug-ksr-reporter-dispatch-holder` fixes `ksr_reporter` in `kill-your-self-report.sh`. Spool-send dynamic resolution is complementary. | **Handled**: Covered by `c002-bug-ksr-reporter-dispatch-holder`. Do not modify its files in rows B1–B6. |
| **C3** | **Cross-Box Path / File Inlining** | `<box-far>` cannot read local files on `sat` (`/var/spool-hub/...`). Cross-box messages citing local paths fail. | Update `spool-fleet-relay.sh`: detect referenced sat file paths in message body and embed contents as payload attachments when relaying across boxes. | **Accepted**: Extension row B8 (`spool-fleet-relay.sh`). Note: Does NOT solve or collide with `c002-bug-placer-brief-other-box` (which fixes placer brief reading in `spl-spawn-place.func.sh`). |
| **C4** | **Deterministic Ask Bookkeeping** | Dispatchers manually run `ask_put`, `ask_ack`, and `ask_close` when handling asks. | Automatically mark ask `done` when an outgoing message of kind `result` (or task completion) on the matching task ID succeeds. **Never** close on an `In progress` note! | **Accepted**: Extension row B9 (`spl-asks-auto-close.func.sh`). |
| **C5** | **DM Reply Starter Fallback** | Owner DM waited 35 minutes because only session starter could reply. | Add fallback authorization allowing active dispatch lease holder to answer DMs when starter session is dead. | **Handled**: Already queued in bug row `c003-bug-dm-reply-starter-gone`. |
| **C6** | **Deterministic Handoff Generation** | Each rotation requires manually writing open items handoff file. | Synthesize handoff file from active queue state (`do_spl_spawn_place`), open asks (`asks.json`), and hold notes. | **Accepted**: Extension row B10 (`spl-handoff-render.func.sh`). |
| **C7** | **Unified `do_spl_verify_done`** | Multiple disjoint checks to confirm whether a lane is done. | Compose `do_check_lane_served` and `do_spl_done_claim_check` into a single action returning binary `PASS` or `FAIL`. | **Accepted**: Incorporated directly into Rule 2 (Row B5). |

### Queued Bug Row Disjointness Confirmation (Resolves N4, N10, N11, X6):
1. `c002-bug-ksr-reporter-dispatch-holder` (Resolves N11): touches `csi-spl-orc/src/bash/features/spawn-agents/scripts/kill-your-self-report.sh` (`ksr_reporter`) and `test-kill-your-self-report.sh`. (Does NOT touch `spl-asks-tick.func.sh`, which is listed under "Must NOT touch"). Build rows B1–B6 touch neither of those files.
2. `c002-bug-lane-issue-end-apply-only`: touches `spl-lane-issue.func.sh`. Build rows B1–B6 touch neither file.
3. `c002-bug-placer-brief-other-box` (Resolves N4, X4): touches `spl-spawn-place.func.sh`. Row B6 (Rule 3) touches `spl-spawn-place.func.sh:584` (`spl_spawn_place_launch`) and is therefore **strictly ordered AFTER `c002-bug-placer-brief-other-box`**.
4. `c-184@sat` lease scripts (Resolves N10, X6): rows B1–B6 do NOT touch `spl-dispatch-lease*` or `spl-orch-lease*`. They perform read-only lease queries via `do_spl_dispatch_lease show`.

---

## 5. Boundary Matrix: Deterministic Script vs. Model Intelligence

To prevent automation overreach and protect operational safety, the operational boundaries between scripts and models are strictly partitioned:

```mermaid
flowchart TD
    subgraph FullyAutomated["STRICTLY AUTOMATED (0% Model Intelligence)"]
        A1[R7 Review Line syntax & test execution verification for PASS lines]
        A2[Cross-vendor & reviewer brief lifetime verification]
        A3[Git branch head SHA immutability checks]
        A4[Patch-id cherry comparison & anti-extra unreviewed commit guard over branch]
        A5[Journal transcript re-verification of original review message in archive]
        A6[GitHub Actions CI workflow status queries success or skipped]
        A7[Cloud Run /version & Firebase Hosting /build.json verification]
        A8[Author notifications upon reviewer seat launch at spawn-place line 584]
        A9[Immediate '**In progress**: noted' acknowledgment to ^Poll: msg-id votes]
        A10[Machine UTC timestamp formatting and token expansion]
    end

    subgraph HumanModel["STRICTLY MODEL / HUMAN (Preserved Dispatcher Judgment)"]
        H1[Review FAIL diagnosis: evaluating why code failed and deciding next action]
        H2[Rebase Conflict Semantics: judging whether modified range-diff hunks introduce defects]
        H3[Owner Go Decisions: authorizing tasks with protected operational keywords]
        H4[Unreviewed rows and ambiguous deliverables lacking PASS in automation.log]
        H5[Owner Conversation: discussing design alternatives, tradeoffs, priorities]
        H6[Emergency overrides and force-push requests]
    end
```

### 5.1 Hard Automation Safety Invariants
1. **Never Bypass an Access Gate**: Automated scripts must never override pre-push hooks, skip review line checks, or force-push commits.
2. **Fail Closed**: Any network timeout, git ambiguity, missing file, or unexpected exit code immediately halts automation and leaves state untouched.
3. **Comprehensive Audit Trail**: Every automated action must write a structured log entry to `$SPOOL_ROOT/dispatch/automation.log` specifying timestamp, message ID, action taken, actor, input SHAs, and verification receipts. The log file and directory `$SPOOL_ROOT/dispatch/` are initialized on first append (`mkdir -p "$SPOOL_ROOT/dispatch" && touch ...`) introduced in build row B4 upon its first logged event and used by B4, B5, and B6.

---

## 6. Implementation Plan: Build Rows B1..B6 & Extension Rows

### 6.1 Build Rows (Smallest first, completely disjoint files, ordered for safety) (Resolves N4, N10, X6)

```mermaid
flowchart LR
    B1[Row B1: Rule 6<br/>Machine Time Helper] --> B2[Row B2: Rule 4<br/>Live Proof Table Generator]
    B2 --> B3[Row B3: Rule 5<br/>Poll Ack Daemon]
    B3 --> B4[Row B4: Rule 1<br/>Review PASS Watcher & GO]
    B4 --> B5[Row B5: Rule 2<br/>Landed Verifier & ACCEPTED]
    B5 --> B6[Row B6: Rule 3<br/>Placer Launch Hook]
```

| Row | Target Rule | Primary Files Touched | Hooked Subsystem / Integration Point | Scope & Deliverable | Test & Red Controls | Size | Order |
|---|---|---|---|---|---|---|---|
| **B1** | **Rule 6** | `csi-spl-orc/src/bash/run/spl-post-time.func.sh`<br>`csi-spl-orc/src/bash/tests/spl-post-time.tst.sh` | Integrated into `spl-desk-reply.func.sh` and `spl-desk-post.func.sh` | Function `spl_post_timestamp` & template replacer for `{{NOW_UTC}}`, `{{TODAY_UTC}}`, `{{NOW_ISO}}`. Enforces Section 4 syntax. | Control: colloquial time rejected. Passes on valid token expansion and Section 4 times. | Small | 1 |
| **B2** | **Rule 4** | `csi-spl-orc/src/bash/run/spl-desk-live-proof-render.func.sh`<br>`csi-spl-orc/src/bash/tests/spl-desk-live-proof-render.tst.sh` | Standalone named action `do_spl_desk_live_proof_render` (composes `_spl_served_env` and `do_check_deploy_lag`) | Synthesizes verified Markdown `**Live**` table. Requires mandatory `LIVE_CHECKED` and `LIVE_NOT_CHECKED`. Uses `merge-base --is-ancestor` for served check. | Control: omitted `LIVE_CHECKED` or `LIVE_NOT_CHECKED` refused; unlanded SHA refused; deployed commit outputs verified table. | Small | 2 |
| **B3** | **Rule 5** | `csi-spl-orc/src/bash/run/spl-desk-poll-ack.func.sh`<br>`csi-spl-orc/src/bash/run/spl-desk-poll-ack-install-cron.func.sh`<br>`csi-spl-orc/src/bash/tests/spl-desk-poll-ack.tst.sh` | Standalone named action `do_spl_desk_poll_ack` on 1-minute cron installed in the desk owner user's crontab (the user that runs it; Rule 5 section 4 says why not `box_agent_user`). Queries `do_spl_dispatch_lease show` ro. Does NOT touch `spl-dispatch-lease*`. | Evaluates incoming `HUM-<n>` poll votes matching `^Poll: <msg-id>`. Emits immediate `**In progress**: noted.` post via `do_spl_desk_reply` and wakes topic owner. Known limit: a poll or a reply posted from another box is not seen (no ack; fails closed). | Control: non-owner vote ignored; duplicate vote ignored; owner vote immediately replied. | Medium | 3 |
| **B4** | **Rule 1** | `csi-spl-orc/src/bash/run/spl-review-go.func.sh`<br>`csi-spl-orc/src/bash/run/spl-review-go-install-cron.func.sh`<br>`csi-spl-orc/src/bash/tests/spl-review-go.tst.sh` | Standalone named action `do_spl_review_go` on 1-minute cron installed under `env.box.box_agent_user`. Queries `do_spl_dispatch_lease show` ro. Does NOT touch `spl-dispatch-lease*`. | Evaluates cross-vendor `PASS` review lines, verifies reviewer via `$SPOOL_ROOT/<id>/lifetime/brief.md`, scans for protected owner-go keywords, branch immutability, and local module tests in `ran:`. Records verified `PASS <ts> <msg_id> ... <sha>` in `automation.log` and emits `GO <sha>`. | Controls: `FAIL` escalates without GO/REJECT; same vendor refused; unassigned reviewer refused; owner-go keyword refused; remote log refused. Valid `PASS` emits `GO`. | Medium | 4 |
| **B5** | **Rule 2** | `csi-spl-orc/src/bash/run/spl-push-master.func.sh`<br>`csi-spl-orc/src/bash/run/spl-accepted-close.func.sh`<br>`csi-spl-orc/src/bash/run/spl-accepted-close-install-cron.func.sh`<br>`csi-spl-orc/src/bash/tests/spl-accepted-close.tst.sh` | Standalone named action `do_spl_accepted_close` on 1-minute cron installed under `env.box.box_agent_user`. Queries `do_spl_dispatch_lease show` ro. Enhances `do_spl_push_master` to append pushed range to `pushes.log`. Does NOT touch `kill-your-self-report.sh` or `spl-dispatch-lease*`. | Enhances `do_spl_push_master` to append `<iso-timestamp> <pushed_base>..<landed-sha>` to `pushes.log` upon push success. Composes `do_check_lane_served` and `do_spl_done_claim_check`. Reads `<msg_id>` from `automation.log` and re-verifies reviewer journal transcript; enforces cumulative anti-extra unreviewed commit guard across all recorded pushed ranges in `pushes.log`; verifies cherry patch-id presence, range-diff hunk parity, CI green/skipped, issue key, and served build. Emits `ACCEPTED (auto...)`. | Controls: empty commit refused; partial landing refused; unreviewed extra commit in multi-push sequence refused (tested after real 2-push sequence); journal transcript failure refused; rebase logic change refused; unreviewed row refused. Valid landing emits `ACCEPTED (auto...)`. | Medium | 5 |
| **B6** | **Rule 3** | `csi-spl-orc/src/bash/run/spl-spawn-review-notify.func.sh`<br>`csi-spl-orc/src/bash/tests/spl-spawn-review-notify.tst.sh` | Post-spawn hook in `spl-spawn-place.func.sh:584` (`spl_spawn_place_launch`). Ordered AFTER `c002-bug-placer-brief-other-box`. | Parses reviewer brief with decorated cells (`\| a-213@sat (agy) \|`) and notifies authors across boxes using registry. | Control: decorated cell matches; malformed brief logs warning; valid brief notifies authors. | Medium | 6 |

### 6.2 Secondary Extension Rows (Post-Rules 1–6)
- **Row B7 (C1 Standby Auto-Archive)**: `csi-spl-orc/src/bash/run/spl-standby-archive.func.sh` — background daemon auto-archiving unaddressed notifications for standby seats.
- **Row B8 (C3 Cross-Box Relay Inliner)**: `csi-spl-orc/src/bash/features/spawn-agents/scripts/spool-fleet-relay.sh` — embeds local file attachments into payloads crossing between `sat` and `<box-far>`. (Enhancement to relay inlining; independent of placer brief reading).
- **Row B9 (C4 Ask Auto-Closer)**: `csi-spl-orc/src/bash/run/spl-asks-auto-close.func.sh` — marks open asks `done` ONLY upon successful outbound message of kind `result` (or verified task completion) on the matching task ID.
- **Row B10 (C6 Standby Handoff Synthesizer)**: `csi-spl-orc/src/bash/run/spl-handoff-render.func.sh` — generates standby handover markdown from live queue and ask registries.

---

## 7. Invariants & Acceptance Criteria

### 7.1 System Invariants
1. **Safety First**: No automated script may execute an action if any prerequisite check yields ambiguous or non-zero return codes.
2. **Dispatcher Judgment Preserved**: Any review `FAIL` verdict, rebase conflict with modified diff hunks, unreviewed row, unreviewed extra commit in any pushed range, task touching protected owner-go keywords (`(?i:\bapply\b)`, `do-provision`, `do-tf-apply`, `PROBE_PRD_GO`, `DRY_RUN=0`, `ENV=prd`, `\bIAM\b`, `\bbilling\b`, `service account key`, `/etc/`), or docs-only review lacking test executions MUST be escalated to the dispatcher. Automation never rejects or authorizes these cases.
3. **Immutable History**: Automated `ACCEPTED` decisions must record the exact reviewed SHA, landed SHA, original review message ID, and verification receipts in `$SPOOL_ROOT/dispatch/automation.log`.
4. **No Phantom Closes**: A lane must never be issued `ACCEPTED` unless all reviewed commits from its verified `PASS` record in `automation.log` are proven present on `origin/master` (via cherry patch-id equivalence), zero unreviewed extra commits are present on the lane branch, the original review message is re-verified against the reviewer's private transcript, verified by CI (success or skipped), and actively served on dev/prd.

### 7.2 Acceptance Criteria for Build Rows
1. Every build row must deliver its named `./run` action and test in the same commit.
2. Every test must include verified red controls proving every refusal path before demonstrating the passing assertion.
3. Distribution hygiene (`do_check_dist_hygiene`) must remain 100% clean across all new files.
4. Fast pre-push lint (`do_check_pre_push_lint`) must pass with zero errors.
