package hub

import (
	"net/http"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// DM pointers (owner, prd t1 dc6d5e3f; store/dm_pointers.go): the DM view of
// a person and an agent (GET /v1/view/topics?dm=true&peer=<agent>) also
// carries `pointers`, the channel lines between the two of them - a tag in a
// channel topic and the agent's line back - newest first. Each is the stored
// row itself (its channel and task_id intact), so the WUI draws it as a
// pointer that opens the line in its topic. Only on the first page: an older
// page (before=) carries none.

// attachDMPointers sets body.Pointers for a DM view of one peer; false = it
// answered (an error).
func (s *Server) attachDMPointers(w http.ResponseWriter, r *http.Request, t store.Tenant, sq store.TopicQuery, mod modView, body *topicsBody) bool {
	pr, ok := s.o.Store.(store.DMPointerReader)
	if !ok || !sq.DM || sq.Agent == "" || sq.Viewer == "" || !sq.BeforeAt.IsZero() {
		return true
	}
	rows, err := pr.ViewDMPointers(r.Context(), t.ID, store.DMPointerQuery{Viewer: sq.Viewer, Agent: sq.Agent, AgentBox: sq.AgentBox,
		Reader: sq.Reader, ReaderChannels: sq.ReaderChannels, Lobby: sq.Lobby, Now: sq.Now})
	if err == nil && len(rows) > 0 {
		var react map[string][]store.StoredReaction
		if react, err = s.rowReactions(r.Context(), t.ID, rows); err == nil {
			rows = mod.keepMsgs(rows)
			vs := viewMsgs(rows, react)
			mod.markMsgs(rows, vs)
			for i := range vs { // a box reply's envelope has no tag: the row's channel is the truth
				if vs[i].Channel == nil {
					vs[i].Channel = &rows[i].RowChannel
				}
			}
			body.Pointers = vs
		}
	}
	if err != nil {
		s.o.Log.Error().Err(err).Str("tenant", t.ID).Msg("topics dm pointers")
		writeErr(w, http.StatusInternalServerError, "internal", "topics unavailable")
		return false
	}
	return true
}
