// SPDX-License-Identifier: AGPL-3.0-only

package hub_test

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/csitea/csi-spl/spool-hub-api/internal/blob"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// P7 (spec 169 T8b): the objects of 5.3 are proved in the buckets themselves,
// and the kept list (5.6) carries the date each copy expires.

// toP6 runs a whole move up to and with P6.
func (f *moveFix) toP6(t *testing.T) {
	t.Helper()
	f.toP3(t)
	f.must(t, "step", "P4", nil)
	f.must(t, "mark", "P5", nil)
	f.must(t, "step", "P6", nil)
}

// proofsByName is P7's .proofs as name -> count.
func proofsByName(out map[string]any) map[string]float64 {
	m := map[string]float64{}
	ps, _ := out["proofs"].([]any)
	for _, p := range ps {
		r := p.(map[string]any)
		m[r["name"].(string)], _ = r["count"].(float64)
	}
	return m
}

// p4DoneAt reads P4's done_at from the journal table, as the test's own check.
func p4DoneAt(t *testing.T, f *moveFix) time.Time {
	t.Helper()
	ctx := context.Background()
	var at time.Time
	err := pgx.BeginFunc(ctx, f.e.st.(*store.Postgres).Pool(), func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, `SELECT set_config('app.rls_scope', 'operator', true)`); err != nil {
			return err
		}
		return tx.QueryRow(ctx, `SELECT done_at FROM channel_move_steps WHERE tenant_id = $1 AND move_id = $2::uuid AND step = 'P4'`,
			f.dst, f.moveID).Scan(&at)
	})
	if err != nil {
		t.Fatal(err)
	}
	return at.UTC()
}

// The green case: both buckets' proofs are 0, and every kept row that ends with
// a retention is P4's done_at + the days P7's detail gave; the others keep their
// words. kept_until is the last of the dates (Q3).
func TestChannelMoveP7ObjectsAndExpiry(t *testing.T) {
	f := moveFixture(t, true)
	f.toP6(t)
	days := map[string]int{"daily DB dumps": 30, "off-project copy of the dumps": 90, "Cloud SQL automated backups": 7,
		"Qto daily export": 30, "box-state copy": 30, "hub logs": 30}
	out := f.must(t, "step", "P7", moveDetail(map[string]any{"retention_days": days}))
	got := proofsByName(out)
	for _, n := range []string{"objects M4 files bucket: left in <SRC>", "objects M4 files bucket: missing in <DST>",
		"objects M8 Qto pictures: left in <SRC>", "objects M8 Qto pictures: missing in <DST>"} {
		if c, ok := got[n]; !ok || c != 0 {
			t.Errorf("proof %q: %v %v, want present and 0", n, c, ok)
		}
	}
	at := p4DoneAt(t, f)
	kept, _ := out["kept"].([]any)
	dated := 0
	for _, k := range kept {
		r := k.(map[string]any)
		store, _ := r["store"].(string)
		d, ok := days[store]
		if !ok {
			if strings.Contains(r["gone_by"].(string), "retention") || r["expires"] != r["gone_by"] {
				t.Errorf("an undated row keeps its words: %v", r)
			}
			continue
		}
		want := at.AddDate(0, 0, d).Format(time.DateOnly)
		if r["expires"] != want || !strings.HasSuffix(r["gone_by"].(string), ": "+want) {
			t.Errorf("%s: %v, want expires %s (P4 %s + %d days)", store, r, want, at, d)
		}
		dated++
	}
	if dated != len(days) {
		t.Errorf("dated %d kept rows, want %d: %v", dated, len(days), kept)
	}
	if want := at.AddDate(0, 0, 90).Format(time.DateOnly); out["kept_until"] != want {
		t.Errorf("kept_until %v, want %s", out["kept_until"], want)
	}
	t.Logf("green: kept_until %v; proofs %v", out["kept_until"], got)
}

// RED CONTROL: an object planted back in <SRC> after P6 fails P7, which stays
// not done; P6's counts said it was deleted. With no retention_days a kept row
// says "not read", never a date.
func TestChannelMoveP7ObjectLeftInSource(t *testing.T) {
	f := moveFixture(t, true)
	f.toP6(t)
	key, err := blob.Key(f.src, f.blobID)
	if err != nil {
		t.Fatal(err)
	}
	if err := (blob.Dir{Root: f.e.blobs}).Put(context.Background(), key, []byte("the channel's file "+f.ch)); err != nil {
		t.Fatal(err)
	}
	out := f.must(t, "step", "P7", nil)
	if c := proofsByName(out)["objects M4 files bucket: left in <SRC>"]; c != 1 {
		t.Fatalf("the planted object: count %v, want 1: %v", c, out["proofs"])
	}
	if s := steps(f.must(t, "journal", "", nil))["P7"]; s != "started" {
		t.Errorf("a failed P7 is not done: %v", s)
	}
	until, _ := out["kept_until"].(string)
	if !strings.HasPrefix(until, "not read: no date for ") {
		t.Errorf("kept_until with no retention_days: %q", until)
	}
	for _, k := range out["kept"].([]any) {
		r := k.(map[string]any)
		if strings.Contains(r["gone_by"].(string), "retention") && r["expires"] != "not read: no retention_days in P7's detail" {
			t.Errorf("no date is guessed: %v", r)
		}
	}
	t.Logf("red control: objects M4 files bucket: left in <SRC> %v", proofsByName(out)["objects M4 files bucket: left in <SRC>"])
}
