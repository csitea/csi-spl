package hub_test

import (
	"context"
	"net/http"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// TestActAsCloneGateRidesTheWalk (perf round 4 G7): on Postgres the clone
// gate of the DM list rides the topic walk's batch, so the walk RUNS for a
// clone. The answer must stay exactly the gate's: a clone that is itself an
// end of a DM - a walk that matches a row - still gets 403 and never that
// row. CONTROL: the same DM is listed for its other end once the clone stops.
func TestActAsCloneGateRidesTheWalk(t *testing.T) {
	e := followEnv(t)
	cs, ok := e.st.(interface {
		dmCloneStore
		StopClone(ctx context.Context, tenant, clone, reason string, now time.Time) error
	})
	if !ok {
		t.Skip("act-as clone store needs Postgres (SPOOL_TEST_PG_DSN)")
	}
	tid, _ := e.tenant()
	ctx := context.Background()
	now := time.Now().UTC().Truncate(time.Microsecond)
	target := seat(t, e, tid, "developer")
	cl, err := cs.StartClone(ctx, store.CloneStart{TenantID: tid, TargetHum: target, AdminName: "Admin",
		CreatedBy: target, ExpiresAt: now.Add(time.Hour)}, now)
	if err != nil {
		t.Fatal(err)
	}
	dmTask := uuidV4()
	putRow(t, e, tid, dmTask, "", cl.CloneHum, "CLE-07", "a DM the clone is an end of", now)

	for _, path := range []string{"/v1/view/topics?dm=true", "/v1/view/topics?dm=true&limit=50&dm_counts=true", "/v1/view/topics?peer=CLE-07"} {
		code, out := call(t, e, tid, http.MethodGet, path, cl.CloneHum, nil)
		if code != http.StatusForbidden {
			t.Errorf("live clone GET %s = %d, want 403", path, code)
		}
		if ts, _ := out["topics"].([]any); len(ts) != 0 {
			t.Errorf("live clone GET %s leaked %d topic(s) of the walk", path, len(ts))
		}
	}

	if err := cs.StopClone(ctx, tid, cl.CloneHum, "stop", now.Add(time.Minute)); err != nil {
		t.Fatal(err)
	}
	// CONTROL: the walk does match that DM - for CLE-07's side of it, the
	// ended clone is no clone and the gate passes the walk's rows through.
	code, out := call(t, e, tid, http.MethodGet, "/v1/view/topics?dm=true", cl.CloneHum, nil)
	if ts, _ := out["topics"].([]any); code != http.StatusOK || len(ts) != 1 {
		t.Fatalf("control: ended clone GET topics?dm=true = %d with %d topic(s), want 200/1", code, len(ts))
	}
}
