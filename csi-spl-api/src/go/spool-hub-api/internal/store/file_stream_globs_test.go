package store

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// Spec 160 row B9 (SPL-4294, rdb 0242): the web glob store. Memory always,
// Postgres with a DSN (hub-pg.tst.sh, PRE_PUSH_TIER=full). Red on
// origin/master before SPL-4294: no FileStreamGlobStore, the package does
// not compile. The per-case red controls are named on each test.

func (c fsCase) globs() FileStreamGlobStore { return c.s.(FileStreamGlobStore) }

func (c fsCase) addGlob(tid, box, key, glob string, max int) (FileStreamGlob, error) {
	return c.globs().AddFileStreamGlob(c.ctx, tid, FileStreamGlobAdd{Box: box, Key: key, Glob: glob, Actor: "HUM-1", Max: max}, c.now)
}

func (c fsCase) audit(t *testing.T, tid string) []FileStreamGlobAuditRow {
	t.Helper()
	rows, err := c.globs().FileStreamGlobAudit(c.ctx, tid, nil, 0)
	if err != nil {
		t.Fatal(err)
	}
	return rows
}

// TestFileStreamGlobStoreAddRemove (cases C43 and C45, store half): an add
// stores a pending live glob and one add audit row; a taken key and a full
// box are refused with nothing stored; a remove frees the key and the slot
// and writes one remove row; a second remove is ErrNotFound and writes none.
// CONTROL: a count that took removed globs in would refuse the add after
// the remove as full.
func TestFileStreamGlobStoreAddRemove(t *testing.T) {
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			c := newFSCase(t, s)
			tid := c.workspace(t, "box-a")
			g, err := c.addGlob(tid, "box-a", "app", "/var/log/app*.log", 2)
			if err != nil || g.State != wire.FileStreamGlobPending || g.Box != "box-a" || g.CreatedBy != "HUM-1" || g.RemovedAt != nil {
				t.Fatalf("add = %+v %v", g, err)
			}
			if _, err := c.addGlob(tid, "box-a", "app", "/var/log/x", 2); !errors.Is(err, ErrFileStreamGlobKeyTaken) {
				t.Fatalf("taken key: %v, want ErrFileStreamGlobKeyTaken", err)
			}
			if _, err := c.addGlob(tid, "box-a", "cron", "/var/log/cron*", 2); err != nil {
				t.Fatal(err)
			}
			if _, err := c.addGlob(tid, "box-a", "third", "/var/log/z", 2); !errors.Is(err, ErrFileStreamGlobsFull) {
				t.Fatalf("a 3rd of max 2: %v, want ErrFileStreamGlobsFull", err)
			}
			if _, err := c.addGlob(tid, "box-none", "app", "/var/log/z", 2); !errors.Is(err, ErrNotFound) {
				t.Fatalf("a box with no row: %v, want ErrNotFound", err)
			}
			if _, err := c.globs().RemoveFileStreamGlob(c.ctx, tid, g.ID, "HUM-2", c.now); err != nil {
				t.Fatal(err)
			}
			if _, err := c.globs().RemoveFileStreamGlob(c.ctx, tid, g.ID, "HUM-2", c.now); !errors.Is(err, ErrNotFound) {
				t.Fatalf("second remove: %v, want ErrNotFound", err)
			}
			if _, err := c.addGlob(tid, "box-a", "app", "/var/log/app2*.log", 2); err != nil {
				t.Fatalf("CONTROL: the removed glob's key and slot are free again: %v", err)
			}
			rows := c.audit(t, tid)
			var adds, removes int
			for _, a := range rows {
				switch a.Action {
				case FileStreamGlobAuditAdd:
					adds++
				case FileStreamGlobAuditRemove:
					removes++
					if a.Actor != "HUM-2" || a.GlobID != g.ID {
						t.Errorf("remove row = %+v", a)
					}
				}
			}
			if adds != 3 || removes != 1 || len(rows) != 4 {
				t.Fatalf("audit = %d rows, %d adds, %d removes; want 4, 3, 1: %+v", len(rows), adds, removes, rows)
			}
		})
	}
}

