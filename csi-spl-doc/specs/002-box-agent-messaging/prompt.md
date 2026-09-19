# Prompt: 002 on-box agent messaging (the local spool)

The prompt that, handed to a capable coding agent at the start, would have
produced `specs/002-box-agent-messaging/` and its implementation with the
fewest detours. It was written after the fact, from the spec, its git history
and the code as verified on the tree named in the Verification snapshot.

---

## 1. Goal and why

Build the **local spool**: one Go binary, `spool`, that lets agents on one box
(`CLE-*`, `GRK-*`, `AGY-*`) exchange messages and files through a folder,
`$SPOOL_ROOT`, with **no hub, no network and no keys**.

Why this comes first: the cloud message bus (`003-spool-message-bus`) needs a
box API that every agent already uses. Ship that API now, backed by a folder,
so 003 only adds a backend behind the same verbs, the same MCP tools and the
same `v:1` JSON. Nothing you build here is throwaway. The on-disk object *is*
the future wire object.

The behavioural reference is the box's existing file protocol:
`<id>/{inbox,outbox,archive}/`, one file per message, `<ts>--<from>--<slug>`
names, ack by moving inbox → archive, the file as the source of truth and a
tmux poke only as a doorbell. Read that protocol (the `agent-msg` skill and the
ysg-box scripts) to learn the contract. **Never modify, import or shell out to
ysg-box.** Write a fresh implementation that you own.

## 2. Binding constraints

1. **Local mail is unsigned.** Read `contracts/trust-modes.md` §1, §2 and §2.1
   before you write any code. Local trust is POSIX permissions on
   `$SPOOL_ROOT`. `send` and `recv` need no key and no pin. The stored `v:1`
   has no `sig`. A `sig` already on a file is tolerated and not checked. Do
   **not** build per-agent Ed25519 signing. That design was specified,
   implemented and then torn out in this feature's history (see §5, trap 1).
2. **Keys are per box, optional, and for hub prep only.**
   `spool keygen [--box <id>]` writes `box-<id>.key` with mode `0600` under
   `$SPOOL_KEYS_DIR` (default `$HOME/.spool/keys`). `spool pin --box <id>
   --pubkey <b64> [--force]` writes `$SPOOL_ROOT/pins/box-<id>.pub` with mode
   `0644`. `$SPOOL_BOX_ID` has **no default**: keygen fails fast (exit `1`) when
   neither `--box` nor the env var is set. A box key never signs local mail.
3. **Exit codes:** `0` means ok. `78` means a content-hash mismatch on
   `get-file`/`get-dir`, and that is its **only** local meaning. `1` covers
   usage errors, IO errors and a malformed inbox file. On a malformed file,
   `recv` still prints the good messages, leaves the bad file in `inbox/` and
   exits `1`.
4. **The `v:1` schema is permanent** (`contracts/message-schema.md`). It has
   these fields: `v, msg_id, task_id, ts, from, to, kind, body, files`.
   - `kind` is one of `task|result|note|reject`.
   - Ids match `^[A-Z]{2,4}-\d+$`, and the `BOX-` prefix is forbidden.
   - Unknown keys are rejected.
   - Limits: 64 KiB body, 16 files, 32 MiB per file.

   Changing the object means bumping `v`. If you need attachment fields beyond
   `file_id/name/bytes/sha256`, such as `mode`, `kind` or `path`, **amend
   message-schema.md in the same commit**. Do not let the code outgrow the
   contract silently.
5. **Canonical bytes:** the disk form must be byte-identical to
   `jq -cjS .` of the object: sorted keys, compact, no trailing newline. In
   particular, `<`, `>` and `&` must **not** be escaped. Go's `json.Marshal`
   escapes them, so encode with `SetEscapeHTML(false)`. Lock the output with
   the golden vector in `contracts/canonical-json.md`, plus the second vector
   that has one `files[]` entry and a body containing `"`, a newline and `<&>`.
   The hub will sign exactly these bytes, so NFR-003 depends on this.
6. **Delivery is an atomic rename, claimed at most once.** Ack moves
   `inbox/<f>` to `archive/<f>` with `rename(2)` on one filesystem. When two
   `recv --ack` processes race, only the process whose rename **succeeded** may
   return the message. The one that loses (`ENOENT`) must drop it silently. It
   must not print the message and must not fail.
7. **Paths come from env with documented defaults, nothing else is baked in.**
   The variables are `SPOOL_ROOT` (default `/var/spool-hub`, an owner decision
   that is separate from any other message tree), `SPOOL_KEYS_DIR`,
   `SPOOL_PINS_DIR`, `SPOOL_BOX_ID`, `SPOOL_LOG_LEVEL` and `SPOOL_LOG_FORMAT`.
   Refuse a keys dir that resolves inside `$SPOOL_ROOT` (NFR-002).
