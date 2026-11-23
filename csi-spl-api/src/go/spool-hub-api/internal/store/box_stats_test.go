package store

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

// rdb 0117: the box load + memory history. Samples append, list oldest first
// per box or for every box, fold into per-hour avg / peak, a CHECK the Go
// side refuses is a CHECK the table refuses, the prune drops only rows past
// the cut, and another tenant sees none of it. Run on Memory and Postgres.
func TestBoxStatsAppendListPrune(t *testing.T) {
	ctx := context.Background()
	t0 := time.Date(2026, 10, 4, 10, 0, 0, 0, time.UTC)
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			bs, ok := st.(BoxStats)
			if !ok {
				t.Fatalf("%s keeps no box stats", name)
			}
			tid := newTenant(t, st)
			other := newTenant(t, st)
			s := func(box string, at time.Time, l1 float64, avail int64, agents int) BoxStat {
				return BoxStat{Box: box, WriterBox: "box-desk-" + box, At: at, Load1: l1, Load5: l1 / 2, Load15: 0.25,
					CPUs: 8, MemTotalKB: 1000, MemAvailKB: avail, SwapUsedKB: 5, AgentsLive: agents}
			}
			for _, b := range []BoxStat{
				withDisks(s("sat", t0.Add(5*time.Minute), 2.5, 600, 3), BoxDisk{"/", 100, 40, 55, ""}, BoxDisk{"/mnt/data", 900, 500, 0, ""}),
				withDisks(s("sat", t0.Add(10*time.Minute), 4.5, 200, 5), BoxDisk{"/", 100, 30, 65, ""}),
				s("sat", t0.Add(65*time.Minute), 1.25, 900, 1),
				s("tower", t0.Add(7*time.Minute), 0.47, 400, 2),
			} {
				if why := CheckBoxStat(b); why != "" {
					t.Fatalf("sample %+v: %s", b, why)
				}
				if err := bs.AppendBoxStat(ctx, tid, b); err != nil {
					t.Fatal(err)
				}
			}

			rows, err := bs.ListBoxStats(ctx, tid, "sat", t0)
			if err != nil || len(rows) != 3 || len(rows[0].Disks) != 2 || rows[0].Disks[0].UsedKB != 55 || rows[0].Disks[1] != (BoxDisk{"/mnt/data", 900, 500, 0, ""}) ||
				rows[2].Disks == nil || len(rows[2].Disks) != 0 || rows[0].Load1 != 2.5 || rows[2].MemAvailKB != 900 || rows[0].WriterBox != "box-desk-sat" || !rows[0].At.Equal(t0.Add(5*time.Minute)) {
				t.Fatalf("sat rows: %+v %v", rows, err)
			}
			all, _ := bs.ListBoxStats(ctx, tid, "", t0)
			if len(all) != 4 || all[1].Box != "tower" || all[1].Load1 != 0.47 {
				t.Fatalf("every box, oldest first (0.47 reads back as 0.47): %+v", all)
			}
			if late, _ := bs.ListBoxStats(ctx, tid, "sat", t0.Add(time.Hour)); len(late) != 1 {
				t.Fatalf("since: %+v", late)
			}
			if none, _ := bs.ListBoxStats(ctx, other, "", t0); len(none) != 0 {
				t.Fatalf("another tenant reads: %+v", none)
			}

			h := BoxStatHours(all)
			if len(h) != 3 {
				t.Fatalf("hours: %+v", h)
			}
			if a := h[0]; a.Box != "sat" || !a.Hour.Equal(t0) || a.N != 2 || a.Load1Avg != 3.5 || a.Load1Peak != 4.5 ||
				a.MemUsedAvgKB != 600 || a.MemUsedPeakKB != 800 || a.MemAvailMinKB != 200 || a.AgentsAvg != 4 || a.AgentsPeak != 5 || a.CPUs != 8 {
				t.Fatalf("sat 10:00: %+v", a)
			}
			if d := h[0].Disks; len(d) != 2 || d[0] != (BoxDiskHour{"/", 100, 30, 65}) || d[1] != (BoxDiskHour{"/mnt/data", 900, 500, 0}) {
				t.Fatalf("sat 10:00 disks (per mount: size, least free): %+v", d)
			}
			if h[1].Disks == nil || len(h[1].Disks) != 0 {
				t.Fatalf("an hour with no disk sample lists none: %+v", h[1].Disks)
			}
			if h[1].Box != "sat" || h[1].N != 1 || h[2].Box != "tower" {
				t.Fatalf("order box, hour: %+v", h)
			}

			// the prune is every tenant's, older than the cut only
			if err := bs.AppendBoxStat(ctx, other, s("sat", t0.Add(-time.Hour), 1, 1, 1)); err != nil {
				t.Fatal(err)
			}
			n, err := bs.PruneBoxStats(ctx, t0.Add(6*time.Minute))
			if err != nil || n < 2 {
				t.Fatalf("prune: %d %v", n, err)
			}
			if rest, _ := bs.ListBoxStats(ctx, tid, "", t0.Add(-BoxStatsRetention)); len(rest) != 3 {
				t.Fatalf("after prune: %+v", rest)
			}
		})
	}
}

