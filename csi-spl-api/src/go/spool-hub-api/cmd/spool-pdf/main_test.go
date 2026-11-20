// SPDX-License-Identifier: AGPL-3.0-only

package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"image"
	"image/color"
	"image/png"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/topicpdf"
)

// fakeChrome writes a shell script that plays the browser: script is its body.
func fakeChrome(t *testing.T, script string) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), "chrome")
	if err := os.WriteFile(p, []byte("#!/bin/sh\n"+script+"\n"), 0o700); err != nil { //nolint:gosec // G306: a test stub must be executable
		t.Fatal(err)
	}
	return p
}

func post(t *testing.T, h http.Handler, method, path string, body []byte) *httptest.ResponseRecorder {
	t.Helper()
	w := httptest.NewRecorder()
	h.ServeHTTP(w, httptest.NewRequest(method, path, bytes.NewReader(body)))
	return w
}

func TestOnlyPostRender(t *testing.T) {
	s, _ := newServer(fakeChrome(t, "exit 1"), "")
	for _, c := range []struct {
		method, path string
		want         int
	}{{"GET", "/render", 405}, {"POST", "/", 404}, {"GET", "/healthz", 404}, {"POST", "/render/x", 404}} {
		if w := post(t, s, c.method, c.path, nil); w.Code != c.want {
			t.Errorf("%s %s = %d, want %d", c.method, c.path, w.Code, c.want)
		}
	}
}

func TestRefusesOverCapAndWhileBusy(t *testing.T) {
	s, _ := newServer(fakeChrome(t, "exit 1"), "")
	if w := post(t, s, "POST", "/render", make([]byte, MaxHTMLBytes+1)); w.Code != http.StatusRequestEntityTooLarge {
		t.Fatalf("over the cap = %d, want 413", w.Code)
	}
	s.busy <- struct{}{} // a render holds the one slot
	if w := post(t, s, "POST", "/render", []byte("<p>x</p>")); w.Code != http.StatusTooManyRequests {
		t.Fatalf("while busy = %d, want 429", w.Code)
	}
	<-s.busy
}

func TestFailedRenderAnswersChromeTail(t *testing.T) {
	s, _ := newServer(fakeChrome(t, `i=0; while [ $i -lt 30 ]; do echo "chrome line $i"; i=$((i+1)); done; exit 3`), "")
	w := post(t, s, "POST", "/render", []byte("<p>x</p>"))
	body := w.Body.String()
	if w.Code != 500 || !strings.Contains(body, "chrome line 29") || !strings.Contains(body, "chrome line 10") || strings.Contains(body, "chrome line 9\n") {
		t.Fatalf("= %d, want 500 with the last 20 lines:\n%s", w.Code, body)
	}
	s, _ = newServer(fakeChrome(t, "exit 0"), "")
	if w := post(t, s, "POST", "/render", []byte("<p>x</p>")); w.Code != 500 || !strings.Contains(w.Body.String(), "no PDF") {
		t.Fatalf("no PDF written = %d %s", w.Code, w.Body.String())
	}
}

// The browser gets 7.1.6's flags, a page file and its own temp dir, and the
// PDF it writes is the answer; the temp dir is gone afterwards.
func TestRenderAnswersThePDFAndCleansUp(t *testing.T) {
	args := filepath.Join(t.TempDir(), "args")
	s, _ := newServer(fakeChrome(t, `printf '%s\n' "$@" > `+args+`
for a in "$@"; do case "$a" in --print-to-pdf=*) printf '%%PDF-stub' > "${a#--print-to-pdf=}";; esac; done`), "")
	w := post(t, s, "POST", "/render", []byte("<p>x</p>"))
	if w.Code != 200 || w.Body.String() != "%PDF-stub" || w.Header().Get("Content-Type") != "application/pdf" {
		t.Fatalf("= %d %q %q", w.Code, w.Body.String(), w.Header().Get("Content-Type"))
	}
	got, _ := os.ReadFile(args) //nolint:gosec // G304: the test's own temp file
	for _, f := range []string{"--headless=new", "--no-sandbox", "--disable-gpu", "--disable-dev-shm-usage", "--no-pdf-header-footer", "--user-data-dir=", "file://"} {
		if !strings.Contains(string(got), f) {
			t.Errorf("chrome args miss %s:\n%s", f, got)
		}
	}
	page := strings.TrimPrefix(strings.TrimSpace(string(got)[strings.LastIndex(string(got), "file://"):]), "file://")
	if _, err := os.Stat(filepath.Dir(page)); !os.IsNotExist(err) {
		t.Fatalf("the temp dir %s is still there: %v", filepath.Dir(page), err)
	}
}

