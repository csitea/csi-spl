package keyexec

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"

	"golang.org/x/sys/unix"
)

// fakeKey is the obvious fake of spec 127 6; nothing real is ever used.
const fakeKey = "sk-test-0000"

// The fake CLI is this test binary run again with KEYEXEC_FAKE_CLI set; it
// records what it saw into KEYEXEC_FAKE_OUT and ends as the mode says.
func TestMain(m *testing.M) {
	if mode := os.Getenv("KEYEXEC_FAKE_CLI"); mode != "" {
		os.Exit(fakeCLI(mode))
	}
	os.Exit(m.Run())
}

func fakeCLI(mode string) int {
	out := os.Getenv("KEYEXEC_FAKE_OUT")
	var lim unix.Rlimit
	_ = unix.Getrlimit(unix.RLIMIT_CORE, &lim)
	raise := unix.Setrlimit(unix.RLIMIT_CORE, &unix.Rlimit{Cur: 1 << 20, Max: 1 << 20})
	cmdline, _ := os.ReadFile("/proc/self/cmdline")
	rec := map[string]any{
		"env": os.Environ(), "args": os.Args[1:], "cmdline": string(cmdline),
		"core_hard": lim.Max, "core_raise_refused": raise != nil,
	}
	b, _ := json.Marshal(rec)
	f, err := os.OpenFile(out, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600)
	if err == nil {
		fmt.Fprintln(f, string(b))
		f.Close()
	}
	switch mode {
	case "402":
		// What a CLI prints when the vendor refuses the key for credit; the
		// key fragment in it must never travel past the wrapper.
		fmt.Fprintf(os.Stderr, "API Error: status 402 Payment Required: credit exhausted for key %s\n", fakeKey)
		return 1
	case "ratelimit":
		fmt.Fprintln(os.Stderr, "API Error: 429 rate limit exceeded, retry in 20s")
		return 1
	}
	return 0
}

// fakeDesk is the desk socket's server half, in the test only (X1 builds
// the real one): it hands out fakeKey until told the key is exhausted, then
// refuses every lease with key_exhausted, as the hub's 409 makes the desk do.
type fakeDesk struct {
	mu        sync.Mutex
	path      string
	exhausted bool
	reports   []Request
	asks      []Request // every request, in order
	leases    int
	refuse    string // a token to refuse every lease with
}

func newFakeDesk(t *testing.T) *fakeDesk {
	t.Helper()
	dir, err := os.MkdirTemp("", "kx") // short: a unix socket path is <= 107 bytes
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	d := &fakeDesk{path: filepath.Join(dir, "key.sock")}
	ln, err := net.Listen("unix", d.path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ln.Close() })
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			go d.serve(c)
		}
	}()
	return d
}

func (d *fakeDesk) serve(c net.Conn) {
	defer c.Close()
	line, err := bufio.NewReader(c).ReadBytes('\n')
	if err != nil {
		return
	}
	var req Request
	_ = json.Unmarshal(line, &req)
	d.mu.Lock()
	d.asks = append(d.asks, req)
	var r Reply
	switch {
	case req.Op == "exhausted":
		d.exhausted = true
		d.reports = append(d.reports, req)
		r = Reply{OK: true}
	case d.refuse != "":
		r = Reply{Error: d.refuse}
	case d.exhausted:
		r = Reply{Error: TokenKeyExhausted}
	default:
		d.leases++
		r = Reply{OK: true, Key: fakeKey, BaseURL: "https://llm.example.com/v1"}
	}
	d.mu.Unlock()
	_ = json.NewEncoder(c).Encode(r)
}

// seat is one prepared start of the fake CLI.
type seat struct {
	t       *testing.T
	desk    *fakeDesk
	seatDir string
	out     string
	home    string
}

func newSeat(t *testing.T) *seat {
	t.Helper()
	root := t.TempDir()
	s := &seat{t: t, desk: newFakeDesk(t), seatDir: filepath.Join(root, "seat"),
		out: filepath.Join(root, "out.jsonl"), home: filepath.Join(root, "home")}
	if err := os.Mkdir(s.seatDir, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(s.home, 0o700); err != nil {
		t.Fatal(err)
	}
	return s
}

// run starts kind's fake CLI once through Run.
func (s *seat) run(kind, mode string, noClassify bool, extraEnv ...string) (int, string) {
	self, err := os.Executable()
	if err != nil {
		s.t.Fatal(err)
	}
	env := append([]string{"KEYEXEC_FAKE_CLI=" + mode, "KEYEXEC_FAKE_OUT=" + s.out, "HOME=" + s.home,
		"PATH=" + os.Getenv("PATH")}, extraEnv...)
	var stderr bytes.Buffer
	rc := Run(context.Background(), Opts{
		Kind: kind, CLI: self, Args: []string{"--fake-arg"}, Env: env, SeatDir: s.seatDir,
		Helper: "'/opt/spool' key-helper --sock '/run/x' claude",
		Desk:   SockDesk{Path: s.desk.path, Seat: s.seatDir}, Stdin: strings.NewReader(""), Stdout: &bytes.Buffer{},
		Stderr: &stderr, NoClassify: noClassify,
	})
	return rc, stderr.String()
}

// starts reads every record the fake CLI wrote, one per start.
func (s *seat) starts() []map[string]any {
	b, err := os.ReadFile(s.out)
	if os.IsNotExist(err) {
		return nil
	}
	if err != nil {
		s.t.Fatal(err)
	}
	var out []map[string]any
	for _, l := range strings.Split(strings.TrimSpace(string(b)), "\n") {
		var m map[string]any
		if err := json.Unmarshal([]byte(l), &m); err != nil {
			s.t.Fatalf("fake record: %v", err)
		}
		out = append(out, m)
	}
	return out
}

func envOf(rec map[string]any) map[string]string {
	out := map[string]string{}
	for _, kv := range rec["env"].([]any) {
		k, v, _ := strings.Cut(kv.(string), "=")
		out[k] = v
	}
	return out
}
