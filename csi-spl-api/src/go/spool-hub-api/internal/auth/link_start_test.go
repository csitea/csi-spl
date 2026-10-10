package auth_test

import (
	"context"
	"net/http"
	"sync"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/auth"
)

// linkRecorder is a Registrar that remembers the LinkTo of each sign-in.
type linkRecorder struct {
	mu    sync.Mutex
	links []string
}

func (l *linkRecorder) Register(_ context.Context, id auth.Identity, _ string) (string, error) {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.links = append(l.links, id.LinkTo)
	return "HUM-7", nil
}

func (l *linkRecorder) last() string {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.links[len(l.links)-1]
}

// t1 f265541a (c-832 finding, option A): a pending sign-in email turns active
// only through a provider sign-in that the holder's own signed-in session
// started. GET start?link=1 signs that HUM-* into the state and the callback
// hands it to the Registrar as Identity.LinkTo; without a session it is 401.
// CONTROL: a plain (cold) start carries no LinkTo, so no pending address can
// catch it.
func TestLinkStartCarriesTheSessionHuman(t *testing.T) {
	reg := &linkRecorder{}
	r := newRig(t, reg)
	c := browser(t)

	resp, err := noFollow(c).Get(r.hub + "/api/v1/auth/google/start?link=1")
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("link start without a session: %d, want 401", resp.StatusCode)
	}

	signIn(t, c, r, "google", "")
	if got := reg.last(); got != "" {
		t.Fatalf("CONTROL cold sign-in carried LinkTo %q", got)
	}
	signIn(t, c, r, "google", "?link=1")
	if got := reg.last(); got != "HUM-7" {
		t.Fatalf("link sign-in carried LinkTo %q, want the session's HUM-7", got)
	}
	signIn(t, c, r, "google", "")
	if got := reg.last(); got != "" {
		t.Fatalf("CONTROL a later plain sign-in carried LinkTo %q", got)
	}
}
