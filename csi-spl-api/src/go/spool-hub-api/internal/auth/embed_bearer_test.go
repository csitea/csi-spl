package auth

import (
	"bytes"
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// TestEmbedTokenRoundTrip: a minted token, sent as a Bearer, reads back as
// the hash the mint returned; two mints differ.
func TestEmbedTokenRoundTrip(t *testing.T) {
	tok, hash, err := NewEmbedToken()
	if err != nil || len(hash) != sha256.Size {
		t.Fatalf("mint: %x %v", hash, err)
	}
	if raw, err := base64.RawURLEncoding.DecodeString(tok); err != nil || len(raw) != embedTokenBytes {
		t.Fatalf("the token is not 256 bits of base64url (%v)", err)
	}
	for _, scheme := range []string{"Bearer", "bearer"} {
		r := httptest.NewRequest(http.MethodGet, "/", nil)
		r.Header.Set("Authorization", scheme+" "+tok)
		if got, err := EmbedBearer(r); err != nil || !bytes.Equal(got, hash) {
			t.Errorf("%s: read %x %v, want %x", scheme, got, err, hash)
		}
	}
	if other, _, _ := NewEmbedToken(); other == tok {
		t.Error("two mints gave one token")
	}
}

// TestEmbedBearerOnlyFromTheHeader: the token is read from Authorization
// alone. The same token as a cookie or in the query string is no token, and
// a malformed header is refused. CONTROL: the header form of that token
// passes, so each refusal is the carrier's, not the token's.
func TestEmbedBearerOnlyFromTheHeader(t *testing.T) {
	tok, _, _ := NewEmbedToken()
	short := base64.RawURLEncoding.EncodeToString(make([]byte, 16))
	cases := map[string]func(r *http.Request){
		"none": func(*http.Request) {},
		"cookie": func(r *http.Request) {
			r.AddCookie(&http.Cookie{Name: "embed", Value: tok, HttpOnly: true, Secure: true})
		},
		"query":        func(r *http.Request) { r.URL.RawQuery = "token=" + tok },
		"basic":        func(r *http.Request) { r.Header.Set("Authorization", "Basic "+tok) },
		"no scheme":    func(r *http.Request) { r.Header.Set("Authorization", tok) },
		"other scheme": func(r *http.Request) { r.Header.Set("Authorization", "Token "+tok) },
		"short":        func(r *http.Request) { r.Header.Set("Authorization", "Bearer "+short) },
		"long":         func(r *http.Request) { r.Header.Set("Authorization", "Bearer "+tok+tok) },
		"padded":       func(r *http.Request) { r.Header.Set("Authorization", "Bearer "+tok+"=") },
		"not base64":   func(r *http.Request) { r.Header.Set("Authorization", "Bearer "+strings.Repeat("!", 43)) },
		"empty":        func(r *http.Request) { r.Header.Set("Authorization", "Bearer ") },
	}
	for name, set := range cases {
		r := httptest.NewRequest(http.MethodGet, "/", nil)
		set(r)
		if h, err := EmbedBearer(r); !errors.Is(err, ErrNoEmbedBearer) || h != nil {
			t.Errorf("%s: %x %v, want ErrNoEmbedBearer", name, h, err)
		}
	}
	r := httptest.NewRequest(http.MethodGet, "/", nil)
	r.Header.Set("Authorization", "Bearer "+tok)
	if _, err := EmbedBearer(r); err != nil {
		t.Fatalf("CONTROL: the header form is refused: %v", err)
	}
}
