package hubclient

import (
	"bufio"
	"context"
	"encoding/json"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// A box's fact sheet for its hello (t1 f77c9f87 the Boxes page, d1d9bcd3
// "basic troubleshooting info for each box"): what a Unix admin reads first -
// OS and release, kernel, host, CPUs, load, memory, addresses, and the
// versions of the run-times and agent CLIs. Owner 7e013eab: "once per day -
// no more often". So the sheet is collected at most once per hostEvery and
// kept in a file, which a restarted daemon reuses; every hello re-sends it,
// so a restarted hub has it again at the next redial. Disk per mount is not
// here: it is the box-stats sample's.

// hostEvery: how old the sheet may get before it is collected again.
const hostEvery = 24 * time.Hour

// hostProbeTimeout bounds one probe command.
const hostProbeTimeout = 3 * time.Second

// maxHostIPs caps the addresses a box reports (the hub caps them again).
const maxHostIPs = 8

// hostProbes is every run-time the sheet reports and the command that prints
// its version. One the box does not have is left out.
var hostProbes = []struct {
	name string
	argv []string
}{
	{"go", []string{"go", "version"}},
	{"node", []string{"node", "--version"}},
	{"python", []string{"python3", "--version"}},
	{"git", []string{"git", "--version"}},
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

// hostRunner runs one probe and answers the first line of its stdout.
type hostRunner func(ctx context.Context, argv []string) (string, error)

// hostEnv is everything the collector reads, so a test can stand in for it.
type hostEnv struct {
	run      hostRunner
	read     func(string) ([]byte, error)
	readlink func(string) (string, error)
	hostname func() (string, error)
	ips      func() []string
	goos     string
	arch     string
	cpus     int
}

func liveHostEnv() hostEnv {
	return hostEnv{run: runProbe, read: os.ReadFile, readlink: os.Readlink, hostname: os.Hostname,
		ips: localIPs, goos: runtime.GOOS, arch: runtime.GOARCH, cpus: runtime.NumCPU()}
}

// HostFacts answers the production Client.Host: the sheet kept in path,
// collected again only once it is hostEvery old. spoolVersion is this
// binary's own version, stamped into runtimes on every hello (an upgrade
// shows at once without a new collection).
func HostFacts(path, spoolVersion string) func(context.Context) *wire.BoxHost {
	env := liveHostEnv()
	s := &hostSheet{path: path, version: spoolVersion, now: time.Now,
		collect: func(ctx context.Context) *wire.BoxHost { return collectHost(ctx, env) }}
	return s.get
}

// hostSheet is the once-a-day cache: in memory, backed by its file.
type hostSheet struct {
	path    string
	version string
	now     func() time.Time
	collect func(context.Context) *wire.BoxHost

	mu   sync.Mutex
	host *wire.BoxHost
	at   time.Time
}

func (s *hostSheet) get(ctx context.Context) *wire.BoxHost {
	s.mu.Lock()
	defer s.mu.Unlock()
	now := s.now()
	if s.host == nil {
		s.load()
	}
	if s.host == nil || now.Sub(s.at) >= hostEvery || s.at.After(now.Add(time.Hour)) {
		h := s.collect(ctx)
		h.ReportedAt = now.UTC().Format(time.RFC3339)
		s.host, s.at = h, now
		if raw, err := json.Marshal(h); err == nil && s.path != "" {
			writeAtomic(s.path, raw) //nolint:errcheck // best effort: the next start collects again
		}
	}
	out := *s.host
	if s.version != "" {
		out.Runtimes = make(map[string]string, len(s.host.Runtimes)+1)
		for k, v := range s.host.Runtimes {
			out.Runtimes[k] = v
		}
		out.Runtimes["spool"] = s.version
	}
	return &out
}

// load reads a sheet an earlier process wrote; a missing or unreadable one
// leaves s empty, so get collects.
func (s *hostSheet) load() {
	raw, err := os.ReadFile(s.path)
	if err != nil {
		return
	}
	var h wire.BoxHost
	if json.Unmarshal(raw, &h) != nil {
		return
	}
	at, err := time.Parse(time.RFC3339, h.ReportedAt)
	if err != nil {
		return
	}
	s.host, s.at = &h, at
}

// collectHost reads the sheet: OS, system and network, and every run-time
// probed in parallel.
func collectHost(ctx context.Context, env hostEnv) *wire.BoxHost {
	h := &wire.BoxHost{OS: hostOS(ctx, env), System: hostSystem(ctx, env), Network: hostNetwork(ctx, env)}
	vers := make([]string, len(hostProbes))
	var wg sync.WaitGroup
	for i, p := range hostProbes {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if out, err := probe(ctx, env, p.argv...); err == nil {
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

// probe runs one command under hostProbeTimeout, its output trimmed.
func probe(ctx context.Context, env hostEnv, argv ...string) (string, error) {
	pctx, cancel := context.WithTimeout(ctx, hostProbeTimeout)
	defer cancel()
	out, err := env.run(pctx, argv)
	return strings.TrimSpace(out), err
}

// fileText is a file's content trimmed, "" when it cannot be read.
func fileText(env hostEnv, path string) string {
	b, err := env.read(path)
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(b))
}

// hostOS: /etc/os-release and the kernel release on Linux, sw_vers on macOS,
// else just the GOOS.
func hostOS(ctx context.Context, env hostEnv) *wire.HostOS {
	o := &wire.HostOS{Name: env.goos, Arch: env.arch}
	switch env.goos {
	case "linux":
		rel := parseKV(fileText(env, "/etc/os-release"), "=")
		if rel["NAME"] != "" {
			o.Name = rel["NAME"]
		}
		o.Version, o.Pretty = rel["VERSION_ID"], rel["PRETTY_NAME"]
		if o.Version == "" {
			o.Version = rel["VERSION"]
		}
		o.Kernel = fileText(env, "/proc/sys/kernel/osrelease")
	case "darwin":
		if out, err := probe(ctx, env, "sw_vers", "-productName"); err == nil && out != "" {
			o.Name = out
		}
		if out, err := probe(ctx, env, "sw_vers", "-productVersion"); err == nil {
			o.Version = out
		}
	}
	if o.Kernel == "" && env.goos != "windows" {
		if out, err := probe(ctx, env, "uname", "-r"); err == nil {
			o.Kernel = out
		}
	}
	return o
}

// hostSystem: the host name, time zone, boot time, CPUs, load and memory -
// from /proc on Linux, sysctl on macOS.
func hostSystem(ctx context.Context, env hostEnv) *wire.HostSystem {
	s := &wire.HostSystem{CPUs: env.cpus, Timezone: hostTimezone(env)}
	if env.hostname != nil {
		s.Hostname, _ = env.hostname()
	}
	switch env.goos {
	case "linux":
		for _, line := range strings.Split(fileText(env, "/proc/stat"), "\n") {
			if sec, ok := strings.CutPrefix(line, "btime "); ok {
				if n, err := strconv.ParseInt(strings.TrimSpace(sec), 10, 64); err == nil {
					s.BootAt = time.Unix(n, 0).UTC().Format(time.RFC3339)
				}
			}
		}
		cpu := parseKV(fileText(env, "/proc/cpuinfo"), ":")
		s.CPUModel = firstOf(cpu["model name"], cpu["Model"], cpu["Hardware"], cpu["cpu model"])
		if f := strings.Fields(fileText(env, "/proc/loadavg")); len(f) >= 3 {
			s.Load = strings.Join(f[:3], " ")
		}
		mem := parseKV(fileText(env, "/proc/meminfo"), ":")
		s.MemTotalMB, s.MemAvailMB = kibToMiB(mem["MemTotal"]), kibToMiB(mem["MemAvailable"])
		s.SwapTotalMB, s.SwapFreeMB = kibToMiB(mem["SwapTotal"]), kibToMiB(mem["SwapFree"])
		if out, _ := probe(ctx, env, "systemctl", "is-system-running"); out != "" {
			s.State = out // degraded exits 1 and still prints its state
		}
	case "darwin":
		if out, err := probe(ctx, env, "sysctl", "-n", "machdep.cpu.brand_string"); err == nil {
			s.CPUModel = out
		}
		if out, err := probe(ctx, env, "sysctl", "-n", "vm.loadavg"); err == nil {
			if f := strings.Fields(strings.Trim(out, "{} ")); len(f) >= 3 {
				s.Load = strings.Join(f[:3], " ")
			}
		}
		if out, err := probe(ctx, env, "sysctl", "-n", "hw.memsize"); err == nil {
			if n, err := strconv.ParseInt(out, 10, 64); err == nil {
				s.MemTotalMB = n >> 20
			}
		}
		if out, err := probe(ctx, env, "sysctl", "-n", "kern.boottime"); err == nil { // { sec = 1696000000, usec = 0 } ...
			if m := regexp.MustCompile(`sec = (\d+)`).FindStringSubmatch(out); m != nil {
				if n, err := strconv.ParseInt(m[1], 10, 64); err == nil {
					s.BootAt = time.Unix(n, 0).UTC().Format(time.RFC3339)
				}
			}
		}
	}
	return s
}

// hostTimezone: /etc/timezone, else the zoneinfo name /etc/localtime links
// to, else the zone's abbreviation.
func hostTimezone(env hostEnv) string {
	if tz := fileText(env, "/etc/timezone"); tz != "" {
		return tz
	}
	if env.readlink != nil {
		if l, err := env.readlink("/etc/localtime"); err == nil {
			if _, name, ok := strings.Cut(l, "zoneinfo/"); ok && name != "" {
				return name
			}
		}
	}
	name, _ := time.Now().Zone()
	return name
}

// hostNetwork: the box's own addresses (primary first), its default
// gateway and the resolvers it is configured with.
func hostNetwork(ctx context.Context, env hostEnv) *wire.HostNetwork {
	n := &wire.HostNetwork{}
	if env.ips != nil {
		n.IPs = env.ips()
	}
	switch env.goos {
	case "linux":
		n.Gateway = routeGateway(fileText(env, "/proc/net/route"))
	case "darwin":
		if out, err := env.run(ctx, []string{"route", "-n", "get", "default"}); err == nil {
			n.Gateway = parseKV(out, ":")["gateway"]
		}
	}
	for _, line := range strings.Split(fileText(env, "/etc/resolv.conf"), "\n") {
		if f := strings.Fields(line); len(f) >= 2 && f[0] == "nameserver" && len(n.DNS) < 4 {
			n.DNS = append(n.DNS, f[1])
		}
	}
	return n
}

// routeGateway reads the default route's gateway from /proc/net/route
// (little-endian hex).
func routeGateway(table string) string {
	for _, line := range strings.Split(table, "\n") {
		f := strings.Fields(line)
		if len(f) < 3 || f[1] != "00000000" || f[2] == "00000000" {
			continue
		}
		v, err := strconv.ParseUint(f[2], 16, 32)
		if err != nil {
			continue
		}
		return net.IPv4(byte(v), byte(v>>8), byte(v>>16), byte(v>>24)).String()
	}
	return ""
}

// localIPs is every global unicast address on an up, non-loopback interface,
// the primary first: the source address of the default route, which a UDP
// "dial" to a documentation address picks without sending anything. Container
// bridges and veths are left out.
func localIPs() []string {
	var out []string
	add := func(ip net.IP) {
		if ip == nil || !ip.IsGlobalUnicast() || len(out) == maxHostIPs {
			return
		}
		s := ip.String()
		for _, o := range out {
			if o == s {
				return
			}
		}
		out = append(out, s)
	}
	if c, err := net.Dial("udp", "192.0.2.1:9"); err == nil {
		if a, ok := c.LocalAddr().(*net.UDPAddr); ok {
			add(a.IP)
		}
		c.Close()
	}
	ifs, _ := net.Interfaces()
	for _, i := range ifs {
		if i.Flags&net.FlagUp == 0 || i.Flags&net.FlagLoopback != 0 || bridgeIface(i.Name) {
			continue
		}
		addrs, _ := i.Addrs()
		for _, a := range addrs {
			if n, ok := a.(*net.IPNet); ok {
				add(n.IP)
			}
		}
	}
	return out
}

func bridgeIface(name string) bool {
	for _, p := range []string{"docker", "br-", "veth", "virbr", "cni", "flannel"} {
		if strings.HasPrefix(name, p) {
			return true
		}
	}
	return false
}

// parseKV reads "KEY<sep>value" lines (os-release, cpuinfo, meminfo, route
// get), the first value of each key, unquoted and trimmed.
func parseKV(s, sep string) map[string]string {
	out := map[string]string{}
	sc := bufio.NewScanner(strings.NewReader(s))
	for sc.Scan() {
		k, v, ok := strings.Cut(sc.Text(), sep)
		k = strings.TrimSpace(k)
		if !ok || k == "" || strings.HasPrefix(k, "#") {
			continue
		}
		if _, seen := out[k]; !seen {
			out[k] = strings.Trim(strings.TrimSpace(v), `"'`)
		}
	}
	return out
}

// kibToMiB reads a meminfo value ("16314200 kB") as MiB.
func kibToMiB(v string) int64 {
	f := strings.Fields(v)
	if len(f) == 0 {
		return 0
	}
	n, err := strconv.ParseInt(f[0], 10, 64)
	if err != nil {
		return 0
	}
	return n >> 10
}

func firstOf(vs ...string) string {
	for _, v := range vs {
		if v != "" {
			return v
		}
	}
	return ""
}

// runProbe runs argv[0] from PATH, else from ~/.local/bin (where the agent
// CLIs install, and which a daemon's PATH may lack). Its first stdout line,
// also when the command exits non-zero (systemctl is-system-running prints
// "degraded" and exits 1).
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
	line, _, _ := strings.Cut(string(out), "\n")
	return line, err
}
