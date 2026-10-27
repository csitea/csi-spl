package store

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// Spec 160 row B2 (SPL-3888, rdb 0236): the file streams store. Memory
// always, Postgres with a DSN (hub-pg.tst.sh, PRE_PUSH_TIER=full). Red on
// origin/master before SPL-3888: no FileStreamStore, the package does not
// compile. The per-case red controls are named on each test.

type fsCase struct {
	ctx context.Context
	s   Store
	fs  FileStreamStore
	now time.Time
	lim FileStreamLimits
}

func newFSCase(t *testing.T, s Store) fsCase {
	t.Helper()
	// MaxWorkspaces high: the Postgres test database holds other runs'
	// streams; TestFileStreamMaxWorkspaces measures them first.
	return fsCase{ctx: context.Background(), s: s, fs: s.(FileStreamStore), now: time.Now().UTC().Truncate(time.Second),
		lim: FileStreamLimits{MaxWorkspaces: 1 << 20}}
}

// workspace is a new tenant with box pinned and seen (its hello's
// TouchBox writes the boxes row the streams hang on).
func (c fsCase) workspace(t *testing.T, box string) string {
	t.Helper()
	tid := newTenant(t, c.s)
	c.pinBox(t, tid, box)
	return tid
}

func (c fsCase) pinBox(t *testing.T, tid, box string) {
	t.Helper()
	if err := c.s.PutPin(c.ctx, tid, box, pubkey(), false, c.now, c.now); err != nil {
		t.Fatal(err)
	}
	if err := c.s.TouchBox(c.ctx, tid, box, c.now); err != nil {
		t.Fatal(err)
	}
}

func (c fsCase) announce(t *testing.T, tid, box string, keys ...string) []wire.FileStreamAckState {
	t.Helper()
	in := make([]wire.FileStreamAnnounced, len(keys))
	for i, k := range keys {
		in[i] = wire.FileStreamAnnounced{StreamKey: k, Path: "/var/log/" + k + ".log", State: wire.FileStreamFollowing}
	}
	out, err := c.fs.AnnounceFileStreams(c.ctx, tid, box, in, c.lim, c.now)
	if err != nil {
		t.Fatal(err)
	}
	return out
}

// lines is n lines of seq from..from+n-1, at is the time of each.
func fsLines(from int64, n int, at time.Time, text string) []wire.FileStreamLine {
	out := make([]wire.FileStreamLine, n)
	for i := range out {
		out[i] = wire.FileStreamLine{Seq: from + int64(i), At: at, Text: fmt.Sprintf("%s %d", text, from+int64(i))}
	}
	return out
}

func (c fsCase) push(tid, box, key string, ls []wire.FileStreamLine) (FileStreamPushResult, error) {
	return c.fs.RecordFileStreamLines(c.ctx, tid, box, wire.FileStreamsPushFrame{StreamKey: key, Lines: ls,
		Dropped: 2, Redactions: map[string]int64{"github-token": 1}}, c.lim, c.now)
}

func (c fsCase) stream(t *testing.T, tid, key string) FileStream {
	t.Helper()
	all, err := c.fs.ListFileStreams(c.ctx, tid)
	if err != nil {
		t.Fatal(err)
	}
	for _, f := range all {
		if f.StreamKey == key {
			return f
		}
	}
	t.Fatalf("no stream %s in %s: %+v", key, tid, all)
	return FileStream{}
}

func (c fsCase) kept(t *testing.T, tid, key string) []FileStreamLine {
	t.Helper()
	ls, err := c.fs.FileStreamLines(c.ctx, tid, c.stream(t, tid, key).ID, FileStreamLinesQuery{})
	if err != nil {
		t.Fatal(err)
	}
	return ls
}