func withDisks(b BoxStat, d ...BoxDisk) BoxStat {
	b.Disks = d
	return b
}

func TestCheckBoxStat(t *testing.T) {
	ok := BoxStat{Box: "sat", Load1: 1, Load5: 1, Load15: 1, CPUs: 4, MemTotalKB: 1, MemAvailKB: 1}
	if why := CheckBoxStat(ok); why != "" {
		t.Fatal(why)
	}
	full := ok
	for i := 0; i < BoxDisksMax; i++ {
		full.Disks = append(full.Disks, BoxDisk{fmt.Sprintf("/m%d", i), 1, 1, 0, ""})
	}
	if why := CheckBoxStat(full); why != "" {
		t.Fatalf("16 mounts: %s", why)
	}
	typed := ok
	typed.Disks = []BoxDisk{{"/", 1, 1, 0, "ext4"}, {"/tmp", 1, 1, 0, "tmpfs"}, {"/net", 1, 1, 0, "fuse.sshfs"}}
	if why := CheckBoxStat(typed); why != "" {
		t.Fatalf("fstype (row T11): %s", why)
	}
	for _, f := range []func(*BoxStat){
		func(b *BoxStat) { b.Box = "Sat" },
		func(b *BoxStat) { b.Box = "" },
		func(b *BoxStat) { b.Load1 = -1 },
		func(b *BoxStat) { b.Load15 = 100001 },
		func(b *BoxStat) { b.CPUs = 0 },
		func(b *BoxStat) { b.MemAvailKB = -1 },
		func(b *BoxStat) { b.SwapUsedKB = -1 },
		func(b *BoxStat) { b.AgentsLive = -1 },
		func(b *BoxStat) {
			b.Disks = make([]BoxDisk, 17)
			for i := range b.Disks {
				b.Disks[i].Mount = fmt.Sprintf("/m%d", i)
			}
		},
		func(b *BoxStat) { b.Disks = []BoxDisk{{"data", 1, 1, 0, ""}} },
		func(b *BoxStat) { b.Disks = []BoxDisk{{"/", 1, 1, 0, ""}, {"/", 2, 2, 0, ""}} },
		func(b *BoxStat) { b.Disks = []BoxDisk{{"/a\nb", 1, 1, 0, ""}} },
		func(b *BoxStat) { b.Disks = []BoxDisk{{"/", -1, 1, 0, ""}} },
		func(b *BoxStat) { b.Disks = []BoxDisk{{"/", 1, 1, -1, ""}} },
		func(b *BoxStat) { b.Disks = []BoxDisk{{"/", 1, 1, 0, "Ext4"}} },
		func(b *BoxStat) { b.Disks = []BoxDisk{{"/", 1, 1, 0, "a-type-name-of-25-bytes-x"}} },
	} {
		b := ok
		f(&b)
		if CheckBoxStat(b) == "" {
			t.Errorf("accepted %+v", b)
		}
	}
}

