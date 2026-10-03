package store

import (
	"strings"
	"testing"
	"time"
)

// Refactor r2 #5: sortAliases and sortReleaseNotes are stable sorts. Ties on
// every key keep their input order; NewID / Subject tell the rows apart.
func TestSortAliasesTies(t *testing.T) {
	t0 := time.Date(2026, 10, 2, 8, 0, 0, 0, time.UTC)
	t1 := t0.Add(time.Minute)
	in := []AgentAlias{
		{OldID: "CLE-2", BoxID: "b", NewID: "1", MappedAt: t1},
		{OldID: "CLE-1", BoxID: "b", NewID: "2", MappedAt: t0},
		{OldID: "CLE-1", BoxID: "a", NewID: "3", MappedAt: t0},
		{OldID: "CLE-2", BoxID: "a", NewID: "4", MappedAt: t0.In(time.FixedZone("x", 3600))},
		{OldID: "CLE-1", BoxID: "a", NewID: "5", MappedAt: t0},
		{OldID: "CLE-1", BoxID: "b", NewID: "6", MappedAt: t1},
	}
	sortAliases(in)
	var got []string
	for _, a := range in {
		got = append(got, a.NewID)
	}
	if want := "3 5 2 4 6 1"; strings.Join(got, " ") != want {
		t.Fatalf("order = %v, want %s", got, want)
	}
}

func TestSortReleaseNotesTies(t *testing.T) {
	t0 := time.Date(2026, 10, 2, 8, 0, 0, 0, time.UTC)
	t1 := t0.Add(time.Hour)
	in := []ReleaseNote{
		{Version: "v1.2.3", CommittedAt: t0, SHA: "b", Subject: "1"},
		{Version: "", CommittedAt: t1, SHA: "a", Subject: "2"},
		{Version: "v1.10.0", CommittedAt: t0, SHA: "c", Subject: "3"},
		{Version: "v1.2.3", CommittedAt: t1, SHA: "z", Subject: "4"},
		{Version: "v1.2.3", CommittedAt: t0, SHA: "a", Subject: "5"},
		{Version: "v1.2.3", CommittedAt: t0, SHA: "a", Subject: "6"},
		{Version: "bogus", CommittedAt: t1, SHA: "a", Subject: "7"},
		{Version: "", CommittedAt: t0, SHA: "a", Subject: "8"},
	}
	sortReleaseNotes(in)
	var got []string
	for _, n := range in {
		got = append(got, n.Subject)
	}
	if want := "3 4 5 6 1 2 7 8"; strings.Join(got, " ") != want {
		t.Fatalf("order = %v, want %s", got, want)
	}
}
