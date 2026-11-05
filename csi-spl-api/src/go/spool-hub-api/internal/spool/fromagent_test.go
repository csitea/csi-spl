package spool

import (
	"os"
	"path/filepath"
	"testing"
)

// HOWTO-satellite-work §4 gap 3: a relayed line names its sender's box, and
// only the box whose pin signed the envelope may make that claim.
func TestWithFromAgent(t *testing.T) {
	st := New(newCfg(t))
	m, err := st.Compose("CLE-001", "CLE-100004", "", "note", "from_agent: CLE-77963@box-desk\nthe body", nil)
	if err != nil {
		t.Fatal(err)
	}
	got := WithFromAgent(m, "box-desk")
	if got.From != "CLE-77963@box-desk" || got.Body != "the body" {
		t.Fatalf("got from=%q body=%q", got.From, got.Body)
	}
	if m.From != "CLE-001" {
		t.Fatalf("the original was mutated: %q", m.From)
	}
	for name, box := range map[string]string{"another box's claim": "sat", "no box": ""} {
		if got := WithFromAgent(m, box); got != m {
			t.Fatalf("%s: rewritten to %q", name, got.From)
		}
	}
	for _, body := range []string{"no claim\nfrom_agent: CLE-9@box-desk", "from_agent: HUM-4@box-desk\nx", "from_agent: CLE-9\nx", "from_agent: CLE-9@box-desk"} {
		mm := *m
		mm.Body = body
		if got := WithFromAgent(&mm, "box-desk"); got != &mm {
			t.Fatalf("%q: rewritten to %q", body, got.From)
		}
	}
}

// The rewritten line still reaches the harness inbox (bridgeFleet) and reads
// back with `spool recv` (validStored), from carrying @box.
func TestDeliverAtBoxSenderIntoFleetRoot(t *testing.T) {
	cfg := newCfg(t)
	fleet := t.TempDir()
	cfg.FleetRoot = fleet
	st := New(cfg)
	if err := os.MkdirAll(filepath.Join(fleet, "CLE-77963", "inbox"), 0o775); err != nil {
		t.Fatal(err)
	}
	m, err := st.Compose("CLE-001", "CLE-77963", "", "result", "from_agent: CLE-100004@sat\nreply from the satellite", nil)
	if err != nil {
		t.Fatal(err)
	}
	if wrote, err := st.Deliver(WithFromAgent(m, "sat")); err != nil || !wrote {
		t.Fatalf("deliver: %v %v", wrote, err)
	}
	fcfg := *cfg
	fcfg.SpoolRoot, fcfg.FleetRoot = fleet, ""
	got, err := New(&fcfg).Recv("CLE-77963", true)
	if err != nil || len(got.Messages) != 1 || got.Failed != 0 {
		t.Fatalf("recv in the fleet root: %v %+v", err, got)
	}
	if g := got.Messages[0]; g.From != "CLE-100004@sat" || g.Body != "reply from the satellite" {
		t.Fatalf("got from=%q body=%q", g.From, g.Body)
	}
	// control: a malformed @box from is still refused on read
	if err := validStored(got.Messages[0]); err != nil {
		t.Fatal(err)
	}
	bad := *got.Messages[0]
	bad.From = "CLE-100004@Not A Box"
	if validStored(&bad) == nil {
		t.Fatal("a malformed box in from passed validStored")
	}
}

// FromAgentOf is the same rule on a hub row's columns (RCA 8c64225e A1.1).
func TestFromAgentOf(t *testing.T) {
	id, box, rest, ok := FromAgentOf("c-003", "box-a", "from_agent: c-001@box-a\nReal subject\nmore")
	if !ok || id != "c-001" || box != "box-a" || rest != "Real subject\nmore" {
		t.Fatalf("got %q %q %q %v", id, box, rest, ok)
	}
	for name, c := range map[string][3]string{
		"another box's claim": {"c-003", "box-b", "from_agent: c-001@box-a\nx"},
		"a person's row":      {"HUM-4", "box-a", "from_agent: c-001@box-a\nx"},
		"no line":             {"c-003", "box-a", "plain\nfrom_agent: c-001@box-a"},
		"one line only":       {"c-003", "box-a", "from_agent: c-001@box-a"},
	} {
		if _, _, rest, ok := FromAgentOf(c[0], c[1], c[2]); ok || rest != c[2] {
			t.Fatalf("%s: split to %q", name, rest)
		}
	}
}
