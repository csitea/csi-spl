package hub

import (
	"context"
	"net/http"

	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
)

// DMs go to demo agents only (specs/077 3.2, T014, owner Q3). A demo_user's
// DM (a send stored with no channel) is refused 403 demo_dm_human when its
// other party is a person: the frame's `to`, or any end of the DM rows the
// task already holds, so a reply into an existing human DM is refused
// whatever it addresses. The browser send (wuiSend) is the one path a demo
// session has to a new DM row: a box send needs a pinned box, and no HTTP
// route creates a message (edit and merge rewrite the caller's own rows,
// which this check never lets be a human DM). A channel post, a human
// DMing a demo user, and every other role are untouched.

// demoDMHuman is the refusal token.
const demoDMHuman = "demo_dm_human"

// demoDM is the (token, status, detail) triple of the check for a browser
// send by c stored in channel ("" = a DM): "" = go on. Fails closed: a
// topic that cannot be read is refused rather than possibly a human's.
func (s *Server) demoDM(ctx context.Context, c *wuiConn, channel string, m *msg.Message) (string, int, string) {
	if channel != "" || !s.isDemoVisitor(ctx, c.tenant, c.member) {
		return "", 0, ""
	}
	if humanEnd(m.To, c.from) {
		return demoDMHuman, http.StatusForbidden, "a demo user DMs demo agents only"
	}
	a, err := s.o.Store.TopicAccess(ctx, c.tenant, m.TaskID, s.o.Now())
	if err != nil {
		s.o.Log.Error().Err(err).Str("task_id", m.TaskID).Msg("demo dm topic")
		return "internal", http.StatusInternalServerError, "topic lookup failed"
	}
	for _, p := range a.DMParties {
		if humanEnd(p, c.from) {
			return demoDMHuman, http.StatusForbidden, "a demo user DMs demo agents only"
		}
	}
	return "", 0, ""
}

// humanEnd reports whether id is a person (isPerson) other than self.
func humanEnd(id, self string) bool {
	return id != self && isPerson(id)
}
