package action

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/config"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hubclient"
	"github.com/csitea/csi-spl/spool-hub-api/internal/sign"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// TestPublishPinRefusesWithoutHub: with no $SPOOL_HUB_URL PublishPin refuses
// before it reads the root key or signs anything.
func TestPublishPinRefusesWithoutHub(t *testing.T) {
	_, err := PublishPin(&config.Config{}, PinArgs{Box: "box-a", PubKey: "pk", RootKey: "not-read"})
	if err == nil || !strings.Contains(err.Error(), "$SPOOL_HUB_URL") {
		t.Fatalf("err = %v, want the $SPOOL_HUB_URL refusal", err)
	}
}

// TestPublishPinSignsInjectedClock: PinArgs.Now sets the signed ts, so two
// ops in the same second order without a sleep, and the sig covers that ts.
func TestPublishPinSignsInjectedClock(t *testing.T) {
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	var got []wire.PinRequest
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var pr wire.PinRequest
		if err := json.NewDecoder(r.Body).Decode(&pr); err != nil {
			t.Error(err)
		}
		got = append(got, pr)
		w.Write([]byte(`{}`)) //nolint:errcheck
	}))
	defer srv.Close()
	base := time.Date(2026, 10, 5, 12, 0, 0, 0, time.UTC)
	cfg := &config.Config{HubURL: srv.URL, Tenant: "t1"}
	for i := range 2 {
		at := base.Add(time.Duration(i) * time.Millisecond)
		in := PinArgs{Box: "box-a", PubKey: "pk", RootKey: base64.StdEncoding.EncodeToString(priv),
			HTTP: srv.Client(), Now: func() time.Time { return at }}
		if _, err := PublishPin(cfg, in); err != nil {
			t.Fatal(err)
		}
	}
	if len(got) != 2 {
		t.Fatalf("got %d requests, want 2", len(got))
	}
	t0, err0 := time.Parse(time.RFC3339Nano, got[0].TS)
	t1, err1 := time.Parse(time.RFC3339Nano, got[1].TS)
	if err0 != nil || err1 != nil || !t0.Before(t1) {
		t.Fatalf("ts not ordered by the injected clock: %q, %q", got[0].TS, got[1].TS)
	}
	if want := base.Format(time.RFC3339Nano); got[0].TS != want {
		t.Errorf("ts = %q, want %q", got[0].TS, want)
	}
	p, err := wire.PinPayload("box-a", "pk", got[1].TS, false)
	if err != nil {
		t.Fatal(err)
	}
	if err := sign.Verify(pub, p, got[1].Sig); err != nil {
		t.Errorf("sig does not cover the injected ts: %v", err)
	}
}

// TestPublishPinBoundedOnSilentHub: a hub that accepts the request and never
// answers ends the call at the deadline with ErrUnreachable (r3-B02); before,
// the default client had no Timeout and the request no ctx, so it hung.
func TestPublishPinBoundedOnSilentHub(t *testing.T) {
	_, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	release := make(chan struct{})
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		select {
		case <-release:
		case <-r.Context().Done():
		}
	}))
	defer srv.Close()
	defer close(release)
	in := PinArgs{Box: "box-a", PubKey: "pk", RootKey: base64.StdEncoding.EncodeToString(priv),
		Timeout: 50 * time.Millisecond}
	done := make(chan error, 1)
	go func() {
		_, err := PublishPin(&config.Config{HubURL: srv.URL, Tenant: "t1"}, in)
		done <- err
	}()
	select {
	case err := <-done:
		if !errors.Is(err, hubclient.ErrUnreachable) || !errors.Is(err, context.DeadlineExceeded) {
			t.Fatalf("err = %v, want ErrUnreachable wrapping a deadline", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("PublishPin still blocked 5s after a 50ms deadline on a silent hub")
	}
}
