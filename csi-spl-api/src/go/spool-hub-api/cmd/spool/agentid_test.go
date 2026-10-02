package main

import (
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/agentid"
	"github.com/csitea/csi-spl/spool-hub-api/internal/config"
)

// Spec 061: the `spool` flag edge normalises, resolves a legacy id through
// $SPOOL_ROOT/agent-id-aliases.tsv, and refuses it after the deadline.
func TestEdgeIDs(t *testing.T) {
	root := t.TempDir()
	tsv := "CLE-77952\tc-004\tclaude\tbox-desk\t2026-10-02T08:00:00Z\nnot a row\n"
	if err := os.WriteFile(filepath.Join(root, AliasFile), []byte(tsv), 0o644); err != nil {
		t.Fatal(err)
	}
	cfg := &config.Config{SpoolRoot: root}
	old := agentid.Now
	t.Cleanup(func() { agentid.Now = old })

	agentid.Now = func() time.Time { return agentid.LegacyUntil }
	from, to, holder, empty := "CLE-77952", "C-005", "CLE-77952@box-desk", ""
	other := "CLE-77952@box-sat"
	if err := edgeIDs(cfg, map[string]*string{"from": &from, "to": &to, "holder": &holder, "by": &empty, "as": &other}); err != nil {
		t.Fatal(err)
	}
	if from != "c-004" || to != "c-005" || holder != "c-004@box-desk" || empty != "" || other != "CLE-77952@box-sat" {
		t.Fatalf("resolved: %q %q %q %q", from, to, holder, empty)
	}
	unaliased := "CLE-1"
	if err := edgeIDs(cfg, map[string]*string{"as": &unaliased}); err != nil || unaliased != "CLE-1" {
		t.Fatalf("unaliased: %q %v", unaliased, err)
	}

	agentid.Now = func() time.Time { return agentid.LegacyUntil.Add(time.Second) }
	late := "CLE-77952"
	err := edgeIDs(cfg, map[string]*string{"from": &late})
	if err == nil || err.Error() != "--from: CLE-77952 is retired as an id; use c-004" {
		t.Fatalf("after the deadline: %v", err)
	}
}
