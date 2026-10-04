package hubclient

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// The hello's host report: the OS from os-release and the kernel, and each
// run-time's version from its --version line; a CLI the box lacks is absent.
func TestCollectHost(t *testing.T) {
	outs := map[string]string{
		"go":     "go version go1.25.1 linux/amd64",
		"node":   "v22.1.0",
		"docker": "Docker version 27.3.1, build ce12230",
		"claude": "2.1.3 (Claude Code)",
		"qwen":   "no version here", // prints, but nothing to read: absent
	}
	run := func(_ context.Context, argv []string) (string, error) {
		if o, ok := outs[argv[0]]; ok {
			return o, nil
		}
		return "", errors.New("not found")
	}
	read := func(p string) ([]byte, error) {
		switch p {
		case "/etc/os-release":
			return []byte("PRETTY_NAME=\"Debian GNU/Linux 13 (trixie)\"\nNAME=\"Debian GNU/Linux\"\nVERSION_ID=\"13\"\n"), nil
		case "/proc/sys/kernel/osrelease":
			return []byte("6.12.111+deb13-cloud-amd64\n"), nil
		}
		return nil, errors.New("absent")
	}
	h := collectHost(context.Background(), run, read, "linux", "amd64")
	want := wire.HostOS{Name: "Debian GNU/Linux", Version: "13", Kernel: "6.12.111+deb13-cloud-amd64", Arch: "amd64"}
	if h.OS == nil || *h.OS != want {
		t.Fatalf("os = %+v, want %+v", h.OS, want)
	}
	wantRT := map[string]string{"go": "1.25.1", "node": "22.1.0", "docker": "27.3.1", "claude": "2.1.3"}
	if len(h.Runtimes) != len(wantRT) {
		t.Fatalf("runtimes = %v, want %v", h.Runtimes, wantRT)
	}
	for k, v := range wantRT {
		if h.Runtimes[k] != v {
			t.Fatalf("runtimes[%s] = %q, want %q (%v)", k, h.Runtimes[k], v, h.Runtimes)
		}
	}
}

// A box with none of the run-times sends no runtimes map at all, and an OS
// it cannot read is just its GOOS and arch.
func TestCollectHostNothing(t *testing.T) {
	none := func(context.Context, []string) (string, error) { return "", errors.New("no") }
	noFile := func(string) ([]byte, error) { return nil, errors.New("no") }
	h := collectHost(context.Background(), none, noFile, "freebsd", "arm64")
	if h.Runtimes != nil {
		t.Fatalf("runtimes = %v, want none", h.Runtimes)
	}
	if h.OS == nil || *h.OS != (wire.HostOS{Name: "freebsd", Arch: "arm64"}) {
		t.Fatalf("os = %+v", h.OS)
	}
}

// Only a role=box hello carries the host; a role=cli one never asks for it.
func TestDialHelloCarriesHost(t *testing.T) {
	host := &wire.BoxHost{OS: &wire.HostOS{Name: "Debian GNU/Linux"}, Runtimes: map[string]string{"go": "1.25.1"}}
	for _, role := range []string{wire.RoleBox, wire.RoleCLI} {
		h := &scriptedHub{first: challenge, afterHello: welcome}
		c := testClient(t)
		c.Cfg.HubURL = h.start(t)
		c.Cfg.Tenant = "t1"
		c.Cfg.SubmitSocket = "off"
		c.ReadyTimeout = 5 * time.Second
		asked := 0
		c.Host = func(context.Context) *wire.BoxHost { asked++; return host }
		s, err := c.Dial(context.Background(), role)
		if err != nil {
			t.Fatalf("%s: %v", role, err)
		}
		s.Close()
		h.mu.Lock()
		got := h.hello.Host
		h.mu.Unlock()
		if box := role == wire.RoleBox; box != (got != nil) || box != (asked == 1) {
			t.Fatalf("%s: hello host %+v, asked %d", role, got, asked)
		}
		if got != nil && (got.OS == nil || got.OS.Name != host.OS.Name || got.Runtimes["go"] != "1.25.1") {
			t.Fatalf("%s: hello host %+v", role, got)
		}
	}
}
