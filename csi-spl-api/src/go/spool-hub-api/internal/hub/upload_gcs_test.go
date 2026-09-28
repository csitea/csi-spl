package hub_test

import (
	"bytes"
	"context"
	"crypto/rand"
	"net/http"
	"net/http/httptest"
	"net/http/httputil"
	"net/url"
	"os"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/blob"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
)

// TestUploadGCSListCalls counts objects.list requests the hub sends to the
// GCS emulator per new upload (027 T020 FR-001, quota path). A counting
// reverse proxy sits between the hub's GCS client and $STORAGE_EMULATOR_HOST
// (fake-gcs in hub-gcs.tst.sh). It logs one UPLOADGCS line; n = uploads.
func TestUploadGCSListCalls(t *testing.T) {
	emu := os.Getenv("STORAGE_EMULATOR_HOST")
	if emu == "" {
		t.Skip("STORAGE_EMULATOR_HOST unset; GCS emulator not in this run")
	}
	bucket := os.Getenv("SPOOL_HUB_FILES_BUCKET")
	if bucket == "" {
		bucket = "csi-spl-test-files"
	}
	target, _ := url.Parse("http://" + strings.TrimPrefix(emu, "http://"))
	var lists, reqs atomic.Int64
	rp := httputil.NewSingleHostReverseProxy(target)
	proxy := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		reqs.Add(1)
		if r.Method == http.MethodGet && strings.HasSuffix(strings.TrimSuffix(r.URL.Path, "/"), "/b/"+bucket+"/o") {
			lists.Add(1)
		}
		rp.ServeHTTP(w, r)
	}))
	defer proxy.Close()
	t.Setenv("STORAGE_EMULATOR_HOST", strings.TrimPrefix(proxy.URL, "http://"))
	g, err := blob.OpenGCS(context.Background(), bucket)
	if err != nil {
		t.Fatal(err)
	}
	defer g.Close()

	e := newEnv(t, func(o *hub.Options) { o.Blob = g; o.QuotaFileBytes = 1 << 30 })
	tid, _ := e.tenant()
	a := e.box(tid, "box-a", "GRK-03")
	e.pin(tid, a)
	tok := e.uploadToken(tid, a)
	const n = 5
	lists.Store(0)
	reqs.Store(0)
	for i := 0; i < n; i++ {
		data := make([]byte, 64<<10)
		rand.Read(data) //nolint:errcheck
		req, _ := http.NewRequest(http.MethodPost, e.url(tid)+"/v1/files", bytes.NewReader(data))
		req.Header.Set("Authorization", "Bearer "+tok)
		resp, err := e.client.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		resp.Body.Close()
		if resp.StatusCode != http.StatusCreated {
			t.Fatalf("upload %d: %d", i, resp.StatusCode)
		}
	}
	t.Logf("UPLOADGCS uploads=%d list_calls=%d list_per_upload=%.2f gcs_requests_per_upload=%.2f",
		n, lists.Load(), float64(lists.Load())/n, float64(reqs.Load())/n)
	// SPL-1123 budget: scratch put, exists, conditional copy, scratch delete
	// per new upload, plus the one quota list (it was 5.20: Promote asked
	// Exists again right after the handler had).
	if got := reqs.Load(); got > 4*n+1 {
		t.Errorf("%d GCS requests for %d new uploads, budget %d", got, n, 4*n+1)
	}
}
