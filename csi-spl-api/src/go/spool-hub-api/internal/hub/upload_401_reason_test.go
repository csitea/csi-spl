package hub_test

import (
	"bytes"
	"net/http"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/rs/zerolog"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
)

// syncBuf is a concurrency-safe log sink: the hub logs from many goroutines at
// once (the access-log middleware, the WS pumps), so a plain bytes.Buffer races.
type syncBuf struct {
	mu sync.Mutex
	b  bytes.Buffer
}

func (s *syncBuf) Write(p []byte) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.b.Write(p)
}

func (s *syncBuf) contains(sub string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return bytes.Contains(s.b.Bytes(), []byte(sub))
}

func (s *syncBuf) String() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.b.String()
}

// CLE-77795: POST /v1/files refused with 401 "door" must name WHY in the log,
// so a prd 401 with a valid member session is diagnosable. unknown_token is the
// tell-tale of a hub restart (a redeploy or a Cloud Run recycle) that wiped the
// per-process upload-token map — the browser still held a token the new process
// never minted, which is the root cause of the retried-upload bug. The response
// body stays "door" (the WUI keys its refresh-and-retry off that code).
func TestUploadTokenRefusalLogsReason(t *testing.T) {
	var mu sync.Mutex
	now := time.Now()
	clock := func() time.Time { mu.Lock(); defer mu.Unlock(); return now }
	advance := func(d time.Duration) { mu.Lock(); now = now.Add(d); mu.Unlock() }

	buf := &syncBuf{}
	e := newEnv(t, func(o *hub.Options) { o.Log = zerolog.New(buf); o.Now = clock })
	tid, _ := e.tenant()

	post := func(auth string) int {
		req, _ := http.NewRequest(http.MethodPost, e.url(tid)+"/v1/files", strings.NewReader("hello bytes"))
		req.Header.Set("Content-Type", "application/octet-stream")
		if auth != "" {
			req.Header.Set("Authorization", auth)
		}
		resp, err := e.client.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		resp.Body.Close()
		return resp.StatusCode
	}

	// 1. no Authorization at all → no_bearer.
	if code := post(""); code != http.StatusUnauthorized {
		t.Fatalf("no auth: got %d, want 401", code)
	}
	// 2. a token this process never minted (a hub restart wiped the map) → unknown_token.
	if code := post("Bearer deadbeefdeadbeef"); code != http.StatusUnauthorized {
		t.Fatalf("bogus token: got %d, want 401", code)
	}
	// 3. a real token, then the clock past its TTL → expired_token.
	b := e.box(tid, "box-a", "GRK-03")
	e.pin(tid, b)
	tok := e.uploadToken(tid, b)
	advance(6 * time.Minute) // UploadTokenTTL is 5m in newEnv
	if code := post("Bearer " + tok); code != http.StatusUnauthorized {
		t.Fatalf("expired token: got %d, want 401", code)
	}

	for _, want := range []string{
		`"reason":"no_bearer"`,
		`"reason":"unknown_token"`,
		`"reason":"expired_token"`,
	} {
		if !buf.contains(want) {
			t.Errorf("upload 401 log is missing %s\n--- log ---\n%s", want, buf.String())
		}
	}
	// the diagnostic names the path so it is grep-able alongside the access log.
	if !buf.contains("upload token refused") {
		t.Errorf("no 'upload token refused' log line\n%s", buf.String())
	}
}
