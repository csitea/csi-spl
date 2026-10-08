package hubclient

import (
	"os"
	"path/filepath"
	"reflect"
	"testing"
	"time"
)

// writeRun writes a fleet root's agent run report, modified at mod.
func writeRun(t *testing.T, root, body string, mod time.Time) {
	t.Helper()
	p := filepath.Join(root, AgentRunFile)
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Chtimes(p, mod, mod); err != nil {
		t.Fatal(err)
	}
}

// t1 bc1a43e1 (fix A): the report says run for a live, able agent, stop for
// a stuck one, and nothing for one with no process - all three are reported,
// the last two as not running. A non-agent roster id is never reported.
func TestAgentRunReport(t *testing.T) {
	root := t.TempDir()
	now := time.Date(2026, 10, 8, 12, 0, 0, 0, time.UTC)
	clock := func() time.Time { return now }
	writeRun(t, root, "# agent-run v1\nc-001\trun\nc-002\tstop\tstalled pid=7: usage limit\nc-099\trun\n", now.Add(-time.Minute))
	got := AgentRunReport(root, clock)([]string{"c-001", "c-002", "c-003", "RSP-1"})
	want := map[string]bool{"c-001": true, "c-002": false, "c-003": false}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("report = %v, want %v", got, want)
	}

	// A stale report is no report: the tick stopped, so nobody knows.
	writeRun(t, root, "c-001\trun\n", now.Add(-AgentRunMaxAge-time.Second))
	if got := AgentRunReport(root, clock)([]string{"c-001"}); got != nil {
		t.Fatalf("stale report = %v, want nil", got)
	}
	// No report, no fleet root: nil, so the hub keeps the box's presence.
	if got := AgentRunReport(t.TempDir(), clock)([]string{"c-001"}); got != nil {
		t.Fatalf("missing report = %v, want nil", got)
	}
	if AgentRunReport("", clock) != nil {
		t.Fatal("no fleet root must give no report func")
	}
}

// The scan tick re-announces when the roster OR the report changed.
func TestRunKey(t *testing.T) {
	a := []string{"c-001", "c-002"}
	if runKey(nil, a) != "" {
		t.Fatal("no report must key empty")
	}
	k1 := runKey(map[string]bool{"c-001": true, "c-002": false}, a)
	k2 := runKey(map[string]bool{"c-001": true, "c-002": true}, a)
	if k1 == k2 || k1 == "" || runKey(map[string]bool{"c-001": true, "c-002": false}, a) != k1 {
		t.Fatalf("keys %q %q", k1, k2)
	}
}
