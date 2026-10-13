signed against f33d909e0358a390347acb18b895d186dba4f75f

## 1. Section Review (Sections 0–13)

- **Section 0 (The owner's words):** AGREE. The five binding rules (R1–R5) faithfully translate owner messages 3cfe43ce, 0f7b0d3d, 9a0a1732, 7559efa5, and e6cdd9f3 into explicit architectural constraints.
- **Section 1 (Today, measured: where a message body lands in clear text):** CHANGE. The audit is largely accurate (D1–D8, S1–S9, P1–P9 verified), but misses five concrete code locations where message bodies or transcripts land in clear text or argv:
  1. Watchdog transcript and input dumps (`spl-watchdog.func.sh:824,843-844`).
  2. Terminal rendering in agent inbox tool (`agent-inbox.sh:65-68`).
  3. Acceptance check in exit gate (`kill-your-self-report.sh:150-151`).
  4. Desk reply body extraction and formatting (`spl-desk-reply.func.sh:387,430`).
  5. Box-local spool send command-line argv (`spool-send.sh:305,354`).
  Exact replacement text provided in section 2 below.
- **Section 2 (The rules):** AGREE. The 8 operational rules preserve complete byte-for-byte backward compatibility for plain workspaces while ensuring strict cryptographic boundaries for encrypted workspaces.
- **Section 3 (Data: the envelope and the "encrypted" dirs):** AGREE. The `v:3` envelope, outer structure without clear `body`, base64 age payload in `ct`, clean filenames without body slugs, and dedicated `encrypted/` hierarchy fully satisfy R2 and R3.
- **Section 4 (The key model):** AGREE. Embedding `filippo.io/age` directly in the Go binary avoids external gpg-agent daemon fragility. The daemon `spool keyd` with `mlock` and socket-level `SO_PEERCRED` enforcement provides safe in-memory identity management.
- **Section 5 (The passphrase rule):** AGREE. Enforcing `golang.org/x/term` `ReadPassword` on `/dev/tty` and failing fast on any environment variable, pipe, argv, or non-terminal file descriptor strictly upholds R1.
- **Section 6 (Agents dedicated to a workspace):** AGREE. Dedicated OS user `spw-<id>` with 0700 permissions establishes the only real Unix DAC isolation barrier on a shared machine while respecting the 40-agent ceiling.
- **Section 7 (Performance):** AGREE. Pure Go X25519/ChaCha20-Poly1305 overhead is negligible (<1 ms for typical p50 515 B / p99 3631 B messages), and scrypt passphrase derivation is isolated to box startup.
- **Section 8 (Migration and rollback):** AGREE. Safe four-stage transition (flag -> user setup -> migration -> optional rollback) ensures existing plain mail is sealed and verified against the owner key before deletion.
- **Section 9 (Honest limits):** AGREE. Clearly states the threat model: protects against inter-agent, inter-workspace, and disk-level snooping, but cannot protect against root/sudo or vendor model ingestion.
- **Section 10 (Functional requirements):** AGREE. Requirements FR1–FR12 provide unambiguous acceptance criteria and map cleanly to test proofs.
- **Section 11 (Build split):** CHANGE. Lane L7 is oversized (12 scripts) and conflates screen capture handling with filesystem lifecycle operations. Split L7 into L7a (screen and pane captures) and L7b (lifecycle and directory moves). Include `agent-inbox.sh` and `kill-your-self-report.sh` in the lane plan. Exact replacement text provided in section 4 below.
- **Section 12 (Owner questions):** AGREE on framing; votes detailed in section 5 below.
- **Section 13 (Panel):** AGREE. Consensus threshold (>= 1 agy + >= 1 grok + 2 claude) matches the owner rule.

---

## 2. Verification of Section 1 "Measured Today" and Clear-Text Audit

### 2.1 Confirmation of Existing Findings (D3, D5, S1)

- **D3 (`api/internal/spool/spool.go:286-310`):** CONFIRMED.
  Command: `sed -n '286,310p' csi-spl-api/src/go/spool-hub-api/internal/spool/spool.go`
  Shows: `bridgeFleet` copies DM envelopes into `filepath.Join(root, id, boxInbox)` via `writeFileAtomic(..., 0o664)`.
  Command: `grep -n FLEET_ROOT csi-spl-orc/src/bash/run/spl-local-hub-agent-join.func.sh`
  Shows: Zero matches; the join function does not specify `SPOOL_FLEET_ROOT`.
  Command: `sed -n '348p' csi-spl-orc/src/bash/run/spl-desk-up.func.sh`
  Shows: `local fleet="${SPOOL_FLEET_ROOT-${SPL_WS_SPOOL_ROOT:-/var/spool-hub}}"`, which defaults to `/var/spool-hub`. As a result, agent-to-agent DMs within the private workspace are copied in clear text into the shared fleet spool.
- **D5 (`api/internal/msg/msg.go:286-308`):** CONFIRMED.
  Command: `sed -n '286,308p' csi-spl-api/src/go/spool-hub-api/internal/msg/msg.go`
  Shows: `Filename(m *Message)` generates `slug := slugRe.ReplaceAllString(strings.ToLower(m.Body), "-")` capped at 32 characters, embedding the plaintext body into the filename visible on disk to any user in group `spool-agents`.
- **S1 (`sa/lib/spool-notify.inc.sh:290-295`):** CONFIRMED.
  Command: `sed -n '290,295p' csi-spl-orc/src/bash/features/spawn-agents/lib/spool-notify.inc.sh`
  Shows: `body="$(spool_notify_cut "$body" "${SPOOL_NOTIFY_BODY_MAX:-600}")"` builds `: 'SPOOL ${to}: ${kind} from ... :: ${body} :: run: spool recv --as ${to}'` and types it into the tmux pane.

### 2.2 Missing Locations Where Message Bodies Land in Clear Text

The following five code locations also handle or persist unencrypted message bodies and must be accounted for in Section 1 and addressed in build lanes:

1. **Watchdog transcript and input buffer capture (`spl-watchdog.func.sh:824,843-844`):**
   Command: `grep -nE 'spl_wd_transcript|spl_rotate_input' csi-spl-orc/src/bash/run/spl-watchdog.func.sh -A 2`
   Shows: `spl_wd_transcript "$pid" > "$ctx/transcript"` dumps up to 400 lines of the agent's CLI session transcript (containing clear prompt text and received messages), and `spl_rotate_input "$pane" > "$ctx/input"` records active input lines into `$WD_DIR/ctx/$id/`. Section 1.4 row P3 only noted line 828 (`screen to <tick dir>/pane`).
2. **Terminal rendering in agent inbox utility (`agent-inbox.sh:65-68`):**
   Command: `sed -n '65,68p' csi-spl-orc/src/bash/features/spawn-agents/scripts/agent-inbox.sh`
   Shows: `first = (body[0] if body else "")[:120]` extracts the initial 120 characters of `body` and prints it to stdout.
3. **Exit-clean verification gate (`kill-your-self-report.sh:150-151`):**
   Command: `sed -n '150,151p' csi-spl-orc/src/bash/features/spawn-agents/scripts/kill-your-self-report.sh`
   Shows: `ksr_accept_gate` uses `jq` to extract `((.body // "") | .[0:120])` across `$SPOOL_ROOT/$ID/inbox` and `archive`. An encrypted message cannot be parsed by this check unless the gate handles encrypted workspaces.
4. **Desk reply candidate formatting (`spl-desk-reply.func.sh:387,430`):**
   Command: `sed -n '387p;430p' csi-spl-orc/src/bash/run/spl-desk-reply.func.sh`
   Shows: `head = " ".join(str((m or {}).get("body", "")).split())[:80]` formats and prints up to 80 characters of message bodies to stdout and TSV logs. (Section 1.5 row W4 only cited `spl-desk-reply.sh:148`).
5. **Local spool send command line arguments (`spool-send.sh:305,354`):**
   Command: `sed -n '305p;354p' csi-spl-orc/src/bash/features/spawn-agents/scripts/spool-send.sh`
   Shows: `args=(send --from "$FROM" --to "$TO" --kind "$KIND" --body "$BODY")` invokes `"$SPOOL_BIN" "${args[@]}"`, exposing the message body in `/proc/<pid>/cmdline` during execution.

---

## 3. Key Model Assessment and Threat Boundary (Section 9 Audit)

### 3.1 Adherence to the Owner's Rules
- **R1 (Passphrase on terminal only):** Strictly enforced. `spool key unlock` requires `/dev/tty` and fails if standard input/output is not a terminal or if any passphrase flag or environment variable is detected.
- **R2 (Announce envelope, seal payload):** Enforced. The envelope retains `v`, `msg_id`, `task_id`, `ts`, `from`, `to`, `kind`, and `for` in plaintext so non-recipients ignore it, while `body` and attachment references are sealed inside `ct`.
- **R3 (Dedicated `encrypted/` directories):** Enforced. `<root>/<agent>/encrypted/{inbox,outbox,archive}` ensures legacy tools and plain commands never read sealed payloads.
- **R4 (Workspace-generic design):** Enforced. Configuration uses `spool_enc` flag and workspace IDs without hard-coded paths or workspace names.
- **R5 (Dedicated agents and OS user):** Enforced. `spw-<id>` with 0700 home prevents inter-workspace snooping on shared hosts.

### 3.2 What Root and Sudo Still Read
Section 9 is technically sound and necessary. On Linux systems, no user-space cryptography protects data in memory against `root` or users with `sudo` access:
1. **Keyd daemon memory:** While `keyd` is unlocked, `root` can read its virtual memory via `/proc/<pid>/mem` or ptrace, extracting clear-text age private keys despite `mlock` and `PR_SET_DUMPABLE=0` (which only inhibit swapping and unprivileged core dumps).
2. **Harness memory:** Decrypted message bodies residing in agent process memory can be read by `root` via `/proc/<pid>/mem`.
3. **Tmux server and buffers:** `root` can access tmux server sockets, capturing scrollback buffers, panes, and paste buffers.
4. **Agent CLI transcripts:** Stored in the workspace user's home directory (`~/.claude/projects/...`, `~/.gemini/...`); accessible to `root`.
5. **Filesystem traces:** Deleted plaintext files may persist in ext4 journals or unallocated blocks until overwritten.

To maintain real secrecy against `root`, the hosting box must not have shared administrative access, and workspace agents must have no `sudo` privileges (Q4: Option A).

---

## 4. Build Split Audit (Section 11)

### 4.1 Disjointness Check
The files listed across lanes L1 through L10 are strictly disjoint. No two lanes modify the same file paths.

### 4.2 Scope Reduction: Splitting Lane L7
Lane L7 currently lists 12 separate scripts across `csi-spl-orc/src/bash/run/` and `csi-spl-orc/src/bash/features/spawn-agents/scripts/`. This is excessive for a single small task. L7 should be divided into two focused lanes:
- **L7a (Screen and pane captures):** `spl-lane-restart.func.sh`, `spl-rotate-lib.func.sh`, `spl-lane-rotate.func.sh`, `spl-wd-takeover.func.sh`, `spl-peer-restart.func.sh`, `spl-orch-rotate.func.sh`, `spl-watchdog.func.sh`, `spl-lane-handover.func.sh`.
- **L7b (Lifecycle moves and retired copies):** `spawn-remote.sh`, `agent-id-retire.sh`, `desk-seat-drop.sh`, `spl-desk-rebox.func.sh`, plus `agent-inbox.sh` and `kill-your-self-report.sh`.

### 4.3 Missing Tests and Live Proofs
1. **L2 (keyd socket access control):** Add a unit test verifying that connections to `keyd.sock` from a process with a different UID are rejected via `SO_PEERCRED`.
2. **L5 (spool-send fallback guard):** Add a test ensuring `spool-send.sh` refuses unencrypted jq fallback into `peers/inbox` when operating in an `enc` workspace.
3. **L6b (OS user isolation proof):** Add a live proof verifying that user `spw-<id>` cannot read `/var/spool-hub/<other-agent>` or another workspace's `<state>` directory.

---

## 5. Owner Questions (Q1–Q7 Votes and Rationale)

- **Q1 (Cipher): Vote A.** Pure Go in-process age (`filippo.io/age`) eliminates external gpg/gpg-agent daemon dependencies, socket IPC failures, and keyring state while aligning with existing local-hub backup crypto tooling.
- **Q2 (Passphrases for agent keys): Vote A.** All agents of a workspace share its dedicated OS user (`spw-<id>`), so requiring N individual agent passphrases multiplies manual typing without adding a meaningful OS security boundary.
- **Q3 (OS users): Vote A.** One OS user per workspace establishes strict Unix DAC isolation between workspaces while avoiding the overhead and token refresh conflicts of per-agent vendor CLI logins.
- **Q4 (sudo for a workspace's agents): Vote A.** Sudo privileges allow an agent to inspect `/proc/<pid>/mem` and sockets across all workspaces, completely breaking inter-workspace isolation.
- **Q5 (CLI transcripts): Vote A now, defer B.** Restricting transcripts to the workspace user's 0700 home directory provides immediate inter-workspace protection without introducing filesystem mount and startup race complexities for vendor CLIs.
- **Q6 (The owner key in every `for`): Vote A.** Mandatory inclusion of the owner recipient ensures operational disaster recovery, auditing, and export capability if an agent crashes or rotates keys.
- **Q7 (Unlock after a reboot): Vote A.** Unattended unlock from a key file directly violates owner rule R1 (terminal tty only), leaving keys vulnerable to disk theft.

---

## 6. Language: Authoritative Agy Rewrites

As the designated authority on repo language (CLAUDE.md:140), agy provides the following precision rewrites for unclear or ambiguous phrasing in `spec.md`:

1. **Section 0, R3 (lines 48–49):**
   - *Current:* "With the separate dir the "encrypted for X, skipped" stub of 0f7b0d3d is no longer needed: the plain dirs only ever hold clear-text messages."
   - *Rewrite:* "With dedicated directories, the 'encrypted for X, skipped' stub from msg 0f7b0d3d is no longer required, as plain directories will exclusively contain plaintext messages."
2. **Section 1.1 (line 84):**
   - *Current:* "D3 matters first for the private workspace."
   - *Rewrite:* "D3 is of primary concern for the private workspace."
3. **Section 1.2 (lines 109–110):**
   - *Current:* "Parse sets DisallowUnknownFields (msg.go:168-172): a reader of today refuses a file with a new key such as enc. With R3 (separate dirs) that is a feature: an old binary never meets such a file."
   - *Rewrite:* "Because `Parse` enables `DisallowUnknownFields` (`msg.go:168-172`), current readers reject any file containing a new key such as `enc`. Under R3 (separate directories), this acts as a safeguard because legacy binaries will never encounter such files."
4. **Section 3.1 (lines 209–210):**
   - *Current:* "The header shows who talks to whom, the task and the time: accepted (section 9)."
   - *Rewrite:* "The plaintext header exposes sender and recipient identities, task identifier, and timestamp; this metadata exposure is an explicit design trade-off accepted in section 9."
5. **Section 4 (lines 266–267):**
   - *Current:* "Only its recipient stays on the box. Every sealed message names it in `for`: the owner can read everything, also after an agent and its key are gone."
   - *Rewrite:* "Only its recipient identity remains on the box. Because every sealed message includes it in `for`, the owner retains complete read and recovery access even after an agent has retired and its ephemeral identity has been purged."
6. **Section 4 (lines 283–284):**
   - *Current:* "Sealing needs no unlock: writing a message uses recipients only. A desk sidecar keeps delivering while keyd is locked; mail waits sealed."
   - *Rewrite:* "Sealing requires no unlocked private keys because encryption relies exclusively on public recipient identities. The desk sidecar continues message delivery while `keyd` is locked, allowing incoming messages to accumulate safely in sealed form."
7. **Section 6.1 (lines 309–311):**
   - *Current:* "Unix permissions are the only wall between two processes of the same user. Today every agent runs as one of two OS users (1.1), so a 0700 dir or a keyd socket keeps no other agent out. An `enc` workspace therefore gets **its own OS user** `spw-<first 8 hex of the workspace id>` (never its name):"
   - *Rewrite:* "Unix permissions provide the only boundary between processes on the host. Because all agents currently run under one of two shared OS users (1.1), a 0700 directory or unix socket provides no protection against other agents. An `enc` workspace therefore requires **its own dedicated OS user** `spw-<first 8 hex of the workspace id>` (never its name):"
8. **Section 11 (lines 442–443):**
   - *Current:* "One plain-workspace fix can land at once, with no format change: P5, `spawn-remote.sh` brief mode 644 -> 600 (inside L7's files)."
   - *Rewrite:* "One plain-workspace security fix can land immediately without format changes: P5 (tightening `spawn-remote.sh` brief permissions from 0644 to 0600 within L7b)."
