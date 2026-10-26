# Spec 154 v1.2: claude review seat verdict

Seat: c-771 (claude), the one cross-vendor review seat for the v1.2 draft.
Issue: SPL-3456 (the editor's). Spec under review: `spec.md` at
`5915c91b3` (`git log -1 --format=%h origin/master -- spec.md` ->
`5915c91b3`), checked on the tree `origin/master` = `0c838c4f1`, against the
landed B2 code (`a4b9b1187`) on that same tree.

Verdict: **NOT SIGNED.** Four rows are WRONG (W1-W4, section 2); the rest
is OK. W1 and W2 decide whether B8a is buildable as written; W3 and W4 are
one-line folds. Paths below are under
`csi-spl-api/src/go/spool-hub-api/internal/store/` unless they say
otherwise; "spec" is `csi-spl-doc/specs/154-contacts-section/spec.md`.

## 1. Checks

| # | check | verdict | evidence on `0c838c4f1` |
|---|---|---|---|
| 1 | spec sha | OK | spec last changed at `5915c91b3`; nothing later |
| 2 | B8a claim under `asOperator`, joining `gcal_connections` `status = 'connected'` | OK | the 149 claim is that shape: `gcal_postgres.go:138-143` (`asOperator`, `status = 'connected'`, `sync_lease_until`, `FOR UPDATE SKIP LOCKED`); `rdb/0226_contacts.sql:144` has the FK `(tenant_id, human_id) -> gcal_connections`, so the join is on the FK columns |
| 3 | the fencing token needs no new column | OK | 149's token is the stored lease end (`gcal.go:21-25`, `GcalLease.Until` `gcal.go:110-117`); `0226_contacts.sql:151` has `sync_lease_until timestamptz NULL` |
| 4 | B8a renewal and finish "under `asOperator`" | **WRONG (W1)** | section 2 |
| 5 | B8a names every store write B8 needs (B8 keeps no store file) | **WRONG (W2)** | section 2 |
| 6 | B8a personal contact methods under `inPerson`, link fields | OK, wording in W2 | B2 writes no link field: `personal_contacts_postgres.go:149` inserts `(person_id, first_name, last_name, email, phone, created_at, updated_at)`; `ContactPatch` (`personal_contacts.go:78-83`) has the four values only. So B8a must add new `inPerson` methods, and it says so |
| 7 | new `inPerson` names in `personCallers` | OK, note N1 | `personal_scope_test.go:24` "must come from the authenticated human session only"; precedent for a non-session person: `appendRealmReceipts` (`:33`, the leaver) |
| 8 | B8a test cell | **WRONG (W3)** | spec:865 holds `'TestOperatorScopeCallers\|TestPersonScopeCallers'` with a bare pipe inside a table row |
| 9 | B2's `operatorCallers` entries | OK, cite **WRONG (W4)** | `operator_scope_test.go:25` `"ContactsSyncOf"`, `:26` `"MarkContactsPurgePending"`; `git show --stat a4b9b1187` -> `operator_scope_test.go \| 2 +`; the only `asOperator` calls in B2's files: `contacts_sync_postgres.go:105` (`asOperatorQuery`, ContactsSyncOf) and `:125` (MarkContactsPurgePending) |
| 10 | B8: after B3, B7, B8a; no store file; cases lose what moved | OK | spec:871 files are `hub/`, `gcal/`, `config.go`, `hub_gcal.go`, `server.go` only; "after" = `B3, B7, B8a`; cases `C12, C15-C23f`; spec:882 order text agrees |
| 11 | section 5: C23g to B8a, new C23h, C23i, store-level, red controls can fail | OK, note N2 | spec:827-829. C23h's control fails on a claim without the join (a disconnected row is returned); C23i's fails on a write that ignores the token. C23h's skip list needs "in backoff": W2 |
| 12 | files disjoint (B8a and B2 share files only in order) | OK | B4 calls B2's memory hook and edits only `humans_rbac.go` and test files (spec:867, 887); B5 calls B2's search method, no store edit (spec:868); B1's store files are test files B8a does not list (spec:863) |
| 13 | row count, section 10, version line | OK | `grep -c` of the build-row lines in spec section 6 -> 13; spec:856-859 "becomes thirteen"; spec:992 section 10 row; spec:994 `1.2-draft`; header spec:3-8 |

## 2. WRONG rows to fold

**W1 (B8a, spec:865; C23i, spec:829): renewal and finish are not
`asOperator`.** Spec 2.5 says the claim, the fencing token and the per-page
renewal "are 149 2.5's, applied to `contacts_sync`" (spec:303-304), and the
three scopes put only the claim in the operator scope (spec:310-311). In
149 every fenced write runs in the lease's workspace scope:
`gcalFenced` = `s.inTenant(ctx, l.Tenant, …)` (`gcal_postgres.go:174-175`),
used by `RenewGcalLease` (`:204-207`) and `FinishGcalSync` (`:287-290`).
It also breaks the row's own count: `TestOperatorScopeCallers` flags every
function that calls `asOperator` (`operator_scope_test.go:144-146`), so a
claim, a renewal and a finish under `asOperator` need three new entries,
not "the third `operatorCallers` entry for the claim". `contacts_sync`'s
`tenant_scope` policy (`0226_contacts.sql:162-164`) admits the write in
the binding's workspace. Fold: "the claim under `asOperator`; the lease
renewal, the finish and every other fenced write in the binding's
workspace scope (`inTenant(lease.Tenant)`, as `gcalFenced`); one new
`operatorCallers` entry, the claim".

**W2 (B8a, spec:865; C23h, spec:828): B8a omits store writes B8 needs.**
B8 now "keeps no store file" (spec:871, 882), so every store method of the
cycle has to be B8a's, or B8 cannot be built. Two are not named:

- the backoff and status line: `contacts_sync` has `backoff_until` and
  `status_detail` (`0226_contacts.sql:152-153`); C21 (spec:819, row B8)
  expects "`backoff_until` set" after a 429. B8a must name the fenced write
  of `backoff_until` + `status_detail` (or carry them in the finish), and
  the claim must skip a row with `backoff_until > now`; C23h's
  "disconnected, unenabled or lease-held rows skipped" gets "or in backoff".
- the reads of the outbound half: the row says the cycle's personal
  contact "writes", but C23g says "reads and writes" (spec:827) and the
  outbound half reads the contacts changed since `out_cursor`, the
  soft-deleted ones whose Google delete is pending, then hard-deletes them
  once Google confirms. Name them, and `google_etag` with the link fields
  (`0226_contacts.sql:75`; the row names only `google_resource`,
  `google_account`).

**W3 (B8a, spec:865): escape the pipe.** The test cell's `-run` pattern
`TestOperatorScopeCallers|TestPersonScopeCallers` is written with a bare
pipe, which splits the table row in GFM. B1's row escapes it with a
backslash (spec:863, `'TestRLS\|TestCrossTenant'`).

**W4 (B2, spec:864): the cited sha is not on master.** "as built on
`1ab36063d`": `git branch -r --contains 1ab36063d` ->
`origin/review/s154-b2-contacts-store` only. The landed B2 is
`a4b9b1187`, as the header says (spec:6). Fold: cite `a4b9b1187`.

## 3. Notes (no fold needed)

- **N1**: the B8a `personCallers` reasons should say the person is the
  binding's `contacts_sync.human_id` from the operator claim, not a
  session, since `personal_scope_test.go:24` asks for a session person
  (precedent `appendRealmReceipts`, `:33`).
- **N2**: C23g says "a cycle"; at B8a there is no cycle yet (B8's hub
  code). Read at store level, it is "the cycle's store methods under the
  operator scope read 0 rows of `personal.contacts`"; testable as written.

## 4. Re-check after the fold

Only W1-W4, in my own message on task `bd49b4c7`, then this file gets a
section 5 with the sign.

## 5. Re-check of the fold: SIGNED

Re-checked W1-W4 only, on `spec.md` at `60904da23` (the editor a-870's
fold; `git log -1 --format=%h origin/master -- spec.md` -> `60904da23`):

| # | verdict | line on `60904da23` |
|---|---|---|
| W1 | OK | B8a: "the claim under `asOperator` … the lease renewal, finish, and the fenced write of `backoff_until` + `status_detail` in the binding's workspace scope, `inTenant(lease.Tenant)`, as `gcalFenced`"; "one new `operatorCallers` entry, the claim"; C23i: "in the binding's workspace scope (`inTenant(lease.Tenant)`)" |
| W2 | OK | B8a: "skipping `backoff_until > now`", the fenced `backoff_until` + `status_detail` write, "outbound reads changed since `out_cursor`, soft-deleted pending Google delete, hard delete after Google confirms, and link fields `google_account`, `google_resource`, `google_etag`"; C23h: "lease-held or in-backoff rows skipped" |
| W3 | OK | B8a test cell: `'TestOperatorScopeCallers\|TestPersonScopeCallers'`; the B1, B2, B8a and B8 rows each count 9 cell pipes once the escaped ones are dropped |
| W4 | OK | B2: "as built on `a4b9b1187`"; `1ab36063d` is left only in the section 10 row that records this seat's finding |

**SIGNED v1.2 at `60904da23`** (seat claude, c-771). Notes N1 and N2 stay
notes for the B8a builder.
