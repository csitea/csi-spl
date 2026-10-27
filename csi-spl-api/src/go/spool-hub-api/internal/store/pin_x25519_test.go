package store

import (
	"context"
	"errors"
	"os"
	"testing"
	"time"
)

// rdb 0234 (spec 127 5.2 step 3): a live pin carries its desk recipient,
// "" clears it, a revoked or missing pin is ErrNotFound; Postgres refuses a
// value that is not an age recipient (23514).
func TestPinBoxX25519(t *testing.T) {
	stores := map[string]interface {
		Store
		PinX25519
	}{"memory": NewMemory()}
	if os.Getenv("SPOOL_TEST_PG_DSN") != "" {
		stores["postgres"] = rlsStore(t)
	}
	const rc = "age1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq"
	for name, s := range stores {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			now := time.Now()
			a := newTenant(t, s)
			if err := s.SetPinBoxX25519(ctx, a, "box-a", rc, now); !errors.Is(err, ErrNotFound) {
				t.Fatalf("no pin: %v, want ErrNotFound", err)
			}
			if err := s.PutPin(ctx, a, "box-a", pubkey(), false, now, now); err != nil {
				t.Fatal(err)
			}
			if got, err := s.PinBoxX25519(ctx, a, "box-a"); err != nil || got != "" {
				t.Fatalf("fresh pin: %q %v, want none", got, err)
			}
			if err := s.SetPinBoxX25519(ctx, a, "box-a", rc, now); err != nil {
				t.Fatal(err)
			}
			if got, err := s.PinBoxX25519(ctx, a, "box-a"); err != nil || got != rc {
				t.Fatalf("after set: %q %v", got, err)
			}
			if err := s.SetPinBoxX25519(ctx, a, "box-a", "", now); err != nil {
				t.Fatal(err)
			}
			if got, err := s.PinBoxX25519(ctx, a, "box-a"); err != nil || got != "" {
				t.Fatalf("after clear: %q %v", got, err)
			}
			if pg, ok := s.(*Postgres); ok {
				if err := pg.SetPinBoxX25519(ctx, a, "box-a", "not-a-recipient", now); pgCode(err) != "23514" {
					t.Fatalf("malformed recipient: %v, want 23514", err)
				}
			}
		})
	}
}
