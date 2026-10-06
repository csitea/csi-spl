package hub

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"sort"
	"strings"
	"sync"
	"time"
	"unicode"
	"unicode/utf8"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// A member's manual status (spec 096 sections 7.3 and 7.4, rdb 0141): "Busy",
// "Unavailable until 14:00", with an optional note, per workspace. The
// member sets it with PUT /v1/me/status and clears it with DELETE; the roster
// and search carry it as `status`; every browser socket of the workspace gets
// a `status` frame on a change, the welcome snapshot and the expiry sweep.
// The presence frame is untouched: a status is a separate frame type, so an
// old tab never misreads it.

const (
	statusNoteMax    = 80                  // characters, spec section 3
	statusUntilMax   = 90 * 24 * time.Hour // Q6
	statusSweepEvery = time.Minute         // per tenant, on the relay tick
	statusAvailable  = "available"
)

// viewStatus is the roster's and search's `status` object; omitted when the
// member is available or the status expired.
type viewStatus struct {
	State string `json:"state"`
	Note  string `json:"note,omitempty"`
	Until string `json:"until,omitempty"`
}

// statusMsg is the `status` frame (spec 7.4). state "available" clears it and
// carries no note and no until.
type statusMsg struct {
	Type  string `json:"type"`
	Peer  string `json:"peer"`
	State string `json:"state"`
	Note  string `json:"note,omitempty"`
	Until string `json:"until,omitempty"`
}

// statusUntil is the wire form of an until: RFC 3339 UTC, "" = no end.
func statusUntil(t time.Time) string {
	if t.IsZero() {
		return ""
	}
	return t.UTC().Format(time.RFC3339)
}

func toViewStatus(st store.HumanStatus) *viewStatus {
	return &viewStatus{State: st.State, Note: st.Note, Until: statusUntil(st.Until)}
}

func statusFrame(st store.HumanStatus) statusMsg {
	return statusMsg{Type: "status", Peer: st.HumanID + "@" + WUIBox, State: st.State, Note: st.Note, Until: statusUntil(st.Until)}
}

func clearedFrame(humanID string) statusMsg {
	return statusMsg{Type: "status", Peer: humanID + "@" + WUIBox, State: statusAvailable}
}

// liveStatuses is every live status of tenant, by HUM-*; empty when the store
// keeps none or the read fails (the caller's answer then just omits it).
func (s *Server) liveStatuses(ctx context.Context, tenant string) map[string]store.HumanStatus {
	hs, ok := s.o.Store.(store.HumanStatuses)
	if !ok {
		return nil
	}
	m, err := hs.HumanStatuses(ctx, tenant, s.o.Now())
	if err != nil {
		s.o.Log.Error().Err(err).Str("tenant", tenant).Msg("human status read")
		return nil
	}
	return m
}

// broadcastStatus writes frames to every browser socket of tenant.
func (s *Server) broadcastStatus(ctx context.Context, tenant string, frames []statusMsg) {
	if len(frames) == 0 {
		return
	}
	s.mu.Lock()
	var targets []*wuiConn
	for c := range s.wui {
		if c.tenant == tenant {
			targets = append(targets, c)
		}
	}
	s.mu.Unlock()
	for _, c := range targets {
		for i := range frames {
			c.write(ctx, &frames[i]) //nolint:errcheck
		}
	}
}