// A render past the renderer's own cap answers 504 (spec 183 7.1.6), which
// the hub's topicpdf reads as ErrTimeout -> 504 render_timeout.
func TestRenderTimeoutKillsChrome(t *testing.T) {
	s, err := newServer(fakeChrome(t, "sleep 30 & wait"), "200ms") // the sleep plays a hung browser (a fixture)
	if err != nil {
		t.Fatal(err)
	}
	start := time.Now()
	w := post(t, s, "POST", "/render", []byte("<p>x</p>"))
	if w.Code != http.StatusGatewayTimeout || !strings.Contains(w.Body.String(), "render passed 200ms") {
		t.Fatalf("= %d %s", w.Code, w.Body.String())
	}
	if d := time.Since(start); d > 10*time.Second {
		t.Fatalf("the hung render held the request %s: its process group was not killed", d)
	}
	if _, err := newServer("", "soon"); err == nil {
		t.Fatalf("a bad SPOOL_PDF_RENDER_TIMEOUT was accepted")
	}
}

// The caller's own context ending (a client gone) is not the renderer's cap:
// it stays a 500, never the 504 that tells the hub the render timed out.
func TestClientCancelIsNotTheCap(t *testing.T) {
	up := filepath.Join(t.TempDir(), "up")
	s, _ := newServer(fakeChrome(t, "touch "+up+"; sleep 30 & wait"), "") // a hung browser (a fixture), the default 115s cap
	ctx, cancel := context.WithCancel(context.Background())
	go func() { // cancel once the browser runs: the event, not a nap
		for deadline := time.Now().Add(10 * time.Second); time.Now().Before(deadline); time.Sleep(10 * time.Millisecond) {
			if _, err := os.Stat(up); err == nil {
				break
			}
		}
		cancel()
	}()
	w := httptest.NewRecorder()
	s.ServeHTTP(w, httptest.NewRequest("POST", "/render", bytes.NewReader([]byte("<p>x</p>"))).WithContext(ctx))
	if w.Code != http.StatusInternalServerError || !strings.Contains(w.Body.String(), "render stopped: context canceled") {
		t.Fatalf("client cancel = %d %s, want 500 render stopped", w.Code, w.Body.String())
	}
}

// The hub's topicpdf reads the renderer's answers through HTTPRenderer and
// Status: past the cap -> 504 render_timeout, a fast failure -> 503
// render_unavailable (the renderer's 500), a good render -> the PDF.
func TestHubReadsCapAsRenderTimeout(t *testing.T) {
	for _, c := range []struct {
		name, script, timeout string
		code                  int
		token                 string
	}{
		{"past the cap", "sleep 30 & wait", "200ms", 504, "render_timeout"},
		{"fails fast", "exit 3", "", 503, "render_unavailable"},
		{"good", `for a in "$@"; do case "$a" in --print-to-pdf=*) printf '%%PDF-stub' > "${a#--print-to-pdf=}";; esac; done`, "", 200, ""},
	} {
		s, _ := newServer(fakeChrome(t, c.script), c.timeout)
		srv := httptest.NewServer(s)
		pdf, err := topicpdf.HTTPRenderer{URL: srv.URL, Client: srv.Client()}.Render(context.Background(), []byte("<p>x</p>"))
		srv.Close()
		if code, token := topicpdf.Status(err); code != c.code || token != c.token {
			t.Errorf("%s: Status = %d %q (%v), want %d %q", c.name, code, token, err, c.code, c.token)
		}
		if c.code == 200 && string(pdf) != "%PDF-stub" {
			t.Errorf("%s: pdf = %q", c.name, pdf)
		}
	}
}

