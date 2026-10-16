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
	out, err := Tail(cfg, "", first.TaskID, true)
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

// A topic this spool holds nothing of is an error naming who asked and where,
// never an empty list (SPL-2105): with no seat and no workspace, the box and
// its spool root; with both, the seat and its workspace.
func TestTailOfAnUnseenTopicSaysWhy(t *testing.T) {
	cfg := testkit.NewConfig(t)
	testkit.Agents(t, cfg, "c-550")
	const unseen = "0badf00d-0000-4000-8000-000000000269"
	_, err := Tail(cfg, "", unseen, false)
	if err == nil || !strings.Contains(err.Error(), "no messages visible to this box in the local spool "+cfg.SpoolRoot) {
		t.Fatalf("box tail: %v, want the box and its spool root", err)
	}
	cfg.Tenant = "t1"
	_, err = Tail(cfg, "c-550", unseen, true)
	for _, want := range []string{"topic " + unseen, "no messages visible to c-550 in workspace t1", "if the link is from another workspace, this seat cannot read it"} {
		if err == nil || !strings.Contains(err.Error(), want) {
			t.Errorf("seated tail: %v, want %q", err, want)
		}
	}
	if ExitCode(err) != 1 {
		t.Errorf("exit %d, want 1", ExitCode(err))
	}
}
