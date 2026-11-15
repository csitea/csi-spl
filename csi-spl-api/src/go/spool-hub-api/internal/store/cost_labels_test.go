package store

import (
	"context"
	"errors"
	"testing"
)

// SPL-5546, rdb 0285: an entry's text is its master-locale label from the
// start; the other locales are set, replaced and read back; the master's is
// never edited; a reader gets its locale, else the master's text.
func TestCostEntryLabels(t *testing.T) {
	ctx := context.Background()
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			cl, ce := st.(CostLabelStore), st.(CostEntryStore)
			master, err := cl.CostLabelMaster(ctx)
			if err != nil || master != MemCostLabelMaster {
				t.Fatalf("master: %q %v, want %q (rdb 0285 seed)", master, err, MemCostLabelMaster)
			}
			text := "Заплата " + uid("")[:8]
			e, err := ce.CreateCostEntry(ctx, CostEntry{Type: "hr", Label: text, Amount: 10, Currency: "EUR", Period: "2026-10", CreatedBy: "op"})
			if err != nil {
				t.Fatal(err)
			}
			all, err := cl.CostEntryLabels(ctx)
			if err != nil || len(all[e.ID]) != 1 || all[e.ID][master] != text {
				t.Fatalf("a new entry's labels: %v %v, want only {%s: %s}", all[e.ID], err, master, text)
			}
			if err := cl.SetCostEntryLabels(ctx, e.ID, map[string]string{"en": "Salary", "fi": "Palkka", master: text}, "acc"); err != nil {
				t.Fatal(err)
			}
			if err := cl.SetCostEntryLabels(ctx, e.ID, map[string]string{"en": "Gross salary"}, "acc"); err != nil {
				t.Fatal(err)
			}
			all, _ = cl.CostEntryLabels(ctx)
			if got := all[e.ID]; len(got) != 2 || got["en"] != "Gross salary" || got[master] != text {
				t.Fatalf("replaced labels: %v, want en + the master's only (fi dropped)", got)
			}
			for want, loc := range map[string]string{"Gross salary": "en", text + "|fi": "fi", text + "|": ""} {
				in, err := cl.CostLabelsIn(ctx, loc)
				if err != nil {
					t.Fatal(err)
				}
				if got, ok := in[text]; (want == "Gross salary") != ok || (ok && got != want) {
					t.Errorf("CostLabelsIn(%q)[text] = %q %v; want %q (the master's text is no entry)", loc, got, ok, want)
				}
			}
			for why, bad := range map[string]map[string]string{
				"the master's text changed": {master: "Other"}, "an unknown locale": {"xx": "x"},
				"an empty label": {"en": " "}, "a 101-character label": {"en": string(make([]rune, 101))},
			} {
				if err := cl.SetCostEntryLabels(ctx, e.ID, bad, "acc"); err == nil || errors.Is(err, ErrNotFound) {
					t.Errorf("%s: %v, want a check error", why, err)
				}
			}
			if err := cl.SetCostEntryLabels(ctx, "00000000-0000-4000-8000-000000000000", map[string]string{"en": "x"}, "acc"); !errors.Is(err, ErrNotFound) {
				t.Errorf("no entry: %v, want ErrNotFound", err)
			}
			if err := ce.DeleteCostEntry(ctx, e.ID); err != nil {
				t.Fatal(err)
			}
			if all, _ = cl.CostEntryLabels(ctx); len(all[e.ID]) != 0 {
				t.Errorf("a deleted entry's labels stay: %v", all[e.ID])
			}
		})
	}
}

// SPL-5546: a component's label is the reader's locale's, else the seed's
// English (no master-locale row is seeded).
func TestHRComponentLabelsIn(t *testing.T) {
	ctx := context.Background()
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			in, err := st.(CostLabelStore).HRComponentLabelsIn(ctx, "fi")
			if err != nil {
				t.Fatal(err)
			}
			if len(in) != len(DefaultHRComponents) {
				t.Fatalf("%d components, want %d", len(in), len(DefaultHRComponents))
			}
			for _, c := range DefaultHRComponents {
				if in[c.Component] != c.Label {
					t.Errorf("%s: %q, want the seed's %q", c.Component, in[c.Component], c.Label)
				}
			}
		})
	}
}