// statusSnapshot writes one `status` frame per live status, after the
// presence snapshot of the welcome (spec 7.4).
func (s *Server) statusSnapshot(ctx context.Context, c *wuiConn) {
	live := s.liveStatuses(ctx, c.tenant)
	ids := make([]string, 0, len(live))
	for id := range live {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	for _, id := range ids {
		f := statusFrame(live[id])
		c.write(ctx, &f) //nolint:errcheck
	}
}

// ---- the write ----------------------------------------------------------------

// statusBody is PUT /v1/me/status.
type statusBody struct {
	State         string  `json:"state"`
	Note          *string `json:"note"`
	Until         *string `json:"until"`
	PauseNotify   bool    `json:"pause_notify"`
	AllWorkspaces bool    `json:"all_workspaces"`
}

// cleanNote trims the note and strips control characters (a line break or a
// tab becomes a space: the note is one line). false when it is longer than
// statusNoteMax characters.
func cleanNote(in string) (string, bool) {
	out := strings.Map(func(r rune) rune {
		switch {
		case r == '\n' || r == '\r' || r == '\t':
			return ' '
		case unicode.IsControl(r):
			return -1
		}
		return r
	}, strings.ToValidUTF8(in, ""))
	out = strings.TrimSpace(out)
	return out, utf8.RuneCountInString(out) <= statusNoteMax
}

// parseStatus validates the body at now; the error text is the 400's detail.
func parseStatus(b statusBody, now time.Time) (store.HumanStatus, string) {
	st := store.HumanStatus{State: b.State, PauseNotify: b.PauseNotify}
	switch b.State {
	case "busy", "unavailable":
	case statusAvailable:
		return st, ""
	default:
		return st, "state must be available, busy or unavailable"
	}
	if b.Note != nil {
		note, ok := cleanNote(*b.Note)
		if !ok {
			return st, "note must be at most 80 characters"
		}
		st.Note = note
	}
	if b.Until != nil && strings.TrimSpace(*b.Until) != "" {
		until, err := time.Parse(time.RFC3339, strings.TrimSpace(*b.Until))
		if err != nil {
			return st, "until must be an RFC 3339 time"
		}
		if !until.After(now) || until.Sub(now) > statusUntilMax {
			return st, "until must be in the future and at most 90 days out"
		}
		st.Until = until.UTC().Truncate(time.Second)
	}
	return st, ""
}

// statusCaller is the signed-in member of this workspace; an agent or a
// caller without a member session is refused (Q5: agents set no status).
func (s *Server) statusCaller(w http.ResponseWriter, r *http.Request) (store.Tenant, string, store.HumanStatuses, bool) {
	s.allowOrigin(w, r)
	t, hum, ok := s.humanTenant(w, r)
	if !ok {
		return t, "", nil, false
	}
	if hum == "" {
		writeForbidden(w, rbac.TopicsRead, "a status needs a signed-in member session")
		return t, "", nil, false
	}
	// A write is the member's own published text: like their keys, not for a
	// demo visitor (specs/077: every role but demo_user holds self.keys).
	if r.Method != http.MethodGet && !s.permit(w, r, t.ID, hum, rbac.SelfKeys) {
		return t, "", nil, false
	}
	hs, ok := s.o.Store.(store.HumanStatuses)
	if !ok {
		writeErr(w, http.StatusInternalServerError, "internal", "status unavailable")
		return t, "", nil, false
	}
	return t, hum, hs, true
}

// statusTenants is where a write goes: this workspace, plus with all (Q2,
// "Set in all my workspaces") every other one the member belongs to.
func (s *Server) statusTenants(ctx context.Context, tenant, hum string, all bool) []string {
	out := []string{tenant}
	ml, ok := s.o.Store.(store.MembershipLister)
	if !all || !ok {
		return out
	}
	ms, err := ml.Memberships(ctx, hum)
	if err != nil {
		s.o.Log.Error().Err(err).Str("tenant", tenant).Msg("status memberships")
		return out
	}
	for _, m := range ms {
		if m.TenantID != tenant {
			out = append(out, m.TenantID)
		}
	}
	return out
}

// applyStatus writes st (state available = clear) in tenant and tells that
// workspace's browser sockets.
func (s *Server) applyStatus(ctx context.Context, hs store.HumanStatuses, tenant string, st store.HumanStatus) error {
	if st.State == statusAvailable {
		if _, err := hs.ClearHumanStatus(ctx, tenant, st.HumanID); err != nil {
			return err
		}
		s.broadcastStatus(ctx, tenant, []statusMsg{clearedFrame(st.HumanID)})
		return nil
	}
	if err := hs.PutHumanStatus(ctx, tenant, st); err != nil {
		return err
	}
	s.broadcastStatus(ctx, tenant, []statusMsg{statusFrame(st)})
	return nil
}

// writeStatus applies st in each tenant, the caller's own first: a refusal
// there is the answer; a failure in another workspace is logged and skipped.
func (s *Server) writeStatus(w http.ResponseWriter, r *http.Request, hs store.HumanStatuses, tenants []string, st store.HumanStatus) bool {
	for i, tenant := range tenants {
		err := s.applyStatus(r.Context(), hs, tenant, st)
		switch {
		case err == nil:
		case i > 0:
			s.o.Log.Error().Err(err).Str("tenant", tenant).Msg("status write, other workspace")
		case errors.Is(err, store.ErrNotFound):
			writeErr(w, http.StatusNotFound, "not_member", "not a member of this tenant")
			return false
		default:
			s.o.Log.Error().Err(err).Str("tenant", tenant).Msg("status write")
			writeErr(w, http.StatusInternalServerError, "internal", "status not stored")
			return false
		}
	}
	return true
}

// ownStatus is the answer of GET / PUT / DELETE /v1/me/status: the caller's
// own status, with pause_notify, which the roster never shows.
func ownStatus(st store.HumanStatus, live bool, tenants []string) map[string]any {
	out := map[string]any{"state": statusAvailable, "pause_notify": false}
	if live {
		out["state"], out["pause_notify"] = st.State, st.PauseNotify
		if st.Note != "" {
			out["note"] = st.Note
		}
		if u := statusUntil(st.Until); u != "" {
			out["until"] = u
		}
	}
	if len(tenants) > 1 {
		out["workspaces"] = tenants
	}
	return out
}

// PUT /v1/me/status {state, note?, until?, pause_notify?, all_workspaces?}.
func (s *Server) handlePutHumanStatus(w http.ResponseWriter, r *http.Request) {
	t, hum, hs, ok := s.statusCaller(w, r)
	if !ok {
		return
	}
	var body statusBody
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4<<10))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&body); err != nil {
		writeErr(w, http.StatusBadRequest, "bad_json", "body must be {state, note?, until?, pause_notify?, all_workspaces?}")
		return
	}
	now := s.o.Now()
	st, bad := parseStatus(body, now)
	if bad != "" {
		writeErr(w, http.StatusBadRequest, "bad_status", bad)
		return
	}
	st.HumanID, st.SetBy, st.SetAt = hum, hum, now.UTC()
	tenants := s.statusTenants(r.Context(), t.ID, hum, body.AllWorkspaces)
	if !s.writeStatus(w, r, hs, tenants, st) {
		return
	}
	writeJSON(w, http.StatusOK, ownStatus(st, st.State != statusAvailable, tenants))
}