// TestFileStreamAnnounceAndPush: an announce stores the keys, a push stores
// its lines once (a re-send writes nothing, case C10's hub half), counts
// add up, a key no longer announced turns gone, and the keys past PerBox
// are refused. CONTROL: an ON CONFLICT that stored twice would read 6
// lines after the re-send.
func TestFileStreamAnnounceAndPush(t *testing.T) {
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			c := newFSCase(t, s)
			tid := c.workspace(t, "box-a")
			if got := c.announce(t, tid, "box-a", "app", "cron"); got[0].State != wire.FileStreamFollowing || got[1].Reason != "" {
				t.Fatalf("announce = %+v", got)
			}
			if _, err := c.push(tid, "box-a", "nope", fsLines(1, 1, c.now, "x")); !errors.Is(err, ErrFileStreamUnknown) {
				t.Fatalf("unannounced push: %v, want ErrFileStreamUnknown", err)
			}
			for i := 0; i < 2; i++ {
				r, err := c.push(tid, "box-a", "app", fsLines(1, 3, c.now, "line"))
				if err != nil || r.AckedSeq != 3 || r.Inserted != 3-3*i {
					t.Fatalf("push %d: %+v %v", i, r, err)
				}
			}
			if ls := c.kept(t, tid, "app"); len(ls) != 3 || ls[0].Text != "line 1" || ls[2].Seq != 3 {
				t.Fatalf("kept = %+v", ls)
			}
			f := c.stream(t, tid, "app")
			if f.LinesTotal != 3 || f.LinesKept != 3 || f.LastSeq != 3 || f.LinesDropped != 4 || f.Redactions["github-token"] != 2 ||
				f.BytesKept != int64(len("line 1")*3) || f.LastLineAt == nil || !f.LastLineAt.Equal(c.now) {
				t.Fatalf("stream = %+v", f)
			}
			c.announce(t, tid, "box-a", "app")
			if g := c.stream(t, tid, "cron"); g.State != wire.FileStreamGone {
				t.Fatalf("cron after it left the list: %s, want gone", g.State)
			}
			c.lim.PerBox = 1
			got := c.announce(t, tid, "box-a", "app", "cron")
			if got[0].State != wire.FileStreamFollowing || got[1].State != wire.FileStreamRefused || got[1].Reason != FileStreamReasonPerBox {
				t.Fatalf("announce past PerBox = %+v", got)
			}
			if _, err := c.push(tid, "box-a", "cron", fsLines(1, 1, c.now, "x")); !errors.Is(err, ErrFileStreamRefused) {
				t.Fatalf("push to a hub-refused stream: %v, want ErrFileStreamRefused", err)
			}
		})
	}
}

// TestFileStreamBoxAndWorkspaceAreTheCallers (case C11, store half): a
// stream announced by box-a in W is not box-b's and not W2's, and an
// announce for a box with no row in W is refused. CONTROL: a lookup by key
// alone would let box-b push into box-a's stream.
func TestFileStreamBoxAndWorkspaceAreTheCallers(t *testing.T) {
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			c := newFSCase(t, s)
			w, w2 := c.workspace(t, "box-a"), c.workspace(t, "box-a")
			c.announce(t, w, "box-a", "app")
			c.pinBox(t, w, "box-b")
			if _, err := c.push(w, "box-b", "app", fsLines(1, 1, c.now, "x")); !errors.Is(err, ErrFileStreamUnknown) {
				t.Fatalf("box-b into box-a's stream: %v", err)
			}
			if _, err := c.push(w2, "box-a", "app", fsLines(1, 1, c.now, "x")); !errors.Is(err, ErrFileStreamUnknown) {
				t.Fatalf("W2's box-a into W's stream: %v", err)
			}
			if _, err := c.fs.AnnounceFileStreams(c.ctx, w, "box-zz", nil, c.lim, c.now); !errors.Is(err, ErrNotFound) {
				t.Fatalf("announce of a box not in W: %v, want ErrNotFound", err)
			}
			if all, _ := c.fs.ListFileStreams(c.ctx, w2); len(all) != 0 {
				t.Fatalf("W2 lists W's streams: %+v", all)
			}
			if _, err := c.fs.FileStreamLines(c.ctx, w2, c.stream(t, w, "app").ID, FileStreamLinesQuery{}); !errors.Is(err, ErrNotFound) {
				t.Fatalf("W2 reads W's stream by id: %v, want ErrNotFound", err)
			}
		})
	}
}

