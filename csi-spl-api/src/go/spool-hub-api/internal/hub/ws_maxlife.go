package hub

import (
	"sync/atomic"
	"time"

	"github.com/coder/websocket"
)

// Socket max life (SPL-1981). prd 2026-10-15 07:32-07:36Z answered 594
// requests 429 "no available instance" at normal load (p99 44 requests in
// flight per instance, p99 CPU 5%) because both of the max_instances=2 slots
// were held by instances Cloud Run had already retired: a retired instance
// gets no new request but lives on, and counts, until its last open request
// ends, and a box or browser socket with no end runs to the 3600 s request
// timeout (instance ...69f9cffe89 retired 07:22:45, its eleven 3601 s box
// sockets kept it until 07:41:12). The replacements Cloud Run started for the
// second retirement were stopped within 7-17 s. Closing every socket after
// WSMaxLife bounds how long a retired instance holds a slot; the peer redials
// onto a live instance like after any roll.

// CloseMaxLife is the reason of the 1012 (service restart) close a socket
// gets at its max life; the box client and the browser redial on any close
// but 4409.
const CloseMaxLife = "max_life"

// rotateGrace is how long a socket closed at its max life still counts as
// online on this instance: its peer redials within a second or two, so the
// planned close shows no offline/online flap to the browsers.
const rotateGrace = 15 * time.Second

// maxLife closes the socket with 1012 max_life once it has been open for
// WSMaxLife less up to a fifth (jittered, so the sockets of one roll do not
// come back together), after marking it rotated. It returns the timer's stop,
// to be deferred; a zero WSMaxLife arms nothing.
func (s *Server) maxLife(rotated *atomic.Bool, closeFn func(websocket.StatusCode, string)) func() {
	d := s.o.WSMaxLife
	if d <= 0 {
		return func() {}
	}
	if j := int64(d / 5); j > 0 {
		// the clock's nanoseconds spread the sockets; nothing here needs a
		// random number generator
		d -= time.Duration(time.Now().UnixNano() % j)
	}
	t := time.AfterFunc(d, func() {
		rotated.Store(true)
		closeFn(websocket.StatusServiceRestart, CloseMaxLife)
	})
	return func() { t.Stop() }
}
