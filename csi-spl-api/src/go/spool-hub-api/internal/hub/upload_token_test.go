package hub_test

import (
	"bytes"
	"context"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/rs/zerolog"

	"github.com/csitea/csi-spl/spool-hub-api/internal/blob"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
)

// SPL-1815: prd runs up to two hub instances (cnf max_instances 2). The
// browser's socket rides the session-affinity cookie to one of them; its
// POST /v1/files goes without credentials and may land on the other. On
// 2026-10-14 07:46..07:48Z every upload from the owner's phone did, and the
// other instance, which never minted the token, answered 401 door (n = 20).
//
// uploadKey is the derived key both instances share in prd.
var uploadKey = bytes.Repeat([]byte{7}, 32)

// newUploadPeer is a second hub process on e's store and blobs, reached by
// its own client: Cloud Run's other instance.
func newUploadPeer(t *testing.T, e *env, key []byte, now func() time.Time) *env {
	t.Helper()
	srv, err := hub.New(hub.Options{
		Store: e.st, Blob: blob.Dir{Root: e.blobs}, Log: zerolog.Nop(),
		TenantHostPattern: "{tenant}" + domain, HelloSkew: 300 * time.Second, HelloTimeout: 2 * time.Second,
		UploadTokenTTL: 5 * time.Minute, QueueTTL: 7 * 24 * time.Hour, QueueMaxPerBox: 1000,
		RetentionAlerts: 7 * 24 * time.Hour, RetentionChannels: 30 * 24 * time.Hour, Version: "test-peer",
		ViewDoor: hub.ViewDoorOff, LobbyTaskID: lobby, ViewCORSOrigins: []string{wuiOrigin},
		UploadTokenKey: key, Now: now,
	})
	if err != nil {
		t.Fatal(err)
	}
	ts := httptest.NewServer(srv.Handler())
	t.Cleanup(func() { srv.Shutdown(); ts.Close() })
	addr := ts.Listener.Addr().String()
	tr := http.DefaultTransport.(*http.Transport).Clone()
	tr.DialContext = func(ctx context.Context, network, _ string) (net.Conn, error) {
		return (&net.Dialer{}).DialContext(ctx, network, addr)
	}
	return &env{t: t, st: e.st, srv: srv, ts: ts, client: &http.Client{Transport: tr}, blobs: e.blobs}
}

// postFileOn is the browser's upload: raw bytes, the Bearer, no cookie.
func postFileOn(t *testing.T, e *env, tenant, token string) int {
	t.Helper()
	req, _ := http.NewRequest(http.MethodPost, e.url(tenant)+"/v1/files", strings.NewReader("png bytes "+token[:4]))
	req.Header.Set("Content-Type", "application/octet-stream")
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Origin", wuiOrigin)
	resp, err := e.client.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	return resp.StatusCode
}

// The browser's token minted on A uploads on B. The control is today's prd
// shape before the fix, no shared key: B refuses it 401, which is the
// owner's "uploads are not working".
func TestWUIUploadTokenWorksOnTheOtherInstance(t *testing.T) {
	for _, tc := range []struct {
		name string
		key  []byte
		want int
	}{
		{"shared key", uploadKey, http.StatusCreated},
		{"control: no key, per-process map", nil, http.StatusUnauthorized},
	} {
		t.Run(tc.name, func(t *testing.T) {
			a := newEnv(t, func(o *hub.Options) {
				o.ViewDoor, o.LobbyTaskID, o.ViewCORSOrigins, o.UploadTokenKey = hub.ViewDoorOff, lobby, []string{wuiOrigin}, tc.key
			})
			b := newUploadPeer(t, a, tc.key, nil)
			tid, _ := a.tenant()
			w := dialWUI(t, a, tid, "HUM-1")
			if code := postFileOn(t, a, tid, w.w.UploadToken); code != http.StatusCreated {
				t.Fatalf("upload on the minting instance: %d, want 201", code)
			}
			if code := postFileOn(t, b, tid, w.w.UploadToken); code != tc.want {
				t.Fatalf("upload on the other instance: %d, want %d", code, tc.want)
			}
		})
	}
}

// A signed token is still a credential: a forged MAC, a token past its TTL,
// another tenant's host, and a box's token on the other instance are all
// refused. The box token stays per process on purpose: the box's session
// probe reads that 401 door as a redeploy strand (redeploy_test.go).
func TestWUIUploadTokenSignedRefusals(t *testing.T) {
	var mu sync.Mutex
	now := time.Now()
	clock := func() time.Time { mu.Lock(); defer mu.Unlock(); return now }
	a := newEnv(t, func(o *hub.Options) {
		o.ViewDoor, o.LobbyTaskID, o.ViewCORSOrigins, o.UploadTokenKey, o.Now = hub.ViewDoorOff, lobby, []string{wuiOrigin}, uploadKey, clock
	})
	b := newUploadPeer(t, a, uploadKey, clock)
	tid, _ := a.tenant()
	other, _ := a.tenant()
	tok := dialWUI(t, a, tid, "HUM-1").w.UploadToken

	payload, sig, ok := strings.Cut(tok, ".")
	if !ok || sig == "" {
		t.Fatalf("WUI upload token is not signed: %q", tok)
	}
	forged := payload + "." + strings.Repeat("A", len(sig))
	if code := postFileOn(t, b, tid, forged); code != http.StatusUnauthorized {
		t.Errorf("forged MAC: %d, want 401", code)
	}
	if code := postFileOn(t, b, other, tok); code != http.StatusForbidden {
		t.Errorf("another tenant's host: %d, want 403", code)
	}

	bx := a.box(tid, "box-a", "GRK-03")
	a.pin(tid, bx)
	boxTok := a.uploadToken(tid, bx)
	if strings.Contains(boxTok, ".") {
		t.Errorf("a box token is signed: %q", boxTok)
	}
	if code := postFileOn(t, b, tid, boxTok); code != http.StatusUnauthorized {
		t.Errorf("box token on the other instance: %d, want 401 (the probe's strand signal)", code)
	}

	mu.Lock()
	now = now.Add(6 * time.Minute) // past the 5 min TTL
	mu.Unlock()
	if code := postFileOn(t, b, tid, tok); code != http.StatusUnauthorized {
		t.Errorf("expired signed token: %d, want 401", code)
	}
}
