package store

import (
	"context"
	"fmt"
	"os"
	"sort"
	"strconv"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// Performance harness (specs/027 T010, FR-001). Postgres only, never in the
// default run: the benchmarks need -bench, the sweep test SPOOL_PERF_SWEEP_ROWS.
// The same file measures BEFORE and AFTER a store change, so every number it
// prints comes from one harness.

func perfDSN(tb testing.TB) string {
	tb.Helper()
	dsn := os.Getenv("SPOOL_TEST_PG_DSN")
	if dsn == "" {
		tb.Skip("SPOOL_TEST_PG_DSN unset (run hub-pg.tst.sh)")
	}
	return dsn
}

// perfStore opens dsn (plus extra query params) and migrates it.
func perfStore(tb testing.TB, extra string) *Postgres {
	tb.Helper()
	ctx := context.Background()
	pg, err := OpenPostgres(ctx, perfDSN(tb)+extra)
	if err != nil {
		tb.Fatal(err)
	}
	tb.Cleanup(pg.Close)
	if _, err := Migrate(ctx, pg.Pool(), sqlDir(tb)); err != nil {
		tb.Fatal(err)
	}
	return pg
}

func perfTenant(tb testing.TB, pg *Postgres) string {
	tb.Helper()
	id := uid("t-")
	if err := pg.CreateTenant(context.Background(), Tenant{ID: id, RootPubKey: pubkey()}); err != nil {
		tb.Fatal(err)
	}
	return id
}

func pct(d []time.Duration, p float64) time.Duration {
	if len(d) == 0 {
		return 0
	}
	i := int(float64(len(d)-1) * p)
	return d[i]
}

// BenchmarkSendPath: the hub's store work for one send (InsertMessage then
// Enqueue, ws.go onSend) from C concurrent senders, per pool size, set through
// the DSN so the number does not depend on the code's default. pool=4 is pgx's
// default on the 1-vCPU hub (max(4, NumCPU)); 8 fits Cloud SQL db-f1-micro
// (max_connections 25) with two instances overlapping during a roll.
func BenchmarkSendPath(b *testing.B) {
	perfDSN(b)
	for _, pool := range []string{"4", "8", "16", "30"} {
		for _, conc := range []int{50, 200} {
			b.Run(fmt.Sprintf("pool=%s/conc=%d", pool, conc), func(b *testing.B) {
				pg := perfStore(b, "&pool_max_conns="+pool)
				tenant := perfTenant(b, pg)
				ctx, now := context.Background(), time.Now().UTC()
				lat := make([]time.Duration, b.N)
				var next atomic.Int64
				var wg sync.WaitGroup
				var failed atomic.Value
				b.ResetTimer()
				start := time.Now()
				for w := 0; w < conc; w++ {
					wg.Add(1)
					go func(w int) {
						defer wg.Done()
						box := "box-" + strconv.Itoa(w%10)
						for {
							i := next.Add(1) - 1
							if i >= int64(b.N) {
								return
							}
							t0 := time.Now()
							m := msgFor(tenant, uuid4(), box, now, now, "env")
							if _, err := pg.InsertMessage(ctx, m); err != nil {
								failed.Store(err)
								return
							}
							if err := pg.Enqueue(ctx, tenant, m.MsgID, box, now, now.Add(time.Hour), 1000); err != nil {
								failed.Store(err)
								return
							}
							lat[i] = time.Since(t0)
						}
					}(w)
				}
				wg.Wait()
				wall := time.Since(start)
				b.StopTimer()
				if err, _ := failed.Load().(error); err != nil {
					b.Fatal(err)
				}
				sort.Slice(lat, func(i, j int) bool { return lat[i] < lat[j] })
				b.ReportMetric(float64(b.N)/wall.Seconds(), "sends/s")
				b.ReportMetric(float64(pct(lat, 0.50).Microseconds())/1000, "p50-ms")
				b.ReportMetric(float64(pct(lat, 0.95).Microseconds())/1000, "p95-ms")
				b.ReportMetric(float64(pg.Pool().Config().MaxConns), "maxconns")
			})
		}
	}
}

// BenchmarkSetRoster50: one hello replacing a 50-agent roster.
func BenchmarkSetRoster50(b *testing.B) {
	pg := perfStore(b, "")
	tenant := perfTenant(b, pg)
	ctx, now := context.Background(), time.Now().UTC()
	agents := make([]string, 50)
	for i := range agents {
		agents[i] = fmt.Sprintf("CLE-%d", i+1)
	}
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		if err := pg.SetRoster(ctx, tenant, "box-a", agents, now); err != nil {
			b.Fatal(err)
		}
	}
}

// stmtTracer records every statement's duration, and each transaction's
// (begin .. commit/rollback on one connection).
type stmtTracer struct {
	mu       sync.Mutex
	longest  time.Duration
	longSQL  string
	longTx   time.Duration
	stmts    int
	txOpen   map[*pgx.Conn]time.Time
	inflight map[*pgx.Conn]time.Time
	sqlOf    map[*pgx.Conn]string
}

func newStmtTracer() *stmtTracer {
	return &stmtTracer{txOpen: map[*pgx.Conn]time.Time{}, inflight: map[*pgx.Conn]time.Time{}, sqlOf: map[*pgx.Conn]string{}}
}

func (t *stmtTracer) TraceQueryStart(ctx context.Context, c *pgx.Conn, d pgx.TraceQueryStartData) context.Context {
	t.mu.Lock()
	defer t.mu.Unlock()
	now := time.Now()
	t.inflight[c], t.sqlOf[c] = now, d.SQL
	if d.SQL == "begin" {
		t.txOpen[c] = now
	}
	return ctx
}