// rdb 0317 (spec 071 8.8.1, row T10): the htop header scalars round-trip on
// box_stats (NULL for an older box), and box_snapshots keeps ONE row per box,
// upserted with its sample under the same at, listed per box or for every
// box, untouched by a sample without a snapshot, pruned with the samples, and
// never read by another tenant. Run on Memory and Postgres.
func TestBoxSnapshotsUpsertListPrune(t *testing.T) {
	ctx := context.Background()
	t0 := time.Date(2026, 11, 23, 17, 0, 0, 0, time.UTC)
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			bs, ok := st.(BoxSnapshots)
			if !ok {
				t.Fatalf("%s keeps no box snapshots", name)
			}
			tid := newTenant(t, st)
			other := newTenant(t, st)
			cpu, swapT, buf, cache, tasks, run, up := 37.5, int64(4096), int64(100), int64(200), 512, 3, int64(86400)
			stat := func(box string, at time.Time) BoxStat {
				return BoxStat{Box: box, WriterBox: "box-desk-" + box, At: at, Load1: 1, CPUs: 4, MemTotalKB: 1000, MemAvailKB: 500,
					CPUPct: &cpu, SwapTotalKB: &swapT, MemBuffersKB: &buf, MemCachedKB: &cache, TasksTotal: &tasks, TasksRunning: &run, UptimeS: &up}
			}
			dirsAt := t0.Add(-time.Minute)
			snap := BoxSnapshot{CPUCoresPct: []float64{12.34, 99.96}, CPUUserPct: 20.04, CPUSysPct: 5, CPUIOWaitPct: 0.5, TasksThreads: 900,
				TopDirs:   []BoxDir{{"/var/log", "/", 2048, false}, {"/srv/cache/uid-1000", "/srv", 1 << 20, true}},
				TopDirsAt: &dirsAt, TopDirsPartial: true, TopDirsUnvisited: 2, TopDirsUnreadable: 1}
			if why := CheckBoxSnapshot(snap); why != "" {
				t.Fatal(why)
			}
			for _, w := range []struct {
				b BoxStat
				s *BoxSnapshot
			}{{stat("sat", t0), &snap}, {stat("tower", t0.Add(time.Minute)), &BoxSnapshot{TasksThreads: 7}}} {
				if why := CheckBoxStat(w.b); why != "" {
					t.Fatal(why)
				}
				if err := bs.AppendBoxStatSnapshot(ctx, tid, w.b, w.s); err != nil {
					t.Fatal(err)
				}
			}
			legacy := BoxStat{Box: "sat", WriterBox: "box-desk-sat", At: t0.Add(2 * time.Minute), Load1: 1, CPUs: 4}
			if err := bs.AppendBoxStatSnapshot(ctx, tid, legacy, nil); err != nil {
				t.Fatal(err)
			}

			rows, err := st.(BoxStats).ListBoxStats(ctx, tid, "sat", t0)
			if err != nil || len(rows) != 2 {
				t.Fatalf("sat rows: %+v %v", rows, err)
			}
			if r := rows[0]; r.CPUPct == nil || *r.CPUPct != 37.5 || *r.SwapTotalKB != 4096 || *r.MemBuffersKB != 100 || *r.MemCachedKB != 200 ||
				*r.TasksTotal != 512 || *r.TasksRunning != 3 || *r.UptimeS != 86400 {
				t.Fatalf("htop header scalars do not round-trip: %+v", r)
			}
			if r := rows[1]; r.CPUPct != nil || r.SwapTotalKB != nil || r.TasksTotal != nil || r.UptimeS != nil {
				t.Fatalf("an older box's sample reads NULL scalars: %+v", r)
			}

			all, err := bs.ListBoxSnapshots(ctx, tid, "")
			if err != nil || len(all) != 2 {
				t.Fatalf("one snapshot per box: %+v %v", all, err)
			}
			got := all["sat"]
			if !got.At.Equal(t0) || len(got.CPUCoresPct) != 2 || got.CPUCoresPct[0] != 12.3 || got.CPUCoresPct[1] != 100 || got.CPUUserPct != 20 ||
				got.TasksThreads != 900 || len(got.TopDirs) != 2 || got.TopDirs[1] != (BoxDir{"/srv/cache/uid-1000", "/srv", 1 << 20, true}) ||
				got.TopDirsAt == nil || !got.TopDirsAt.Equal(dirsAt) || !got.TopDirsPartial || got.TopDirsUnvisited != 2 || got.TopDirsUnreadable != 1 {
				t.Fatalf("sat snapshot (at = the sample's, a sample without one leaves it, percentages 1 decimal): %+v", got)
			}
			// a newer snapshot replaces the row, never adds one
			if err := bs.AppendBoxStatSnapshot(ctx, tid, stat("sat", t0.Add(5*time.Minute)), &BoxSnapshot{TasksThreads: 1}); err != nil {
				t.Fatal(err)
			}
			one, _ := bs.ListBoxSnapshots(ctx, tid, "sat")
			if len(one) != 1 || !one["sat"].At.Equal(t0.Add(5*time.Minute)) || one["sat"].TasksThreads != 1 || one["sat"].TopDirs != nil {
				t.Fatalf("upsert: %+v", one)
			}
			if none, _ := bs.ListBoxSnapshots(ctx, other, ""); len(none) != 0 {
				t.Fatalf("another tenant reads: %+v", none)
			}

			// the prune drops a snapshot older than the cut, with the samples
			if _, err := st.(BoxStats).PruneBoxStats(ctx, t0.Add(2*time.Minute)); err != nil {
				t.Fatal(err)
			}
			left, _ := bs.ListBoxSnapshots(ctx, tid, "")
			if _, gone := left["tower"]; len(left) != 1 || gone || left["sat"].TasksThreads != 1 {
				t.Fatalf("after prune: tower (at t0+1m) goes, sat (t0+5m) stays: %+v", left)
			}
		})
	}
}

