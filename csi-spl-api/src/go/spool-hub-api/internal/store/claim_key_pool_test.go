package store

import (
	"context"
	"errors"
	"net/url"
	"os"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

// claimKey's "is this key live elsewhere" read runs on the pin transaction
// itself (spec 108 3.1). It once took a second pool connection while the
// transaction and its advisory lock held the first: with racers >= pool
// size each held a connection waiting for another one, and the pool
// deadlocked (the 20-minute hang of TestSpec108PinKeyRaceOneWins, workflow 20).
//
// Count: one key raced by 8 seats of 8 workspaces (PutPin and
// RedeemJoinToken alternating) on a pool of 2, under a 15 s deadline, must
// end 1 seated, 7 ErrKeyLive, 0 other. CONTROL: with keyLiveElsewhere back
// on asOperatorQuery (the pool), racers end in context deadline exceeded and
// the count goes red. The memory store has no pool: the same race there only
// shows the one-winner rule holds.
func TestClaimKeyRaceSmallPool(t *testing.T) {
	const racers, poolMax = 8, 2
	for name, s := range claimKeyDrivers(t, poolMax) {
		t.Run(name, func(t *testing.T) {
			now := time.Now().UTC()
			jt := s.(JoinTokens)
			key := pubkey()
			tenants := make([]string, racers)
			hashes := make([]string, racers)
			for i := range racers {
				tenants[i] = newTenant(t, s)
				if i%2 == 1 {
					hashes[i] = strings.Repeat(uid(""), 7)[:64]
					if err := jt.CreateJoinToken(context.Background(), JoinToken{Hash: hashes[i], TenantID: tenants[i],
						CreatedBy: "HUM-1", ExpiresAt: now.Add(time.Hour)}); err != nil {
						t.Fatal(err)
					}
				}
			}
			ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
			defer cancel()
			errs := make([]error, racers)
			start := make(chan struct{})
			var wg sync.WaitGroup
			for i := range racers {
				wg.Add(1)
				go func() {
					defer wg.Done()
					<-start
					if i%2 == 0 {
						errs[i] = s.PutPin(ctx, tenants[i], "box-race", key, false, now, now)
					} else {
						_, errs[i] = jt.RedeemJoinToken(ctx, tenants[i], hashes[i], "box-race", key, "", now)
					}
				}()
			}
			t0 := time.Now()
			close(start)
			wg.Wait()
			seated, live, other := 0, 0, 0
			for i, err := range errs {
				switch {
				case err == nil:
					seated++
				case errors.Is(err, ErrKeyLive):
					live++
				default:
					other++
					t.Logf("racer %d: %v", i, err)
				}
			}
			t.Logf("%d racers, pool %d: %d seated, %d ErrKeyLive, %d other, %s",
				racers, poolMax, seated, live, other, time.Since(t0).Round(time.Millisecond))
			if seated != 1 || live != racers-1 || other != 0 {
				t.Fatalf("want 1 seated, %d ErrKeyLive, 0 other; got %d, %d, %d", racers-1, seated, live, other)
			}
		})
	}
}

// asOperatorInTx widens the scope for its one read only: after it the tenant
// transaction sees its own rows again, not every workspace's. CONTROL: the
// read inside it does see the other workspace's pin.
func TestAsOperatorInTxRestoresScope(t *testing.T) {
	s, ok := claimKeyDrivers(t, 2)["postgres"].(*Postgres)
	if !ok {
		t.Skip("postgres only: SPOOL_TEST_PG_DSN is unset")
	}
	ctx := context.Background()
	if by, err := s.RLSBypassed(ctx); err != nil || by {
		t.Skipf("role bypasses row level security (err %v): the scope is unobservable", err)
	}
	now := time.Now().UTC()
	mine, other := newTenant(t, s), newTenant(t, s)
	key := pubkey()
	if err := s.PutPin(ctx, other, "box-a", key, false, now, now); err != nil {
		t.Fatal(err)
	}
	const count = `SELECT count(*) FROM pins WHERE pubkey = $1`
	err := s.inTenant(ctx, mine, func(tx pgx.Tx) error {
		var in, after int
		var scope string
		if err := s.asOperatorInTx(ctx, tx, count, []any{[]byte(key)}, func(r pgx.Rows) error { return r.Scan(&in) }); err != nil {
			return err
		}
		if err := tx.QueryRow(ctx, count, []byte(key)).Scan(&after); err != nil {
			return err
		}
		if err := tx.QueryRow(ctx, `SELECT coalesce(current_setting('app.rls_scope', true), '')`).Scan(&scope); err != nil {
			return err
		}
		if in != 1 {
			t.Errorf("control: the operator read saw %d pins of the other workspace, want 1", in)
		}
		if after != 0 || scope != "" {
			t.Errorf("after asOperatorInTx: %d pins of the other workspace visible, rls_scope %q; want 0 and \"\"", after, scope)
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
}

// claimKeyDrivers is drivers with the Postgres pool capped at poolMax
// connections (the DSN's own pool_max_conns is replaced).
func claimKeyDrivers(t *testing.T, poolMax int) map[string]Store {
	t.Helper()
	out := map[string]Store{"memory": NewMemory()}
	dsn := os.Getenv("SPOOL_TEST_PG_DSN")
	if dsn == "" {
		return out
	}
	drivers(t) // migrates the database
	pg, err := OpenPostgres(context.Background(), withPoolMax(t, dsn, poolMax))
	if err != nil {
		t.Fatalf("postgres: %v", err)
	}
	t.Cleanup(pg.Close)
	if got := pg.Pool().Config().MaxConns; got != int32(poolMax) {
		t.Fatalf("control: pool max %d, want %d", got, poolMax)
	}
	out["postgres"] = pg
	return out
}

func withPoolMax(t *testing.T, dsn string, n int) string {
	t.Helper()
	v := strconv.Itoa(n)
	if strings.HasPrefix(dsn, "postgres://") || strings.HasPrefix(dsn, "postgresql://") {
		u, err := url.Parse(dsn)
		if err != nil {
			t.Fatal(err)
		}
		q := u.Query()
		q.Set("pool_max_conns", v)
		u.RawQuery = q.Encode()
		return u.String()
	}
	var kept []string
	for _, f := range strings.Fields(dsn) {
		if !strings.HasPrefix(f, "pool_max_conns=") {
			kept = append(kept, f)
		}
	}
	return strings.Join(append(kept, "pool_max_conns="+v), " ")
}
