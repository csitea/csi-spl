package store

import (
	"context"
	"testing"
	"time"
)

// perf r4 G2: LocateTopicOrMessage probes every tenant in ONE batch, each in
// its own scope. It finds the id in the tenant that holds it whatever its
// place in the list, the first holder wins, and a tenant left out of the list
// is never searched (the scope is the tenant's, never the operator's).
func TestLocateTopicOrMessage(t *testing.T) {
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			ctx, now := context.Background(), time.Now().UTC()
			a, b, c := newTenant(t, s), newTenant(t, s), newTenant(t, s)
			m := msgFor(c, uuid4(), "box-b", now, now, "e-"+c)
			if _, err := s.InsertMessage(ctx, m); err != nil {
				t.Fatal(err)
			}
			sr := s.(SetReads)
			for _, x := range []struct {
				tenants []string
				id      string
				want    string
			}{
				{[]string{a, b, c}, m.TaskID, c},
				{[]string{a, b, c}, m.MsgID, c},
				{[]string{c, a}, m.TaskID, c},
				{[]string{a, b}, m.TaskID, ""}, // CONTROL: c not asked, c not searched
				{[]string{a, b, c}, uuid4(), ""},
				{nil, m.TaskID, ""},
			} {
				got, err := sr.LocateTopicOrMessage(ctx, x.tenants, x.id)
				if err != nil || got != x.want {
					t.Fatalf("locate %v %s = %q %v, want %q", x.tenants, x.id, got, err, x.want)
				}
			}
			if _, err := sr.LocateTopicOrMessage(ctx, []string{a, " "}, m.TaskID); err == nil {
				t.Fatal("an empty tenant in the list must be refused (fail closed)")
			}
		})
	}
}

// perf r4 G2: ChannelSettings is exactly what ChannelHumanMembers and
// ChannelNoFallback read one channel at a time (the oracle), for created,
// default, opted-out and unknown channels.
func TestChannelSettingsMatchesPerChannelReads(t *testing.T) {
	pg, ok := drivers(t)["postgres"].(*Postgres)
	if !ok {
		t.Skip("SPOOL_TEST_PG_DSN unset")
	}
	ctx, now := context.Background(), time.Now()
	tid := newTenant(t, pg)
	owner := seatMember(t, pg, tid, "biz_owner")
	dev := seatMember(t, pg, tid, "developer")
	for _, c := range []string{"ops", "qa", "web"} {
		if err := pg.CreateChannel(ctx, Channel{TenantID: tid, ChannelID: c, Name: c, CreatedBy: owner, CreatedAt: now}); err != nil {
			t.Fatal(err)
		}
	}
	if err := pg.AddChannelHumans(ctx, tid, "ops", []string{owner, dev}, owner, now); err != nil {
		t.Fatal(err)
	}
	if err := pg.AddChannelHumans(ctx, tid, "qa", []string{dev}, owner, now); err != nil {
		t.Fatal(err)
	}
	if err := pg.SetChannelNoFallback(ctx, tid, "qa", true); err != nil {
		t.Fatal(err)
	}
	other := newTenant(t, pg) // CONTROL: another tenant's same slug never counts
	if err := pg.CreateChannel(ctx, Channel{TenantID: other, ChannelID: "web", Name: "web", CreatedBy: owner, CreatedAt: now}); err != nil {
		t.Fatal(err)
	}
	if err := pg.SetChannelNoFallback(ctx, other, "web", true); err != nil {
		t.Fatal(err)
	}
	ids := append([]string{"ops", "qa", "web", "nope"}, DefaultChannels...)
	got, err := pg.ChannelSettings(ctx, tid, ids)
	if err != nil {
		t.Fatal(err)
	}
	for _, ch := range ids {
		ms, err := pg.ChannelHumanMembers(ctx, tid, ch)
		if err != nil {
			t.Fatal(err)
		}
		off, err := pg.ChannelNoFallback(ctx, tid, ch)
		if err != nil {
			t.Fatal(err)
		}
		if want := (ChannelSetting{Humans: len(ms), NoFallback: off}); got[ch] != want {
			t.Fatalf("%s: set read %+v, per-channel %+v", ch, got[ch], want)
		}
	}
	if got["ops"].Humans != 2 || !got["qa"].NoFallback || got["web"].NoFallback {
		t.Fatalf("seeded facts not read: %+v", got)
	}
}
