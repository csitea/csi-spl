package action

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/testkit"
)

// Tail with asJSON prints one decodable v:1 object per message, each line
// ending in a newline (refactor r3-01 pin).
func TestTailJSONOneLinePerMessage(t *testing.T) {
	cfg := testkit.NewConfig(t)
	testkit.Agents(t, cfg, "CLE-2")
	first, err := Send(cfg, SendArgs{From: "CLE-1", To: "CLE-2", Kind: "note", Body: "one"})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := Send(cfg, SendArgs{From: "CLE-1", To: "CLE-2", Kind: "note", Body: "two", TaskID: first.TaskID}); err != nil {
		t.Fatal(err)
	}
	out, err := Tail(cfg, first.TaskID, true)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasSuffix(out, "\n") {
		t.Fatalf("output does not end in a newline: %q", out)
	}
	lines := strings.Split(strings.TrimSuffix(out, "\n"), "\n")
	if len(lines) != 2 {
		t.Fatalf("got %d lines, want 2: %q", len(lines), out)
	}
	// two sends in one second tie on ts and order by msg_id, so the bodies
	// are checked as a set
	bodies := map[string]bool{}
	for i, line := range lines {
		var m struct {
			V    int    `json:"v"`
			Body string `json:"body"`
		}
		if err := json.Unmarshal([]byte(line), &m); err != nil {
			t.Fatalf("line %d %q: %v", i, line, err)
		}
		if m.V != 1 {
			t.Errorf("line %d: v=%d, want 1", i, m.V)
		}
		bodies[m.Body] = true
	}
	if !bodies["one"] || !bodies["two"] {
		t.Errorf("bodies %v, want one and two", bodies)
	}
}
