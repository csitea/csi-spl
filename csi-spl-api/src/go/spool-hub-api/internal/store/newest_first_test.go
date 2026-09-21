package store

// CLE-3425 — every listing the store answers is newest first. These are the two
// orderings clients render straight through: the channel list and the member
// list. Ordering that a client re-sorts anyway is not covered here.

import (
	"testing"
	"time"
)

func TestSortChannelStatsNewestActivityFirst(t *testing.T) {
	at := func(s string) time.Time {
		v, err := time.Parse(time.RFC3339, s)
		if err != nil {
			t.Fatal(err)
		}
		return v
	}
	stat := func(id string, created, last string) ChannelStat {
		st := ChannelStat{Channel: Channel{ChannelID: id}}
		if created != "" {
			st.CreatedAt = at(created)
		}
		if last != "" {
			st.LastAt = at(last)
		}
		return st
	}
	// The four dev t1 rows measured on 2026-09-20 before the fix, when the WUI
	// rendered the hub's a-z answer: alerts, live-proof, lobby, tasks.
	out := []ChannelStat{
		stat("alerts", "2026-09-19T16:00:00Z", ""),
		stat("live-proof", "2026-09-19T17:10:00Z", "2026-09-20T03:24:56Z"),
		stat("lobby", "2026-09-19T16:00:00Z", "2026-09-20T03:04:50Z"),
		stat("tasks", "2026-09-19T16:00:00Z", ""),
	}
	SortChannelStats(out)
	want := []string{"live-proof", "lobby", "alerts", "tasks"}
	for i, id := range want {
		if out[i].ChannelID != id {
			t.Fatalf("order %d: got %s, want %s (%v)", i, out[i].ChannelID, id, order(out))
		}
	}
	// alerts and tasks were seeded with the tenant, so they tie on creation and
	// the tie-break is a-z - stated here as the contract rather than left to luck.
	if out[2].ChannelID != "alerts" || out[3].ChannelID != "tasks" {
		t.Fatalf("a-z breaks a tie: %v", order(out))
	}

	// A channel created seconds ago, with nothing in it, leads: it is the newest
	// thing in the tenant, and created_at is all there is to rank it by.
	out = append(out, stat("brand-new", "2026-09-20T06:00:00Z", ""))
	SortChannelStats(out)
	if out[0].ChannelID != "brand-new" {
		t.Fatalf("a fresh empty channel leads: %v", order(out))
	}
	if got := ChannelActivity(out[0]); !got.Equal(at("2026-09-20T06:00:00Z")) {
		t.Fatalf("ChannelActivity of an empty channel is its created_at, got %v", got)
	}
	// CONTROL: a message always wins over creation on the SAME channel.
	if got := ChannelActivity(stat("x", "2026-09-20T06:00:00Z", "2026-09-20T07:00:00Z")); !got.Equal(at("2026-09-20T07:00:00Z")) {
		t.Fatalf("a message wins over creation, got %v", got)
	}
}

func order(out []ChannelStat) []string {
	ids := make([]string, 0, len(out))
	for _, st := range out {
		ids = append(ids, st.ChannelID)
	}
	return ids
}

func TestSortHumansNewestFirst(t *testing.T) {
	hs := []HumanEntry{{HumanID: "HUM-2"}, {HumanID: "HUM-10"}, {HumanID: "HUM-1"}, {HumanID: "HUM-9"}}
	sortHumans(hs)
	want := []string{"HUM-10", "HUM-9", "HUM-2", "HUM-1"}
	for i, id := range want {
		if hs[i].HumanID != id {
			t.Fatalf("order %d: got %s, want %s (%+v)", i, hs[i].HumanID, id, hs)
		}
	}
	// A 010-shaped id (HUM-google-sub-1@t1) counts as 0 and keeps a stable a-z
	// tail rather than landing in the middle of the numbered ones.
	hs = append(hs, HumanEntry{HumanID: "HUM-google-sub-1@t1"}, HumanEntry{HumanID: "HUM-azure-sub-1@t1"})
	sortHumans(hs)
	if hs[len(hs)-2].HumanID != "HUM-azure-sub-1@t1" || hs[len(hs)-1].HumanID != "HUM-google-sub-1@t1" {
		t.Fatalf("non-numeric ids keep an a-z tail: %+v", hs)
	}
}