// chromeOrSkip is the box's browser, or the test is NOT RUN (never faked, no
// install: spec 183 row P2).
func chromeOrSkip(t *testing.T) (string, string) {
	t.Helper()
	pdftotext, err := exec.LookPath("pdftotext")
	if err != nil {
		t.Skip("NOT RUN: no pdftotext on this box")
	}
	if c := os.Getenv("SPOOL_PDF_CHROME"); c != "" {
		return c, pdftotext
	}
	for _, c := range []string{"chromium-browser", "chromium", "google-chrome"} {
		if p, err := exec.LookPath(c); err == nil {
			return p, pdftotext
		}
	}
	t.Skip("NOT RUN: no Chrome or Chromium on this box")
	return "", ""
}

// The done test of spec 183 row P2: 3 rows and 1 picture through
// topicpdf.HTML, HTTPRenderer and this server with a real browser make a PDF
// whose pdftotext holds the title and the 3 bodies.
func TestDoneThreeRowsOnePictureRealChrome(t *testing.T) {
	chrome, pdftotext := chromeOrSkip(t)
	rows, blob, pic := doneFixture(t)
	page, n, err := topicpdf.HTML(rows, topicpdf.Title(rows), blob)
	if err != nil || n != 1 {
		t.Fatalf("HTML: n=%d err=%v", n, err)
	}
	if !bytes.Contains(page, []byte("data:image/png;base64,"+base64.StdEncoding.EncodeToString(pic))) {
		t.Fatalf("the picture's data: URL is not in the HTML")
	}
	s, _ := newServer(chrome, "")
	srv := httptest.NewServer(s)
	defer srv.Close()
	pdf, err := topicpdf.HTTPRenderer{URL: srv.URL, Client: srv.Client()}.Render(context.Background(), page)
	if err != nil || !bytes.HasPrefix(pdf, []byte("%PDF-")) {
		t.Fatalf("Render: %d bytes, %v", len(pdf), err)
	}
	file := filepath.Join(t.TempDir(), "out.pdf")
	if err := os.WriteFile(file, pdf, 0o600); err != nil {
		t.Fatal(err)
	}
	text, err := exec.Command(pdftotext, file, "-").Output() //nolint:gosec // G204: the box's pdftotext on our own file
	if err != nil {
		t.Fatal(err)
	}
	flat := strings.Join(strings.Fields(string(text)), " ")
	for _, s := range []string{"Topic export alpha starter", "Second row bravo with a picture", "Third row charlie closes it"} {
		if strings.Count(flat, s) < 1 {
			t.Errorf("pdftotext misses %q:\n%s", s, flat)
		}
	}
	if strings.Count(flat, "Topic export alpha starter") < 2 {
		t.Errorf("the title (the starter's opening) is not printed above the cards:\n%s", flat)
	}
	t.Logf("PDF %d bytes, pdftotext: %s", len(pdf), flat)
}

func doneFixture(t *testing.T) ([]store.EditableMessage, func(string) ([]byte, error), []byte) {
	t.Helper()
	img := image.NewRGBA(image.Rect(0, 0, 32, 16))
	for x := range 32 {
		img.Set(x, 8, color.RGBA{B: 220, A: 255})
	}
	var b bytes.Buffer
	if err := png.Encode(&b, img); err != nil {
		t.Fatal(err)
	}
	sum := sha256.Sum256(b.Bytes())
	id := hex.EncodeToString(sum[:])
	at := time.Date(2026, 11, 20, 8, 0, 0, 0, time.UTC)
	mk := func(i int, body string, files ...msg.Attachment) store.EditableMessage {
		inner, _ := json.Marshal(map[string]any{"v": 1, "body": body, "files": files})
		return store.EditableMessage{MsgID: "m" + string(rune('0'+i)), FromID: "c-004", Kind: "note", Body: body,
			Msg: inner, TS: at.Add(time.Duration(i) * time.Minute)}
	}
	rows := []store.EditableMessage{
		mk(1, "Topic export alpha starter"),
		mk(2, "Second row bravo with a picture", msg.Attachment{Mode: "blob", Kind: "file", FileID: id, SHA256: id, Name: "line.png", Bytes: int64(b.Len())}),
		mk(3, "Third row charlie closes it"),
	}
	blob := func(f string) ([]byte, error) { return b.Bytes(), nil }
	return rows, blob, b.Bytes()
}
