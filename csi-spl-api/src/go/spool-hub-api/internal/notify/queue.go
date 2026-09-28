package notify

import (
	"sync"
	"sync/atomic"

	"github.com/csitea/csi-spl/spool-hub-api/internal/config"
	"github.com/csitea/csi-spl/spool-hub-api/internal/logging"
	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
)

// Queue takes the terminal leg OFF the delivery path.
//
// Run is synchronous, and writeBox calls it inside Session.receive inside the
// sidecar's readLoop - so for as long as a poke takes, that box cannot read
// its NEXT recv frame. That is head-of-line blocking, not just latency: the
// second of two messages sent back to back paid the first one's terminal leg
// on top of its own. The measured leg is ~80 ms, so a burst of five put the
// last one ~320 ms behind before a single byte of it was late.
//
// A queue fixes that without loosening what an agent sees. One lane per
// RECIPIENT, each drained by one goroutine, so pokes to an agent still arrive
// in the order the messages were delivered to it; lanes for different agents
// no longer wait on each other, and none of them holds up the read loop.
//
// It is deliberately opt-in, not the default. A short-lived CLI (`spool
// send`, the MCP tool) exits the instant its delivery returns, and a queued
// poke would die with the process - so only a long-running box daemon starts
// one. `spool hub-run` does; everything else keeps the synchronous Run it
// already had.
type Queue struct {
	cfg   *config.Config
	mu    sync.Mutex
	lanes map[string]chan queued
	wg    sync.WaitGroup
	off   bool
}

type queued struct {
	m  *msg.Message
	to string
}

// lane depth per recipient. Deep enough that an ordinary burst never reaches
// it, shallow enough that a pane nobody is draining cannot grow without
// bound. Overflow is dropped and logged: the file is the record (002), so a
// lost doorbell costs a delayed read, never a lost message.
const laneDepth = 64

var installed atomic.Pointer[Queue]

// Start builds a queue and installs it as this process's terminal leg. The
// caller must Stop it, which drains what is already queued.
func Start(cfg *config.Config) *Queue {
	q := &Queue{cfg: cfg, lanes: map[string]chan queued{}}
	installed.Store(q)
	return q
}

// Stop closes every lane, waits for the pokes already queued, and puts the
// process back on the synchronous path.
func (q *Queue) Stop() {
	if q == nil {
		return
	}
	installed.CompareAndSwap(q, nil)
	q.mu.Lock()
	if q.off {
		q.mu.Unlock()
		return
	}
	q.off = true
	for _, ch := range q.lanes {
		close(ch)
	}
	q.mu.Unlock()
	q.wg.Wait()
}

// Deliver is what the store calls after a message lands in a local inbox. It
// hands the poke to the installed queue when there is one, and otherwise runs
// it synchronously exactly as before.
func Deliver(cfg *config.Config, m *msg.Message, to string) {
	if q := installed.Load(); q != nil && q.enqueue(m, to) {
		return
	}
	Run(cfg, m, to)
}

// enqueue reports whether the poke was accepted onto a lane.
func (q *Queue) enqueue(m *msg.Message, to string) bool {
	if !Enabled(q.cfg) || m == nil || to == "" {
		return false
	}
	q.mu.Lock()
	if q.off {
		q.mu.Unlock()
		return false
	}
	ch, ok := q.lanes[to]
	if !ok {
		ch = make(chan queued, laneDepth)
		q.lanes[to] = ch
		q.wg.Add(1)
		go q.serve(ch)
	}
	q.mu.Unlock()

	select {
	case ch <- queued{m: m, to: to}:
		return true
	default:
		// The lane is full: this agent's pane is not keeping up. Say so once
		// per dropped poke and move on - blocking here would put the read
		// loop back behind the very leg this queue exists to get off it.
		log := logging.New(q.cfg)
		log.Warn().Str("to", to).Str("msg_id", m.MsgID).
			Int("lane_depth", laneDepth).
			Msg("terminal delivery not shown: the pane's queue is full; the message is still in the inbox")
		return true
	}
}

func (q *Queue) serve(ch chan queued) {
	defer q.wg.Done()
	for it := range ch {
		Run(q.cfg, it.m, it.to)
	}
}
