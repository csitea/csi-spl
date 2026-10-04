package hub

import (
	"regexp"
	"sort"
	"strings"
	"sync"

	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// Box facts (t1 f77c9f87, the Boxes page): the OS and run-times a box says it
// runs on, sent once per hello (wire.BoxHost) and served on the roster view as
// boxes[].os and boxes[].runtimes.
//
// They are process memory, not a table: the hub runs one instance
// (max_instances 1, like s.boxes), and every box says them again at its next
// hello, so a fresh revision knows a box again once it redials. Last hello
// wins; a hello without them (an older box) clears them.
//
// The box is untrusted here: every string is cut to printable ASCII and
// maxFactLen bytes, a run-time name must be a short slug, and at most
// maxRuntimes of them are kept. Nothing is refused - a hello is never lost
// over a cosmetic field.

const (
	maxFactLen  = 64
	maxRuntimes = 16
)

// runtimeNameRe: a run-time's name, the key of boxes[].runtimes.
var runtimeNameRe = regexp.MustCompile(`^[a-z][a-z0-9_-]{0,23}$`)

// boxFacts is one box's cleaned report.
type boxFacts struct {
	os       *wire.HostOS
	runtimes map[string]string
}

// boxHosts holds every box's facts, keyed (tenant, box); its own lock, so a
// roster read never takes the routing mutex for them.
type boxHosts struct {
	mu sync.Mutex
	m  map[[2]string]boxFacts
}

func (h *boxHosts) set(tenant, box string, host *wire.BoxHost) {
	k := [2]string{tenant, box}
	f, ok := cleanHost(host)
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

// cleanHost cuts a hello's host report to what the hub keeps; false = nothing
// is left of it.
func cleanHost(host *wire.BoxHost) (boxFacts, bool) {
	if host == nil {
		return boxFacts{}, false
	}
	var f boxFacts
	if o := host.OS; o != nil {
		c := wire.HostOS{Name: cleanFact(o.Name), Version: cleanFact(o.Version), Kernel: cleanFact(o.Kernel), Arch: cleanFact(o.Arch)}
		if c != (wire.HostOS{}) {
			f.os = &c
		}
	}
	names := make([]string, 0, len(host.Runtimes))
	for name := range host.Runtimes {
		if runtimeNameRe.MatchString(name) {
			names = append(names, name)
		}
	}
	sort.Strings(names) // a hostile map past the cap keeps the same entries every time
	for _, name := range names {
		v := cleanFact(host.Runtimes[name])
		if v == "" {
			continue
		}
		if f.runtimes == nil {
			f.runtimes = map[string]string{}
		}
		f.runtimes[name] = v
		if len(f.runtimes) == maxRuntimes {
			break
		}
	}
	return f, f.os != nil || f.runtimes != nil
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
