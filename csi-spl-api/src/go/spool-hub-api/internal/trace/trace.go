// Package trace is the stopwatch behind the delivery latency budget
// one appended NDJSON line per hop a message crosses on this box,
// so the hops can be subtracted from each other instead of guessed at.
//
// It answers a question the logs cannot. A delivery crosses several processes
// on two machines, and the only hops that can be SUBTRACTED are the ones read
// from a single clock. Every mark here is stamped by the box's clock, so
// ws_recv -> inbox_written -> notify_visible is a real interval; a probe that
// runs on the same box gets its own send into the same arithmetic for free,
// which is what makes the whole browser-to-pane leg measurable without asking
// the hub to agree about time.
//
// It is OFF unless $SPOOL_TRACE names a file. Off, a mark is one atomic load
// and a return - nothing is opened, formatted or locked - so the production
// path pays nothing to carry the instrument. On, it appends to one O_APPEND
// file: short lines under PIPE_BUF, so concurrent writers interleave whole
// lines rather than shredding each other's.
//
// Nothing here can fail a delivery. A trace that cannot be written is dropped
// in silence: the file is the record (002), and this is a stopwatch.
package trace

import (
	"encoding/json"
	"os"
	"sync"
	"time"
)

// Stages, in the order a hub-borne message crosses them on the receiving box.
const (
	// StageWSRecv is the instant the box sidecar's read loop has a recv frame
	// parsed far enough to name the message.
	StageWSRecv = "ws_recv"
	// StageInboxWritten is the instant the v:1 object is on disk in the
	// recipient's inbox - the delivery itself (002).
	StageInboxWritten = "inbox_written"
	// StageNotifyStart is the instant the terminal leg is handed the message.
	StageNotifyStart = "notify_start"
	// StageNotifyDone is the instant that leg returned, with its exit code.
	StageNotifyDone = "notify_done"
	// StageNotifyVisible is written by the notifier itself, not by this
	// process: the instant the line was typed into the agent's pane. That is
	// where "delivered AND visible" stops.
	StageNotifyVisible = "notify_visible"
)

// Event is one line of the trace file.
type Event struct {
	Stage string `json:"stage"`
	// TSNano is the box's wall clock in nanoseconds. Wall, not monotonic: the
	// readings are compared against a probe in ANOTHER process on this box,
	// and Go's monotonic reading is per-process.
	TSNano int64  `json:"ts_nano"`
	MsgID  string `json:"msg_id,omitempty"`
	To     string `json:"to,omitempty"`
	RC     int    `json:"rc,omitempty"`
	Note   string `json:"note,omitempty"`
}

var (
	once sync.Once
	path string
	mu   sync.Mutex
)

func target() string {
	once.Do(func() { path = os.Getenv("SPOOL_TRACE") })
	return path
}

// On reports whether tracing is enabled for this process.
func On() bool { return target() != "" }

// Mark appends one event. It is a no-op when $SPOOL_TRACE is unset, and it
// never returns an error: a stopwatch that can fail a delivery is worse than
// no stopwatch.
func Mark(e Event) {
	p := target()
	if p == "" {
		return
	}
	if e.TSNano == 0 {
		e.TSNano = time.Now().UnixNano()
	}
	raw, err := json.Marshal(e)
	if err != nil {
		return
	}
	raw = append(raw, '\n')
	// O_APPEND plus a line short enough for PIPE_BUF is what keeps concurrent
	// writers from shredding each other; the mutex only orders this process.
	mu.Lock()
	defer mu.Unlock()
	f, err := os.OpenFile(p, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o664)
	if err != nil {
		return
	}
	f.Write(raw) //nolint:errcheck // a stopwatch never fails a delivery
	f.Close()    //nolint:errcheck
}
