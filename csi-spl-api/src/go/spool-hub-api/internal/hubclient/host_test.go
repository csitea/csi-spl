package hubclient

import (
	"context"
	"errors"
	"path/filepath"
	"reflect"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// fakeHostEnv is a Linux box: these files, these command outputs, nothing else.
func fakeHostEnv(files, outs map[string]string) hostEnv {
	return hostEnv{
		run: func(_ context.Context, argv []string) (string, error) {
			if o, ok := outs[argv[0]]; ok {
				return o, nil
			}
			return "", errors.New("not found")
		},
		read: func(p string) ([]byte, error) {
			if f, ok := files[p]; ok {
				return []byte(f), nil
			}
			return nil, errors.New("absent")
		},
		readlink: func(string) (string, error) { return "/usr/share/zoneinfo/Europe/Helsinki", nil },
		hostname: func() (string, error) { return "box-a", nil },
		ips:      func() []string { return []string{"10.0.0.5", "fd00::5"} },
		goos:     "linux", arch: "amd64", cpus: 8,
	}
}

// The fact sheet: what a Unix admin reads first (t1 d1d9bcd3) - OS and
// release, kernel, host, boot, CPUs, load, memory, addresses, gateway, DNS,
// and each run-time's version; a CLI the box lacks is absent.
func TestCollectHost(t *testing.T) {
	files := map[string]string{
		"/etc/os-release":            "PRETTY_NAME=\"Debian GNU/Linux 13 (trixie)\"\nNAME=\"Debian GNU/Linux\"\nVERSION_ID=\"13\"\n",
		"/proc/sys/kernel/osrelease": "6.12.111+deb13-cloud-amd64\n",
		"/proc/stat":                 "cpu  1 2 3\nbtime 1759500000\nprocesses 9\n",
		"/proc/cpuinfo":              "processor\t: 0\nmodel name\t: AMD EPYC 7B13\nprocessor\t: 1\nmodel name\t: AMD EPYC 7B13\n",
		"/proc/loadavg":              "0.12 0.20 0.30 1/234 5678\n",
		"/proc/meminfo":              "MemTotal:       16384000 kB\nMemFree: 1 kB\nMemAvailable:    8192000 kB\nSwapTotal:       2048000 kB\nSwapFree:        1024000 kB\n",
		"/proc/net/route":            "Iface\tDestination\tGateway \tFlags\nens4\t00000000\t0100000A\t0003\nens4\t0000000A\t00000000\t0001\n",
		"/etc/resolv.conf":           "# generated\nsearch example.internal\nnameserver 10.0.0.2\nnameserver 1.1.1.1\n",
	}
	outs := map[string]string{
		"go":        "go version go1.25.1 linux/amd64",
		"node":      "v22.1.0",
		"python3":   "Python 3.13.5",
		"git":       "git version 2.47.3",
		"docker":    "Docker version 27.3.1, build ce12230",
		"claude":    "2.1.3 (Claude Code)",
		"qwen":      "no version here", // prints, but nothing to read: absent
		"systemctl": "degraded",
	}
	h := collectHost(context.Background(), fakeHostEnv(files, outs))
	wantOS := wire.HostOS{Name: "Debian GNU/Linux", Version: "13", Pretty: "Debian GNU/Linux 13 (trixie)", Kernel: "6.12.111+deb13-cloud-amd64", Arch: "amd64"}
	if h.OS == nil || *h.OS != wantOS {
		t.Fatalf("os = %+v, want %+v", h.OS, wantOS)
	}
	wantSys := wire.HostSystem{Hostname: "box-a", Timezone: "Europe/Helsinki", BootAt: time.Unix(1759500000, 0).UTC().Format(time.RFC3339),
		CPUs: 8, CPUModel: "AMD EPYC 7B13", Load: "0.12 0.20 0.30", MemTotalMB: 16000, MemAvailMB: 8000,
		SwapTotalMB: 2000, SwapFreeMB: 1000, State: "degraded"}
	if h.System == nil || *h.System != wantSys {
		t.Fatalf("system = %+v\nwant %+v", h.System, wantSys)
	}
	wantNet := wire.HostNetwork{IPs: []string{"10.0.0.5", "fd00::5"}, Gateway: "10.0.0.1", DNS: []string{"10.0.0.2", "1.1.1.1"}}
	if h.Network == nil || !reflect.DeepEqual(*h.Network, wantNet) {
		t.Fatalf("network = %+v, want %+v", h.Network, wantNet)
	}
	wantRT := map[string]string{"go": "1.25.1", "node": "22.1.0", "python": "3.13.5", "git": "2.47.3", "docker": "27.3.1", "claude": "2.1.3"}
	if !reflect.DeepEqual(h.Runtimes, wantRT) {
		t.Fatalf("runtimes = %v, want %v", h.Runtimes, wantRT)
	}
}

// A box with none of it sends no runtimes map at all, and an OS it cannot
// read is just its GOOS and arch.
func TestCollectHostNothing(t *testing.T) {
	env := fakeHostEnv(nil, nil)
	env.goos, env.arch = "freebsd", "arm64"
	h := collectHost(context.Background(), env)
	if h.Runtimes != nil {
		t.Fatalf("runtimes = %v, want none", h.Runtimes)
	}
	if h.OS == nil || *h.OS != (wire.HostOS{Name: "freebsd", Arch: "arm64"}) {
		t.Fatalf("os = %+v", h.OS)
	}
}

// Owner 7e013eab: "once per day - no more often". Every hello within the day
// re-sends the one sheet, a restarted daemon reuses the file, and only a day
// later is it collected again. The spool version is stamped on every read.
func TestHostSheetOncePerDay(t *testing.T) {
	path := filepath.Join(t.TempDir(), ".hub", "host-facts.json")
	now := time.Date(2026, 10, 4, 12, 0, 0, 0, time.UTC)
	collected := 0
	collect := func(context.Context) *wire.BoxHost {
		collected++
		return &wire.BoxHost{OS: &wire.HostOS{Name: "Debian GNU/Linux"}, Runtimes: map[string]string{"go": "1.25.1"}}
	}
	sheet := func(ver string) *hostSheet {
		return &hostSheet{path: path, version: ver, now: func() time.Time { return now }, collect: collect}
	}
	ctx := context.Background()
	a := sheet("8.9.6")
	h := a.get(ctx)
	if collected != 1 || h.ReportedAt != "2026-10-04T12:00:00Z" || h.Runtimes["spool"] != "8.9.6" || h.Runtimes["go"] != "1.25.1" {
		t.Fatalf("first hello: collected %d, %+v", collected, h)
	}
	now = now.Add(23 * time.Hour)
	if a.get(ctx); collected != 1 {
		t.Fatalf("collected again within the day (%d)", collected)
	}
	b := sheet("8.9.7") // a restarted, upgraded daemon
	if h := b.get(ctx); collected != 1 || h.ReportedAt != "2026-10-04T12:00:00Z" || h.Runtimes["spool"] != "8.9.7" {
		t.Fatalf("restart re-collected (%d) or lost the sheet: %+v", collected, h)
	}
	if b.host.Runtimes["spool"] != "" {
		t.Fatal("the stamped spool version leaked into the cached sheet")
	}
	now = now.Add(time.Hour)
	if h := b.get(ctx); collected != 2 || h.ReportedAt != "2026-10-05T12:00:00Z" {
		t.Fatalf("a day-old sheet was not collected again: %d %+v", collected, h)
	}
}

func TestRouteGateway(t *testing.T) {
	if g := routeGateway("Iface\tDestination\tGateway\neth0\t0000A8C0\t00000000\neth0\t00000000\t0101A8C0\n"); g != "192.168.1.1" {
		t.Fatalf("gateway = %q", g)
	}
	if g := routeGateway(""); g != "" {
		t.Fatalf("gateway of no table = %q", g)
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
