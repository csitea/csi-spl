package hub_test

import (
	"context"
	"net/http"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// dmCloneStore is env.st's Postgres slice used to mint an act-as clone; the
// memory store has none, so the test skips there.
type dmCloneStore interface {
	StartClone(ctx context.Context, in store.CloneStart, now time.Time) (store.Clone, error)
}

// TestActAsCloneCannotReadDM is the owner's rule made a control (18597eaa,
// verbatim: "no of course"): an act-as clone sees only the person's channels
// and issues, NEVER their DMs. Every DM surface refuses the clone
// server-side, and a control proves the real person still reads their own DM.
func TestActAsCloneCannotReadDM(t *testing.T) {
	e := followEnv(t)
	cs, ok := e.st.(dmCloneStore)
	if !ok {
		t.Skip("act-as clone store needs Postgres (SPOOL_TEST_PG_DSN)")
	}
	tid, _ := e.tenant()
	ctx := context.Background()
	now := time.Now().UTC().Truncate(time.Microsecond)

	target := seat(t, e, tid, "developer")

	// a DM between the target and an agent peer (channel "" = a DM), plus a
	// public channel post the clone WILL still see (so the test proves the
	// clone is not merely blind).
	dmTask, chTask := uuidV4(), uuidV4()
	putRow(t, e, tid, dmTask, "", target, "CLE-07", "the private DM: secretword", now)
	putRow(t, e, tid, chTask, "lobby", target, "CLE-07", "a public lobby post", now.Add(time.Second))

	cl, err := cs.StartClone(ctx, store.CloneStart{TenantID: tid, TargetHum: target, AdminName: "Admin",
		CreatedBy: target, ExpiresAt: now.Add(time.Hour)}, now)
	if err != nil {
		t.Fatal(err)
	}

	// CONTROL: the real target reads their DM.
	if code, _ := call(t, e, tid, http.MethodGet, "/v1/view/topics?dm=true", target, nil); code != http.StatusOK {
		t.Fatalf("control: target dm=true = %d, want 200", code)
	}
	if code, n := readTopic(t, e, tid, dmTask, target); code != http.StatusOK || n != 1 {
		t.Fatalf("control: target reads own DM = %d n=%d, want 200/1", code, n)
	}

	// The CLONE is refused every DM surface.
	if code, _ := call(t, e, tid, http.MethodGet, "/v1/view/topics?dm=true", cl.CloneHum, nil); code != http.StatusForbidden {
		t.Errorf("clone GET topics?dm=true = %d, want 403", code)
	}
	if code, _ := call(t, e, tid, http.MethodGet, "/v1/view/topics?peer=CLE-07", cl.CloneHum, nil); code != http.StatusForbidden {
		t.Errorf("clone GET topics?peer=CLE-07 = %d, want 403", code)
	}
	// It cannot READ the DM topic — not an end of it, so zero messages.
	if _, n := readTopic(t, e, tid, dmTask, cl.CloneHum); n != 0 {
		t.Errorf("clone read the target's DM: got %d message(s), want 0", n)
	}
	// Its search finds no DM preview (the DM's word is unreachable).
	if code, out := call(t, e, tid, http.MethodGet, "/v1/view/search?q=secretword", cl.CloneHum, nil); code == http.StatusOK {
		if res, _ := out["results"].([]any); len(res) != 0 {
			t.Errorf("clone search surfaced %d DM result(s), want 0", len(res))
		}
	}
	// CONTROL: the clone still reads a normal channel topic (channels are allowed).
	if code, n := readTopic(t, e, tid, chTask, cl.CloneHum); code != http.StatusOK || n != 1 {
		t.Errorf("clone reads a public channel topic = %d n=%d, want 200/1", code, n)
	}
}
