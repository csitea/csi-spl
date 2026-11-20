package main

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/action"
)

// Spec 183 row P3: `spool topic-pdf` against a stub hub serving the 7.1.1
// route. The done test: the flags, output and exit codes of 7.1.2; the file
// holds exactly the bytes the stub served (sha256); a 404 exits 3 and writes
// no file. RED control: ignore --out, and TestTopicPDFWritesServedBytes fails
// on the path.

const pdfTask = "0f8fad5b-d9cb-469f-a165-70867728950e"

// pdfHub serves body as the export of every topic, or refuses with
// status + token when status is not 200; seen holds every request URI.
type pdfHub struct {
	mu     sync.Mutex
	body   []byte
	status int
	token  string
	seen   []string
}

func (p *pdfHub) serve(w http.ResponseWriter, r *http.Request) {
	p.mu.Lock()
	p.seen = append(p.seen, r.URL.RequestURI())
	status, token, body := p.status, p.token, p.body
	p.mu.Unlock()
	if r.Header.Get("Authorization") != "Bearer tok" || !strings.HasSuffix(r.URL.Path, "/export.pdf") {
		writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "unauthorized"})
		return
	}
	if status != http.StatusOK {
		writeJSON(w, status, map[string]string{"error": token})
		return
	}
	w.Header().Set("Content-Type", "application/pdf")
	w.Header().Set("Content-Disposition", `attachment; filename="hello-world-0f8fad5b-20261120T120000Z.pdf"`)
	w.Header().Set("X-Spool-Rows", "3")
	w.Header().Set("X-Spool-Pictures", "1")
	w.Write(body) //nolint:errcheck
}

func (p *pdfHub) requests() []string {
	p.mu.Lock()
	defer p.mu.Unlock()
	return append([]string(nil), p.seen...)
}

func newPDFHub(t *testing.T) (*pdfHub, string) {
	t.Helper()
	body := make([]byte, 200<<10)
	if _, err := rand.Read(body); err != nil {
		t.Fatal(err)
	}
	p := &pdfHub{body: append([]byte("%PDF-1.7\n"), body...), status: http.StatusOK}
	h := newScriptHub(t, nil, p.serve)
	return p, h.URL
}

func runTopicPDF(t *testing.T, url string, args ...string) (int, action.TopicPDFResult, string) {
	t.Helper()
	cfg := hubCfg(t, url)
	rc, out, errOut := capture(t, "", func() int { return cmdTopicPDF(cfg, args) })
	var res action.TopicPDFResult
	if rc == 0 {
		if strings.Count(out, "\n") != 1 || json.Unmarshal([]byte(out), &res) != nil {
			t.Fatalf("stdout is not one JSON line: %q", out)
		}
	}
	return rc, res, errOut
}

// TestTopicPDFWritesServedBytes: --out names the file; it holds exactly the
// served bytes, and the JSON line says so (path, bytes, rows, pictures,
// sha256). An existing file there is replaced.
func TestTopicPDFWritesServedBytes(t *testing.T) {
	p, url := newPDFHub(t)
	out := filepath.Join(t.TempDir(), "topic.pdf")
	if err := os.WriteFile(out, []byte("old"), 0o600); err != nil {
		t.Fatal(err)
	}
	rc, res, errOut := runTopicPDF(t, url, "--task", pdfTask, "--out", out)
	if rc != 0 {
		t.Fatalf("rc %d err %q", rc, errOut)
	}
	sum := sha256.Sum256(p.body)
	want := action.TopicPDFResult{TaskID: pdfTask, Path: out, Bytes: int64(len(p.body)), Rows: 3, Pictures: 1, SHA256: hex.EncodeToString(sum[:])}
	if res != want {
		t.Fatalf("result %+v, want %+v", res, want)
	}
	got, err := os.ReadFile(out)
	if err != nil {
		t.Fatalf("the file named by --out: %v", err)
	}
	if gs := sha256.Sum256(got); gs != sum {
		t.Fatalf("file sha256 %x, the stub served %x", gs, sum)
	}
	if r := p.requests(); len(r) != 1 || r[0] != "/v1/topics/"+pdfTask+"/export.pdf" {
		t.Errorf("hub saw %q", r)
	}
	if left, _ := filepath.Glob(filepath.Join(filepath.Dir(out), ".topic-pdf-*")); len(left) != 0 {
		t.Errorf("temp files left: %v", left)
	}
}

