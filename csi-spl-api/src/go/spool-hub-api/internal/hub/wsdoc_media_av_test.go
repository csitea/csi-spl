package hub_test

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// Spec 190 row H1 (SPL-6152): POST /v1/workspace/doctree/{doc}/media on
// testkit Postgres. Red on origin/master: the route does not exist, every
// upload below answers 405. Red control of the row: the route reading the
// body with readAllCapped in place of the stream fails
// TestWorkspaceDocMediaStreams' memory bound (the commit body holds the run).
//
//	go test ./internal/hub -run 'WorkspaceDocMedia' -v

// mp4Of is a body that sniffs as an ISO base media file, n bytes long.
func mp4Of(n int) []byte {
	b := make([]byte, n)
	copy(b, "\x00\x00\x00\x18ftypmp42\x00\x00\x00\x00mp42isom")
	return b
}

// mediaPost sends body to doc's media route as member as (or with bearer)
// and answers the status and the JSON answer.
func mediaPost(t *testing.T, e *env, tid, doc, as, bearer, ctype, filename string, body io.Reader, n int64) (int, map[string]any) {
	t.Helper()
	doc, q, _ := strings.Cut(doc, "?") // a doc path may carry its query (fs=repo)
	u := e.url(tid) + doc + "/media?" + q
	if filename != "" {
		u += "&filename=" + filename
	}
	req, _ := http.NewRequest(http.MethodPost, u, body)
	req.ContentLength = n
	req.Header.Set("Content-Type", ctype)
	if bearer != "" {
		req.Header.Set("Authorization", "Bearer "+bearer)
	} else {
		req.Header.Set(memberHeader, as)
	}
	resp, err := e.client.Do(req)
	if err != nil {
		t.Fatalf("POST %s: %v", u, err)
	}
	defer resp.Body.Close()
	out := map[string]any{}
	json.NewDecoder(resp.Body).Decode(&out) //nolint:errcheck
	return resp.StatusCode, out
}

// mediaEnv is a workspace with an own docs store, a member and one doc.
func mediaEnv(t *testing.T, mut ...func(*hub.Options)) (*env, *hub.WorkspaceDocs, string, string, string) {
	t.Helper()
	d := wsDocs(t, t.TempDir())
	e := rbacEnv(t, append([]func(*hub.Options){func(o *hub.Options) { o.WorkspaceDocs = d }}, mut...)...)
	if _, ok := e.st.(*store.Postgres); !ok {
		t.Skip("workspace documents need Postgres (SPOOL_TEST_PG_DSN)")
	}
	tid, _ := e.tenant()
	as := seat(t, e, tid, "developer")
	doc := docTreeAPI + "/" + dtStr(mustCall(t, e, tid, http.MethodPost, docTreeAPI, as, map[string]any{"title": "media"}, 200), "id")
	return e, d, tid, as, doc
}

