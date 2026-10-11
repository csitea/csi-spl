package hub

import (
	"context"
	"encoding/json"
	"net/http"
	"net/url"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// An agent reads its Flow over its own box socket (spec 130 section 5): a
// flow_read frame, answered by the same folded read the WUI route serves,
// keyed by the session's agent as <id>@<box> (one id runs on several boxes).
// The acting agent must be one this box announced, as for a send or an
// issue. `spool flow` and the MCP tool spool_flow send it; the reply is a
// flow_read frame with the request's msg_id and the page in Flow.

func (s *Server) onFlowRead(ctx context.Context, x *session, f wire.Frame) {
	id := f.MsgID
	if !uuidRe.MatchString(id) {
		x.fail(ctx, "", "bad_frame", http.StatusBadRequest, "a flow_read frame needs msg_id (a UUID) to pair the reply")
		return
	}
	if detail := senderRefusal(x, f.As); detail != "" {
		x.fail(ctx, id, TokenFromNotAnnounced, http.StatusForbidden, detail)
		return
	}
	fe, ok := s.o.Store.(store.FlowFolder)
	if !ok {
		x.fail(ctx, id, "internal", http.StatusInternalServerError, "flow unavailable")
		return
	}
	v, err := url.ParseQuery(f.Query)
	if err != nil {
		v = url.Values{"limit": {"bad"}}
	}
	v.Set("fold", "day")
	v.Del("counts_only")
	q, valid := flowQueryOf(v)
	if !valid {
		x.fail(ctx, id, "bad_query", http.StatusBadRequest, "query: limit 1..50; kind mention|blocked|ready|release; before a cursor")
		return
	}
	q.Tenant, q.Member, q.Now, q.Lobby = x.tenant, f.As+"@"+x.box, s.o.Now(), s.o.LobbyTaskID
	body, err := s.flowFoldBody(ctx, fe, q)
	if err != nil {
		s.o.Log.Error().Err(err).Str("tenant", x.tenant).Msg("agent flow read")
		x.fail(ctx, id, "internal", http.StatusInternalServerError, "flow unavailable")
		return
	}
	raw, err := json.Marshal(body)
	if err != nil {
		x.fail(ctx, id, "internal", http.StatusInternalServerError, "reply does not encode")
		return
	}
	x.write(ctx, wire.Frame{Type: wire.TFlowRead, MsgID: id, Flow: raw}) //nolint:errcheck
}
