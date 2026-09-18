package auth

import (
	"strings"
	"testing"
	"time"
)

func TestTokenRoundTripAndTamper(t *testing.T) {
	key := subkey(strings.Repeat("k", 32), labelState)
	now := time.Unix(1_800_000_000, 0)
	tok, err := signToken(key, statePayload{Provider: "google", Nonce: "n1", Exp: now.Add(time.Minute).Unix()})
	if err != nil {
		t.Fatal(err)
	}
	var got statePayload
	if err := openToken(key, tok, &got, now); err != nil || got.Nonce != "n1" || got.Provider != "google" {
		t.Fatalf("round trip: %v %+v", err, got)
	}
	payload, sig, _ := strings.Cut(tok, ".")
	for name, bad := range map[string]string{
		"empty":         "",
		"no sig":        payload,
		"flipped sig":   payload + "." + strings.Repeat("A", len(sig)),
		"other payload": "eyJwIjoiZmFjZWJvb2sifQ." + sig,
	} {
		if err := openToken(key, bad, &statePayload{}, now); err != errBadToken {
			t.Errorf("%s: want errBadToken, got %v", name, err)
		}
	}
	if err := openToken(key, tok, &statePayload{}, now.Add(2*time.Minute)); err != errExpiredToken {
		t.Errorf("expired: got %v", err)
	}
}

// A session and a state are signed with different subkeys: neither verifies
// as the other.
func TestSubkeysSeparateStateFromSession(t *testing.T) {
	root := strings.Repeat("k", 32)
	now := time.Unix(1_800_000_000, 0)
	sess, _ := signToken(subkey(root, labelSession), Session{V: 1, Exp: now.Add(time.Hour).Unix()})
	if err := openToken(subkey(root, labelState), sess, &statePayload{}, now); err != errBadToken {
		t.Fatalf("session accepted as state: %v", err)
	}
}

func TestSafeRedirect(t *testing.T) {
	for in, want := range map[string]string{
		"":                     "/",
		"/c/general":           "/c/general",
		"https://evil.example": "/",
		"//evil.example":       "/",
		"/\\evil.example":      "/",
		"c/general":            "/",
		"/x\r\nSet-Cookie: a":  "/",
	} {
		if got := safeRedirect(in); got != want {
			t.Errorf("safeRedirect(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestValidTenant(t *testing.T) {
	for in, want := range map[string]bool{"t1": true, "acme-dev": true, "": false, "-x": false,
		"Acme": false, "a.b": false, strings.Repeat("a", 64): false} {
		if validTenant(in) != want {
			t.Errorf("validTenant(%q) != %v", in, want)
		}
	}
}