// TestWorkspaceDocMediaStreams: a 20 MiB mp4 is stored under its doc at
// qto-media/<doc>/<sha256>.mp4 without the hub holding it in memory; the
// same bytes again answer the same name with 200; a 33 MiB one is a 413
// before its body is read.
func TestWorkspaceDocMediaStreams(t *testing.T) {
	e, d, tid, as, doc := mediaEnv(t)
	body := mp4Of(20 << 20)
	var before, after runtime.MemStats
	runtime.GC()
	runtime.ReadMemStats(&before)
	code, out := mediaPost(t, e, tid, doc, as, "", "video/mp4", "", bytes.NewReader(body), int64(len(body)))
	runtime.ReadMemStats(&after)
	if code != http.StatusCreated || dtStr(out, "kind") != "video" || dtStr(out, "name") != shaHex(body)+".mp4" {
		t.Fatalf("20 MiB mp4: %d %v", code, out)
	}
	if want := doc + "/media/" + shaHex(body) + ".mp4"; dtStr(out, "http_path") != want {
		t.Fatalf("http_path %q, want %q", dtStr(out, "http_path"), want)
	}
	// The client's copy of the body is not allocated here; the server's
	// heap growth for one upload must stay far below the file.
	if grew := after.TotalAlloc - before.TotalAlloc; grew > 12<<20 {
		t.Fatalf("one 20 MiB upload allocated %d MiB: the hub held the body in memory", grew>>20)
	}
	key := filepath.Join(mustLoc(t, d, tid), "qto-media", strings.TrimPrefix(doc, docTreeAPI+"/"), shaHex(body)+".mp4")
	if fi, err := os.Stat(key); err != nil || fi.Size() != int64(len(body)) {
		t.Fatalf("stored object: %v %v", fi, err)
	}
	if code, again := mediaPost(t, e, tid, doc, as, "", "video/mp4", "", bytes.NewReader(body), int64(len(body))); code != http.StatusOK || dtStr(again, "name") != dtStr(out, "name") {
		t.Fatalf("the same bytes again: %d %v, want 200 and the same name", code, again)
	}
	// The 33 MiB body sends 64 KiB, then holds until the answer is in: a hub
	// that read the body before answering would wait for it, and the test
	// ends red at the guard instead.
	big := &heldReader{head: 64 << 10, release: make(chan struct{})}
	guard := time.AfterFunc(10*time.Second, func() { big.timedOut = true; close(big.release) })
	code, out = mediaPost(t, e, tid, doc, as, "", "video/mp4", "", big, 33<<20)
	if guard.Stop() {
		close(big.release)
	}
	if big.timedOut || code != http.StatusRequestEntityTooLarge || dtStr(out, "error") != "too_large" {
		t.Fatalf("33 MiB declared: %d %v (held body timed out: %v), want 413 too_large before the body", code, out, big.timedOut)
	}
	t.Logf("20 MiB mp4 stored (heap +%d KiB), the same bytes again 200, 33 MiB declared 413 with the body held after 64 KiB",
		(after.TotalAlloc-before.TotalAlloc)>>10)
}

// heldReader yields head zero bytes, then blocks until release closes, then
// fails: a body the server must not need to answer.
type heldReader struct {
	head     int
	release  chan struct{}
	timedOut bool
}

func (h *heldReader) Read(p []byte) (int, error) {
	if h.head > 0 {
		n := min(len(p), h.head)
		clear(p[:n])
		h.head -= n
		return n, nil
	}
	<-h.release
	return 0, io.ErrUnexpectedEOF
}

// TestWorkspaceDocMediaTypes: the C3 table, kind file and the deny list.
func TestWorkspaceDocMediaTypes(t *testing.T) {
	e, _, tid, as, doc := mediaEnv(t)
	elf := append([]byte("\x7fELF\x02\x01\x01"), make([]byte, 64)...)
	for _, c := range []struct {
		name, ctype, filename string
		body                  []byte
		code                  int
		err, kind, ext        string
	}{
		{"mp4 sent as audio/mpeg", "audio/mpeg", "", mp4Of(4096), 415, "bad_media", "", ""},
		{"png", "image/png", "", pngOf(t, 9), 201, "", "image", "png"},
		{"text sent as a png", "image/png", "", []byte("not a picture"), 415, "bad_media", "", ""},
		{"a 6 MiB picture", "image/jpeg", "", make([]byte, 6<<20), 413, "too_large", "", ""},
		{"m4a", "audio/mp4", "", mp4Of(2048), 201, "", "audio", "m4a"},
		{"pdf", "application/pdf", "report.pdf", []byte("%PDF-1.7 hello"), 201, "", "file", "pdf"},
		{"svg is a file", "image/svg+xml", "logo.svg", []byte("<svg xmlns='http://www.w3.org/2000/svg'/>"), 201, "", "file", "svg"},
		{"a file named .mp4 is no video", "application/octet-stream", "clip.MP4", []byte("plain bytes"), 201, "", "file", "bin"},
		{"exe by name", "application/x-msdownload", "setup.EXE", []byte("hello"), 415, "denied_type", "", ""},
		{"ELF named .pdf", "application/pdf", "fake.pdf", elf, 415, "denied_type", "", ""},
		{"empty", "application/pdf", "e.pdf", nil, 400, "bad_body", "", ""},
	} {
		code, out := mediaPost(t, e, tid, doc, as, "", c.ctype, c.filename, bytes.NewReader(c.body), int64(len(c.body)))
		if code != c.code || dtStr(out, "error") != c.err || dtStr(out, "kind") != c.kind ||
			(c.ext != "" && !strings.HasSuffix(dtStr(out, "name"), "."+c.ext)) {
			t.Errorf("%s: %d %v, want %d %q kind %q .%s", c.name, code, out, c.code, c.err, c.kind, c.ext)
		}
	}
	t.Logf("types: mp4 as mpeg 415, png/m4a/pdf/svg/.mp4-file stored, text-as-png 415, 6 MiB jpeg 413, exe and ELF 415 denied_type, empty 400")
}