8. **One verb layer.** The CLI (`cmd/spool`) and the stdio MCP server
   (`spool mcp`) both call one `internal/action` package. Each MCP tool's text
   is byte-for-byte the verb's stdout. A failure becomes `IsError` with text
   `spool: <reason> (exit <code>)`. Tool names are kind-agnostic:
   `spool_put_file`, `spool_send`, `spool_recv`, `spool_get_file` and
   `spool_tail`. Never add `spool_send_claude` or similar.
9. **MCP library:** the official `github.com/modelcontextprotocol/go-sdk`
   (v1.8.0), using `mcp.StdioTransport`. Do not use `mark3labs/mcp-go`. The SDK
   requires `go 1.25.0`. Set that as the module's `go` directive from the start.
10. **Patterns:** follow pas-psf for config (`caarlos0/env`, fail-fast),
    logging (`zerolog`), `internal/testkit` temp-root fixtures, and bash
    `*.tst.sh` tests (NFR-005).
11. **Repo rules** (repo `CLAUDE.md`):
    - Everything lives under `csi-spl`. The module home is
      `csi-spl-api/src/go/spool-hub-api`.
    - Builds are offline: `GOFLAGS=-mod=mod GOPROXY=off GOSUMDB=off GOTOOLCHAIN=local`,
      from the module cache.
    - Commits carry the canonical identity named in the repo `CLAUDE.md`, have
      no AI trailers, and use explicit pathspecs.
    - Keep content org-neutral: CI's distribution-hygiene sweep rejects
      personal names, bare OS user names, personal home dirs and owner mail.

### Non-goals (these belong to 003/006 or later)

- The hub: Cloud Run, Postgres, GCS, NATS, WebSocket, envelopes, and the
  `from_box`/`to_box` fields.
- Cross-box delivery and the signed-URL relay.
- Live notification (`SendMessage`, tmux poke) with delivery semantics. 002
  guarantees the file leg only.
- Any edit to ysg-box.

Do not add a hub flag to 002. The one hook 003 needs is the `delivery` field
in the send result, which is always `"local"` here.

## 3. Acceptance criteria and the exact checks

| # | Criterion | Check |
|---|---|---|
| A1 | US1: send → recv → ack in a clean temp root, with no keygen and no pin. The stored JSON has no `sig`. A second `recv --ack` returns `[]`. | `go test ./internal/spool -run 'TestUS1'` |
| A2 | A malformed inbox file: good messages are printed, the bad file stays, exit `1`. | `TestUS1_MalformedFileSurfacesExit1` |
| A3 | Concurrent `--ack`: 0 double deliveries in 200 paired races. | A bash loop: two `recv --ack` in parallel per fresh root, and the summed array length must be `1` every time. |
| A4 | US2: put → send `--file-id` → get-file verifies sha256. Identical bytes dedupe to one `files/<id>`. A corrupted blob gives exit `78` and no dest file. An absent blob gives exit `1` and no partial file. | `TestUS2_*`, and smoke checks "hash mismatch refused (exit 78)" |
| A5 | US3: `tail --task` is oldest-first, deduped across inbox, outbox and archive. `--json` is NDJSON that round-trips through `jq`. | `TestUS3_TailOrdered` |
| A6 | US4 / SC-004: an MCP call and its CLI verb give identical text and files, and a hash mismatch is a tool error with `(exit 78)`. | `go test ./internal/mcp -run TestSC004MCPEqualsCLI`, plus smoke over real stdio |
| A7 | Canonical bytes equal the golden vectors, and a body with `<&>` is written raw. | a `go test` in `internal/msg` plus `cmp <(tr -d '\n' < f) <(jq -cjS . f)` on a sent file |
| A8 | FR-015: a legacy `.md` in `inbox/` comes back as a `kind:"note"` `v:1` object with no `sig`, and is archived on `--ack`. Every synthesized field still passes `Validate()`. | `TestLegacyMDBridge` |
| A9 | FR-014: the Go source has no ysg-box path, import or `MSGS_ROOT`. | `bash csi-spl-api/src/bash/tests/no-ysg-box-ref.tst.sh` |
| A10 | Everything is green together: gofmt, vet, `go test ./...`, the gates, and the 10+ check smoke. | `bash csi-spl-api/src/bash/tests/run-all-tests.sh`, which must end `ALL csi-spl-api TESTS PASSED` |

## 4. Order of work

1. Read `contracts/trust-modes.md`, `message-schema.md`,
   `canonical-json.md`, `cli.md`, `mcp-tools.md` and `local-folder-layout.md`
   in full. Where a contract is silent, take the smallest non-breaking option
   and record it in `spec.md` under Clarifications.
2. Set up the module (`go 1.25.0`), `build.sh`, `run-all-tests.sh` and the
   `no-ysg-box-ref` gate (T001 to T003).
