package hub

import (
	"context"
	"sync"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// Browsers on another hub process (spec 059 §11 S3). A line stored through
// one process used to reach only the browser sockets that process holds; the
// store now announces every stored message (store.WUIWaker, the same listen
// connection as the box wake-up) and each process loads the row and runs the
// same fanoutWUI for the browsers it holds. The storing process marks the
// msg id first, so its own announcement never fans a line out twice. A
// browser that missed a line while reconnecting already catches up from the
// DB (view-v1 after=<cursor>), on whichever process answers.

const (
	wuiWakeQueue = 1024 // pending announcements; a full queue drops, the browser's after= catch-up covers it
	fannedMax    = 4096 // msg ids remembered per process
)

// fannedSet is the (tenant, msg_id) this process fanned out lately, bounded:
// the oldest falls out.
type fannedSet struct {
	mu   sync.Mutex
	ring [][2]string
	next int
	has  map[[2]string]bool
}

// add records k and reports whether it was new.
func (f *fannedSet) add(k [2]string) bool {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.has[k] {
		return false
	}
	if f.ring == nil {
		f.ring, f.has = make([][2]string, fannedMax), map[[2]string]bool{}
	}
	delete(f.has, f.ring[f.next])
	f.ring[f.next] = k
	f.next = (f.next + 1) % fannedMax
	f.has[k] = true
	return true
}

// wuiWakeWorker fans out each announced message this process has not, to
// the browser sockets it holds; a tenant with no socket here costs no read.
func (s *Server) wuiWakeWorker(ctx context.Context, ww store.WUIWaker, kick <-chan [2]string) {
	for {
		var k [2]string
		select {
		case <-ctx.Done():
			return
		case k = <-kick:
		}
		if member, ok := flowMarkWake(k[1]); ok { // spec 062: a member's marks moved
			s.pushFlowCounts(ctx, k[0], member)
			continue
		}
		if !s.holdsWUI(k[0]) || !s.fanned.add(k) {
			continue
		}
		row, err := ww.FanoutRow(ctx, k[0], k[1])
		if err != nil {
			s.o.Log.Warn().Err(err).Str("tenant", k[0]).Str("msg_id", k[1]).Msg("wui wake row")
			continue
		}
		s.fanoutWUI(ctx, row)
	}
}

// holdsWUI: this process holds a browser socket of tenant.
func (s *Server) holdsWUI(tenant string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	for c := range s.wui {
		if c.tenant == tenant {
			return true
		}
	}
	return false
}
