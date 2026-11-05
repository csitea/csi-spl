package action

import (
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"net/http"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/config"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// TestDesksWho: an explicit asker names itself; otherwise the desk box, then
// the base config's box, then "this box" (r51-05).
func TestDesksWho(t *testing.T) {
	for _, c := range []struct {
		name, who, want string
		d               Desks
	}{
		{"explicit asker", "c-001", "c-001", Desks{Box: "b1"}},
		{"desk box", "", "box b1", Desks{Box: "b1", Base: &config.Config{BoxID: "b2"}}},
		{"base config box", "", "box b2", Desks{Base: &config.Config{BoxID: "b2"}}},
		{"base config without a box", "", "this box", Desks{Base: &config.Config{}}},
		{"neither", "", "this box", Desks{}},
	} {
		t.Run(c.name, func(t *testing.T) {
			if got := c.d.who(c.who); got != c.want {
				t.Fatalf("who(%q) = %q, want %q", c.who, got, c.want)
			}
		})
	}
}

// wpKey is a fresh ed25519 key pair for the pinRequest cases.
func wpKey(t *testing.T) (ed25519.PublicKey, ed25519.PrivateKey) {
	t.Helper()
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	return pub, priv
}

// wpVerify fails the test unless sig is a base64 ed25519 signature of payload.
func wpVerify(t *testing.T, pub ed25519.PublicKey, payload []byte, sig string) {
	t.Helper()
	raw, err := base64.StdEncoding.DecodeString(sig)
	if err != nil {
		t.Fatalf("sig not base64: %v", err)
	}
	if !ed25519.Verify(pub, payload, raw) {
		t.Fatalf("sig does not verify over %s", payload)
	}
}

// TestPinRequestRevoke: a revoke is DELETE /v1/pins/<box>, its RevokeRequest
// signed over RevokePayload.
func TestPinRequestRevoke(t *testing.T) {
	pub, priv := wpKey(t)
	const ts = "2026-11-05T21:00:00Z"
	method, path, body, err := pinRequest(PinArgs{Revoke: true, Box: "b1"}, priv, ts)
	if err != nil {
		t.Fatal(err)
	}
	if method != http.MethodDelete || path != "/v1/pins/b1" {
		t.Fatalf("got %s %s, want DELETE /v1/pins/b1", method, path)
	}
	rr, ok := body.(wire.RevokeRequest)
	if !ok {
		t.Fatalf("body is %T, want wire.RevokeRequest", body)
	}
	if rr.BoxID != "b1" || rr.TS != ts {
		t.Fatalf("body = %+v", rr)
	}
	p, err := wire.RevokePayload("b1", ts)
	if err != nil {
		t.Fatal(err)
	}
	wpVerify(t, pub, p, rr.Sig)
}

// TestPinRequestPin: without Revoke it is POST /v1/pins, its PinRequest
// signed over PinPayload.
func TestPinRequestPin(t *testing.T) {
	pub, priv := wpKey(t)
	const ts = "2026-11-05T21:00:00Z"
	in := PinArgs{Box: "b1", PubKey: "pk-b1", Force: true}
	method, path, body, err := pinRequest(in, priv, ts)
	if err != nil {
		t.Fatal(err)
	}
	if method != http.MethodPost || path != "/v1/pins" {
		t.Fatalf("got %s %s, want POST /v1/pins", method, path)
	}
	pr, ok := body.(wire.PinRequest)
	if !ok {
		t.Fatalf("body is %T, want wire.PinRequest", body)
	}
	if pr.BoxID != "b1" || pr.PubKey != "pk-b1" || pr.TS != ts || !pr.Force {
		t.Fatalf("body = %+v", pr)
	}
	p, err := wire.PinPayload("b1", "pk-b1", ts, true)
	if err != nil {
		t.Fatal(err)
	}
	wpVerify(t, pub, p, pr.Sig)
}

// TestRecvInvalidAndEmpty: an invalid agent id reads nothing (nil slice and
// an error); a valid id with an empty inbox is a non-nil empty slice.
func TestRecvInvalidAndEmpty(t *testing.T) {
	cfg := &config.Config{SpoolRoot: t.TempDir()}
	got, err := Recv(cfg, "not an id", false)
	if err == nil || got != nil {
		t.Fatalf("invalid id: got %v, %v; want nil slice and an error", got, err)
	}
	got, err = Recv(cfg, "c-001", false)
	if err != nil {
		t.Fatalf("empty inbox: %v", err)
	}
	if got == nil || len(got) != 0 {
		t.Fatalf("empty inbox: got %#v, want a non-nil empty slice", got)
	}
}