// TestFileStreamGlobStoreRefusalAudit (case C45, store half): a refused add
// is one row with its reason, no glob id, its text cut to what the table
// keeps (a control character and 700 bytes from the browser); the page is
// newest first and before pages back. CONTROL: an uncut glob of 700 bytes
// with a NUL would not insert on Postgres.
func TestFileStreamGlobStoreRefusalAudit(t *testing.T) {
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			c := newFSCase(t, s)
			tid := c.workspace(t, "box-a")
			junk := "/var/log/\x00" + string(make([]byte, 700))
			for i, reason := range []string{"bad_glob", "outside_folders"} {
				if err := c.globs().AuditFileStreamGlobRefusal(c.ctx, tid, FileStreamGlobAuditRow{Box: "box-a", Key: "k", Glob: junk,
					Actor: "HUM-1", Reason: reason, At: c.now.Add(time.Duration(i) * time.Second)}); err != nil {
					t.Fatal(err)
				}
			}
			rows := c.audit(t, tid)
			if len(rows) != 2 || rows[0].Reason != "outside_folders" || rows[0].Action != FileStreamGlobAuditRefused || rows[0].GlobID != "" ||
				len(rows[0].Glob) > fileStreamAuditTextMax {
				t.Fatalf("refusal rows = %+v", rows)
			}
			before := rows[0].At
			older, err := c.globs().FileStreamGlobAudit(c.ctx, tid, &before, 10)
			if err != nil || len(older) != 1 || older[0].Reason != "bad_glob" {
				t.Fatalf("before page = %+v %v", older, err)
			}
			n, err := c.globs().PruneFileStreamGlobAudit(c.ctx, c.now.Add(time.Second))
			if err != nil || n < 1 {
				t.Fatalf("prune = %d %v", n, err)
			}
			if rows := c.audit(t, tid); len(rows) != 1 || rows[0].Reason != "outside_folders" {
				t.Fatalf("after the prune = %+v", rows)
			}
		})
	}
}

// TestFileStreamGlobStorePullAndReport (case C46, store half; 3.8.5): a
// box's pull lists its live globs in its workspace only, oldest first; a
// report sets the state of that box's glob only and replaces its folders;
// a report with nil folders leaves them. CONTROL: a pull by box alone
// would return W2's box-a glob.
func TestFileStreamGlobStorePullAndReport(t *testing.T) {
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			c := newFSCase(t, s)
			tid, tid2 := c.workspace(t, "box-a"), c.workspace(t, "box-a")
			c.pinBox(t, tid, "box-b")
			a1, _ := c.addGlob(tid, "box-a", "one", "/var/log/one*", 8)
			b1, _ := c.addGlob(tid, "box-b", "one", "/var/log/one*", 8)
			w2, _ := c.addGlob(tid2, "box-a", "two", "/var/log/two*", 8)
			gone, _ := c.addGlob(tid, "box-a", "gone", "/var/log/gone*", 8)
			if _, err := c.globs().RemoveFileStreamGlob(c.ctx, tid, gone.ID, "HUM-1", c.now); err != nil {
				t.Fatal(err)
			}
			got, err := c.globs().BoxFileStreamGlobs(c.ctx, tid, "box-a")
			if err != nil || len(got) != 1 || got[0].ID != a1.ID {
				t.Fatalf("pull of box-a in W = %+v %v, want only %s", got, err, a1.ID)
			}
			folders := []wire.FileStreamFolderReport{{Path: "/var/log", State: wire.FileStreamFolderAllowed}, {Path: "/etc", State: wire.FileStreamFolderRefused, Reason: "too short"}}
			report := []wire.FileStreamGlobReport{
				{ID: a1.ID, State: wire.FileStreamGlobPartial, Matched: 12, Followed: 6, OverCap: 6},
				{ID: b1.ID, State: wire.FileStreamGlobRefused, Reason: "not mine"},
				{ID: w2.ID, State: wire.FileStreamGlobRefused, Reason: "not mine"},
			}
			if err := c.globs().ReportFileStreamGlobs(c.ctx, tid, "box-a", folders, report, c.now); err != nil {
				t.Fatal(err)
			}
			list, fs, err := c.globs().ListFileStreamGlobs(c.ctx, tid)
			if err != nil || len(list) != 2 || len(fs) != 2 || fs[0].Path != "/etc" || fs[1].State != wire.FileStreamFolderAllowed {
				t.Fatalf("list = %+v %+v %v", list, fs, err)
			}
			for _, g := range list {
				if g.ID == a1.ID && (g.State != wire.FileStreamGlobPartial || g.Matched != 12 || g.OverCap != 6 || g.ReportedAt == nil) {
					t.Errorf("box-a's glob after the report = %+v", g)
				}
				if g.ID == b1.ID && g.State != wire.FileStreamGlobPending {
					t.Errorf("box-b's glob took box-a's report: %+v", g)
				}
			}
			if l2, _, _ := c.globs().ListFileStreamGlobs(c.ctx, tid2); len(l2) != 1 || l2[0].State != wire.FileStreamGlobPending {
				t.Errorf("W2's glob took W's box-a report: %+v", l2)
			}
			if err := c.globs().ReportFileStreamGlobs(c.ctx, tid, "box-a", nil, nil, c.now); err != nil {
				t.Fatal(err)
			}
			known, kept, err := c.globs().FileStreamBoxFolders(c.ctx, tid, "box-a")
			if err != nil || !known || len(kept) != 2 {
				t.Fatalf("nil folders kept them? known %v %+v %v", known, kept, err)
			}
			if known, _, _ := c.globs().FileStreamBoxFolders(c.ctx, tid, "box-b"); known {
				t.Errorf("box-b announced nothing, yet known")
			}
		})
	}
}

