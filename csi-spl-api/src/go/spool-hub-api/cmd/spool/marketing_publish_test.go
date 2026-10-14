package main

import (
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
)

// SPL-1855: marketing-publish POSTs the publish with the box's upload token
// and the owner in X-Spool-Requester, prints the hub's answer, and names a
// refusal (409 once-per-post) with a non-zero exit.
func TestMarketingPublishVerb(t *testing.T) {
	h := &docsHub{token: "tok"}
	var mu sync.Mutex
	var got []string
	code := http.StatusOK
	mux := http.NewServeMux()
	mux.HandleFunc("/v1/ws", h.wsHello)
	mux.HandleFunc("POST /v1/marketing/posts/{id}/publish", func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		defer mu.Unlock()
		got = append(got, r.PathValue("id")+"|"+r.Header.Get("Authorization")+"|"+r.Header.Get("X-Spool-Requester")+"|"+r.Header.Get("X-Spool-Tenant"))
		w.WriteHeader(code)
		if code == http.StatusOK {
			_, _ = io.WriteString(w, `{"post":"`+r.PathValue("id")+`","published":1}`)
			return
		}
		_, _ = io.WriteString(w, `{"error":"already_recorded","detail":"the post is already published"}`)
	})
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	docEnv(t, srv.URL)

	rc, out, errOut := captureRun(t, []string{"marketing-publish", "2026-10-14-new-post", "--for", "HUM-42"})
	if rc != 0 || !strings.Contains(out, `"published":1`) || errOut != "" {
		t.Fatalf("publish: rc %d out %q err %q", rc, out, errOut)
	}
	if len(got) != 1 || got[0] != "2026-10-14-new-post|Bearer tok|HUM-42|t1" {
		t.Fatalf("hub saw %q", got)
	}
	code = http.StatusConflict
	rc, _, errOut = captureRun(t, []string{"marketing-publish", "2026-10-14-new-post", "--for", "HUM-42"})
	if rc == 0 || !strings.Contains(errOut, "409") || !strings.Contains(errOut, "already_recorded") {
		t.Fatalf("second publish: rc %d err %q, want a named 409", rc, errOut)
	}
	// refused before any call: no owner, a bad post id, two posts
	for _, args := range [][]string{
		{"marketing-publish", "2026-10-14-new-post"},
		{"marketing-publish", "../x", "--for", "HUM-42"},
		{"marketing-publish", "2026-10-14-a", "2026-10-14-b", "--for", "HUM-42"},
	} {
		if rc, _, _ := captureRun(t, args); rc == 0 {
			t.Fatalf("%v: rc 0, want a refusal", args)
		}
	}
	if len(got) != 2 {
		t.Fatalf("a refused call reached the hub: %q", got)
	}
}
