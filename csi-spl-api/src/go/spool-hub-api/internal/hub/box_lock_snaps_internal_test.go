package hub

import (
	"context"
	"errors"
	"testing"

	"github.com/rs/zerolog"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// lockListStore answers LockedBoxes with err (nil: no lock).
type lockListStore struct {
	store.Store
	err error
}

func (l lockListStore) LockedBoxes(context.Context, string) ([]string, error) { return nil, l.err }

// R7 D2 of row B5 (point (d): hide, never show): the live fan-out reads only
// the lock snapshot, so a workspace this instance never read, or whose last
// locks read failed, hides every frame with a box end from everyone; one
// read with no lock shows them again. A frame with no box end (human only)
// is never hidden. RED CONTROL: the old put (an empty read deletes the
// snapshot) and the old ignored error let the box frame through.
func TestLockSnapsFailClosed(t *testing.T) {
	ctx := context.Background()
	box := parties{fromID: "CLE-02", fromBox: "box-sh", toID: "ALL-0"}
	human := parties{fromID: "HUM-2", toID: "ALL-0"}
	down := &Server{o: Options{Store: lockListStore{err: errors.New("store down (test)")}, Log: zerolog.Nop()}}
	if !down.locks.hides("t1", "HUM-2", box) || down.locks.hides("t1", "HUM-2", human) {
		t.Fatal("never-read workspace: want the box frame hidden, the human frame shown")
	}
	down.locks.put("t1", map[string]*store.BoxLock{"box-own": {BoxID: "box-own", Owners: []string{"HUM-1"}}})
	if _, err := down.tenantLocks(ctx, "t1"); err == nil {
		t.Fatal("tenantLocks: want the store error")
	}
	if !down.locks.hides("t1", "HUM-1", box) {
		t.Fatal("after a failed read: want the box frame hidden (the old snapshot named only box-own)")
	}
	up := &Server{o: Options{Store: lockListStore{}, Log: zerolog.Nop()}}
	if _, err := up.tenantLocks(ctx, "t1"); err != nil {
		t.Fatal(err)
	}
	if up.locks.hides("t1", "HUM-2", box) {
		t.Fatal("CONTROL: a read with no lock: want the box frame shown")
	}
}
