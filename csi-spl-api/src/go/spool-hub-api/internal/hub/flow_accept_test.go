package hub_test

import (
	"context"
	"net/http"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/action"
	"github.com/csitea/csi-spl/spool-hub-api/internal/spool"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// Spec 130 section 4 (FR-005), lane L3: `spool send --kind result --accept
// <msg_id>` carries the v:1 key accepts to the hub, which labels the line
// `ready` in its readers' Flow; the same send without it is a plain dm. A
// same-box acceptance (spool-send.sh routes it through the hub to its own
// box) keeps the key and reaches the agent's harness inbox exactly once.
func TestAcceptedResultIsReadyInTheFlow(t *testing.T) {
	e := followEnv(t)
	tid, _ := e.tenant()
	ctx := context.Background()
	a := e.box(tid, "box-a", "c-007", "c-008")
	e.pin(tid, a)
	h := harness(t, a, "c-007", "c-008")
	s, err := a.c.Dial(ctx, wire.RoleBox)
	if err != nil {
		t.Fatal(err)
	}
	defer closeWait(s)
	dialFlowMember(t, e, tid, "HUM-2")

	result := send(t, a, "c-008", "c-007", "result", "L3 done", "")
	accept := func(from, to, toBox, kind string) (action.SendResult, error) {
		return action.SendCtx(ctx, a.cfg, action.SendArgs{From: from, To: to, ToBox: toBox, Kind: kind,
			Body: "ACCEPTED", Accepts: result.MsgID, Hub: a.c})
	}
	if _, err := accept("c-007", "HUM-2", "box-wui", "note"); err == nil {
		t.Fatal("--accept on a note was sent; it accepts a result only")
	}
	if _, err := accept("c-007", "HUM-2", "box-wui", "result"); err != nil {
		t.Fatalf("accept to HUM-2: %v", err)
	}
	if _, err := action.SendCtx(ctx, a.cfg, action.SendArgs{From: "c-007", To: "HUM-2", ToBox: "box-wui",
		Kind: "result", Body: "not an acceptance", TaskID: "11111111-2222-4333-8444-555555555555", Hub: a.c}); err != nil {
		t.Fatal(err)
	}
	kinds := func(kind string) int {
		code, out := call(t, e, tid, http.MethodGet, "/v1/view/flow?fold=day&kind="+kind, "HUM-2", nil)
		if code != http.StatusOK {
			t.Fatalf("GET flow kind=%s: %d %v", kind, code, out)
		}
		lines, _ := out["lines"].([]any)
		return len(lines)
	}
	eventually(t, "HUM-2's Flow holds the acceptance as ready and the plain result as dm", func() bool {
		return kinds("ready") == 1 && kinds("dm") == 1
	})

	// same box, through the hub: one copy in c-008's harness inbox, accepts kept
	if _, err := accept("c-007", "c-008", "box-a", "result"); err != nil {
		t.Fatalf("same-box accept through the hub: %v", err)
	}
	eventually(t, "the same-box acceptance in c-008's harness inbox", func() bool {
		res, err := spool.New(h).Recv("c-008", false)
		return err == nil && len(res.Messages) == 1
	})
	res, _ := spool.New(h).Recv("c-008", false)
	if m := res.Messages[0]; m.Accepts != result.MsgID || m.Kind != "result" {
		t.Fatalf("same-box acceptance = %+v, want accepts %s", m, result.MsgID)
	}
}
