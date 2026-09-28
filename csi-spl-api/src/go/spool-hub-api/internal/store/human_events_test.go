package store

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"testing"
	"time"
)

// events-v1 store (rdb 0045) on memory and, with SPOOL_TEST_PG_DSN,
// Postgres: own rows only, newest first, paging, the 500-row trim, clear, and
// the row checks the table enforces.
func TestHumanEvents(t *testing.T) {
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			now := time.Now().UTC().Truncate(time.Microsecond)
			h := s.(Humans)
			es := s.(HumanEvents)
			a, err := h.Admit(ctx, Identity{Provider: "google", Subject: uid("ev-a-")}, "", AdmitPolicy{}, now)
			if err != nil {
				t.Fatal(err)
			}
			b, err := h.Admit(ctx, Identity{Provider: "google", Subject: uid("ev-b-")}, "", AdmitPolicy{}, now)
			if err != nil {
				t.Fatal(err)
			}
			at := now.Add(-time.Second)
			if _, err := es.AddHumanEvents(ctx, "HUM-999999999", []HumanEvent{{Message: "x"}}, now); !errors.Is(err, ErrNotFound) {
				t.Fatalf("unknown human: %v", err)
			}
			for _, bad := range []HumanEvent{{ErrorID: "ERR-nope"}, {Status: 1000}, {Message: strings.Repeat("m", 801)}, {Method: "\xff"}} {
				if _, err := es.AddHumanEvents(ctx, a, []HumanEvent{bad}, now); err == nil {
					t.Fatalf("bad row accepted: %+v", bad)
				}
			}
			n, err := es.AddHumanEvents(ctx, a, []HumanEvent{
				{ErrorID: "ERR-20260925-190000-9B2F", OccurredAt: &at, Source: "api", Status: 502, Message: "one", Route: "/lobby"},
				{Message: "two"},
			}, now)
			if err != nil || n != 2 {
				t.Fatalf("add: %d %v", n, err)
			}
			if _, err := es.AddHumanEvents(ctx, b, []HumanEvent{{Message: "bob"}}, now); err != nil {
				t.Fatal(err)
			}
			got, err := es.HumanEventsPage(ctx, a, 0, 10)
			if err != nil || len(got) != 2 || got[0].Message != "two" || got[1].Message != "one" {
				t.Fatalf("page: %v %+v", err, got)
			}
			one := got[1]
			if one.Kind != HumanEventKindError || one.HumanID != a || one.Status != 502 || one.OccurredAt == nil ||
				!one.OccurredAt.Equal(at) || !one.ReceivedAt.Equal(now) || one.ErrorID != "ERR-20260925-190000-9B2F" {
				t.Fatalf("row: %+v", one)
			}
			if p, _ := es.HumanEventsPage(ctx, a, got[0].ID, 10); len(p) != 1 || p[0].Message != "one" {
				t.Fatalf("before: %+v", p)
			}
			// Trim to the newest HumanEventsKeep.
			batch := make([]HumanEvent, 0, HumanEventsKeep+5)
			for i := 0; i < HumanEventsKeep+5; i++ {
				batch = append(batch, HumanEvent{Message: fmt.Sprintf("m%03d", i)})
			}
			if _, err := es.AddHumanEvents(ctx, a, batch, now); err != nil {
				t.Fatal(err)
			}
			all, _ := es.HumanEventsPage(ctx, a, 0, HumanEventsKeep+50)
			if len(all) != HumanEventsKeep || all[0].Message != fmt.Sprintf("m%03d", HumanEventsKeep+4) || all[len(all)-1].Message != "m005" {
				t.Fatalf("trim: %d rows, newest %q oldest %q", len(all), all[0].Message, all[len(all)-1].Message)
			}
			if bob, _ := es.HumanEventsPage(ctx, b, 0, 10); len(bob) != 1 {
				t.Fatalf("trim touched bob: %+v", bob)
			}
			c, err := es.ClearHumanEvents(ctx, a)
			if err != nil || c != HumanEventsKeep {
				t.Fatalf("clear: %d %v", c, err)
			}
			if p, _ := es.HumanEventsPage(ctx, a, 0, 10); len(p) != 0 {
				t.Fatalf("after clear: %+v", p)
			}
			if bob, _ := es.HumanEventsPage(ctx, b, 0, 10); len(bob) != 1 {
				t.Fatalf("clear touched bob: %+v", bob)
			}
		})
	}
}