3. Build the foundations: `internal/config`, `logging`, `testkit`, `msg`
   (with the golden-vector tests **before** any writer), `spool` (layout and
   atomic write/rename) and `sign` (box key and pin only), then `cmd/spool`
   dispatch and exit codes (T004 to T007).
4. US1: unsigned send and recv/ack, the claimed-once ack, the malformed-file
   path, and the legacy `.md` bridge. Write the Go tests and the bash smoke.
   Commit and push this as the MVP before starting anything else.
5. Build `internal/action` **before** any second front end. Then do US2
   (blobs, deterministic dir tar, path refs) and US3 (tail). Each gets its own
   commit.
6. US4: `internal/mcp` on go-sdk and `spool mcp`, with an SC-004 test that
   drives the real binary and an in-memory MCP session on twin roots.
7. Polish: `quickstart.md`, a paste-able temp-root walkthrough that mirrors
   `spool-smoke.tst.sh`; the box install path (docs only); a hygiene sweep;
   and a stale-term grep across spec, plan, data-model and contracts.

## 5. Traps this feature actually hit (avoid them up front)

1. **Signed-first, then unsigned.** Phases 1 to 5 shipped per-agent Ed25519
   signing, pin checks and a `78` refusal on a bad signature. Commit `90786cd`
   then rewrote send, recv, the tests and the testkit to the unsigned
   trust-modes contract, and every T008 to T012 task line now carries a
   "superseded by T029" note. Start from trust-modes §2. A task list written
   before that contract existed is wrong.
2. **The contract moved mid-flight.** Trust-modes moved from `doc/md/` into
   `contracts/trust-modes.md` with its section numbers kept (22 citations were
   re-pointed). Cite contracts by `§N` and keep section numbers stable when
   you move a file.
3. **Offline module cache.** Phase 6 stalled because go-sdk was not in the
   cache. Ask the owner up front to approve a one-time fetch of
   `modelcontextprotocol/go-sdk@v1.8.0`, and set `go 1.25.0` on day one.
   Changing the directive later (1.22 → 1.25.0) meant touching docs a second
   time.
4. **Default root churn.** `SPOOL_ROOT` changed once, by owner decision, to
   `/var/spool-hub`, and nine files had to follow. Keep the default in one
   constant (`config.go`), and reference it by name, not by value, in docs.
5. **Go's JSON is not jq's.** `json.Marshal` HTML-escapes `<>&`, so the disk
   bytes differ from `jq -cS`. 003's `internal/wire` noticed this and used
   `SetEscapeHTML(false)`. Nobody fixed 002's `msg.Marshal`. Write the golden
   test first so this cannot happen.
6. **Ack race.** You must not append a message to the result before the
   rename that claims it succeeds.
7. **Legacy bridge fallbacks must still validate.** A `.md` whose filename has
   no valid agent id must not come back with `from:"LEGACY"`, which fails the
   id regex. Pick a documented valid sentinel or surface the file as
   malformed. Validate the synthesized object like any other.
8. **Attachment shape drift.** Blobs, dir tars and path refs added `mode`,
   `kind` and `path` to `files[]`, and a `--file-id` attach gets
   `name=<file_id>` and no `bytes`. Update `message-schema.md` in the same
   change, or keep the attachment to the four contract fields.
9. **Verb spelling.** The contract says `spool-send`; the binary does
   `spool send`. Either ship the `spool-<verb>` shims or write the contract as
   `spool <verb>`. Do not leave a code comment claiming shims that do not
   exist.
10. **Hygiene sweep.** It runs in CI over the whole tree, docs included. It
    bans personal names, bare OS user names, personal home dirs and owner
    mail. `ysg-box` is allowed as a product name. Run the sweep's greps
    locally before you push.

## 6. What to hand back

- Commits on trunk, each pushed as soon as it is green, with shas listed per
  phase.
- `tasks.md` with every task ticked, plus a sha or a check per task.
  Superseded tasks are marked as superseded, not silently rewritten.
- The output of `run-all-tests.sh` (its last line) and the A3 race count
  (n=200).
- Any contract clarification you had to make, recorded in `spec.md`
  Clarifications and in trust-modes §2.1.
- A short list of open items that belong to 003 (for example `delivery`,
  box key files, `to_box`).

---

## Verification snapshot

- **Tree:** `dd447fae961a57e038992578814b25a8f3133e65` (origin/master at the
  time of the check). **Date:** 2026-09-19. **n=1** for each check, except
  where a row says otherwise.
- `bash csi-spl-api/src/bash/tests/run-all-tests.sh` → `ALL csi-spl-api TESTS
  PASSED` (gofmt, vet, `go test ./...`, ysg-box/host/hostname gates, smoke,
  hub-pg, hub-gcs).
