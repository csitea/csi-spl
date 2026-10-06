package hub

import (
	"context"
	"encoding/json"
	"net"
	"reflect"
	"regexp"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// Box facts (t1 f77c9f87 the Boxes page, d1d9bcd3 "basic troubleshooting
// info for each box"): the fact sheet a box sends on its hello (wire.BoxHost)
// - OS, run-times, system, network - served on the roster view as
// boxes[].os, .runtimes, .system, .network and .facts_reported_at.
//
// The box collects the sheet at most once a day (owner 7e013eab) and
// re-sends the same sheet on every hello. The hub serves it from process
// memory and also stores it (rdb 0140, store.BoxFacts): a Cloud Run roll
// leaves every box socket on the OLD revision, and the NEW one, which answers
// every fresh roster read, said "not reported yet" until each box redialled
// (t1 950d5562, "the sat box has a lot of box info unreported"). So a process
// reads a tenant's stored sheets once, on its first roster read. Last hello
// with a sheet wins; a hello without one (an older box, a one-shot sync)
// leaves the kept sheet as it is.
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
// roster read never takes the routing mutex for them. loaded is the tenants
// whose stored sheets this process has read.
type boxHosts struct {
	mu     sync.Mutex
	m      map[[2]string]boxFacts
	loaded map[string]bool
}

// set keeps a hello's cleaned sheet; true when it differs from the one held
// (so it is worth storing).
func (h *boxHosts) set(tenant, box string, f boxFacts) bool {
	k := [2]string{tenant, box}
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.m == nil {
		h.m = map[[2]string]boxFacts{}
	}
	old, had := h.m[k]
	h.m[k] = f
	return !had || !reflect.DeepEqual(old, f)
}

// fill adds the stored sheets of a tenant that no hello has set since, and
// marks the tenant loaded.
func (h *boxHosts) fill(tenant string, got map[string]boxFacts) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.m == nil {
		h.m = map[[2]string]boxFacts{}
	}
	for box, f := range got {
		if _, ok := h.m[[2]string{tenant, box}]; !ok {
			h.m[[2]string{tenant, box}] = f
		}
	}
	if h.loaded == nil {
		h.loaded = map[string]bool{}
	}
	h.loaded[tenant] = true
}

func (h *boxHosts) isLoaded(tenant string) bool {
	h.mu.Lock()
	defer h.mu.Unlock()
	return h.loaded[tenant]
}

// keepHostFacts takes a role=box hello's sheet: kept in memory and, when it
// changed, stored. A hello without a usable sheet changes nothing. A store
// error is logged, never fails the hello.
func (s *Server) keepHostFacts(ctx context.Context, tenant, box string, host *wire.BoxHost) {
	f, ok := cleanHost(host, s.o.Now())
	if !ok || !s.hosts.set(tenant, box, f) {
		return
	}
	fs, ok := s.o.Store.(store.BoxFacts)
	if !ok {
		return
	}
	raw, err := json.Marshal(f.wire())
	if err == nil && len(raw) > store.BoxFactsMaxBytes {
		return // past the rdb 0140 CHECK: memory only
	}
	if err == nil {
		err = fs.PutBoxFacts(ctx, tenant, store.BoxFactSheet{Box: box, ReportedAt: f.reportedAt, Sheet: raw})
	}
	if err != nil {
		s.o.Log.Warn().Err(err).Str("tenant", tenant).Str("box", box).Msg("box facts not stored")
	}
}

// loadHostFacts reads the tenant's stored sheets once per process, so a
// fresh revision serves them before any box redials. A failed read is
// logged and tried again on the next roster read.
func (s *Server) loadHostFacts(ctx context.Context, tenant string) {
	if s.hosts.isLoaded(tenant) {
		return
	}
	got := map[string]boxFacts{}
	if fs, ok := s.o.Store.(store.BoxFacts); ok {
		rows, err := fs.ListBoxFacts(ctx, tenant)
		if err != nil {
			s.o.Log.Warn().Err(err).Str("tenant", tenant).Msg("box facts not read")
			return
		}
		now := s.o.Now()
		for _, r := range rows {
			var host wire.BoxHost
			if json.Unmarshal(r.Sheet, &host) != nil {
				continue
			}
			host.ReportedAt = rfc(r.ReportedAt)
			if f, ok := cleanHost(&host, now); ok { // cleaned again: the row is data, not trusted
				got[r.Box] = f
			}
		}
	}
	s.hosts.fill(tenant, got)
}

// wire is f as the sheet a box sends: what the store keeps.
func (f boxFacts) wire() wire.BoxHost {
	return wire.BoxHost{ReportedAt: rfc(f.reportedAt), OS: f.os, Runtimes: f.runtimes, System: f.system, Network: f.network}
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
		SwapTotalMB: factMB(s.SwapTotalMB), SwapFreeMB: factMB(s.SwapFreeMB),
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

// factMB is a swap figure: nil when not read or out of [0, maxFactMB]; a 0
// (no swap) is kept.
func factMB(n *int64) *int64 {
	if n == nil || *n < 0 || *n > maxFactMB {
		return nil
	}
	v := *n
	return &v
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