// TestFileStreamRateRefusesWholePush (case C23, store half): a push that
// takes a minute over twice the rate stores nothing; a re-send of stored
// lines does not count twice. CONTROL: a check before the insert that
// counted the re-sent seqs refuses the second, identical push.
func TestFileStreamRateRefusesWholePush(t *testing.T) {
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			c := newFSCase(t, s)
			c.lim.RatePerMin = 5 // twice: 10 a minute
			tid := c.workspace(t, "box-a")
			c.announce(t, tid, "box-a", "app")
			at := c.now.Truncate(time.Minute)
			for i := 0; i < 2; i++ {
				if _, err := c.push(tid, "box-a", "app", fsLines(1, 8, at, "a")); err != nil {
					t.Fatalf("push %d of 8: %v", i, err)
				}
			}
			if _, err := c.push(tid, "box-a", "app", fsLines(9, 3, at, "b")); !errors.Is(err, ErrFileStreamRate) {
				t.Fatalf("8 + 3 > 10: %v, want ErrFileStreamRate", err)
			}
			if n := len(c.kept(t, tid, "app")); n != 8 {
				t.Fatalf("after the refused push %d lines kept, want 8 (nothing of it)", n)
			}
			if f := c.stream(t, tid, "app"); f.LinesKept != 8 || f.LastSeq != 8 {
				t.Fatalf("counts moved by the refused push: %+v", f)
			}
			if _, err := c.push(tid, "box-a", "app", fsLines(9, 3, at.Add(time.Minute), "c")); err != nil {
				t.Fatalf("the next minute: %v", err)
			}
		})
	}
}

// TestFileStreamTimes: a line older than the retention is acked and not
// stored, a line ahead of the hub's clock is stored at now.
func TestFileStreamTimes(t *testing.T) {
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			c := newFSCase(t, s)
			tid := c.workspace(t, "box-a")
			c.announce(t, tid, "box-a", "app")
			ls := append(fsLines(1, 1, c.now.Add(-8*24*time.Hour), "old"), fsLines(2, 1, c.now.Add(time.Hour), "ahead")...)
			r, err := c.push(tid, "box-a", "app", ls)
			if err != nil || r.Inserted != 1 || r.Expired != 1 || r.AckedSeq != 2 {
				t.Fatalf("push = %+v %v", r, err)
			}
			if k := c.kept(t, tid, "app"); len(k) != 1 || k[0].Seq != 2 || !k[0].At.Equal(c.now) {
				t.Fatalf("kept = %+v", k)
			}
		})
	}
}

// TestFileStreamCapsPerWorkspace (case C38): workspace A pushes 3x its line
// and byte caps while B holds lines within its own: A ends within its caps,
// its oldest gone first, and B's count and oldest line are unchanged.
// CONTROL: v0.2's hub-wide prune (the oldest lines of every workspace)
// deletes B's lines, which are older than A's.
func TestFileStreamCapsPerWorkspace(t *testing.T) {
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			c := newFSCase(t, s)
			c.lim.RatePerMin = 1 << 20
			a, b := c.workspace(t, "box-a"), c.workspace(t, "box-b")
			c.announce(t, a, "box-a", "app")
			c.announce(t, b, "box-b", "app")
			c.lim.MaxLines = 10
			if _, err := c.push(b, "box-b", "app", fsLines(1, 6, c.now.Add(-time.Hour), "b")); err != nil {
				t.Fatal(err)
			}
			for i := int64(0); i < 3; i++ {
				r, err := c.push(a, "box-a", "app", fsLines(1+10*i, 10, c.now.Add(time.Duration(i)*time.Second), "a"))
				if err != nil || (i > 0 && r.Pruned != 10) {
					t.Fatalf("A push %d: %+v %v", i, r, err)
				}
			}
			ka := c.kept(t, a, "app")
			if len(ka) != 10 || ka[0].Seq != 21 {
				t.Fatalf("A kept %d lines from seq %d, want 10 from 21", len(ka), ka[0].Seq)
			}
			if kb := c.kept(t, b, "app"); len(kb) != 6 || kb[0].Seq != 1 {
				t.Fatalf("B's lines touched by A's prune: %+v", kb)
			}
			// The byte cap: lines of 12 bytes, at most 50 bytes kept.
			c.lim.MaxLines, c.lim.MaxBytes = 1<<20, 50
			if _, err := c.push(a, "box-a", "app", fsLines(31, 4, c.now.Add(time.Minute), strings.Repeat("y", 9))); err != nil {
				t.Fatal(err)
			}
			if f := c.stream(t, a, "app"); f.BytesKept > 50 || f.LinesKept != 4 || len(c.kept(t, a, "app")) != 4 {
				t.Fatalf("A over its byte cap: %+v", f)
			}
		})
	}
}