// TestWorkspaceDocMediaDoor: an agent token stores; another workspace, a
// doc locked to someone else, a reader without docs.write, the repo tree
// and an unknown doc are refused before any byte is stored.
func TestWorkspaceDocMediaDoor(t *testing.T) {
	e, _, tid, as, doc := mediaEnv(t)
	clip := mp4Of(1024)
	b := e.box(tid, "box-media", "CLE-09")
	e.pin(tid, b)
	if code, out := mediaPost(t, e, tid, doc, "", e.uploadToken(tid, b), "video/mp4", "", bytes.NewReader(clip), int64(len(clip))); code != http.StatusCreated {
		t.Fatalf("agent token: %d %v, want 201", code, out)
	}
	owner := seat(t, e, tid, rbac.Admin)
	locked := docTreeAPI + "/" + dtStr(mustCall(t, e, tid, http.MethodPost, docTreeAPI, owner, map[string]any{"title": "mine", "restricted": true}, 200), "id")
	other, _ := e.tenant()
	viewer := seat(t, e, tid, rbac.TimeAccountant) // no docs permission
	for _, c := range []struct {
		name, tid, doc, as string
		want               int
	}{
		{"another workspace", other, doc, seat(t, e, other, "developer"), 404},
		{"a doc locked to someone else", tid, locked, as, 404},
		{"an unknown doc", tid, docTreeAPI + "/" + uuidV4(), as, 404},
		{"a reader without docs.write", tid, doc, viewer, 403},
		{"the repo tree", tid, doc + "?fs=repo", as, 403},
	} {
		if code, out := mediaPost(t, e, c.tid, c.doc, c.as, "", "video/mp4", "", bytes.NewReader(clip), int64(len(clip))); code != c.want {
			t.Errorf("%s: %d %v, want %d", c.name, code, out, c.want)
		}
	}
	if code, out := mediaPost(t, e, tid, locked, owner, "", "video/mp4", "", bytes.NewReader(clip), int64(len(clip))); code != http.StatusCreated {
		t.Fatalf("CONTROL: the locked doc's own human: %d %v, want 201", code, out)
	}
	t.Logf("door: agent 201, locked doc's human 201; other workspace, locked to another, unknown 404; viewer, repo 403")
}

// TestWorkspaceDocMediaQuota: the declared length is checked against the
// workspace's file quota before the body is read.
func TestWorkspaceDocMediaQuota(t *testing.T) {
	e, _, tid, as, doc := mediaEnv(t, func(o *hub.Options) {
		o.QuotaFileBytes = 1 << 20
		o.FileUsageTTL = time.Nanosecond
	})
	clip := mp4Of(2 << 20)
	if code, out := mediaPost(t, e, tid, doc, as, "", "video/mp4", "", bytes.NewReader(clip), int64(len(clip))); code != 429 || dtStr(out, "error") != "quota" {
		t.Fatalf("2 MiB over a 1 MiB quota: %d %v, want 429 quota", code, out)
	}
	small := mp4Of(64 << 10)
	if code, out := mediaPost(t, e, tid, doc, as, "", "video/mp4", "", bytes.NewReader(small), int64(len(small))); code != http.StatusCreated {
		t.Fatalf("CONTROL: 64 KiB under the quota: %d %v", code, out)
	}
	t.Logf("quota: 2 MiB declared over 1 MiB is 429 quota, 64 KiB stored")
}
