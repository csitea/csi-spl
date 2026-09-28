package mcp

import (
	"context"
	"encoding/json"
	"flag"
	"os"
	"testing"
)

var updateTools = flag.Bool("update", false, "rewrite testdata/tools.golden from the current server")

// TestToolsListGolden pins what an MCP client is told: every tool's name,
// description and input / output schema, byte for byte. Recorded before
// NewServerOpts was split into one method per tool (SPL-1029 round 2).
func TestToolsListGolden(t *testing.T) {
	cs, _ := seated(t, "")
	res, err := cs.ListTools(context.Background(), nil)
	if err != nil {
		t.Fatal(err)
	}
	got, err := json.MarshalIndent(res.Tools, "", "  ")
	if err != nil {
		t.Fatal(err)
	}
	const path = "testdata/tools.golden"
	if *updateTools {
		if err := os.MkdirAll("testdata", 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, got, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	want, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != string(want) {
		t.Fatalf("tools/list differs from %s:\n%s", path, got)
	}
}
