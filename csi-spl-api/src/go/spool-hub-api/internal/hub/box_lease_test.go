package hub_test

import (
	"context"
	"encoding/json"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/action"
)

// CLE-77911: two machines' boxes share one fleet-wide lease through the real
// front end (action.Lease == `spool lease`). The hub records the writing box
// from the session, a lost compare-and-set answers won=false with the current
// row (not an error), and a malformed frame is refused before the store.

type leaseOut struct {
	Holder string `json:"holder"`
	Box    string `json:"box"`
	Gen    int64  `json:"gen"`
	AgeS   int64  `json:"age_s"`
	Won    bool   `json:"won"`
}

func leaseCall(t *testing.T, b *box, in action.LeaseArgs) leaseOut {
	t.Helper()
	in.Hub = b.c
	raw, err := action.Lease(context.Background(), b.cfg, in)
	if err != nil {
		t.Fatalf("lease %+v: %v", in, err)
	}
	var out leaseOut
	if err := json.Unmarshal(raw, &out); err != nil {
		t.Fatalf("answer %s: %v", raw, err)
	}
	return out
}

func TestBoxFleetLease(t *testing.T) {
	e, tid, _, _, pc, sat := boxArchiveRig(t)

	if got := leaseCall(t, pc, action.LeaseArgs{Fleet: "main", Role: "dispatch"}); got.Gen != 0 || got.AgeS != -1 {
		t.Fatalf("no row: %+v", got)
	}
	got := leaseCall(t, pc, action.LeaseArgs{Fleet: "main", Role: "dispatch", Holder: "CLE-002@pc", IfGen: 0})
	if !got.Won || got.Gen != 1 || got.Holder != "CLE-002@pc" || got.Box != "box-b" {
		t.Fatalf("pc first write: %+v", got)
	}
	// the satellite raced on the same gen: it loses and reads the holder
	got = leaseCall(t, sat, action.LeaseArgs{Fleet: "main", Role: "dispatch", Holder: "CLE-102@sat", IfGen: 0})
	if got.Won || got.Holder != "CLE-002@pc" || got.Gen != 1 {
		t.Fatalf("sat lost race: %+v", got)
	}
	// on the gen it read, the satellite takes over; the box is its own
	got = leaseCall(t, sat, action.LeaseArgs{Fleet: "main", Role: "dispatch", Holder: "CLE-102@sat", IfGen: 1})
	if !got.Won || got.Holder != "CLE-102@sat" || got.Box != "box-c" || got.Gen != 2 {
		t.Fatalf("sat takeover: %+v", got)
	}
	if got := leaseCall(t, pc, action.LeaseArgs{Fleet: "main", Role: "dispatch"}); got.Holder != "CLE-102@sat" || got.AgeS < 0 {
		t.Fatalf("pc reads: %+v", got)
	}

	// refusals: the client checks, and the hub checks a raw frame too
	for _, in := range []action.LeaseArgs{
		{Fleet: "Main", Role: "dispatch"},
		{Fleet: "main", Role: "dispatch", Holder: "no-at", IfGen: 0},
		{Fleet: "main", Role: "dispatch", Holder: "CLE-002@pc", IfGen: -1},
	} {
		in.Hub = pc.c
		if _, err := action.Lease(context.Background(), pc.cfg, in); err == nil {
			t.Fatalf("accepted %+v", in)
		}
	}
	if _, err := pc.c.Lease(context.Background(), "steal", "main", "dispatch", "CLE-002@pc", 0); err == nil {
		t.Fatalf("hub accepted lease_op steal")
	}
	if _, err := pc.c.Lease(context.Background(), "cas", "main", "dispatch", "bad holder", 2); err == nil {
		t.Fatalf("hub accepted a bad holder")
	}
	if l, _ := e.st.GetFleetLease(context.Background(), tid, "main", "dispatch", time.Now()); l.Gen != 2 {
		t.Fatalf("a refusal wrote: %+v", l)
	}
}