func TestCheckBoxSnapshot(t *testing.T) {
	full := BoxSnapshot{CPUCoresPct: make([]float64, BoxCPUCoresMax), CPUUserPct: 100}
	for i := 0; i < BoxTopDirsMax; i++ {
		full.TopDirs = append(full.TopDirs, BoxDir{Path: fmt.Sprintf("/d%d/.hidden", i), Mount: "/", SizeKB: 1})
	}
	if why := CheckBoxSnapshot(full); why != "" {
		t.Fatalf("10 dirs, 256 cores: %s", why)
	}
	long := strings.Repeat("<", 255) // printable ASCII, 6 bytes of JSON each
	for i, f := range []func(*BoxSnapshot){
		func(s *BoxSnapshot) { s.TopDirs = append(s.TopDirs, BoxDir{Path: "/x", Mount: "/"}) },
		func(s *BoxSnapshot) { s.TopDirs[0].Path = "/var/../etc" },
		func(s *BoxSnapshot) { s.TopDirs[0].Path = "/var/.." },
		func(s *BoxSnapshot) { s.TopDirs[0].Path = "var/log" },
		func(s *BoxSnapshot) { s.TopDirs[0].Path = "/" + strings.Repeat("a", 256) },
		func(s *BoxSnapshot) { s.TopDirs[0].Path = "/srv/josé" },
		func(s *BoxSnapshot) { s.TopDirs[0].Path = "/a\tb" },
		func(s *BoxSnapshot) { s.TopDirs[0].Mount = "data" },
		func(s *BoxSnapshot) { s.TopDirs[0].SizeKB = -1 },
		func(s *BoxSnapshot) { s.CPUCoresPct = append(s.CPUCoresPct, 1) },
		func(s *BoxSnapshot) { s.CPUCoresPct[3] = 100.1 },
		func(s *BoxSnapshot) { s.CPUIOWaitPct = -0.1 },
		func(s *BoxSnapshot) { s.TasksThreads = -1 },
		func(s *BoxSnapshot) { s.TopDirsUnreadable = -1 },
		func(s *BoxSnapshot) {
			for i := range s.TopDirs {
				s.TopDirs[i].Path, s.TopDirs[i].Mount = "/"+long, "/"+long
			}
		},
	} {
		s := full
		s.CPUCoresPct = append([]float64{}, full.CPUCoresPct...)
		s.TopDirs = append([]BoxDir{}, full.TopDirs...)
		f(&s)
		if CheckBoxSnapshot(s) == "" {
			t.Errorf("case %d accepted: %d dirs, first path %.40q, %d cores", i, len(s.TopDirs), s.TopDirs[0].Path, len(s.CPUCoresPct))
		}
	}
	// the htop header scalars of box_stats (rdb 0317 CHECKs)
	ok := BoxStat{Box: "sat", CPUs: 4}
	big, neg, cpu := 4194305, int64(-1), 100.5
	for _, f := range []func(*BoxStat){
		func(b *BoxStat) { b.CPUPct = &cpu },
		func(b *BoxStat) { b.SwapTotalKB = &neg },
		func(b *BoxStat) { b.MemCachedKB = &neg },
		func(b *BoxStat) { b.UptimeS = &neg },
		func(b *BoxStat) { b.TasksTotal = &big },
	} {
		b := ok
		f(&b)
		if CheckBoxStat(b) == "" {
			t.Errorf("accepted %+v", b)
		}
	}
}

