package keyd

import (
	"errors"
	"testing"

	"golang.org/x/sys/unix"
)

// captureWipes swaps wipeOnLockErr for one that keeps each raw slice it is
// handed before the real wipe runs, so the test can read them afterwards.
func captureWipes(t *testing.T) *[][]byte {
	t.Helper()
	var seen [][]byte
	wipeOnLockErr = func(secs []secret) {
		for i := range secs {
			seen = append(seen, secs[i].raw)
		}
		wipeSecrets(secs)
	}
	t.Cleanup(func() { wipeOnLockErr = wipeSecrets })
	return &seen
}

// Rule: an empty identity after a good one wipes the good one's locked bytes.
func TestLockIdentitiesEmptyWipesLocked(t *testing.T) {
	seen := captureWipes(t)
	agents := []AgentKey{{ID: "c-101", Identity: heapIdentity(t)}, {ID: "c-102", Identity: ""}}
	secs, err := lockIdentities(agents)
	if err == nil || err.Error() != "empty identity" {
		wipeSecrets(secs)
		t.Fatalf("empty identity: %v, want empty identity", err)
	}
	if len(*seen) != 1 {
		t.Fatalf("wiped %d locked secrets, want 1", len(*seen))
	}
	if raw := (*seen)[0]; len(raw) == 0 || !allZero(raw) {
		t.Fatal("locked identity not zeroed on the empty-identity error")
	}
}

// Rule: an mlock failure wipes the identity it failed on and every earlier
// locked one.
func TestLockIdentitiesMlockFailWipesLocked(t *testing.T) {
	seen := captureWipes(t)
	var failed []byte
	calls := 0
	mlock = func(b []byte) error {
		calls++
		if calls == 1 {
			return unix.Mlock(b)
		}
		failed = b
		return errors.New("mlock refused")
	}
	t.Cleanup(func() { mlock = unix.Mlock })
	agents := []AgentKey{{ID: "c-101", Identity: heapIdentity(t)}, {ID: "c-102", Identity: heapIdentity(t)}}
	secs, err := lockIdentities(agents)
	if err == nil || err.Error() != "could not lock the identities in memory" {
		wipeSecrets(secs)
		t.Fatalf("mlock failure: %v, want could not lock the identities in memory", err)
	}
	if len(failed) == 0 || !allZero(failed) {
		t.Fatal("identity that failed mlock not zeroed")
	}
	if len(*seen) != 1 || len((*seen)[0]) == 0 || !allZero((*seen)[0]) {
		t.Fatalf("earlier locked identity not zeroed (%d wiped)", len(*seen))
	}
}
