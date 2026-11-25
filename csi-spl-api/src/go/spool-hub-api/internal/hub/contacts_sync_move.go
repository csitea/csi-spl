package hub

import (
	"errors"
	"net/http"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// POST /v1/me/contacts/sync/move: "Sync from here instead" (spec 154 2.2
// step 6, SPL-6454, owner HUM-10 t1 85bdf803 msg deec5dc3). The person's
// one binding, on in another of their workspaces, ends there and starts in
// the session's workspace in one transaction (MoveContactsSync); the
// contacts stay as they are, and the fresh binding's first sync links them
// by (google_account, google_resource) or email (2.5), so nothing is
// imported twice. 200 with the switch's new state (state "here"); 409
// gcal_not_connected without a connected Google connection here, 409
// sync_in_progress while a cycle holds the binding's lease (try again).
func (s *Server) handleContactsSyncMove(w http.ResponseWriter, r *http.Request) {
	c, ok := s.contactsCaller(w, r)
	if !ok {
		return
	}
	cs, ok := s.contactsSyncStore(w)
	if !ok {
		return
	}
	ctx := r.Context()
	if gs, has := s.o.Store.(store.Gcal); has {
		conn, err := gs.GcalConnection(ctx, c.tenant, c.person)
		if err == nil && conn.Status != store.GcalConnected {
			err = store.ErrNotFound
		}
		if errors.Is(err, store.ErrNotFound) {
			writeErr(w, http.StatusConflict, "gcal_not_connected", "connect Google in this workspace first")
			return
		}
		if err != nil {
			s.contactsFail(w, "contacts_sync_move", c, "", err)
			return
		}
	}
	_, err := cs.MoveContactsSync(ctx, c.tenant, c.person, s.o.Now())
	switch {
	case errors.Is(err, store.ErrNotFound):
		writeErr(w, http.StatusConflict, "gcal_not_connected", "connect Google in this workspace first")
		return
	case errors.Is(err, store.ErrContactsSyncBusy):
		writeErr(w, http.StatusConflict, "sync_in_progress", "a contacts sync is running: try again in a minute")
		return
	case err != nil:
		s.contactsFail(w, "contacts_sync_move", c, "", err)
		return
	}
	s.o.Log.Info().Str("op", "contacts_sync_move").Str("person", c.person).Str("tenant", c.tenant).Msg("contacts")
	out, err := s.contactsSyncStateOf(ctx, cs, c)
	if err != nil {
		s.contactsFail(w, "contacts_sync_move", c, "", err)
		return
	}
	writeJSON(w, http.StatusOK, out)
}
