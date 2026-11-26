package hub_test

import (
	"context"
	"encoding/json"
	"strings"
	"testing"

	"github.com/rs/zerolog"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
)

// SPL-4632: every stored beat writes one info line, message "box beat" with
// its tenant and box; the fleet-silent page of step 070 counts them per
// tenant. CONTROL: a refused beat writes none, so a fleet whose beats all
// fail still goes silent.
func TestBoxBeatLogLine(t *testing.T) {
	l := &logBuf{}
	e := rbacEnv(t, func(o *hub.Options) { o.Log = zerolog.New(l) })
	tid, _ := e.tenant()
	b := e.box(tid, "box-b", "CLE-08")
	e.pin(tid, b)
	ctx := context.Background()

	if _, err := b.c.Lane(ctx, "box_beat_put", "", json.RawMessage(`{"pid":0}`)); err == nil {
		t.Fatal("pid 0 acked")
	}
	if n := beatLines(l.String(), tid, "box-b"); n != 0 {
		t.Fatalf("CONTROL: a refused beat wrote %d box beat line(s)", n)
	}
	for _, pid := range []string{`{"pid":4242}`, `{"pid":4243}`} {
		if _, err := b.c.Lane(ctx, "box_beat_put", "", json.RawMessage(pid)); err != nil {
			t.Fatalf("put %s: %v", pid, err)
		}
	}
	if n := beatLines(l.String(), tid, "box-b"); n != 2 {
		t.Fatalf("2 stored beats wrote %d box beat line(s), want 2:\n%s", n, l.String())
	}
}

// beatLines counts the info lines "box beat" of that tenant and box.
func beatLines(log, tenant, box string) int {
	n := 0
	for _, ln := range strings.Split(log, "\n") {
		var e struct {
			Level   string `json:"level"`
			Message string `json:"message"`
			Tenant  string `json:"tenant"`
			Box     string `json:"box"`
		}
		if json.Unmarshal([]byte(ln), &e) != nil {
			continue
		}
		if e.Message == "box beat" && e.Level == "info" && e.Tenant == tenant && e.Box == box {
			n++
		}
	}
	return n
}
