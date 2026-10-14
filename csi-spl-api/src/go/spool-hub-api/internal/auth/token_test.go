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
		"/\t/evil.example":     "/",
		"/\x00/evil.example":   "/",
		"/\x7f/evil.example":   "/",
		"/ /evil.example":      "/",
		"/c/a%20b?x=1#y":       "/c/a%20b?x=1#y",
	} {
		if got := safeRedirect(in); got != want {
			t.Errorf("safeRedirect(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestValidTenant(t *testing.T) {
	for in, want := range map[string]bool{"t1": true, "acme-dev": true, "": false, "-x": false,
		"Acme": false, "a.b": false, "t\u00e9n": false, "t1\xff": false, strings.Repeat("a", 64): false} {
		if validTenant(in) != want {
			t.Errorf("validTenant(%q) != %v", in, want)
		}
	}
}

// SPL-1815: every hub instance derives the same upload-token key from the
// session key, distinct from the session and state keys; no usable session
// key = no key, and the hub keeps its per-process token map.
func TestUploadTokenKey(t *testing.T) {
	k := strings.Repeat("k", 32)
	got := UploadTokenKey(&Config{SessionKey: k})
	if len(got) != 32 || string(got) != string(UploadTokenKey(&Config{SessionKey: k})) {
		t.Fatalf("key not stable: %x", got)
	}
	if string(got) == string(subkey(k, labelSession)) || string(got) == string(subkey(k, labelState)) {
		t.Fatal("upload key equals a session or state key")
	}
	for _, c := range []*Config{nil, {SessionKey: "short"}, {SessionKey: strings.Repeat("PLACEHOLDER", 4)}} {
		if UploadTokenKey(c) != nil {
			t.Fatalf("key from unusable config %+v", c)
		}
	}
}
