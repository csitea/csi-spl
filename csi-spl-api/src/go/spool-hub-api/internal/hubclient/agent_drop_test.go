package hubclient

import (
	"os"
	"path/filepath"
	"reflect"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/config"
)

// dropClient is a box client on box "box-a" whose fleet root holds files,
// with a clock the test moves.
func dropClient(t *testing.T, files map[string]string) (*Client, *time.Time) {
	t.Helper()
	root := t.TempDir()
	for p, body := range files {
		full := filepath.Join(root, p)
		if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(full, []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	now := time.Date(2026, 10, 8, 12, 0, 0, 0, time.UTC)
	c := New(&config.Config{BoxID: "box-a", FleetRoot: root})
	c.Now = func() time.Time { return now }
	c.DropAfter = time.Hour
	return c, &now
}

// t1 bc1a43e1 (fix B): the role ids 001..003 are kept while this box's
// lease mirror seats them here or a rotation holds them; otherwise a dead
// role id leaves like any other (c-001@box-a while lease.orch says c-001@box-b).
func TestDropDeadRoleIDs(t *testing.T) {
	agents := []string{"c-001", "c-002", "c-003", "c-045", "HUM-1"}
	run := map[string]bool{"c-001": false, "c-002": false, "c-003": false, "c-045": false}
	c, now := dropClient(t, map[string]string{
		"dispatch/lease":      "c-003@box-a 1791472541\n",
		"dispatch/lease.orch": "c-001@box-b 1791472539\n",
		AgentRunFile:          "# agent-run v1\nc-002\tstop\theld: rotation since 46s\nc-045\tstop\tstalled pid=7: usage limit\n",
	})
	if got := c.dropDead(agents, run); !reflect.DeepEqual(got, agents) {
		t.Fatalf("first report dropped %v", got)
	}
	*now = now.Add(time.Hour + time.Second)
	want := []string{"c-002", "c-003", "HUM-1"} // HUM-1: never reported, never dropped
	if got := c.dropDead(agents, run); !reflect.DeepEqual(got, want) {
		t.Fatalf("past 1h = %v, want %v", got, want)
	}
	// No report: nothing is dropped.
	if got := c.dropDead(agents, nil); !reflect.DeepEqual(got, agents) {
		t.Fatalf("no report dropped %v", got)
	}
	// A line it sends revives it: its clock restarts.
	c.revive("c-045")
	if got := c.dropDead(agents, run); !reflect.DeepEqual(got, []string{"c-002", "c-003", "c-045", "HUM-1"}) {
		t.Fatalf("revived = %v", got)
	}
	// CONTROL: no threshold, no drop.
	c.DropAfter = 0
	if got := c.dropDead(agents, run); !reflect.DeepEqual(got, agents) {
		t.Fatalf("DropAfter 0 dropped %v", got)
	}
}

func TestParseDropAfter(t *testing.T) {
	for in, want := range map[string]time.Duration{"": 0, "0": 0, "60": time.Hour, " 90 ": 90 * time.Minute, "2h": 2 * time.Hour} {
		if got, err := ParseDropAfter(in); err != nil || got != want {
			t.Fatalf("ParseDropAfter(%q) = %v, %v; want %v", in, got, err, want)
		}
	}
	if _, err := ParseDropAfter("soon"); err == nil {
		t.Fatal("a bad value must refuse")
	}
}
