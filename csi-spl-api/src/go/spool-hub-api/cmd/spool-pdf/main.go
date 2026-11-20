// SPDX-License-Identifier: AGPL-3.0-only

// Command spool-pdf is the renderer service of spec 183 (7.1.6): it turns the
// self-contained HTML the hub builds (internal/topicpdf) into a PDF with
// headless Chromium. One route, POST /render: text/html of at most 40 MiB
// in, application/pdf out; 413 over the cap, 429 while a render runs (one at
// a time per instance), 500 with Chrome's last 20 lines when a render fails.
// No other route, no health route (spec 183 1.2 R1: nothing keeps it warm).
// It listens on $PORT (Cloud Run's, default 8080); only the hub's service
// account may call it (Cloud Run IAM, terraform step 031-cloud-run-pdf).
//
// Env: SPOOL_PDF_CHROME the browser binary (default chromium-browser, the
// image's); SPOOL_PDF_RENDER_TIMEOUT one render's cap (default 115s, under
// the service's 120s request timeout).
package main

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"time"
)

// MaxHTMLBytes is the largest HTML a render takes: 32 MiB of pictures as
// base64 plus the text (spec 183 7.1.6).
const MaxHTMLBytes = 40 << 20

const defaultRenderTimeout = 115 * time.Second

func main() {
	if err := run(); err != nil {
		log.Fatal(err)
	}
}

func run() error {
	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}
	s, err := newServer(os.Getenv("SPOOL_PDF_CHROME"), os.Getenv("SPOOL_PDF_RENDER_TIMEOUT"))
	if err != nil {
		return err
	}
	srv := &http.Server{Addr: ":" + port, Handler: s, ReadHeaderTimeout: 10 * time.Second,
		ReadTimeout: 60 * time.Second, WriteTimeout: 130 * time.Second}
	log.Printf("spool-pdf: listening on :%s, chrome %s, render timeout %s", port, s.chrome, s.timeout)
	return srv.ListenAndServe()
}

// server is the one-route renderer. busy holds one slot: a second render
// while one runs answers 429.
type server struct {
	chrome  string
	timeout time.Duration
	busy    chan struct{}
}

func newServer(chrome, timeout string) (*server, error) {
	s := &server{chrome: chrome, timeout: defaultRenderTimeout, busy: make(chan struct{}, 1)}
	if s.chrome == "" {
		s.chrome = "chromium-browser"
	}
	if timeout != "" {
		d, err := time.ParseDuration(timeout)
		if err != nil || d <= 0 {
			return nil, fmt.Errorf("SPOOL_PDF_RENDER_TIMEOUT=%q: want a positive duration such as 115s", timeout)
		}
		s.timeout = d
	}
	return s, nil
}

func (s *server) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != "/render" {
		http.NotFound(w, r)
		return
	}
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", http.MethodPost)
		http.Error(w, "POST only", http.StatusMethodNotAllowed)
		return
	}
	select {
	case s.busy <- struct{}{}:
		defer func() { <-s.busy }()
	default:
		http.Error(w, "busy: one render at a time", http.StatusTooManyRequests)
		return
	}
	html, err := io.ReadAll(http.MaxBytesReader(w, r.Body, MaxHTMLBytes))
	var tooBig *http.MaxBytesError
	if errors.As(err, &tooBig) {
		http.Error(w, fmt.Sprintf("the HTML is over %d bytes", MaxHTMLBytes), http.StatusRequestEntityTooLarge)
		return
	}
	if err != nil {
		http.Error(w, "read: "+err.Error(), http.StatusBadRequest)
		return
	}
	pdf, err := s.render(r.Context(), html)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "application/pdf")
	_, _ = w.Write(pdf)
}

// render prints html to a PDF in a fresh temp dir, removed on return. The
// browser and every process it starts run in their own process group, killed
// whole when the render passes its timeout or the caller goes away.
func (s *server) render(ctx context.Context, html []byte) ([]byte, error) {
	dir, err := os.MkdirTemp("", "spool-pdf-*")
	if err != nil {
		return nil, err
	}
	defer func() { _ = os.RemoveAll(dir) }()
	page, out := filepath.Join(dir, "in.html"), filepath.Join(dir, "out.pdf")
	if err := os.WriteFile(page, html, 0o600); err != nil {
		return nil, err
	}
	ctx, cancel := context.WithTimeout(ctx, s.timeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, s.chrome, chromeArgs(dir, page, out)...) //nolint:gosec // G204: the binary is the operator's env, the args are fixed
	cmd.Dir = dir
	cmd.Env = append(os.Environ(), "HOME="+dir, "XDG_CONFIG_HOME="+dir, "XDG_CACHE_HOME="+dir)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.Cancel = func() error { return syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL) }
	cmd.WaitDelay = 5 * time.Second
	var trail bytes.Buffer
	cmd.Stdout, cmd.Stderr = &trail, &trail
	runErr := cmd.Run()
	pdf, readErr := os.ReadFile(out) //nolint:gosec // G304: our own temp dir
	if runErr == nil && readErr == nil && len(pdf) > 0 {
		return pdf, nil
	}
	if ctx.Err() != nil {
		runErr = fmt.Errorf("render passed %s: %w", s.timeout, ctx.Err())
	} else if runErr == nil {
		runErr = errors.New("chrome wrote no PDF")
	}
	return nil, fmt.Errorf("%v\n%s", runErr, lastLines(trail.String(), 20))
}

// chromeArgs are spec 183 7.1.6's flags (v0.4): no header or footer (no
// date, URL or temp path in the PDF) and a profile of the render's own.
func chromeArgs(dir, page, out string) []string {
	return []string{"--headless=new", "--no-sandbox", "--disable-gpu", "--disable-dev-shm-usage",
		"--no-pdf-header-footer", "--user-data-dir=" + filepath.Join(dir, "profile"),
		"--print-to-pdf=" + out, "file://" + page}
}

func lastLines(s string, n int) string {
	lines := strings.Split(strings.TrimRight(s, "\n"), "\n")
	if len(lines) > n {
		lines = lines[len(lines)-n:]
	}
	return strings.Join(lines, "\n")
}