// TestBoxSnapshotsRLS: box_snapshots is a tenant table under FORCE row level
// security. A statement without a tenant reads 0 rows, a tenant reads only
// its own, and a row stamped with another tenant is refused. CONTROL: with
// FORCE switched off (a rolled-back transaction) the same unscoped statement
// reads the rows, so the 0 is RLS and not an empty table.
func TestBoxSnapshotsRLS(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	now := time.Now().UTC()
	a, b := newTenant(t, pg), newTenant(t, pg)
	for _, tn := range []string{a, b} {
		if err := pg.AppendBoxStatSnapshot(ctx, tn, BoxStat{Box: "sat", WriterBox: "box-a", At: now, CPUs: 1},
			&BoxSnapshot{TopDirs: []BoxDir{{"/var/log", "/", 1, false}}}); err != nil {
			t.Fatal(err)
		}
	}
	const unscoped = `SELECT count(*) FROM box_snapshots WHERE tenant_id IN ($1, $2)`
	var n int
	if err := pg.pool.QueryRow(ctx, unscoped, a, b).Scan(&n); err != nil || n != 0 {
		t.Fatalf("a statement without a tenant reads %d box_snapshots row(s) (%v), want 0", n, err)
	}
	if err := pg.inTenant(ctx, a, func(tx pgx.Tx) error {
		return tx.QueryRow(ctx, unscoped, a, b).Scan(&n)
	}); err != nil || n != 1 {
		t.Fatalf("tenant a reads %d row(s) (%v), want its own 1", n, err)
	}
	err := pg.inTenant(ctx, a, func(tx pgx.Tx) error {
		_, err := tx.Exec(ctx, `INSERT INTO box_snapshots (tenant_id, box, writer_box, at, snapshot) VALUES ($1, 'x', 'x', now(), '{}')`, b)
		return err
	})
	var pe *pgconn.PgError
	if !errors.As(err, &pe) || pe.Code != "42501" {
		t.Fatalf("a writing a box_snapshots row for b: want 42501, got %v", err)
	}

	tx, err := pg.pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback(ctx) //nolint:errcheck
	if _, err := tx.Exec(ctx, `ALTER TABLE box_snapshots NO FORCE ROW LEVEL SECURITY`); err != nil {
		t.Fatal(err)
	}
	if err := tx.QueryRow(ctx, unscoped, a, b).Scan(&n); err != nil || n != 2 {
		t.Fatalf("control is void: without FORCE the unscoped statement should read both rows, read %d (%v)", n, err)
	}
}