// DELETE /v1/me/status[?all_workspaces=true].
func (s *Server) handleDeleteHumanStatus(w http.ResponseWriter, r *http.Request) {
	t, hum, hs, ok := s.statusCaller(w, r)
	if !ok {
		return
	}
	all := r.URL.Query().Get("all_workspaces") == "true"
	tenants := s.statusTenants(r.Context(), t.ID, hum, all)
	st := store.HumanStatus{HumanID: hum, State: statusAvailable}
	if !s.writeStatus(w, r, hs, tenants, st) {
		return
	}
	writeJSON(w, http.StatusOK, ownStatus(st, false, tenants))
}

// GET /v1/me/status: the caller's own status in this workspace.
func (s *Server) handleGetHumanStatus(w http.ResponseWriter, r *http.Request) {
	t, hum, hs, ok := s.statusCaller(w, r)
	if !ok {
		return
	}
	m, err := hs.HumanStatuses(r.Context(), t.ID, s.o.Now())
	if err != nil {
		s.o.Log.Error().Err(err).Str("tenant", t.ID).Msg("status read")
		writeErr(w, http.StatusInternalServerError, "internal", "status unavailable")
		return
	}
	st, live := m[hum]
	writeJSON(w, http.StatusOK, ownStatus(st, live, nil))
}

// humanStatusPreflight: the headers every browser route allows (no new
// request header: a new header is a new preflight, see 032).
func (s *Server) humanStatusPreflight(w http.ResponseWriter, r *http.Request) {
	if s.allowOrigin(w, r) {
		h := w.Header()
		h.Set("Access-Control-Allow-Methods", "GET, PUT, DELETE")
		h.Set("Access-Control-Allow-Headers", "Authorization, Content-Type, X-Locale")
		h.Set("Access-Control-Max-Age", corsMaxAge)
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) routeHumanStatus(mux *http.ServeMux) {
	mux.HandleFunc("GET /v1/me/status", s.handleGetHumanStatus)
	mux.HandleFunc("PUT /v1/me/status", s.handlePutHumanStatus)
	mux.HandleFunc("DELETE /v1/me/status", s.handleDeleteHumanStatus)
	mux.HandleFunc("OPTIONS /v1/me/status", s.humanStatusPreflight)
}

// ---- the expiry sweep -----------------------------------------------------------

// statusSweeps is when each tenant was last swept.
type statusSweeps struct {
	mu   sync.Mutex
	last map[string]time.Time
}

// due reports whether tenant was not swept within statusSweepEvery of now,
// and stamps it.
func (p *statusSweeps) due(tenant string, now time.Time) bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.last == nil {
		p.last = map[string]time.Time{}
	}
	if at, ok := p.last[tenant]; ok && now.Sub(at) < statusSweepEvery {
		return false
	}
	p.last[tenant] = now
	return true
}

// sweepHumanStatus deletes the expired statuses of every tenant whose browser
// sockets this process holds, at most once a minute per tenant, and sends
// each clearing frame to that workspace's sockets. A tab on another instance
// stops showing it at its own expiry check (reads ignore expired rows).
func (s *Server) sweepHumanStatus(ctx context.Context) {
	hs, ok := s.o.Store.(store.HumanStatuses)
	if !ok {
		return
	}
	s.mu.Lock()
	tenants := map[string]bool{}
	for c := range s.wui {
		tenants[c.tenant] = true
	}
	s.mu.Unlock()
	now := s.o.Now()
	for tenant := range tenants {
		if !s.statusSwept.due(tenant, now) {
			continue
		}
		ids, err := hs.SweepHumanStatus(ctx, tenant, now)
		if err != nil {
			s.o.Log.Error().Err(err).Str("tenant", tenant).Msg("human status sweep")
			continue
		}
		frames := make([]statusMsg, len(ids))
		for i, id := range ids {
			frames[i] = clearedFrame(id)
		}
		s.broadcastStatus(ctx, tenant, frames)
	}
}
