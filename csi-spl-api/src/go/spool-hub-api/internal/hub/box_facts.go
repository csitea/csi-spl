package hub

import (
	"net"
	"regexp"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// Box facts (t1 f77c9f87 the Boxes page, d1d9bcd3 "basic troubleshooting
// info for each box"): the fact sheet a box sends on its hello (wire.BoxHost)
// - OS, run-times, system, network - served on the roster view as
// boxes[].os, .runtimes, .system, .network and .facts_reported_at.
//
// The box collects the sheet at most once a day (owner 7e013eab) and
// re-sends the same sheet on every hello, so the hub keeps it in process
// memory, not a table: the hub runs one instance (max_instances 1, like
// s.boxes) and a fresh revision has it again once the box redials. Last hello
// wins; a hello without one (an older box) clears it.
//
// The box is untrusted here: every string is cut to printable ASCII and
// maxFactLen bytes, a run-time name must be a short slug, the lists and the
// run-times are capped, addresses must parse, numbers must be sane and
// times not in the future. Nothing is refused - a hello is never lost over
// a cosmetic field.

const (
	maxFactLen  = 64
	maxRuntimes = 16
	maxIPs      = 8
	maxDNS      = 4
	// maxFactMB: 1 PiB in MiB, past any real box.
	maxFactMB = 1 << 30
	maxCPUs   = 1 << 16
	// factSkew: how far ahead of the hub's clock a box's time may be.
	factSkew = 5 * time.Minute
)

// runtimeNameRe: a run-time's name, the key of boxes[].runtimes.
var runtimeNameRe = regexp.MustCompile(`^[a-z][a-z0-9_-]{0,23}$`)

// boxFacts is one box's cleaned sheet.
type boxFacts struct {
	reportedAt time.Time
	os         *wire.HostOS
	runtimes   map[string]string
	system     *wire.HostSystem
	network    *wire.HostNetwork
}

// boxHosts holds every box's facts, keyed (tenant, box); its own lock, so a
// roster read never takes the routing mutex for them.
type boxHosts struct {
	mu sync.Mutex
	m  map[[2]string]boxFacts
}

func (h *boxHosts) set(tenant, box string, host *wire.BoxHost, now time.Time) {
	k := [2]string{tenant, box}
	f, ok := cleanHost(host, now)
	h.mu.Lock()
	defer h.mu.Unlock()
	if !ok {
		delete(h.m, k)
		return
	}
	if h.m == nil {
		h.m = map[[2]string]boxFacts{}
	}
	h.m[k] = f
}

func (h *boxHosts) get(tenant, box string) boxFacts {
	h.mu.Lock()
	defer h.mu.Unlock()
	return h.m[[2]string{tenant, box}]
}

// cleanHost cuts a hello's sheet to what the hub keeps; false = nothing is
// left of it. A sheet without a usable reported_at (a v8.9.5 box) is dated
// by the hello that brought it.
func cleanHost(host *wire.BoxHost, now time.Time) (boxFacts, bool) {
	if host == nil {
		return boxFacts{}, false
	}
	f := boxFacts{os: cleanOS(host.OS), runtimes: cleanRuntimes(host.Runtimes),
		system: cleanSystem(host.System, now), network: cleanNetwork(host.Network)}
	if f.os == nil && f.runtimes == nil && f.system == nil && f.network == nil {
		return boxFacts{}, false
	}
	f.reportedAt = now
	if at, ok := factTime(host.ReportedAt, now); ok {
		f.reportedAt = at
	}
	return f, true
}

func cleanOS(o *wire.HostOS) *wire.HostOS {
	if o == nil {
		return nil
	}
	c := wire.HostOS{Name: cleanFact(o.Name), Version: cleanFact(o.Version), Pretty: cleanFact(o.Pretty),
		Kernel: cleanFact(o.Kernel), Arch: cleanFact(o.Arch)}
	if c == (wire.HostOS{}) {
		return nil
	}
	return &c
}

func cleanRuntimes(in map[string]string) map[string]string {
	names := make([]string, 0, len(in))
	for name := range in {
		if runtimeNameRe.MatchString(name) {
			names = append(names, name)
		}
	}
	sort.Strings(names) // a hostile map past the cap keeps the same entries every time
	var out map[string]string
	for _, name := range names {
		v := cleanFact(in[name])
		if v == "" {
			continue
		}
		if out == nil {
			out = map[string]string{}
		}
		out[name] = v
		if len(out) == maxRuntimes {
			break
		}
	}
	return out
}

func cleanSystem(s *wire.HostSystem, now time.Time) *wire.HostSystem {
	if s == nil {
		return nil
	}
	c := wire.HostSystem{Hostname: cleanFact(s.Hostname), Timezone: cleanFact(s.Timezone),
		CPUs: int(factInt(int64(s.CPUs), maxCPUs)), CPUModel: cleanFact(s.CPUModel), Load: cleanFact(s.Load),
		MemTotalMB: factInt(s.MemTotalMB, maxFactMB), MemAvailMB: factInt(s.MemAvailMB, maxFactMB),
		SwapTotalMB: factInt(s.SwapTotalMB, maxFactMB), SwapFreeMB: factInt(s.SwapFreeMB, maxFactMB),
		State: cleanFact(s.State)}
	if at, ok := factTime(s.BootAt, now); ok {
		c.BootAt = rfc(at)
	}
	if c == (wire.HostSystem{}) {
		return nil
	}
	return &c
}

func cleanNetwork(n *wire.HostNetwork) *wire.HostNetwork {
	if n == nil {
		return nil
	}
	c := wire.HostNetwork{IPs: factIPs(n.IPs, maxIPs), Gateway: factIP(n.Gateway), DNS: factIPs(n.DNS, maxDNS)}
	if c.IPs == nil && c.Gateway == "" && c.DNS == nil {
		return nil
	}
	return &c
}

// factIP is s as a canonical IP address, "" when it is not one.
func factIP(s string) string {
	if len(s) > maxFactLen {
		return ""
	}
	ip := net.ParseIP(strings.TrimSpace(s))
	if ip == nil {
		return ""
	}
	return ip.String()
}

// factIPs keeps the first max addresses of in that parse, in order.
func factIPs(in []string, max int) []string {
	var out []string
	for _, s := range in {
		if ip := factIP(s); ip != "" {
			out = append(out, ip)
			if len(out) == max {
				break
			}
		}
	}
	return out
}

// factInt is n when it is in (0, max], else 0 (omitted).
func factInt(n, max int64) int64 {
	if n <= 0 || n > max {
		return 0
	}
	return n
}

// factTime parses an RFC3339 time no later than now + factSkew.
func factTime(s string, now time.Time) (time.Time, bool) {
	if s == "" || len(s) > maxFactLen {
		return time.Time{}, false
	}
	at, err := time.Parse(time.RFC3339, s)
	if err != nil || at.After(now.Add(factSkew)) || at.Year() < 1970 {
		return time.Time{}, false
	}
	return at.UTC(), true
}

// cleanFact keeps printable ASCII only (no control, escape or bidi runes),
// trimmed and cut to maxFactLen bytes.
func cleanFact(s string) string {
	var b strings.Builder
	for _, r := range s {
		if b.Len() == maxFactLen {
			break
		}
		if r >= 0x20 && r < 0x7f {
			b.WriteRune(r)
		}
	}
	return strings.TrimSpace(b.String())
}
