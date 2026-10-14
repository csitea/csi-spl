# Refactoring round 5 - mistral seat proposal (action 02)

> Generated from qto doc `efdfa1f8-1cda-4677-b291-ff431ca984f0`; edit it there. This file is its export: `cd csi-spl-orc && ./run -a do_spl_doctree_export_md` rewrites it.

**Agent**: `m-689@sat` (mistral)
**Action**: `r5-02-go-dead-code` (eliminate dead code and comments that lie in Go)
**Sites**:
- `api:internal/hubclient/hubclient.go:590-592` (`Session.Lost`)
- `api:internal/cicdlogs/cicdlogs.go:529-533` (`DumpJSON`)
- `api:internal/action/action.go:116-121` (`Send`)
- `api:internal/notify/notify.go:66-68` (lying comment)

**Test**: `go test ./internal/hubclient/ ./internal/cicdlogs/ ./internal/action/ ./internal/notify/`

---

## Findings

### 1. `hubclient/hubclient.go:590-592` (`Session.Lost`)
- **No such function exists** in the file. The lines at 590-592 are:
  ```go
  func (s *Session) Done() <-chan struct{} { return s.done }
  ```
- The **`keepaliveLost`** field (line 102) and its callback (line 525) are used in tests (`lost_session_test.go`), but no `Session.Lost` function exists.
- **Conclusion**: This is a **false positive** in the plan. No dead code to remove.

---

### 2. `cicdlogs/cicdlogs.go:529-533` (`DumpJSON`)
- **`DumpJSON` is a test helper** defined in `cicdlogs_helpers_test.go` (line 8):
  ```go
  // DumpJSON is a test helper (compact).
  func DumpJSON(v any) string {
      b, _ := json.Marshal(v)
      return string(b)
  }
  ```
- It is **only used in tests** (`cicdlogs_test.go`).
- **Conclusion**: This is **not dead code**. It is a test helper and should remain in `_test.go`.

---

### 3. `action/action.go:116-121` (`Send`)
- **`Send` is a deprecated test helper** defined in `action_helpers_test.go` (line 16):
  ```go
  // Deprecated: use SendCtx instead.
  func Send(cfg *config.Config, in SendArgs) (SendResult, error) {
      return SendCtx(context.Background(), cfg, in)
  }
  ```
- It is **only used in tests** (`send_test.go`, `filler_test.go`, `tail_test.go`, `fileid_test.go`).
- **Conclusion**: This is **not dead code**. It is a test helper and should remain in `_test.go`.

---

### 4. `notify/notify.go:66-68` (lying comment)
- **Comment at line 70**:
  ```go
  // Queue.Stop() closes the lanes and waits for queued pokes to drain, but does not
  // interrupt a running notifier.
  ```
- **Test result**: The test `TestQueueStopDoesNotInterruptRunningNotifier` confirms the comment is **correct**. `Queue.Stop()` does not interrupt a running notifier.
- **Conclusion**: The comment is **not lying**. No change required.

---

## Summary
- **No dead code** was found in the proposed sites.
- **`Session.Lost`** does not exist (false positive).
- **`DumpJSON`** and **`Send`** are test helpers and should remain in `_test.go`.
- The **`Queue.Stop()`** comment is correct.

**Proposal**: No changes to the codebase. The plan's action 02 is **not applicable** to the mistral seat.

**Next step**: Send `SIGN 49e21c570` to `c-687` with `--task d925`.