package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hubclient"
	"github.com/csitea/csi-spl/spool-hub-api/internal/testkit"
)

// TestHubQueue (SPL-2165): `spool hub-queue` reads the fallback queue from
// disk - no hub, no sidecar - and exits 3 once the oldest entry is past
// $SPOOL_QUEUE_WARN_AFTER; a bad value is refused naming the variable.
func TestHubQueue(t *testing.T) {
	cfg := testkit.NewConfig(t)
	cfg.BoxID = "box-a"
	pending := filepath.Join(cfg.HubDir(), "pending")
	if err := os.MkdirAll(pending, 0o775); err != nil {
		t.Fatal(err)
	}
	p := filepath.Join(pending, "20261016T100000Z--m1.json")
	if err := os.WriteFile(p, []byte("{}"), 0o664); err != nil {
		t.Fatal(err)
	}
	old := time.Now().Add(-20 * time.Minute)
	if err := os.Chtimes(p, old, old); err != nil {
		t.Fatal(err)
	}
	read := func(rc int, out string) hubclient.QueueHealth {
		t.Helper()
		var q hubclient.QueueHealth
		if err := json.Unmarshal([]byte(out), &q); err != nil {
			t.Fatalf("rc %d, not JSON: %q (%v)", rc, out, err)
		}
		return q
	}

	cfg.QueueWarnAfter = "30"
	rc, out, _ := capture(t, "", func() int { return cmdHubQueue(cfg) })
	if q := read(rc, out); rc != 0 || q.Depth != 1 || q.OldestAgeS < 1199 || q.Warn || q.WarnAfterS != 1800 {
		t.Fatalf("below the threshold: rc %d %s", rc, out)
	}
	cfg.QueueWarnAfter = "15"
	rc, out, _ = capture(t, "", func() int { return cmdHubQueue(cfg) })
	if q := read(rc, out); rc != 3 || !q.Warn {
		t.Fatalf("past the threshold: rc %d %s, want 3 and warn", rc, out)
	}
	cfg.QueueWarnAfter = ""
	rc, out, _ = capture(t, "", func() int { return cmdHubQueue(cfg) })
	if q := read(rc, out); rc != 0 || q.Warn || q.WarnAfterS != 0 {
		t.Fatalf("no threshold: rc %d %s", rc, out)
	}
	cfg.QueueWarnAfter = "soon"
	if rc, _, errOut := capture(t, "", func() int { return cmdHubQueue(cfg) }); rc != 1 || !strings.Contains(errOut, "$SPOOL_QUEUE_WARN_AFTER") {
		t.Fatalf("bad warn-after: rc %d %q", rc, errOut)
	}
	cfg.QueueWarnAfter, cfg.QueueLogEvery = "", "often"
	if rc, _, errOut := capture(t, "", func() int { return cmdHubQueue(cfg) }); rc != 1 || !strings.Contains(errOut, "$SPOOL_QUEUE_LOG_EVERY") {
		t.Fatalf("bad log-every: rc %d %q", rc, errOut)
	}
}
