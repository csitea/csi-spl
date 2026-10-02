package hub_test

import (
	"context"
	"encoding/json"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/action"
	"github.com/csitea/csi-spl/spool-hub-api/internal/agentid"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// pinAgentClock sets agentid.Now for one test (spec 061 FR-004).
func pinAgentClock(t *testing.T, at time.Time) {
	t.Helper()
	old := agentid.Now
	agentid.Now = func() time.Time { return at }
	t.Cleanup(func() { agentid.Now = old })
}

// Spec 061 wave A: the hub takes c-004 and the legacy CLE-77952 alike. Before
// the deadline a legacy id in a lane / lease / ask frame becomes its alias;
// after it the frame and a send are refused with the FR-003 text.
func TestAgentIDRenameAccept(t *testing.T) {
	e, tid, _, _, home, _ := boxArchiveRig(t)
	ctx := context.Background()
	if _, _, err := e.st.PutAgentAlias(ctx, tid, store.AgentAlias{OldID: "CLE-77952", NewID: "c-004", Kind: "claude", BoxID: "box-b"}, time.Now()); err != nil {
		t.Fatal(err)
	}
	pinAgentClock(t, agentid.LegacyUntil.Add(-time.Minute))

	// a new id and an aliased legacy id both land; the legacy one as its alias
	laneCall(t, home, action.LaneArgs{Fleet: "main", Agent: "c-005", Box: "box-b"})
	got := laneCall(t, home, action.LaneArgs{Fleet: "main", Agent: "CLE-77952", Box: "box-b"})
	if len(got.Lanes) != 1 || got.Lanes[0].AgentID != "c-004" {
		t.Fatalf("legacy lane id resolves to its alias: %+v", got)
	}
	// the alias is keyed on the box: the same legacy id on another box has none
	if got := laneCall(t, home, action.LaneArgs{Fleet: "main", Agent: "CLE-77952", Box: "box-c"}); got.Lanes[0].AgentID != "CLE-77952" {
		t.Fatalf("other box's legacy id: %+v", got)
	}
	// a legacy id with no alias row is accepted as itself (FR-002)
	if got := laneCall(t, home, action.LaneArgs{Fleet: "main", Agent: "CLE-77953", Box: "box-b"}); got.Lanes[0].AgentID != "CLE-77953" {
		t.Fatalf("unaliased legacy id: %+v", got)
	}
	lease, err := action.Lease(ctx, home.cfg, action.LeaseArgs{Fleet: "main", Role: "orch", Holder: "CLE-77952@box-b", IfGen: 0, Hub: home.c})
	if err != nil || !strings.Contains(string(lease), `"holder":"c-004@box-b"`) {
		t.Fatalf("lease holder resolves: %s %v", lease, err)
	}
	send(t, home, "CLE-08", "CLE-09", "note", "before the deadline", "")

	// GET /api/v1/agent-aliases: the table and the deadline
	code, _, body := viewGet(t, e, tid, "/v1/agent-aliases")
	var view struct {
		LegacyUntil string             `json:"legacy_until"`
		Aliases     []store.AgentAlias `json:"aliases"`
	}
	if err := json.Unmarshal(body, &view); err != nil || code != http.StatusOK || view.LegacyUntil != agentid.LegacyUntilText ||
		len(view.Aliases) != 1 || view.Aliases[0].OldID != "CLE-77952" || view.Aliases[0].NewID != "c-004" {
		t.Fatalf("GET agent-aliases: %d %s", code, body)
	}

	// past the deadline: FR-003, naming the new id when the table has one
	pinAgentClock(t, agentid.LegacyUntil.Add(time.Second))
	if _, err := home.c.Lane(ctx, "put", "main", json.RawMessage(`{"agent_id":"CLE-77952","agent_box":"box-b","state":"live"}`)); err == nil ||
		!strings.Contains(err.Error(), "CLE-77952 is retired as an id; use c-004") {
		t.Fatalf("lane after the deadline: %v", err)
	}
	if _, err := action.SendCtx(ctx, home.cfg, action.SendArgs{From: "CLE-08", To: "CLE-09", Kind: "note", Body: "late", Hub: home.c}); err == nil ||
		!strings.Contains(err.Error(), "CLE-08 is retired as an id; use c-NNN") {
		t.Fatalf("send after the deadline: %v", err)
	}
	laneCall(t, home, action.LaneArgs{Fleet: "main", Agent: "c-005", Box: "box-b", State: "done"})
}
