package hub_test

import (
	"context"
	"io"
	"net/http"
	"strings"
	"testing"

	"github.com/coder/websocket/wsjson"
)

// perf round 4 G11: GET /v1/view/flow carries a validator like the other
// view reads, so a repeat read of an unchanged flow is a 304 with no body,
// and it stays private (`private, no-cache`: the browser asks every time and
// no shared cache keeps it). A new mention flips the tag.
func TestFlowConditionalRead(t *testing.T) {
	e := followEnv(t)
	tid, _ := e.tenant()
	two := dialFlowMember(t, e, tid, "HUM-2")

	get := func(inm string) (int, string, string, string) {
		req, _ := http.NewRequest(http.MethodGet, e.url(tid)+"/v1/view/flow", nil)
		req.Header.Set(memberHeader, "HUM-1")
		if inm != "" {
			req.Header.Set("If-None-Match", inm)
		}
		resp, err := e.client.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		defer resp.Body.Close()
		b, _ := io.ReadAll(resp.Body)
		return resp.StatusCode, resp.Header.Get("ETag"), resp.Header.Get("Cache-Control"), string(b)
	}

	code, tag, cc, body := get("")
	if code != http.StatusOK || !strings.HasPrefix(tag, `W/"`) || body == "" {
		t.Fatalf("first GET: %d etag=%q body=%q, want 200 with a W/ etag", code, tag, body)
	}
	if cc != "private, no-cache" {
		t.Fatalf("Cache-Control %q, want private, no-cache", cc)
	}
	t.Logf("unchanged flow read: %d-byte body -> 0 on 304 (etag %s)", len(body), tag)
	if code, _, _, body := get(tag); code != http.StatusNotModified || body != "" {
		t.Fatalf("If-None-Match on the unchanged flow: %d body=%q, want 304 empty", code, body)
	}

	wsjson.Write(context.Background(), two, map[string]any{"type": "send", "task_id": "lobby", "kind": "chat", "body": "hey @HUM-1"}) //nolint:errcheck
	readFrame(t, two, "ack")
	if code, tag2, _, body := get(tag); code != http.StatusOK || tag2 == tag || !strings.Contains(body, "hey @HUM-1") {
		t.Fatalf("after a mention, the stale etag: %d etag=%q body=%q, want 200 with a new etag", code, tag2, body)
	}
}
