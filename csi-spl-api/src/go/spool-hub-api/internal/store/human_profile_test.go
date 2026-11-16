package store

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"

	"github.com/csitea/csi-spl/spool-hub-api/internal/auth"
)

// SPL-5707 rdb 0290 (spec 154 section 12.5): the backfill splits display_name
// at its first whitespace run into first_name / last_name and never rewrites
// display_name: a name that is not "first last" stays byte-identical. It
// keeps a name already saved, applies twice, and the phone CHECK takes E.164
// only. Raw SQL inside a rolled-back transaction.
func TestHumanProfileMigration(t *testing.T) {
	pg, ok := drivers(t)["postgres"].(*Postgres)
	if !ok {
		t.Skip("SPOOL_TEST_PG_DSN unset")
	}
	ctx := context.Background()
	raw, err := os.ReadFile(filepath.Join(sqlDir(t), "0290_human_first_last_name_phone.sql"))
	if err != nil {
		t.Fatal(err)
	}
	names := []string{"  Mary \t Ann  Smith ", "Solo", "Kept Name", "   "}
	hums := make([]string, len(names))
	for i := range names {
		if hums[i], err = pg.Admit(ctx, Identity{Provider: "google", Subject: uid("hpm-")}, "", AdmitPolicy{}, time.Now().UTC()); err != nil {
			t.Fatal(err)
		}
	}
	err = pgx.BeginFunc(ctx, pg.Pool(), func(tx pgx.Tx) error {
		for i, n := range names {
			if _, err := tx.Exec(ctx, `UPDATE humans SET display_name = $2, first_name = NULL, last_name = NULL WHERE human_id = $1`, hums[i], n); err != nil {
				return err
			}
		}
		if _, err := tx.Exec(ctx, `UPDATE humans SET first_name = 'Own' WHERE human_id = $1`, hums[2]); err != nil {
			return err
		}
		for i := 0; i < 2; i++ {
			if _, err := tx.Exec(ctx, string(raw)); err != nil {
				return fmt.Errorf("apply %d: %w", i+1, err)
			}
		}
		want := [][2]any{{"Mary", "Ann  Smith"}, {"Solo", nil}, {"Own", nil}, {nil, nil}}
		for i, n := range names {
			var dn string
			var first, last *string
			if err := tx.QueryRow(ctx, `SELECT display_name, first_name, last_name FROM humans WHERE human_id = $1`, hums[i]).Scan(&dn, &first, &last); err != nil {
				return err
			}
			if dn != n {
				t.Errorf("%q: display_name rewritten to %q, want byte-identical", n, dn)
			}
			if got := [2]any{optVal(first), optVal(last)}; got != want[i] {
				t.Errorf("%q: first, last = %v, want %v", n, got, want[i])
			}
		}
		if _, err := tx.Exec(ctx, `UPDATE humans SET phone = '+358401234567' WHERE human_id = $1`, hums[0]); err != nil {
			return fmt.Errorf("E.164 phone refused: %w", err)
		}
		// The refused value is last: a check violation aborts the transaction.
		_, err := tx.Exec(ctx, `UPDATE humans SET phone = '040 123 4567' WHERE human_id = $1`, hums[0])
		var pgErr *pgconn.PgError
		if !errors.As(err, &pgErr) || pgErr.Code != "23514" || pgErr.ConstraintName != "humans_phone_check" {
			t.Errorf("phone '040 123 4567': %v, want a violation of humans_phone_check", err)
		}
		return errRollback
	})
	if !errors.Is(err, errRollback) {
		t.Fatal(err)
	}
}

func optVal(s *string) any {
	if s == nil {
		return nil
	}
	return *s
}

// The store side on every driver: SetProfileName writes display_name as the
// join, SetDisplayName splits back, SetPhone "" clears, an unknown human is
// ErrNotFound, and ListMembers carries the three.
func TestHumanProfileStore(t *testing.T) {
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			h := st.(Humans)
			tid := uid("t")
			if err := st.CreateTenant(ctx, Tenant{ID: tid, RootPubKey: make([]byte, 32)}); err != nil {
				t.Fatal(err)
			}
			hum, err := h.Admit(ctx, Identity{Provider: "google", Subject: uid("hps-")}, tid, AdmitPolicy{BootstrapOwner: true}, time.Now().UTC())
			if err != nil {
				t.Fatal(err)
			}
			if err := h.SetProfileName(ctx, hum, "FirstName", "Van LastName"); err != nil {
				t.Fatal(err)
			}
			if err := h.SetPhone(ctx, hum, "+358401234567"); err != nil {
				t.Fatal(err)
			}
			if dn, _ := h.DisplayName(ctx, hum); dn != "FirstName Van LastName" {
				t.Errorf("display_name = %q, want the join", dn)
			}
			ms, err := st.(MemberDirectory).ListMembers(ctx, tid)
			if err != nil || len(ms) != 1 || ms[0].FirstName != "FirstName" || ms[0].LastName != "Van LastName" || ms[0].Phone != "+358401234567" {
				t.Errorf("ListMembers = %+v %v", ms, err)
			}
			if err := h.SetDisplayName(ctx, hum, "Mary Ann Smith"); err != nil {
				t.Fatal(err)
			}
			if err := h.SetPhone(ctx, hum, ""); err != nil {
				t.Fatal(err)
			}
			if p, err := h.Profile(ctx, hum); err != nil || p != (auth.Profile{FirstName: "Mary", LastName: "Ann Smith"}) {
				t.Errorf("Profile = %+v %v, want Mary / Ann Smith, no phone", p, err)
			}
			// R7 W1: a human admitted with only a display_name reads first +
			// last split from it, so the Settings form is never blank.
			tid2 := uid("t")
			if err := st.CreateTenant(ctx, Tenant{ID: tid2, RootPubKey: make([]byte, 32)}); err != nil {
				t.Fatal(err)
			}
			fresh, err := h.Admit(ctx, Identity{Provider: "google", Subject: uid("hps-"), Name: "Mary Smith"}, tid2, AdmitPolicy{BootstrapOwner: true}, time.Now().UTC())
			if err != nil {
				t.Fatal(err)
			}
			if p, err := h.Profile(ctx, fresh); err != nil || p != (auth.Profile{FirstName: "Mary", LastName: "Smith"}) {
				t.Errorf("admitted Profile = %+v %v, want Mary / Smith from display_name", p, err)
			}
			if _, err := h.Profile(ctx, "HUM-0"); !errors.Is(err, ErrNotFound) {
				t.Errorf("unknown human: %v, want ErrNotFound", err)
			}
		})
	}
}
