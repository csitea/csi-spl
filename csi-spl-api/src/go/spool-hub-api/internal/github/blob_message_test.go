package github

import (
	"context"
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

const bmBlobPath = "/repos/o/r/git/blobs/abc123"

// bmClient points a Client at an httptest server that mints an installation
// token and answers the blob route with blob. The key is generated here:
// never a PEM literal in git.
func bmClient(t *testing.T, blob http.HandlerFunc) *Client {
	t.Helper()
	k, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatalf("generate rsa key: %v", err)
	}
	mux := http.NewServeMux()
	mux.HandleFunc("POST /app/installations/9/access_tokens", func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(`{"token":"t"}`))
	})
	mux.HandleFunc("GET "+bmBlobPath, blob)
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	c, err := New(Config{
		API: srv.URL, AppID: "1", InstallationID: "9", Owner: "o", Repo: "r",
		Key: pem.EncodeToMemory(&pem.Block{Type: "RSA PRIVATE KEY", Bytes: x509.MarshalPKCS1PrivateKey(k)}),
	})
	if err != nil {
		t.Fatal(err)
	}
	return c
}

// bmAnswer writes one blob answer with the given encoding.
func bmAnswer(content, encoding string) http.HandlerFunc {
	return func(w http.ResponseWriter, _ *http.Request) {
		_ = json.NewEncoder(w).Encode(map[string]string{"content": content, "encoding": encoding})
	}
}

func TestMessageOfNonJSONIsEmpty(t *testing.T) {
	if got := messageOf([]byte("<html>502 bad gateway</html>")); got != "" {
		t.Fatalf("messageOf(non-JSON) = %q, want empty", got)
	}
}

func TestMessageOfShortIsKept(t *testing.T) {
	if got := messageOf([]byte(`{"message":"Not Found","documentation_url":"x"}`)); got != "Not Found" {
		t.Fatalf("messageOf = %q, want %q", got, "Not Found")
	}
}

func TestMessageOfCapsAt200Bytes(t *testing.T) {
	long := strings.Repeat("m", 250)
	got := messageOf([]byte(`{"message":"` + long + `"}`))
	if len(got) != 200 || got != long[:200] {
		t.Fatalf("messageOf(250 bytes) len = %d, want 200", len(got))
	}
}

func TestBlobRefusedIsAPIError(t *testing.T) {
	for _, status := range []int{http.StatusNotFound, http.StatusInternalServerError} {
		c := bmClient(t, func(w http.ResponseWriter, _ *http.Request) {
			w.WriteHeader(status)
			_, _ = w.Write([]byte(`{"message":"refused"}`))
		})
		b, err := c.Blob(context.Background(), "abc123")
		var ae *APIError
		if !errors.As(err, &ae) || ae.Status != status || ae.Op != "blob" || ae.Message != "refused" {
			t.Fatalf("status %d: Blob err = %#v, want *APIError{blob %d refused}", status, err, status)
		}
		if b != nil {
			t.Fatalf("status %d: Blob bytes = %q, want nil", status, b)
		}
	}
}

func TestBlobNonBase64IsVerbatim(t *testing.T) {
	c := bmClient(t, bmAnswer("plain\ntext", "utf-8"))
	b, err := c.Blob(context.Background(), "abc123")
	if err != nil || string(b) != "plain\ntext" {
		t.Fatalf("Blob(utf-8) = %q, %v; want the content unchanged", b, err)
	}
}

func TestBlobBase64WithNewlinesIsDecoded(t *testing.T) {
	// "hello, blob" base64-encoded, wrapped the way GitHub wraps it.
	c := bmClient(t, bmAnswer("aGVsbG8s\nIGJsb2I=\n", "base64"))
	b, err := c.Blob(context.Background(), "abc123")
	if err != nil || string(b) != "hello, blob" {
		t.Fatalf("Blob(base64) = %q, %v; want %q", b, err, "hello, blob")
	}
}
