package store

import (
	"context"
	"testing"
	"time"
)

// TestUnsignedReplay (CLE-77876): UnsignedWUIPosts lists only a tenant's
// unsigned human channel posts of box-wui since a time, oldest first;
// ResignMessage signs such a row once and refuses a signed or foreign one.
func TestUnsignedReplay(t *testing.T) {
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			rs, ok := s.(UnsignedReplay)
			if !ok {
				t.Fatalf("%s has no UnsignedReplay", name)
			}
			ctx := context.Background()
			now := time.Now().UTC().Truncate(time.Microsecond)
			a, b := newTenant(t, s), newTenant(t, s)
			put := func(tenant, fromBox, from, channel, sig string, at time.Time) string {
				t.Helper()
				m := msgFor(tenant, uuid4(), "box-wui", at, at, `{"env":1}`)
				m.FromBox, m.FromID, m.Channel, m.EnvSig = fromBox, from, channel, sig
				if ins, err := s.InsertMessage(ctx, m); err != nil || !ins {
					t.Fatalf("insert: %v %v", ins, err)
				}
				return m.MsgID
			}
			old := put(a, "box-wui", "HUM-1", "lobby", "", now.Add(-3*time.Hour))
			first := put(a, "box-wui", "HUM-2", "lobby", "", now.Add(-2*time.Hour))
			second := put(a, "box-wui", "HUM-2", "lobby", "", now.Add(-time.Hour))
			put(a, "box-wui", "HUM-2", "lobby", "sig", now.Add(-time.Hour))     // signed
			put(a, "box-wui", "HUM-2", "", "", now.Add(-time.Hour))             // a DM
			put(a, "box-wui", "GRK-03", "lobby", "", now.Add(-time.Hour))       // not a human
			agent := put(a, "box-a", "HUM-2", "lobby", "", now.Add(-time.Hour)) // not box-wui
			put(b, "box-wui", "HUM-2", "lobby", "", now.Add(-time.Hour))        // another tenant

			got, err := rs.UnsignedWUIPosts(ctx, a, now.Add(-150*time.Minute), now, 10)
			if err != nil {
				t.Fatal(err)
			}
			if len(got) != 2 || got[0].MsgID != first || got[1].MsgID != second || got[0].Channel != "lobby" {
				t.Fatalf("listed %+v", got)
			}
			if one, _ := rs.UnsignedWUIPosts(ctx, a, now.Add(-150*time.Minute), now, 1); len(one) != 1 || one[0].MsgID != first {
				t.Fatalf("limit 1: %+v", one)
			}
			if won, err := rs.ResignMessage(ctx, a, first, []byte(`{"signed":1}`), "newsig"); err != nil || !won {
				t.Fatalf("resign: %v %v", won, err)
			}
			if won, _ := rs.ResignMessage(ctx, a, first, []byte(`{"signed":2}`), "again"); won {
				t.Fatal("a signed row was signed again")
			}
			if won, _ := rs.ResignMessage(ctx, a, agent, []byte(`{}`), "x"); won {
				t.Fatal("a box row was re-signed")
			}
			if won, _ := rs.ResignMessage(ctx, b, old, []byte(`{}`), "x"); won {
				t.Fatal("another tenant's row was re-signed")
			}
			got, _ = rs.UnsignedWUIPosts(ctx, a, now.Add(-4*time.Hour), now, 10)
			if len(got) != 2 || got[0].MsgID != old || got[1].MsgID != second {
				t.Fatalf("after resign %+v", got)
			}
		})
	}
}
