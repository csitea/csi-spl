package store

import (
	"errors"
	"slices"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// Spec 160 3.10 row B13 (SPL-4979, rdb 0268): a file removed from the view, the
// store half. Memory always, Postgres with a DSN (hub-pg.tst.sh,
// PRE_PUSH_TIER=full). Red before SPL-4979: no RemoveFileStream, the package
// does not compile. The planted defects are named on each test; the red runs
// are in the commit body.

func (c fsCase) remove(t *testing.T, tid, key string) FileStream {
	t.Helper()
	f, err := c.fs.RemoveFileStream(c.ctx, tid, c.stream(t, tid, key).ID, "HUM-1", c.now)
	if err != nil {
		t.Fatal(err)
	}
	return f
}

// TestFileStreamRemoveSurvivesAnnounce (case C57): a removed key the box
// announces again stays removed and gone, and the ack says so; after a put back
// the next announce sets its state on the same row. CONTROL: an upsert that
// clears removed_at, or writes the box's state, brings the row back.
func TestFileStreamRemoveSurvivesAnnounce(t *testing.T) {
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			c := newFSCase(t, s)
			tid := c.workspace(t, "box-a")
			c.announce(t, tid, "box-a", "app", "cron")
			id := c.stream(t, tid, "app").ID
			if f := c.remove(t, tid, "app"); f.RemovedAt == nil || f.State != wire.FileStreamGone {
				t.Fatalf("after the remove = %+v", f)
			}
			ack := c.announce(t, tid, "box-a", "app", "cron")
			if ack[0].State != wire.FileStreamGone || ack[1].State != wire.FileStreamFollowing {
				t.Fatalf("the re-announce's ack = %+v, want app gone, cron following", ack)
			}
			if f := c.stream(t, tid, "app"); f.RemovedAt == nil || f.State != wire.FileStreamGone || f.ID != id {
				t.Fatalf("the removal did not survive the re-announce: %+v", f)
			}
			if f := c.stream(t, tid, "cron"); f.RemovedAt != nil || f.State != wire.FileStreamFollowing {
				t.Fatalf("CONTROL: cron = %+v, want untouched", f)
			}
			if _, err := c.fs.RestoreFileStream(c.ctx, tid, id, "HUM-1", c.now); err != nil {
				t.Fatal(err)
			}
			c.announce(t, tid, "box-a", "app", "cron")
			if f := c.stream(t, tid, "app"); f.RemovedAt != nil || f.State != wire.FileStreamFollowing || f.ID != id {
				t.Fatalf("after the put back and an announce = %+v, want following on row %s", f, id)
			}
		})
	}
}

// TestFileStreamRemoveKeepsLinesDropsPush (case C59, and item 2 of the plan: an
// older follower keeps announcing and pushing): the stored lines and their
// counts stay; a later push is acked with its highest seq and stores nothing,
// moves no count; after a put back a new push stores again. CONTROL: a remove
// that deletes the lines reads 0 kept; a refused push returns an error here,
// and the box would keep the lines queued.
func TestFileStreamRemoveKeepsLinesDropsPush(t *testing.T) {
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			c := newFSCase(t, s)
			tid := c.workspace(t, "box-a")
			c.announce(t, tid, "box-a", "app")
			if _, err := c.push(tid, "box-a", "app", fsLines(1, 3, c.now, "kept")); err != nil {
				t.Fatal(err)
			}
			before := c.stream(t, tid, "app")
			c.remove(t, tid, "app")
			if ls := c.kept(t, tid, "app"); len(ls) != 3 {
				t.Fatalf("stored lines after the remove = %d, want 3", len(ls))
			}
			// An older follower: it announces and pushes as if nothing happened.
			c.announce(t, tid, "box-a", "app")
			r, err := c.push(tid, "box-a", "app", fsLines(4, 2, c.now, "late"))
			if err != nil || r.Inserted != 0 || r.AckedSeq != 5 {
				t.Fatalf("a push after the remove = %+v %v, want acked 5, 0 stored", r, err)
			}
			after := c.stream(t, tid, "app")
			if ls := c.kept(t, tid, "app"); len(ls) != 3 || after.LinesKept != 3 || after.LinesTotal != before.LinesTotal || after.LastSeq != before.LastSeq {
				t.Fatalf("the late push moved something: %d lines, %+v", len(ls), after)
			}
			if _, err := c.fs.RestoreFileStream(c.ctx, tid, after.ID, "HUM-1", c.now); err != nil {
				t.Fatal(err)
			}
			if r, err := c.push(tid, "box-a", "app", fsLines(6, 1, c.now, "back")); err != nil || r.Inserted != 1 {
				t.Fatalf("a push after the put back = %+v %v, want 1 stored", r, err)
			}
			if ls := c.kept(t, tid, "app"); len(ls) != 4 || ls[3].Seq != 6 {
				t.Fatalf("lines after the put back = %+v, want 1, 2, 3, 6", ls)
			}
		})
	}
}

