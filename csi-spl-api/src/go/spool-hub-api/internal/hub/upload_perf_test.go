package hub_test

import (
	"fmt"
	"io"
	"math/rand"
	"net/http"
	"os"
	"runtime"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
)

// TestUploadHeapPerf is the 027 T020 FR-001 harness (opt-in:
// SPOOL_PERF_UPLOAD=1): 8 concurrent POST /v1/files of msg.MaxFileBytes each
// through the real handler on a blob.Dir. The bodies are generated on the fly
// (a seeded PRNG), so the client holds no copy and the heap measured is the
// hub's. It logs one UPLOADPERF line per run; use -count>=5 for n.
func TestUploadHeapPerf(t *testing.T) {
	if os.Getenv("SPOOL_PERF_UPLOAD") == "" {
		t.Skip("set SPOOL_PERF_UPLOAD=1 to run the upload heap harness")
	}
	const uploads = 8
	size := int64(msg.MaxFileBytes)
	e := newEnv(t)
	tid, _ := e.tenant()
	a := e.box(tid, "box-a", "GRK-03")
	e.pin(tid, a)
	tok := e.uploadToken(tid, a)

	runtime.GC()
	var ms runtime.MemStats
	runtime.ReadMemStats(&ms)
	baseInuse, baseAlloc := ms.HeapInuse, ms.TotalAlloc

	var peak atomic.Uint64
	stop := make(chan struct{})
	sampled := make(chan struct{})
	go func() {
		defer close(sampled)
		var m runtime.MemStats
		for {
			runtime.ReadMemStats(&m)
			if m.HeapInuse > peak.Load() {
				peak.Store(m.HeapInuse)
			}
			select {
			case <-stop:
				return
			case <-time.After(2 * time.Millisecond):
			}
		}
	}()

	start := time.Now()
	var wg sync.WaitGroup
	errs := make(chan error, uploads)
	for i := 0; i < uploads; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			body := io.LimitReader(rand.New(rand.NewSource(int64(i)+time.Now().UnixNano())), size)
			req, _ := http.NewRequest(http.MethodPost, e.url(tid)+"/v1/files", body)
			req.ContentLength = size
			req.Header.Set("Authorization", "Bearer "+tok)
			req.Header.Set("Content-Type", "application/octet-stream")
			resp, err := e.client.Do(req)
			if err != nil {
				errs <- err
				return
			}
			io.Copy(io.Discard, resp.Body) //nolint:errcheck
			resp.Body.Close()
			if resp.StatusCode != http.StatusCreated {
				errs <- fmt.Errorf("upload %d: %d", i, resp.StatusCode)
			}
		}(i)
	}
	wg.Wait()
	elapsed := time.Since(start)
	close(stop)
	<-sampled
	close(errs)
	for err := range errs {
		t.Fatal(err)
	}
	runtime.ReadMemStats(&ms)
	mib := func(b uint64) float64 { return float64(b) / (1 << 20) }
	t.Logf("UPLOADPERF uploads=%d size_mib=%.0f peak_heapinuse_mib=%.1f peak_over_base_per_upload_mib=%.2f totalalloc_per_upload_mib=%.2f ns_per_upload=%d",
		uploads, mib(uint64(size)), mib(peak.Load()), mib(peak.Load()-min(peak.Load(), baseInuse))/uploads,
		mib(ms.TotalAlloc-baseAlloc)/uploads, elapsed.Nanoseconds()/uploads)
}