// fsStreamingWorkspaces is how many workspaces stream now, counted as the
// announce counts them (Postgres: other test runs left theirs).
func fsStreamingWorkspaces(t *testing.T, s Store) int {
	t.Helper()
	n := 0
	switch x := s.(type) {
	case *Postgres:
		err := x.asOperatorQuery(context.Background(), `SELECT count(DISTINCT tenant_id) FROM file_streams
			WHERE state IN ('following', 'missing')`, nil, func(r pgx.Rows) error { return r.Scan(&n) })
		if err != nil {
			t.Fatal(err)
		}
	case *Memory:
		x.mu.Lock()
		ws := map[string]bool{}
		for _, f := range x.fileStreamsLocked().byID {
			if f.State == wire.FileStreamFollowing || f.State == wire.FileStreamMissing {
				ws[f.Tenant] = true
			}
		}
		x.mu.Unlock()
		n = len(ws)
	}
	return n
}

// TestFileStreamMaxWorkspaces: with the cap at the workspaces streaming now
// plus one, a new workspace streams, the next is refused on every key and
// stores no following row, and a workspace already streaming keeps
// announcing. A refused-only announce does not count. CONTROL: a count
// that took in the refused rows would refuse W1's own re-announce.
func TestFileStreamMaxWorkspaces(t *testing.T) {
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			c := newFSCase(t, s)
			w1, w2 := c.workspace(t, "box-a"), c.workspace(t, "box-a")
			c.lim.MaxWorkspaces = fsStreamingWorkspaces(t, s) + 1
			if got := c.announce(t, w1, "box-a", "app"); got[0].State != wire.FileStreamFollowing {
				t.Fatalf("W1 under the cap: %+v", got)
			}
			got := c.announce(t, w2, "box-a", "app", "cron")
			for _, g := range got {
				if g.State != wire.FileStreamRefused || g.Reason != FileStreamReasonWorkspaces {
					t.Fatalf("W2 past the cap: %+v", got)
				}
			}
			if f := c.stream(t, w2, "app"); f.State != wire.FileStreamRefused {
				t.Fatalf("W2's row: %+v", f)
			}
			if got := c.announce(t, w1, "box-a", "app"); got[0].State != wire.FileStreamFollowing {
				t.Fatalf("W1 re-announce at the cap: %+v", got)
			}
		})
	}
}

// TestFileStreamRLSTenantless (case C30): with a stream and a line stored,
// a statement without a tenant reads 0 rows of either table, another
// tenant's scope reads 0, its own reads them. TestRLSCoversEveryTenantTable
// holds ENABLE + FORCE on both. CONTROL: with the policies dropped (rolled
// back) the tenantless read counts the rows.
func TestFileStreamRLSTenantless(t *testing.T) {
	pg := rlsStore(t)
	c := newFSCase(t, pg)
	tid, other := c.workspace(t, "box-a"), c.workspace(t, "box-b")
	c.announce(t, tid, "box-a", "app")
	if _, err := c.push(tid, "box-a", "app", fsLines(1, 2, c.now, "rls")); err != nil {
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
	for _, table := range []string{"file_streams", "file_stream_lines"} {
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
		// The control, rolled back: without the policies and FORCE the
		// tenantless read sees the rows, so the 0 above is the policy's.
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
