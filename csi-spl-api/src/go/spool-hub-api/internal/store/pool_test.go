package store

import (
	"context"
	"os"
	"runtime"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

func TestDSNSets(t *testing.T) {
	for _, c := range []struct {
		dsn, key string
		want     bool
	}{
		{"postgres://u@h/db?sslmode=disable&pool_max_conns=1", "pool_max_conns", true},
		{"postgresql://u@h/db?pool_min_conns=0", "pool_min_conns", true},
		{"postgres://u@h/db?sslmode=disable", "pool_max_conns", false},
		{"postgres://u@h/db?xpool_max_conns=1", "pool_max_conns", false},
		{"host=/cloudsql/x dbname=spool pool_max_conns=3", "pool_max_conns", true},
		{"host=/cloudsql/x dbname=spool", "pool_max_conns", false},
		{"host=h application_name=pool_max_conns=1", "pool_max_conns", false},
	} {
		if got := dsnSets(c.dsn, c.key); got != c.want {
			t.Errorf("dsnSets(%q, %q) = %v, want %v", c.dsn, c.key, got, c.want)
		}
	}
}

// TestShouldPing (db-payload audit cut 8): a connection idle up to 30 s is
// handed out without a ping round trip; past that it is pinged.
func TestShouldPing(t *testing.T) {
	for _, c := range []struct {
		idle time.Duration
		want bool
	}{
		{0, false},
		{2 * time.Second, false}, // pgx's default would ping here
		{29 * time.Second, false},
		{30 * time.Second, false},
		{31 * time.Second, true},
		{5 * time.Minute, true},
	} {
		if got := shouldPing(context.Background(), pgxpool.ShouldPingParams{IdleDuration: c.idle}); got != c.want {
			t.Errorf("shouldPing(idle %s) = %v, want %v", c.idle, got, c.want)
		}
	}
}

// TestPoolLimits (027 T010 CONTROL): limits apply only where the DSN is
// silent; a DSN pool_max_conns=1 still gives a one-connection pool (the
// RLS scope test relies on it), and no limits keeps pgx's default.
func TestPoolLimits(t *testing.T) {
	dsn := os.Getenv("SPOOL_TEST_PG_DSN")
	if dsn == "" {
		t.Skip("SPOOL_TEST_PG_DSN unset (run hub-pg.tst.sh)")
	}
	ctx := context.Background()
	lim := PoolLimits{MaxConns: 8, MinConns: 2, MaxConnIdleTime: 5 * time.Minute}
	open := func(dsn string, l ...PoolLimits) (max, min int32, idle time.Duration) {
		t.Helper()
		pg, err := OpenPostgres(ctx, dsn, l...)
		if err != nil {
			t.Fatal(err)
		}
		defer pg.Close()
		c := pg.Pool().Config()
		return c.MaxConns, c.MinConns, c.MaxConnIdleTime
	}
	if max, min, idle := open(dsn, lim); max != 8 || min != 2 || idle != 5*time.Minute {
		t.Fatalf("limits on a silent DSN: max %d min %d idle %s, want 8 2 5m", max, min, idle)
	}
	if max, min, _ := open(dsn+"&pool_max_conns=1", lim); max != 1 || min != 1 {
		t.Fatalf("DSN pool_max_conns=1 with limits: max %d min %d, want 1 1", max, min)
	}
	if max, min, idle := open(dsn+"&pool_max_conns=3&pool_min_conns=0&pool_max_conn_idle_time=1m", lim); max != 3 || min != 0 || idle != time.Minute {
		t.Fatalf("DSN pool_* with limits: max %d min %d idle %s, want 3 0 1m", max, min, idle)
	}
	want := int32(runtime.NumCPU())
	if want < 4 {
		want = 4
	}
	if max, _, _ := open(dsn); max != want {
		t.Fatalf("no limits: max %d, want pgx default %d", max, want)
	}
}
