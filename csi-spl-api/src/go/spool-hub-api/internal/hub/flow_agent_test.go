package hub_test

import (
	"context"
	"encoding/json"
	"errors"
	"testing"

	"github.com/coder/websocket/wsjson"

	"github.com/csitea/csi-spl/spool-hub-api/internal/action"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hubclient"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// Spec 130 section 5 (FR-007): an agent reads its Flow over its own box
// session, through the real front end (action.Flow == `spool flow` == the MCP
// tool spool_flow), keyed <id>@<box>: a blocker that names it in a channel
// is a `blocked` line; a DM to it is not in its Flow (its inbox has it); an
// agent its box did not announce is refused.
func TestAgentFlowRead(t *testing.T) {
	e := followEnv(t)
	tid, _ := e.tenant()
	ctx := context.Background()
	a := e.box(tid, "box-a", "c-007")
	e.pin(tid, a)
	sa, err := a.c.Dial(ctx, wire.RoleBox) // announces c-007
	if err != nil {
		t.Fatal(err)
	}
	defer closeWait(sa)
	human := dialFlowMember(t, e, tid, "HUM-2")
	for _, f := range []map[string]any{
		{"type": "send", "task_id": "lobby", "kind": "blocker", "body": "stuck: @c-007@box-a please look"},
		{"type": "send", "task_id": "lobby", "kind": "chat", "body": "a bare @c-007 names no box"},
	} {
		wsjson.Write(ctx, human, f) //nolint:errcheck
		readFrame(t, human, "ack")
	}

	read := func(as, kind string) (map[string]any, error) {
		raw, err := action.Flow(ctx, a.cfg, action.FlowArgs{As: as, Kind: kind, Hub: a.c})
		out := map[string]any{}
		if err == nil {
			if jerr := json.Unmarshal(raw, &out); jerr != nil {
				t.Fatalf("reply %s: %v", raw, jerr)
			}
		}
		return out, err
	}
	out, err := read("c-007", "mention")
	if err != nil {
		t.Fatal(err)
	}
	lines, _ := out["lines"].([]any)
	if len(lines) != 1 {
		t.Fatalf("agent flow lines = %v", out)
	}
	l := lines[0].(map[string]any)
	if l["kind"] != "blocked" || l["count"] != float64(1) || l["mark"] != "t:"+lobby {
		t.Fatalf("agent flow line = %v", l)
	}
	var he *hubclient.HubError
	if _, err := read("GRK-99", ""); !errors.As(err, &he) || he.Token != wire.TokenFromNotAnnounced {
		t.Fatalf("unannounced agent: %v", err)
	}
	if _, err := read("c-007", "nope"); !errors.As(err, &he) || he.Token != "bad_query" {
		t.Fatalf("bad kind: %v", err)
	}
}
