package store

import (
	"context"
	"slices"
	"strings"
	"testing"
	"time"
)

// b24-01 (spec 130 section 3.1): FlowQuery.Hidden cuts a line whose
// message's from_box or to_box is a hidden box out of the events, the folded
// lines, the counts, unread and keys, in both drivers. Without Hidden
// (the control) the same member reads every line.
func TestFlowReadCutByHiddenBoxes(t *testing.T) {
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			base := time.Now().UTC().Truncate(time.Microsecond)
			now := base.Add(time.Hour)
			tid := newTenant(t, s)
			if err := s.CreateChannel(ctx, Channel{TenantID: tid, ChannelID: "sec", Name: "sec", CreatedBy: "HUM-1", CreatedAt: base}); err != nil {
				t.Fatal(err)
			}
			if err := s.AddChannelHumans(ctx, tid, "sec", []string{"HUM-1"}, "HUM-1", base); err != nil {
				t.Fatal(err)
			}
			n := 0
			post := func(fromBox, toID, toBox, channel string) string {
				t.Helper()
				n++
				at := base.Add(time.Duration(n) * time.Second)
				m := msgFor(tid, uuid4(), toBox, at, at, "env-"+uuid4())
				m.FromBox, m.FromID, m.ToID, m.Channel, m.Body = fromBox, "c-002", toID, channel, "status"
				if _, err := s.InsertMessage(ctx, m); err != nil {
					t.Fatal(err)
				}
				return m.TaskID
			}
			locked := []string{
				post("box-lk", "HUM-1", "", "sec"),       // an event from the hidden box
				post("box-lk", "HUM-1", "", ""),          // a DM from it
				post("box-op", "c-009", "box-lk", "sec"), // a channel line to it (keys only)
			}
			open := post("box-op", "HUM-1", "", "sec")
			read := func(hidden []string) (FlowPage, FlowFold) {
				t.Helper()
				q := FlowQuery{Tenant: tid, Member: "HUM-1", Limit: 30, Now: now, Hidden: hidden}
				p, err := s.(FlowEvents).FlowRead(ctx, q)
				if err != nil {
					t.Fatal(err)
				}
				f, err := s.(FlowFolder).FlowFoldRead(ctx, q)
				if err != nil {
					t.Fatal(err)
				}
				return p, f
			}
			p, f := read(nil)
			if len(p.Events) != 3 || len(f.Lines) != 3 || p.Unread.Total != 3 || p.Keys["t:"+locked[2]] != 1 {
				t.Fatalf("CONTROL no lock: %d events, %d lines, unread %+v, keys %v; want 3, 3, 3 and t:<to the box> 1",
					len(p.Events), len(f.Lines), p.Unread, p.Keys)
			}
			p, f = read([]string{"box-lk"})
			if len(p.Events) != 1 || p.Events[0].TaskID != open {
				t.Errorf("events %+v, want the open box's line only", p.Events)
			}
			if len(f.Lines) != 1 || f.Lines[0].TaskID != open {
				t.Errorf("lines %+v, want the open box's line only", f.Lines)
			}
			for _, c := range []FlowCounts{p.Counts, p.Unread, f.Counts, f.Unread} {
				if c.Total != 1 || c.DMs != 0 {
					t.Errorf("counts %+v, want Total 1, DMs 0 (the hidden lines counted)", c)
				}
			}
			for _, keys := range []map[string]int{p.Keys, f.Keys} {
				for k := range keys {
					if strings.HasPrefix(k, "dm:") || slices.ContainsFunc(locked, func(task string) bool { return strings.Contains(k, task) }) {
						t.Errorf("key %s names a hidden line: %v", k, keys)
					}
				}
				if keys["t:"+open] != 1 || keys["ch:sec"] != 1 {
					t.Errorf("keys %v, want t:<open> 1 and ch:sec 1", keys)
				}
			}
		})
	}
}
