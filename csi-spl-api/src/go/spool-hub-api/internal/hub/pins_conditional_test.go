package hub_test

import (
	"io"
	"net/http"
	"testing"
)

// GET /v1/pins is the authorized_keys list a box polls on a timer. A
// conditional read (If-None-Match against the ETag) answers 304 with no body
// while the list is unchanged, and a real change flips the ETag and returns the
// full body again.
func TestListPinsConditionalRead(t *testing.T) {
	e := newEnv(t)
	tid, _ := e.tenant()
	a := e.box(tid, "box-a", "GRK-03")
	e.pin(tid, a)
	tok := e.uploadToken(tid, a)

	get := func(inm string) (int, string, string) {
		req, _ := http.NewRequest(http.MethodGet, e.url(tid)+"/v1/pins", nil)
		req.Header.Set("Authorization", "Bearer "+tok)
		if inm != "" {
			req.Header.Set("If-None-Match", inm)
		}
		resp, err := e.client.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		defer resp.Body.Close()
		b, _ := io.ReadAll(resp.Body)
		return resp.StatusCode, resp.Header.Get("ETag"), string(b)
	}

	code, etag, body := get("")
	if code != http.StatusOK || etag == "" || body == "" {
		t.Fatalf("first GET: %d etag=%q body=%q", code, etag, body)
	}
	t.Logf("unchanged pins poll: %d-byte body -> 0 on 304 (etag %s)", len(body), etag)

	if code, _, body := get(etag); code != http.StatusNotModified || body != "" {
		t.Fatalf("If-None-Match on the unchanged list: %d body=%q, want 304 empty", code, body)
	}

	// A new pin must break the validator: the box gets the full list again.
	b2 := e.box(tid, "box-b", "GRK-07")
	e.pin(tid, b2)
	code2, etag2, body2 := get(etag)
	if code2 != http.StatusOK || etag2 == etag || body2 == "" {
		t.Fatalf("after a new pin, If-None-Match with the stale etag: %d etag=%q, want 200 with a new etag and body", code2, etag2)
	}
}
