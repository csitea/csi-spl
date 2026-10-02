package store

import (
	"context"
	"errors"
	"testing"
	"time"
)

// Spec 061 (rdb 0101): the alias table is written once. A second put of the
// same legacy id keeps the first row; a row 0101 would refuse is
// ErrBadAlias; another tenant sees none of it. Run on Memory and Postgres.
func TestAgentAliasesPutOnceList(t *testing.T) {
	ctx := context.Background()
	t0 := time.Date(2026, 10, 2, 8, 0, 0, 0, time.UTC)
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			tid := newTenant(t, st)
			other := newTenant(t, st)

			if as, err := st.ListAgentAliases(ctx, tid); err != nil || len(as) != 0 {
				t.Fatalf("empty table: %+v %v", as, err)
			}
			a := AgentAlias{OldID: "CLE-77952", NewID: "c-004", Kind: "claude", BoxID: "box-desk"}
			got, created, err := st.PutAgentAlias(ctx, tid, a, t0)
			if err != nil || !created || got.NewID != "c-004" || !got.MappedAt.Equal(t0) {
				t.Fatalf("first put: %+v %v %v", got, created, err)
			}
			again := AgentAlias{OldID: "CLE-77952", NewID: "c-005", Kind: "claude", BoxID: "box-desk"}
			if got, created, err = st.PutAgentAlias(ctx, tid, again, t0.Add(time.Hour)); err != nil || created || got.NewID != "c-004" {
				t.Fatalf("second put must keep the first row: %+v %v %v", got, created, err)
			}
			if _, _, err := st.PutAgentAlias(ctx, tid, AgentAlias{OldID: "AGY-2", NewID: "a-005", Kind: "agy", BoxID: "box-desk"}, t0.Add(time.Minute)); err != nil {
				t.Fatal(err)
			}
			for _, bad := range []AgentAlias{
				{OldID: "c-004", NewID: "c-006", Kind: "claude", BoxID: "box-a"}, // old is not legacy
				{OldID: "CLE-1", NewID: "CLE-2", Kind: "claude", BoxID: "box-a"}, // new is not new
				{OldID: "CLE-1", NewID: "g-006", Kind: "grok", BoxID: "box-a"},   // kind changes
				{OldID: "CLE-1", NewID: "c-006", Kind: "grok", BoxID: "box-a"},   // kind column lies
				{OldID: "CLE-1", NewID: "c-006", Kind: "claude", BoxID: "Box"},
				{OldID: "CLE-1", NewID: "c-006", Kind: "claude"}, // no box
			} {
				if _, _, err := st.PutAgentAlias(ctx, tid, bad, t0); !errors.Is(err, ErrBadAlias) {
					t.Errorf("%+v: %v, want ErrBadAlias", bad, err)
				}
			}
			// the same legacy number on another machine is another row
			sat := AgentAlias{OldID: "CLE-77952", NewID: "c-004", Kind: "claude", BoxID: "box-sat"}
			if _, created, err := st.PutAgentAlias(ctx, tid, sat, t0.Add(2*time.Minute)); err != nil || !created {
				t.Fatalf("other box: %v %v", created, err)
			}
			as, err := st.ListAgentAliases(ctx, tid)
			if err != nil || len(as) != 3 || as[0].OldID != "CLE-77952" || as[1].OldID != "AGY-2" || as[0].BoxID != "box-desk" || as[2].BoxID != "box-sat" {
				t.Fatalf("list: %+v %v", as, err)
			}
			if as, err := st.ListAgentAliases(ctx, other); err != nil || len(as) != 0 {
				t.Fatalf("other tenant reads %+v %v", as, err)
			}
		})
	}
}
