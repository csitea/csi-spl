package hubclient

import (
	"bufio"
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
	"sync"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// What a box runs on, for its hello (t1 f77c9f87, the Boxes page): the OS and
// the versions of the run-times and agent CLIs it has. Collected BEFORE the
// dial (the hub's hello timer starts at the challenge) and cached for
// hostTTL: the facts are static, and the daemon redials far more often.

// hostTTL: an upgraded CLI shows within this.
const hostTTL = time.Hour

// hostProbeTimeout bounds one `<cli> --version`.
const hostProbeTimeout = 3 * time.Second

// hostProbes is every run-time the hello reports and the command that prints
// its version. One the box does not have is left out.
var hostProbes = []struct {
	name string
	argv []string
}{
	{"go", []string{"go", "version"}},
	{"node", []string{"node", "--version"}},
	{"docker", []string{"docker", "--version"}},
	{"claude", []string{"claude", "--version"}},
	{"grok", []string{"grok", "--version"}},
	{"qwen", []string{"qwen", "--version"}},
	{"agy", []string{"agy", "--version"}},
}

// versionRe is the first dotted version in a --version line:
// "go version go1.25.1 linux/amd64", "v22.1.0", "Docker version 27.3.1, build x",
// "2.1.3 (Claude Code)".
var versionRe = regexp.MustCompile(`\d+(\.\d+)+([-+][0-9A-Za-z.]+)?`)

// hostRunner runs one probe and answers its stdout.
type hostRunner func(ctx context.Context, argv []string) (string, error)

var hostCache struct {
	sync.Mutex
	at   time.Time
	host *wire.BoxHost
}

// CollectHost is the production Client.Host: this machine's facts, cached.
func CollectHost(ctx context.Context) *wire.BoxHost {
	hostCache.Lock()
	defer hostCache.Unlock()
	if hostCache.host != nil && time.Since(hostCache.at) < hostTTL {
		return hostCache.host
	}
	hostCache.host = collectHost(ctx, runProbe, os.ReadFile, runtime.GOOS, runtime.GOARCH)
	hostCache.at = time.Now()
	return hostCache.host
}

// collectHost reads the OS and probes every run-time, in parallel.
func collectHost(ctx context.Context, run hostRunner, read func(string) ([]byte, error), goos, arch string) *wire.BoxHost {
	h := &wire.BoxHost{OS: hostOS(ctx, run, read, goos, arch)}
	vers := make([]string, len(hostProbes))
	var wg sync.WaitGroup
	for i, p := range hostProbes {
		wg.Add(1)
		go func() {
			defer wg.Done()
			pctx, cancel := context.WithTimeout(ctx, hostProbeTimeout)
			defer cancel()
			if out, err := run(pctx, p.argv); err == nil {
				vers[i] = versionRe.FindString(out)
			}
		}()
	}
	wg.Wait()
	for i, v := range vers {
		if v == "" {
			continue
		}
		if h.Runtimes == nil {
			h.Runtimes = map[string]string{}
		}
		h.Runtimes[hostProbes[i].name] = v
	}
	return h
}

// hostOS: /etc/os-release and the kernel release on Linux, sw_vers on macOS,
// else just the GOOS.
func hostOS(ctx context.Context, run hostRunner, read func(string) ([]byte, error), goos, arch string) *wire.HostOS {
	o := &wire.HostOS{Name: goos, Arch: arch}
	switch goos {
	case "linux":
		if b, err := read("/etc/os-release"); err == nil {
			rel := parseOSRelease(string(b))
			if rel["NAME"] != "" {
				o.Name = rel["NAME"]
			}
			o.Version = rel["VERSION_ID"]
			if o.Version == "" {
				o.Version = rel["VERSION"]
			}
		}
		if b, err := read("/proc/sys/kernel/osrelease"); err == nil {
			o.Kernel = strings.TrimSpace(string(b))
		}
	case "darwin":
		pctx, cancel := context.WithTimeout(ctx, hostProbeTimeout)
		defer cancel()
		if out, err := run(pctx, []string{"sw_vers", "-productName"}); err == nil && strings.TrimSpace(out) != "" {
			o.Name = strings.TrimSpace(out)
		}
		if out, err := run(pctx, []string{"sw_vers", "-productVersion"}); err == nil {
			o.Version = strings.TrimSpace(out)
		}
	}
	if o.Kernel == "" && goos != "windows" {
		pctx, cancel := context.WithTimeout(ctx, hostProbeTimeout)
		defer cancel()
		if out, err := run(pctx, []string{"uname", "-r"}); err == nil {
			o.Kernel = strings.TrimSpace(out)
		}
	}
	return o
}

// parseOSRelease reads KEY=value lines, unquoting the value.
func parseOSRelease(s string) map[string]string {
	out := map[string]string{}
	sc := bufio.NewScanner(strings.NewReader(s))
	for sc.Scan() {
		k, v, ok := strings.Cut(strings.TrimSpace(sc.Text()), "=")
		if !ok || strings.HasPrefix(k, "#") {
			continue
		}
		out[k] = strings.Trim(v, `"'`)
	}
	return out
}

// runProbe runs argv[0] from PATH, else from ~/.local/bin (where the agent
// CLIs install, and which a daemon's PATH may lack). Its first line only.
func runProbe(ctx context.Context, argv []string) (string, error) {
	bin, err := exec.LookPath(argv[0])
	if err != nil {
		home, herr := os.UserHomeDir()
		if herr != nil {
			return "", err
		}
		alt := filepath.Join(home, ".local", "bin", argv[0])
		if _, serr := os.Stat(alt); serr != nil {
			return "", err
		}
		bin = alt
	}
	cmd := exec.CommandContext(ctx, bin, argv[1:]...) //nolint:gosec // a fixed probe list (hostProbes), no shell
	out, err := cmd.Output()
	if err != nil {
		return "", err
	}
	line, _, _ := strings.Cut(string(out), "\n")
	return line, nil
}