- Probes were run against a binary built from that tree in a temp root:
  - HTML escaping: sent body `a<b && c>d`, then `cmp` of the file against
    `jq -cjS .` → `DIFFERENT` (the file holds `<`, `&`).
  - Concurrent `--ack`: **37 / 200** races delivered the message twice.
  - Legacy `.md` named `…--someone--hi.md` → `from:"LEGACY"` (fails the id
    regex), exit `0`.
  - `--file-id` attach → `files[0]` = `{file_id, kind, mode, name=<file_id>,
    sha256}` with no `bytes`.
  - `SPOOL_KEYS_DIR=$SPOOL_ROOT/keys spool keygen` → exit `0`, and the key was
    written inside the spool root.

| Req | Verdict | Evidence (code · test) |
|---|---|---|
| FR-001 verbs | DRIFT | `cmd/spool/main.go:99` dispatches `spool <verb>`. No `spool-<verb>` shim exists in the tree, although the header comment says there are shims and FR-001/`cli.md` name the hyphenated forms. |
| FR-002 root default/env | VERIFIED | `internal/config/config.go:28` |
| FR-003 v:1 file per message, name | DRIFT | `internal/msg/msg.go:209` builds names (the same-second tie-break is fine). But the disk bytes (`msg.go:87`, `json.Marshal`) HTML-escape `<>&`, so they are not `jq -cS` bytes (probe above). |
| FR-004 unsigned send | VERIFIED | `internal/spool/spool.go:45`, `action/action.go:122` · `TestUS1_UnsignedNoKeyNoPin`, `TestUS1_BoxKeyDoesNotSignLocally` |
| FR-005 recv tolerates sig | VERIFIED | `spool.go:137` · `TestUS1_PresentSigIsTolerated` |
| FR-006 atomic ack, at most once | DRIFT | `spool.go:176-180` appends the message before `atomicMove`, so the loser of a race returns it too and exits `1`. Measured 37/200. The sequential double-ack is fine (`TestUS1_DoubleAckDeliversOnce`). |
| FR-007 put-file | VERIFIED | `internal/files/files.go:31`, `:227` · `TestUS2_BlobFileRoundTripAndDedupe` |
| FR-008 get-file verify, no partial | VERIFIED | `files.go:165`, `:196` · smoke "hash mismatch refused (exit 78), nothing written" |
| FR-009 box keygen 0600 outside root | DRIFT | `internal/sign/sign.go:32`, `main.go:147` (prints the public key only) · smoke "box-<id>.key 0600". Nothing rejects a `SPOOL_KEYS_DIR` inside `$SPOOL_ROOT` (probe above). |
| FR-010 box pin | VERIFIED | `sign.go:72`, `action/pin.go:33` · `TestBoxKeyPinSignVerify`, `TestUnpin` |
| FR-011 tail | VERIFIED | `spool.go:206`, `action.go:170` · `TestUS3_TailOrdered` |
| FR-012 MCP thin wrapper | VERIFIED | `internal/mcp/mcp.go:53` · `TestSC004MCPEqualsCLI`, `TestRecvMalformedIsToolError`, smoke stdio check |
| FR-013 kind only as id prefix | VERIFIED | `msg.go:180` · `TestToolNamesAreCanonical`, `TestValidID` |
| FR-014 no ysg-box coupling | VERIFIED | `no-ysg-box-ref.tst.sh` → ok |
| FR-015 legacy .md bridge | DRIFT | `spool.go:331` works (`TestLegacyMDBridge`, smoke). But the fallback `from:"LEGACY"` (`spool.go:411`) and a raw frontmatter `to` are never validated against the schema. |
| NFR-001 Go 1.25+, stdlib crypto | VERIFIED | `go.mod` `go 1.25.0` |
| NFR-002 no private key in root/git/log | DRIFT | The default is fine (`config.go:64-70`), and the key is never printed or logged. A keys dir inside the root is accepted (probe above). |
| NFR-003 disk == wire bytes | DRIFT | 003 `internal/wire/wire.go:131` uses `SetEscapeHTML(false)`; 002 `msg.Marshal` does not. |
| NFR-004 atomic renames | VERIFIED | `spool.go:288` (`os.Rename`; the cross-filesystem fallback is outside the NFR's one-filesystem scope) |
| NFR-005 pas-psf patterns | VERIFIED | `config.go` (caarlos0/env), `internal/logging`, `internal/testkit`, `*.tst.sh` |
| SC-006 schema unchanged | DRIFT | `files[]` carries `mode`, `kind` and `path`, which are not in `message-schema.md`. A `--file-id` attach has `name=<file_id>` and no `bytes`. |
| canonical-json golden test | MISSING | `internal/msg/msg_test.go` has no golden-vector or escaping-vector test (003 has one in `internal/wire/wire_test.go:29`). |

<!-- version: 0.1.0 · updated: 2026-09-19 · last-edit: 2026-09-19T13:20:00Z -->