// TestFileStreamRemoveRetention (case C59): the retention sweep takes a removed
// row's old lines as any other's, and the row, so the removal, stays. CONTROL:
// a sweep that skips removed rows keeps 2 lines; one that deletes the row
// loses the removal, and the next announce would bring it back.
func TestFileStreamRemoveRetention(t *testing.T) {
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			c := newFSCase(t, s)
			sw := s.(fsTenantSweeper)
			tid := c.workspace(t, "box-a")
			c.announce(t, tid, "box-a", "app")
			if _, err := c.push(tid, "box-a", "app", fsLines(1, 2, c.now, "old")); err != nil {
				t.Fatal(err)
			}
			c.remove(t, tid, "app")
			if _, err := sw.sweepFileStreamTenant(c.ctx, tid, c.now.Add(8*24*time.Hour), c.lim); err != nil {
				t.Fatal(err)
			}
			if ls := c.kept(t, tid, "app"); len(ls) != 0 {
				t.Fatalf("lines 8 days on = %d, want 0", len(ls))
			}
			c.announce(t, tid, "box-a", "app")
			if f := c.stream(t, tid, "app"); f.RemovedAt == nil || f.State != wire.FileStreamGone {
				t.Fatalf("the removal after the sweep = %+v, want it kept", f)
			}
		})
	}
}

// TestFileStreamRemoveScopeAndAudit (cases C58, C60, store half): the same key
// on two boxes and in two workspaces, only the one row goes; each change writes
// one audit row, a second remove, a put back of a row not removed and another
// workspace's id are ErrNotFound and write none. CONTROL: a removal keyed on
// stream_key alone takes box-b's row too.
func TestFileStreamRemoveScopeAndAudit(t *testing.T) {
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			c := newFSCase(t, s)
			tid, other := c.workspace(t, "box-a"), c.workspace(t, "box-a")
			c.pinBox(t, tid, "box-b")
			c.announce(t, other, "box-a", "app")
			c.announce(t, tid, "box-a", "app")
			c.announce(t, tid, "box-b", "app")
			all, err := c.fs.ListFileStreams(c.ctx, tid)
			if err != nil || len(all) != 2 || all[0].Box != "box-a" {
				t.Fatalf("list = %+v %v", all, err)
			}
			a, b := all[0].ID, all[1].ID
			if _, err := c.fs.RemoveFileStream(c.ctx, other, a, "HUM-2", c.now); !errors.Is(err, ErrNotFound) {
				t.Fatalf("another workspace's remove: %v, want ErrNotFound", err)
			}
			if _, err := c.fs.RestoreFileStream(c.ctx, tid, a, "HUM-1", c.now); !errors.Is(err, ErrNotFound) {
				t.Fatalf("a put back of a row not removed: %v, want ErrNotFound", err)
			}
			if _, err := c.fs.RemoveFileStream(c.ctx, tid, a, "HUM-1", c.now); err != nil {
				t.Fatal(err)
			}
			if _, err := c.fs.RemoveFileStream(c.ctx, tid, a, "HUM-1", c.now); !errors.Is(err, ErrNotFound) {
				t.Fatalf("a second remove: %v, want ErrNotFound", err)
			}
			if rows := c.audit(t, tid); len(rows) != 1 || rows[0].Action != FileStreamAuditFileRemove || rows[0].Key != "app" ||
				rows[0].Glob != "/var/log/app.log" || rows[0].Box != "box-a" || rows[0].Actor != "HUM-1" || rows[0].GlobID != "" {
				t.Fatalf("audit = %+v, want one file_remove row", rows)
			}
			if rows := c.audit(t, other); len(rows) != 0 {
				t.Fatalf("the other workspace's audit = %+v, want none", rows)
			}
			for _, x := range []struct {
				tenant, box string
				want        []string
			}{{tid, "box-a", []string{"app"}}, {tid, "box-b", []string{}}, {other, "box-a", []string{}}} {
				if got, err := c.fs.RemovedFileStreamKeys(c.ctx, x.tenant, x.box); err != nil || !slices.Equal(got, x.want) {
					t.Errorf("removed keys of %s = %v %v, want %v", x.box, got, err, x.want)
				}
			}
			all, err = c.fs.ListFileStreams(c.ctx, tid)
			if err != nil || all[1].ID != b || all[1].RemovedAt != nil || all[1].State != wire.FileStreamFollowing {
				t.Fatalf("box-b's row = %+v %v, want untouched", all, err)
			}
			if _, err := c.fs.RestoreFileStream(c.ctx, tid, a, "HUM-3", c.now.Add(time.Second)); err != nil {
				t.Fatal(err)
			}
			if rows := c.audit(t, tid); len(rows) != 2 || rows[0].Action != FileStreamAuditFileRestore || rows[0].Actor != "HUM-3" {
				t.Fatalf("audit after the put back = %+v", rows)
			}
		})
	}
}
