package auth_test

import (
	"bytes"
	"encoding/json"
	"net/http"
	"strings"
	"testing"
)

// CLE-34986: ten wrong guesses from a stranger's address locked the owner out
// of a known email from everywhere (the bucket was keyed on the email alone
// and spent before the password check). Now the stranger's address is
// locked, the owner's is not; CONTROL: the stranger's own 11th try is 429,
// and 100 tries spread over many addresses still hit the per-email ceiling.
func TestNativeLoginLockoutIsPerAddress(t *testing.T) {
	r := newNRig(t, map[string]string{"SPOOL_HUB_AUTH_NATIVE_TRUSTED_PROXY_HOPS": "1"}, nil, true)
	r.registerVerified(t, "owner@example.com", pwA)
	login := func(from, pw string) int {
		t.Helper()
		b, _ := json.Marshal(map[string]string{"email": "owner@example.com", "password": pw})
		req, _ := http.NewRequest(http.MethodPost, r.url+"/api/v1/auth/login", bytes.NewReader(b))
		req.Header.Set("Content-Type", "application/json")
		req.Header.Set("X-Forwarded-For", from)
		res, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		res.Body.Close()
		return res.StatusCode
	}
	for i := 0; i < 10; i++ {
		login("203.0.113.9", "guess-"+strings.Repeat("x", i+8))
	}
	if c := login("203.0.113.9", "guess-again-xyz"); c != http.StatusTooManyRequests {
		t.Fatalf("CONTROL: the stranger's 11th try: %d, want 429", c)
	}
	if c := login("198.51.100.7", pwA); c != http.StatusOK {
		t.Fatalf("the owner from their own address after a stranger's 10 guesses: %d, want 200", c)
	}
	// spread: 10 addresses x 9 guesses + the owner's 1 = 100 = the ceiling
	for a := 0; a < 10; a++ {
		for i := 0; i < 9; i++ {
			login("192.0.2."+string(rune('0'+a)), "spread-guess-"+strings.Repeat("y", i+4))
		}
	}
	if c := login("198.51.100.8", pwA); c != http.StatusTooManyRequests {
		t.Fatalf("CONTROL: after 100 tries across addresses: %d, want 429", c)
	}
}
