package hub_test

import (
	"context"
	"crypto/ed25519"
	"net/http"
	"sync/atomic"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// boxesCountingMem / boxesCountingPG count ViewBoxes reads that reach the
// store, keeping every other interface of the concrete store (Searcher).
type boxesCountingMem struct {
	*store.Memory
	n *atomic.Int64
}

func (c boxesCountingMem) ViewBoxes(ctx context.Context, tenant string) ([]store.ViewBox, error) {
	c.n.Add(1)
	return c.Memory.ViewBoxes(ctx, tenant)
}

type boxesCountingPG struct {
	*store.Postgres
	n *atomic.Int64
}

func (c boxesCountingPG) ViewBoxes(ctx context.Context, tenant string) ([]store.ViewBox, error) {
	c.n.Add(1)
	return c.Postgres.ViewBoxes(ctx, tenant)
}

// SPL-1120: a grouped search lists the robots and the boxes from ONE read of
// the tenant's boxes (it read them once per section). CONTROL: two searches
// read twice - the list is per request, never kept.
func TestSearchReadsBoxesOncePerRequest(t *testing.T) {
	var cnt atomic.Int64
	e := newEnv(t, func(o *hub.Options) {
		o.ViewDoor = hub.ViewDoorOff
		o.SearchRatePerMin = 1000
		o.Authorizer = rbac.Fixed(rbac.Developer)
		o.SessionID = func(r *http.Request, _ string) (string, error) { return r.Header.Get("X-Test-Human"), nil }
		switch st := o.Store.(type) {
		case *store.Memory:
			o.Store = boxesCountingMem{st, &cnt}
		case *store.Postgres:
			o.Store = boxesCountingPG{st, &cnt}
		default:
			t.Fatalf("store %T", st)
		}
	})
	ctx := context.Background()
	ta, _ := e.tenant()
	now := time.Now().UTC()
	pub, _, _ := ed25519.GenerateKey(nil)
	if err := e.st.PutPin(ctx, ta, "box-a", pub, false, now, now); err != nil {
		t.Fatal(err)
	}
	e.st.SetRoster(ctx, ta, "box-a", []string{"CLE-07"}, now) //nolint:errcheck

	code, _, r, _ := searchGet(t, e, ta, "a", "")
	if code != http.StatusOK || len(r.Groups["robots"].Results) != 1 || len(r.Groups["boxes"].Results) != 1 {
		t.Fatalf("grouped: %d robots %v boxes %v", code, r.Groups["robots"], r.Groups["boxes"])
	}
	if n := cnt.Load(); n != 1 {
		t.Fatalf("one grouped search read the boxes %d times, want 1", n)
	}
	searchGet(t, e, ta, "a", "")
	if n := cnt.Load(); n != 2 {
		t.Fatalf("two searches read the boxes %d times, want 2", n)
	}
}
