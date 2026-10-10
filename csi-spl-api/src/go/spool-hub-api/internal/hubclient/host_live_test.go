package hubclient

import (
	"context"
	"net"
	"path/filepath"
	"testing"
	"time"
)

// r7-04: the live half of host.go - the real probe runner, the address scan
// and the production HostFacts - which host_test.go replaces with fakes.

func TestRunProbe(t *testing.T) {
	ctx := context.Background()
	if line, err := runProbe(ctx, []string{"printf", "first\nsecond\n"}); err != nil || line != "first" {
		t.Errorf("printf: %q %v", line, err)
	}
	// a non-zero exit still returns the first line it printed
	if line, err := runProbe(ctx, []string{"sh", "-c", "echo degraded; exit 1"}); err == nil || line != "degraded" {
		t.Errorf("exit 1: %q %v", line, err)
	}
	t.Setenv("HOME", t.TempDir()) // no ~/.local/bin fallback either
	if _, err := runProbe(ctx, []string{"no-such-probe-r7-04"}); err == nil {
		t.Error("a missing binary ran")
	}
}

func TestBridgeIface(t *testing.T) {
	for name, want := range map[string]bool{"docker0": true, "br-1a2b": true, "veth9": true, "virbr0": true,
		"cni0": true, "flannel.1": true, "eth0": false, "wlp2s0": false, "enp3s0": false} {
		if bridgeIface(name) != want {
			t.Errorf("bridgeIface(%q) != %v", name, want)
		}
	}
}

// localIPs lists global unicast addresses only, each once, at most maxHostIPs.
func TestLocalIPs(t *testing.T) {
	ips := localIPs()
	if len(ips) > maxHostIPs {
		t.Errorf("%d addresses, cap %d", len(ips), maxHostIPs)
	}
	seen := map[string]bool{}
	for _, s := range ips {
		ip := net.ParseIP(s)
		if ip == nil || !ip.IsGlobalUnicast() || seen[s] {
			t.Errorf("address %q (dup %v)", s, seen[s])
		}
		seen[s] = true
	}
}

// HostFacts collects once, stamps the version, and serves the cached sheet
// (same reported_at) on the next call.
func TestHostFactsLive(t *testing.T) {
	path := filepath.Join(t.TempDir(), "host.json")
	get := HostFacts(path, "9.9.9", "")
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	a := get(ctx)
	if a == nil || a.ReportedAt == "" || a.Runtimes["spool"] != "9.9.9" {
		t.Fatalf("host %+v", a)
	}
	b := get(ctx)
	if b.ReportedAt != a.ReportedAt {
		t.Errorf("second call re-collected: %s then %s", a.ReportedAt, b.ReportedAt)
	}
	if env := liveHostEnv(""); env.asAgent != nil || env.cpus <= 0 || env.goos == "" {
		t.Errorf("liveHostEnv(\"\") = agent %v cpus %d goos %q", env.asAgent != nil, env.cpus, env.goos)
	}
}
