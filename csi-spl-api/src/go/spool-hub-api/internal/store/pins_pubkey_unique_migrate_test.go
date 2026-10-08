package store

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

// rdb 0154 (specs/108 T006, spec section 3.2): one live pin per box key,
// across every workspace, box-wui exempt. Postgres only: the memory store
// does not carry the index.
//
// Pair, n=6 pin calls after the first on one fresh database:
//   - refused (n=2): a key live in workspace A is pinned again, into
//     workspace B and into a second box of A: PutPin answers ErrKeyLive
//     (T007, claimKey), and the same row written past claimKey is the unique
//     violation 23505 on pins_pubkey_live_unique, which mapPinErr maps to
//     ErrKeyLive (the race backstop).
//   - control (n=4): a unique key pins into B; after A's pin is revoked, its
//     key pins into B; the box-wui key pins into both A and B.
func TestPinsPubkeyUnique0154(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	now := time.Now().UTC()
	a, b := newTenant(t, pg), newTenant(t, pg)
	key := pubkey()
	if err := pg.PutPin(ctx, a, "box-a", key, false, now, now); err != nil {
		t.Fatalf("first pin: %v", err)
	}

	refused := func(what, tenant, box string) {
		t.Helper()
		if err := pg.PutPin(ctx, tenant, box, key, false, now, now); !errors.Is(err, ErrKeyLive) {
			t.Fatalf("%s: PutPin of a key live elsewhere: %v, want ErrKeyLive", what, err)
		}
		err := pg.inTenant(ctx, tenant, func(tx pgx.Tx) error {
			_, err := tx.Exec(ctx, `INSERT INTO pins (tenant_id, box_id, pubkey, updated_at, last_op_ts)
				VALUES ($1, $2, $3, $4, $4)`, tenant, box, []byte(key), now)
			return err
		})
		var pe *pgconn.PgError
		if !errors.As(err, &pe) || pe.Code != "23505" || pe.ConstraintName != "pins_pubkey_live_unique" {
			t.Fatalf("%s: a second live pin of the same key was not refused by the index: %v", what, err)
		}
		if !errors.Is(mapPinErr(err), ErrKeyLive) {
			t.Fatalf("%s: mapPinErr(%v) is not ErrKeyLive", what, err)
		}
	}
	refused("other workspace", b, "box-b")
	refused("same workspace, other box", a, "box-a2")

	// Control: the index refuses only a live duplicate.
	if err := pg.PutPin(ctx, b, "box-b", pubkey(), false, now, now); err != nil {
		t.Fatalf("control, unique key: %v", err)
	}
	later := now.Add(time.Second)
	if err := pg.RevokePin(ctx, a, "box-a", later, later); err != nil {
		t.Fatal(err)
	}
	if err := pg.PutPin(ctx, b, "box-b2", key, false, later, later); err != nil {
		t.Fatalf("control, revoked pin's key pinned again: %v", err)
	}
	wui := pubkey()
	for _, tenant := range []string{a, b} {
		if err := pg.PutPin(ctx, tenant, "box-wui", wui, false, now, now); err != nil {
			t.Fatalf("control, box-wui key in workspace %s: %v", tenant, err)
		}
	}
}
