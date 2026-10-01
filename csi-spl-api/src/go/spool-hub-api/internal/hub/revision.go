package hub

import (
	"net/http"

	"github.com/csitea/csi-spl/spool-hub-api/internal/uid"
)

// Bug B (t1 #spool-hub-bugs 4ecb4b0d): a person's message reached the other
// person minutes late, with an old send time. The hub pushes a stored message
// to the browser sockets IT holds (s.wui is process memory), and a Cloud Run
// deploy leaves every open browser socket on the old revision for up to the
// 3600 s request timeout - it keeps ponging, so neither side ever closes it.
// A post stored by the NEW revision (every freshly opened tab, every REST
// write) was therefore never pushed to those sockets; the reader saw it only
// when the socket finally died and the catch-up read ran. Measured on prd
// 2026-09-30 18:43Z..10-01 09:18Z: 26 of 112 browser sockets outlived their
// revision, by p50 636 s / p90 2662 s / max 3337 s - 49 % of all browser
// socket time sat on a revision that was no longer serving.
//
// The process cannot tell it was retired (Cloud Run sends it no signal while
// a request is still open), but the browser can: the welcome names the
// revision the socket is on, and GET /v1/wui/revision is answered by whichever
// revision serves NEW requests. When they differ the WUI re-dials (onto the
// live revision) and runs its catch-up read (live-ws.mjs checkRevision).

// revisionOr is Cloud Run's $K_REVISION when set, else an id for this process
// (lde, tests): two processes never share one, so a restart reads as a change.
func revisionOr(r string) string {
	if r != "" {
		return r
	}
	return "proc-" + uid.Hex(6)
}

// handleWUIRevision answers the revision serving this request. Public, like
// /version; CORS for the view allow-list, never cached.
func (s *Server) handleWUIRevision(w http.ResponseWriter, r *http.Request) {
	s.allowOrigin(w, r)
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, map[string]string{"revision": s.o.Revision})
}
