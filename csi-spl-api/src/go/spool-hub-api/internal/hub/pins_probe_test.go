package hub_test

import (
	"context"
	"io"
	"net/http"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// listCounting counts ListPins reads that reach the store.
type listCounting struct {
	store.Store
	lists atomic.Int64
}

func (c *listCounting) ListPins(ctx context.Context, tenant string) ([]store.Pin, error) {
	c.lists.Add(1)
	return c.Store.ListPins(ctx, tenant)
}

// SPL-1105: the box session probe (GET /v1/pins?probe=1) is answered by the
// token door alone - 204, no list read - while GET /v1/pins still lists and
// a token this process does not know is still 401 door (the redeploy signal
// TestBoxRedialsAfterHubRedeploy rides on).
func TestPinsProbeIsTheDoorWithoutTheList(t *testing.T) {
	var cnt *listCounting
	e := newEnv(t, func(o *hub.Options) { cnt = &listCounting{Store: o.Store}; o.Store = cnt })
	tid, _ := e.tenant()
	a := e.box(tid, "box-a", "CLE-07")
	e.pin(tid, a)
	tok := e.uploadToken(tid, a)
	get := func(path, token string) (int, string) {
		t.Helper()
		req, _ := http.NewRequest(http.MethodGet, e.url(tid)+path, nil)
		if token != "" {
			req.Header.Set("Authorization", "Bearer "+token)
		}
		resp, err := e.client.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		defer resp.Body.Close()
		b, _ := io.ReadAll(resp.Body)
		return resp.StatusCode, string(b)
	}

	cnt.lists.Store(0)
	if code, body := get("/v1/pins?probe=1", tok); code != http.StatusNoContent || body != "" {
		t.Fatalf("probe: %d %q, want 204 and no body", code, body)
	}
	if n := cnt.lists.Load(); n != 0 {
		t.Fatalf("probe read the pin list %d times", n)
	}
	// CONTROL: the list itself is unchanged, and read.
	if code, body := get("/v1/pins", tok); code != http.StatusOK || !strings.Contains(body, `"box-a"`) {
		t.Fatalf("list: %d %s", code, body)
	}
	if n := cnt.lists.Load(); n != 1 {
		t.Fatalf("list read %d times, want 1", n)
	}
	// CONTROL: an unknown token is still the door, probe or not.
	for _, p := range []string{"/v1/pins?probe=1", "/v1/pins"} {
		if code, body := get(p, "not-a-token"); code != http.StatusUnauthorized || !strings.Contains(body, `"door"`) {
			t.Fatalf("%s unknown token: %d %s", p, code, body)
		}
	}
	// The client's Probe takes the short path and answers nil.
	sess, err := a.c.Dial(context.Background(), "box")
	if err != nil {
		t.Fatal(err)
	}
	defer closeWait(sess)
	cnt.lists.Store(0)
	if err := sess.Probe(context.Background()); err != nil {
		t.Fatal(err)
	}
	if n := cnt.lists.Load(); n != 0 {
		t.Fatalf("Session.Probe read the pin list %d times", n)
	}
}
