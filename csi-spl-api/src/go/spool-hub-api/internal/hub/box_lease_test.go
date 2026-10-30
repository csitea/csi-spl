package hub_test

import (
	"context"
	"encoding/json"
	"regexp"
	"strings"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/action"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
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

// leaseEvents is the System log rows of one lease (origin lease/<fleet>/<role>),
// oldest first. The fleet is unique per run: the log is hub-wide.
func leaseEvents(t *testing.T, e *env, fleet, role string) []store.LogEvent {
	t.Helper()
	es, ok := e.st.(store.LogEvents)
	if !ok {
		t.Fatalf("store %T has no System log", e.st)
	}
	page, err := es.SystemEventsPage(context.Background(), 0, 200)
	if err != nil {
		t.Fatal(err)
	}
	var out []store.LogEvent
	for i := len(page) - 1; i >= 0; i-- {
		if page[i].OriginRef == "lease/"+fleet+"/"+role {
			out = append(out, page[i])
		}
	}
	return out
}

// Spec 162 3.3, row B4: a won cas that names lease_reason and changes the
// holder writes one System log row lease.<reason> (C16). Red control (C17):
// a lost cas, a renew by the same holder and a cas with no reason (the
// tenant mirror, an old CLI) write none. A frame without lease_reason is
// still accepted (C18); an unknown reason is refused before the store.
func TestBoxFleetLeaseReason(t *testing.T) {
	e, tid, _, _, pc, sat := boxArchiveRig(t)
	ctx := context.Background()
	fleet := "r" + strings.ReplaceAll(uuidV4(), "-", "")[:20]
	cas := func(b *box, holder string, gen int64, reason string) leaseOut {
		return leaseCall(t, b, action.LeaseArgs{Fleet: fleet, Role: "dispatch", Holder: holder, IfGen: gen, Reason: reason})
	}

	if got := cas(pc, "c-702@pc", 0, "claim"); !got.Won || got.Gen != 1 {
		t.Fatalf("claim: %+v", got)
	}
	if got := cas(pc, "c-702@pc", 1, "failover"); !got.Won || got.Gen != 2 {
		t.Fatalf("renew: %+v", got)
	}
	if got := cas(sat, "c-712@sat", 1, "failover"); got.Won {
		t.Fatalf("stale gen won: %+v", got)
	}
	if got := cas(sat, "c-712@sat", 2, "failover"); !got.Won || got.Holder != "c-712@sat" || got.Gen != 3 {
		t.Fatalf("failover: %+v", got)
	}
	if got := cas(pc, "c-702@pc", 3, ""); !got.Won || got.Holder != "c-702@pc" {
		t.Fatalf("no reason (C18): %+v", got)
	}
	if _, err := pc.c.LeaseFor(ctx, "cas", fleet, "dispatch", "c-702@pc", 4, "bogus"); err == nil {
		t.Fatalf("hub accepted lease_reason bogus")
	}
	if l, _ := e.st.GetFleetLease(ctx, tid, fleet, "dispatch", time.Now()); l.Gen != 4 {
		t.Fatalf("the bogus reason wrote: %+v", l)
	}

	got := leaseEvents(t, e, fleet, "dispatch")
	if len(got) != 2 {
		t.Fatalf("System log rows = %+v, want 2 (claim, failover)", got)
	}
	if c := got[0]; c.Kind != store.LogKindLeaseClaim || c.Level != store.LogLevelInfo || c.Actor != "c-702@pc" ||
		c.Message != "dispatch: none -> c-702@pc (claim)" || c.OriginKind != store.LogOriginComponent {
		t.Fatalf("claim row = %+v", c)
	}
	f := got[1]
	if f.Kind != store.LogKindLeaseFailover || f.Level != store.LogLevelWarn || f.Actor != "c-712@sat" ||
		!regexp.MustCompile(`^dispatch: c-702@pc -> c-712@sat \(failover, silent [0-9]+s\)$`).MatchString(f.Message) {
		t.Fatalf("failover row = %+v", f)
	}
}

// LogHubStarted writes one hub.started row, actor hub, message the version
// (spec 162 3.3).
func TestLogHubStarted(t *testing.T) {
	version := "v0.0.0-" + uuidV4()
	e := newEnv(t, func(o *hub.Options) { o.Version = version })
	e.srv.LogHubStarted(context.Background())
	es := e.st.(store.LogEvents)
	page, err := es.SystemEventsPage(context.Background(), 0, 50)
	if err != nil {
		t.Fatal(err)
	}
	for _, r := range page {
		if r.Kind == store.LogKindHubStarted && r.Actor == "hub" && r.Message == version && r.OriginRef == "hub" {
			return
		}
	}
	t.Fatalf("no hub.started row in %+v", page)
}
