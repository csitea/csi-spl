package store

import (
	"context"
	"crypto/ed25519"
	"encoding/base64"
	"fmt"
	"slices"
	"strings"
	"sync/atomic"
)

// The expected box locks (spec 025 box-owner-lock.md section 6.4, row B6,
// SPL-3014). cnf hub.box_locks_expected lists every locked box with its
// K_lock public half; the hub gets it as SPOOL_HUB_BOX_LOCKS_EXPECTED. A
// listed box is served only with a verified box_locks row that carries that
// lock_pubkey: a missing row (deleted in the database) or a row under another
// key loads as Tampered, so every check of rows B2, B3 and B5 refuses every
// human and the box's hello. Removing a lock by deleting its row therefore
// needs a cnf commit on trunk too, visible in git history.

// BoxLockExpectedPath is the audit path of a listed box with no matching row.
const BoxLockExpectedPath = "expected"

// ExpectedBoxLock is one entry of hub.box_locks_expected.
type ExpectedBoxLock struct {
	TenantID   string
	BoxID      string
	LockPubKey string
}

// ParseExpectedBoxLocks reads SPOOL_HUB_BOX_LOCKS_EXPECTED: entries
// "<tenant>:<box>:<lock_pubkey>" joined with commas, the key standard base64
// of an Ed25519 public key. Empty is none. A malformed entry is an error, so
// a typo never leaves a box unchecked.
func ParseExpectedBoxLocks(s string) ([]ExpectedBoxLock, error) {
	var out []ExpectedBoxLock
	seen := map[[2]string]bool{}
	for _, e := range strings.Split(s, ",") {
		if e = strings.TrimSpace(e); e == "" {
			continue
		}
		p := strings.Split(e, ":")
		if len(p) != 3 || checkTenant(p[0]) != nil || p[1] == "" {
			return nil, fmt.Errorf("box_locks_expected: %q is not <tenant>:<box>:<lock_pubkey>", e)
		}
		if k, err := base64.StdEncoding.DecodeString(p[2]); err != nil || len(k) != ed25519.PublicKeySize {
			return nil, fmt.Errorf("box_locks_expected: %s:%s lock_pubkey is not a base64 Ed25519 key", p[0], p[1])
		}
		key := [2]string{p[0], p[1]}
		if seen[key] {
			return nil, fmt.Errorf("box_locks_expected: %s:%s is listed twice", p[0], p[1])
		}
		seen[key] = true
		out = append(out, ExpectedBoxLock{TenantID: p[0], BoxID: p[1], LockPubKey: p[2]})
	}
	return out, nil
}

// BoxLockExpecter is implemented by Memory and Postgres.
type BoxLockExpecter interface {
	// ExpectBoxLocks replaces the list of expected locks (hub start).
	ExpectBoxLocks(exp []ExpectedBoxLock)
}

var (
	_ BoxLockExpecter = (*Memory)(nil)
	_ BoxLockExpecter = (*Postgres)(nil)
)

// expectedBoxLocks holds the list, read on every lock load.
type expectedBoxLocks struct {
	m atomic.Pointer[map[[2]string]string]
}

func (e *expectedBoxLocks) set(exp []ExpectedBoxLock) {
	m := make(map[[2]string]string, len(exp))
	for _, x := range exp {
		m[[2]string{x.TenantID, x.BoxID}] = x.LockPubKey
	}
	e.m.Store(&m)
}

// want answers the lock_pubkey cnf expects for the box, "" when unlisted.
func (e *expectedBoxLocks) want(tenant, box string) string {
	if m := e.m.Load(); m != nil {
		return (*m)[[2]string{tenant, box}]
	}
	return ""
}

// apply holds a loaded lock (nil = no row) to the list. A listed box with
// no row, or with a row under another lock_pubkey, comes back Tampered:
// locked to nobody. bad reports that the expectation failed, for the
// caller's one tampered audit row (path BoxLockExpectedPath).
func (e *expectedBoxLocks) apply(tenant, box string, l *BoxLock) (out *BoxLock, bad bool) {
	want := e.want(tenant, box)
	switch {
	case want == "":
		return l, false
	case l == nil:
		return &BoxLock{TenantID: tenant, BoxID: box, LockPubKey: want, Tampered: true}, true
	case l.LockPubKey != want:
		l.Tampered = true
		return l, true
	}
	return l, false
}

// withListed merges the tenant's listed boxes into LockedBoxes' answer, so
// the view points read a listed box's lock even when its row is gone.
func (e *expectedBoxLocks) withListed(tenant string, ids []string) []string {
	m := e.m.Load()
	if m == nil {
		return ids
	}
	for k := range *m {
		if k[0] == tenant && !slices.Contains(ids, k[1]) {
			ids = append(ids, k[1])
		}
	}
	slices.Sort(ids)
	return ids
}

func expectedAudit(tenant, box string) BoxLockAudit {
	return BoxLockAudit{TenantID: tenant, BoxID: box, Path: BoxLockExpectedPath, Verdict: BoxLockTamperedRow}
}

// ExpectBoxLocks implements BoxLockExpecter.
func (s *Memory) ExpectBoxLocks(exp []ExpectedBoxLock) { s.expectLocks.set(exp) }

// ExpectBoxLocks implements BoxLockExpecter. The lock caches are cleared, so
// no lock read under the old list is served.
func (s *Postgres) ExpectBoxLocks(exp []ExpectedBoxLock) {
	s.expectLocks.set(exp)
	s.locks.forget()
}

// CheckExpectedBoxLocks loads each expected lock once (the hub start check)
// and answers the listed boxes it refuses: those with no verified row under
// the listed lock_pubkey. The first load error is returned.
func CheckExpectedBoxLocks(ctx context.Context, ls BoxLockStore, exp []ExpectedBoxLock) (refused []ExpectedBoxLock, err error) {
	for _, x := range exp {
		l, err := ls.BoxLock(ctx, x.TenantID, x.BoxID)
		if err != nil {
			return refused, err
		}
		if l == nil || l.Tampered || l.LockPubKey != x.LockPubKey {
			refused = append(refused, x)
		}
	}
	return refused, nil
}