func (t *stmtTracer) TraceQueryEnd(_ context.Context, c *pgx.Conn, _ pgx.TraceQueryEndData) {
	t.mu.Lock()
	defer t.mu.Unlock()
	now := time.Now()
	t.stmts++
	if d := now.Sub(t.inflight[c]); d > t.longest {
		t.longest, t.longSQL = d, t.sqlOf[c]
	}
	if s := t.sqlOf[c]; s == "commit" || s == "rollback" {
		if d := now.Sub(t.txOpen[c]); d > t.longTx {
			t.longTx = d
		}
	}
}

// TestPerfSweep seeds SPOOL_PERF_SWEEP_ROWS expired messages (one queued
// delivery each) over 5 tenants plus unexpired control rows, sweeps, and logs
// wall time, the longest statement and the longest transaction. CONTROL: the
// sweep deletes exactly the expired rows and none of the unexpired ones.
func TestPerfSweep(t *testing.T) {
	rows, _ := strconv.Atoi(os.Getenv("SPOOL_PERF_SWEEP_ROWS"))
	if rows <= 0 {
		t.Skip("SPOOL_PERF_SWEEP_ROWS unset")
	}
	seed := perfStore(t, "")
	ctx := context.Background()
	now := time.Now().UTC().Truncate(time.Second)
	past, future := now.Add(-time.Hour), now.Add(30*24*time.Hour)
	const tenants, keep = 5, 1000
	var ids []string
	for i := 0; i < tenants; i++ {
		ids = append(ids, perfTenant(t, seed))
	}
	t.Cleanup(func() {
		_ = seed.asOperator(ctx, func(tx pgx.Tx) error {
			_, err := tx.Exec(ctx, `DELETE FROM tenants WHERE tenant_id = ANY($1)`, ids)
			return err
		})
	})
	count := func(where string, args ...any) (n int) {
		t.Helper()
		if err := seed.asOperator(ctx, func(tx pgx.Tx) error {
			return tx.QueryRow(ctx, `SELECT count(*) FROM messages WHERE `+where, args...).Scan(&n)
		}); err != nil {
			t.Fatal(err)
		}
		return n
	}
	preExpired := count(`expires_at <= $1`, now)
	per := rows / tenants
	t0 := time.Now()
	for _, id := range ids {
		for _, r := range []struct {
			n   int
			exp time.Time
		}{{per, past}, {keep, future}} {
			if err := seed.asOperator(ctx, func(tx pgx.Tx) error {
				if _, err := tx.Exec(ctx, `INSERT INTO messages (tenant_id, msg_id, task_id, ts, from_box, from_id,
					to_box, to_id, kind, body, msg, env_sig, env, received_at, expires_at)
					SELECT $1, gen_random_uuid(), gen_random_uuid(), $2, 'box-a', 'CLE-01', 'box-b', 'CLE-02',
						'note', 'perf body ' || g, '{"v":1}', 'sig', convert_to(repeat('x', 1000) || g, 'UTF8'), $2, $3
					FROM generate_series(1, $4) g`, id, past.Add(-time.Hour), r.exp, r.n); err != nil {
					return err
				}
				_, err := tx.Exec(ctx, `INSERT INTO deliveries (tenant_id, msg_id, to_box, state, received_at, expires_at)
					SELECT tenant_id, msg_id, 'box-b', 'queued', received_at, expires_at FROM messages
					WHERE tenant_id = $1 AND expires_at = $2`, id, r.exp)
				return err
			}); err != nil {
				t.Fatal(err)
			}
		}
	}
	if _, err := seed.pool.Exec(ctx, `ANALYZE messages; ANALYZE deliveries`); err != nil {
		t.Fatal(err)
	}
	t.Logf("seeded %d expired + %d unexpired messages over %d tenants in %s", per*tenants, keep*tenants, tenants, time.Since(t0).Round(time.Millisecond))

	cfg, err := pgxpool.ParseConfig(perfDSN(t))
	if err != nil {
		t.Fatal(err)
	}
	tr := newStmtTracer()
	cfg.ConnConfig.Tracer = tr
	pool, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		t.Fatal(err)
	}
	defer pool.Close()
	pg := &Postgres{pool: pool}
	t1 := time.Now()
	r, err := pg.Sweep(ctx, now)
	wall := time.Since(t1)
	if err != nil {
		t.Fatal(err)
	}
	t.Logf("PERF sweep rows=%d wall=%s longest-stmt=%s longest-tx=%s stmts=%d expired=%d purged=%d (longest: %.60q)",
		per*tenants, wall.Round(time.Millisecond), tr.longest.Round(time.Millisecond), tr.longTx.Round(time.Millisecond),
		tr.stmts, r.Expired, r.Purged, tr.longSQL)
	if want := per*tenants + preExpired; r.Purged != want {
		t.Fatalf("purged %d, want exactly %d expired", r.Purged, want)
	}
	if r.Expired < per*tenants {
		t.Fatalf("expired %d deliveries, want at least the %d seeded", r.Expired, per*tenants)
	}
	if n := count(`tenant_id = ANY($1) AND expires_at <= $2`, ids, now); n != 0 {
		t.Fatalf("%d expired rows survived the sweep", n)
	}
	if n := count(`tenant_id = ANY($1) AND expires_at > $2`, ids, now); n != keep*tenants {
		t.Fatalf("%d unexpired rows left, want %d (the sweep deleted live rows)", n, keep*tenants)
	}
}
