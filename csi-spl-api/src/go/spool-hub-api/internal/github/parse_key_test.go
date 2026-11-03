package github

import (
	"crypto/ed25519"
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"encoding/pem"
	"errors"
	"strings"
	"testing"
)

// pkRSA generates an RSA key for the test: never a PEM literal in git.
func pkRSA(t *testing.T) *rsa.PrivateKey {
	t.Helper()
	k, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatalf("generate rsa key: %v", err)
	}
	return k
}

// pkPEM wraps der in a PEM block of the given type.
func pkPEM(typ string, der []byte) []byte {
	return pem.EncodeToMemory(&pem.Block{Type: typ, Bytes: der})
}

// pkPKCS8 marshals any private key as PKCS#8 DER.
func pkPKCS8(t *testing.T, k any) []byte {
	t.Helper()
	der, err := x509.MarshalPKCS8PrivateKey(k)
	if err != nil {
		t.Fatalf("marshal pkcs8: %v", err)
	}
	return der
}

// pkNoQuote fails when the error text holds the input, or any line of it.
func pkNoQuote(t *testing.T, err error, in []byte) {
	t.Helper()
	msg := err.Error()
	if strings.Contains(msg, string(in)) {
		t.Fatalf("error quotes the whole input: %q", msg)
	}
	for _, line := range strings.Split(string(in), "\n") {
		line = strings.TrimSpace(line)
		if len(line) >= 8 && strings.Contains(msg, line) {
			t.Fatalf("error quotes an input line %q: %q", line, msg)
		}
	}
}

// TestParseKeyReadsPKCS1AndPKCS8: GitHub's PKCS#1 PEM and a PKCS#8 one both
// give the same RSA key back.
func TestParseKeyReadsPKCS1AndPKCS8(t *testing.T) {
	want := pkRSA(t)
	cases := map[string][]byte{
		"pkcs1": pkPEM("RSA PRIVATE KEY", x509.MarshalPKCS1PrivateKey(want)),
		"pkcs8": pkPEM("PRIVATE KEY", pkPKCS8(t, want)),
	}
	for name, in := range cases {
		t.Run(name, func(t *testing.T) {
			got, err := parseKey(in)
			if err != nil {
				t.Fatalf("parseKey: %v", err)
			}
			if !got.Equal(want) {
				t.Fatal("parseKey returned a different key")
			}
		})
	}
}

// TestParseKeyRefusesWithoutQuoting: not PEM, PEM of junk and a PKCS#8
// ed25519 key are each errBadKey, and the error text holds none of the input.
func TestParseKeyRefusesWithoutQuoting(t *testing.T) {
	_, edKey, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatalf("generate ed25519 key: %v", err)
	}
	cases := map[string][]byte{
		"not pem":       []byte("not-a-pem-block-just-some-secret-looking-text"),
		"pem of junk":   pkPEM("RSA PRIVATE KEY", []byte("junk-bytes-that-are-no-der-at-all")),
		"pkcs8 ed25519": pkPEM("PRIVATE KEY", pkPKCS8(t, edKey)),
	}
	for name, in := range cases {
		t.Run(name, func(t *testing.T) {
			k, err := parseKey(in)
			if k != nil {
				t.Fatal("parseKey returned a key for a bad input")
			}
			if !errors.Is(err, errBadKey) {
				t.Fatalf("err = %v, want errBadKey", err)
			}
			pkNoQuote(t, err, in)
		})
	}
}

// TestAPIErrorFormats: a network error (Status 0) carries no status number;
// a refused call (404) carries it before the message.
func TestAPIErrorFormats(t *testing.T) {
	cases := []struct {
		status int
		want   string
	}{
		{0, "github get contents: connection refused"},
		{404, "github get contents: 404 connection refused"},
	}
	for _, c := range cases {
		e := &APIError{Op: "get contents", Status: c.status, Message: "connection refused"}
		if got := e.Error(); got != c.want {
			t.Errorf("Status %d: Error() = %q, want %q", c.status, got, c.want)
		}
	}
}
