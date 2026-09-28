package hub_test

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"strings"
	"sync"
	"testing"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"

	"github.com/csitea/csi-spl/spool-hub-api/internal/auth"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
)

// every read door re-read the session after humanTenant had
// PROVED it, and dropped that second lookup's error - and "" is "filter
// nothing". A transient membership error (the pool is 8 connections) or a
// member removed mid-request therefore opened search to the whole tenant and
// let the browser socket speak as its own hello.as. The seam here answers the
// first lookup of each request with the signed-in human and fails every
// later one - exactly "proven, then the re-read fails".
func TestReaderLookupFailsClosed(t *testing.T) {
	var (
		mu    sync.Mutex
		seen  = map[string]int{}
		authz *auth.Handler
	)
	r := newDoorRig(t, func(o *hub.Options) {
		authz = o.Auth
		o.SessionID = func(req *http.Request, tenant string) (string, error) {
			key := fmt.Sprintf("%p", req.Header) // shared by every WithContext copy of one request
			mu.Lock()
			seen[key]++
			n := seen[key]
			mu.Unlock()
			if n > 1 {
				return "", errors.New("membership lookup failed")
			}
			sess, err := authz.SessionForTenant(req, tenant)
			return sess.HumanID, err
		}
	})
	mine, _ := r.e.tenant()
	if landed := r.signIn(t, mine); strings.Contains(landed, "auth_error") {
		t.Fatalf("sign-in landed on %s", landed)
	}
	hum := r.session(t).HumanID

	// search: refused, never "search everything".
	if code, _, body := r.get(t, mine, "/v1/view/search?q=deploy"); code != http.StatusInternalServerError {
		t.Fatalf("search with a failed reader lookup: %d %s", code, body)
	}
	// the browser socket: the proven human, never the asserted hello.as.
	ctx := context.Background()
	c, _, err := websocket.Dial(ctx, "ws://"+mine+domain+"/v1/wui/ws", &websocket.DialOptions{HTTPClient: r.browser})
	if err != nil {
		t.Fatal(err)
	}
	defer c.CloseNow()                                                           //nolint:errcheck
	wsjson.Write(ctx, c, map[string]string{"type": "hello", "as": "HUM-999999"}) //nolint:errcheck
	w := &wuiClient{t: t, c: c}
	if f := w.read("welcome"); f.As != hum {
		t.Fatalf("welcome as=%q, want the proven %q", f.As, hum)
	}
}