// TestFileStreamGlobStoreCrossTenant (case C42, store half): W2 removes
// W's glob id: ErrNotFound, no audit row in either. CONTROL: W removes it.
func TestFileStreamGlobStoreCrossTenant(t *testing.T) {
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			c := newFSCase(t, s)
			tid, tid2 := c.workspace(t, "box-a"), c.workspace(t, "box-a")
			g, err := c.addGlob(tid, "box-a", "app", "/var/log/app*", 8)
			if err != nil {
				t.Fatal(err)
			}
			if _, err := c.globs().RemoveFileStreamGlob(c.ctx, tid2, g.ID, "HUM-9", c.now); !errors.Is(err, ErrNotFound) {
				t.Fatalf("W2 removes W's glob: %v, want ErrNotFound", err)
			}
			if len(c.audit(t, tid2)) != 0 || len(c.audit(t, tid)) != 1 {
				t.Fatalf("audit after W2's try: W2 %d, W %d rows; want 0, 1", len(c.audit(t, tid2)), len(c.audit(t, tid)))
			}
			if _, err := c.globs().RemoveFileStreamGlob(c.ctx, tid, g.ID, "HUM-1", c.now); err != nil {
				t.Fatalf("CONTROL: W removes its glob: %v", err)
			}
		})
	}
}

// TestFileStreamGlobRLSTenantless (C30's shape for rdb 0242): a statement
// without a tenant reads 0 rows of the three tables, another tenant's
// scope reads 0, its own reads them. TestRLSCoversEveryTenantTable holds
// ENABLE + FORCE. CONTROL: with RLS off (rolled back) the tenantless read
// counts the rows.
func TestFileStreamGlobRLSTenantless(t *testing.T) {
	pg := rlsStore(t)
	c := newFSCase(t, pg)
	tid, other := c.workspace(t, "box-a"), c.workspace(t, "box-b")
	if _, err := c.addGlob(tid, "box-a", "app", "/var/log/app*", 8); err != nil {
		t.Fatal(err)
	}
	if err := c.globs().ReportFileStreamGlobs(c.ctx, tid, "box-a", []wire.FileStreamFolderReport{{Path: "/var/log", State: wire.FileStreamFolderAllowed}}, nil, c.now); err != nil {
		t.Fatal(err)
	}
	ctx := context.Background()
	count := func(tx pgx.Tx, table string) int {
		var n int
		if err := tx.QueryRow(ctx, `SELECT count(*) FROM `+table+` WHERE tenant_id = $1`, tid).Scan(&n); err != nil {
			t.Fatal(err)
		}
		return n
	}
	for _, table := range []string{"file_stream_globs", "file_stream_glob_audit", "file_stream_folders"} {
		err := pgx.BeginFunc(ctx, pg.pool, func(tx pgx.Tx) error {
			if n := count(tx, table); n != 0 {
				t.Errorf("%s: a tenantless read sees %d rows", table, n)
			}
			if _, err := tx.Exec(ctx, pgScopeTenant, other); err != nil {
				return err
			}
			if n := count(tx, table); n != 0 {
				t.Errorf("%s: another tenant's scope sees %d rows", table, n)
			}
			if _, err := tx.Exec(ctx, pgScopeTenant, tid); err != nil {
				return err
			}
			if n := count(tx, table); n == 0 {
				t.Errorf("%s: the tenant's own scope sees no row (the seed did not land)", table)
			}
			return nil
		})
		if err != nil {
			t.Fatal(err)
		}
		_ = pgx.BeginFunc(ctx, pg.pool, func(tx pgx.Tx) error {
			if _, err := tx.Exec(ctx, `ALTER TABLE `+table+` NO FORCE ROW LEVEL SECURITY; ALTER TABLE `+table+` DISABLE ROW LEVEL SECURITY`); err != nil {
				t.Fatalf("control: %v", err)
			}
			if n := count(tx, table); n == 0 {
				t.Errorf("control: %s without RLS still reads 0, the check proves nothing", table)
			}
			return errors.New("roll back")
		})
	}
}