// TestTopicPDFDefaultDirAndLink: no --out writes the hub's name into
// $SPOOL_ROOT/<agent id>/exports (0700); a WUI link names the topic;
// --typed-by reaches the route.
func TestTopicPDFDefaultDirAndLink(t *testing.T) {
	p, url := newPDFHub(t)
	t.Setenv("SPOOL_AGENT_ID", "c-007")
	cfg := hubCfg(t, url)
	link := "https://t1.example.com/t/" + pdfTask
	rc, out, errOut := capture(t, "", func() int { return cmdTopicPDF(cfg, []string{"--task", link, "--typed-by", "HUM-12"}) })
	var res action.TopicPDFResult
	if rc != 0 || json.Unmarshal([]byte(out), &res) != nil {
		t.Fatalf("rc %d out %q err %q", rc, out, errOut)
	}
	dir := filepath.Join(cfg.SpoolRoot, "c-007", "exports")
	if res.Path != filepath.Join(dir, "hello-world-0f8fad5b-20261120T120000Z.pdf") || res.TaskID != pdfTask {
		t.Fatalf("result %+v", res)
	}
	if fi, err := os.Stat(dir); err != nil || fi.Mode().Perm() != 0o700 {
		t.Errorf("exports dir: %v %v", fi, err)
	}
	if got, err := os.ReadFile(res.Path); err != nil || string(got) != string(p.body) {
		t.Errorf("file: %v", err)
	}
	if r := p.requests(); len(r) != 1 || r[0] != "/v1/topics/"+pdfTask+"/export.pdf?typed_by=HUM-12" {
		t.Errorf("hub saw %q", r)
	}
}

// TestTopicPDFExitCodes: each refusal of 7.1.1 maps to its exit code, stderr
// names the token, and no file (nor a partial one) is left.
func TestTopicPDFExitCodes(t *testing.T) {
	p, url := newPDFHub(t)
	for _, c := range []struct {
		status int
		token  string
		rc     int
	}{
		{404, "not_found", 3},
		{400, "operator_ambiguous", 4},
		{403, "typed_by_not_bound", 4},
		{413, "too_large", 5},
		{503, "render_unavailable", 5},
		{504, "render_timeout", 5},
	} {
		p.mu.Lock()
		p.status, p.token = c.status, c.token
		p.mu.Unlock()
		dir := t.TempDir()
		out := filepath.Join(dir, "topic.pdf")
		rc, _, errOut := runTopicPDF(t, url, "--task", pdfTask, "--out", out)
		if rc != c.rc || !strings.Contains(errOut, c.token) {
			t.Errorf("%d %s: rc %d err %q, want rc %d naming the token", c.status, c.token, rc, errOut, c.rc)
		}
		if left, _ := os.ReadDir(dir); len(left) != 0 {
			t.Errorf("%d %s: left %v in the target dir", c.status, c.token, left)
		}
	}
}

// TestTopicPDFUsage: a missing --task, a bad --typed-by, a bad link and a
// zero --timeout exit 1 before the hub is asked.
func TestTopicPDFUsage(t *testing.T) {
	p, url := newPDFHub(t)
	for _, args := range [][]string{
		nil,
		{"--task", pdfTask, "extra"},
		{"--task", pdfTask, "--typed-by", "c-007"},
		{"--task", "not a link"},
		{"--task", pdfTask, "--timeout", "0s"},
		{"--nope"},
	} {
		if rc, _, errOut := runTopicPDF(t, url, args...); rc != 1 {
			t.Errorf("%v: rc %d err %q, want 1", args, rc, errOut)
		}
	}
	if r := p.requests(); len(r) != 0 {
		t.Errorf("a usage error reached the hub: %q", r)
	}
}
