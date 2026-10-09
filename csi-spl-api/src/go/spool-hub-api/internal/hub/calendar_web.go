package hub

import (
	"net/http"
	"strconv"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/edge"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// GET /v1/public/calendar/events?start=&end= (owner t1 a3ce2031, msg
// a8e3d31d; rdb 0158): the signed-out calendar. Anyone, signed in or not,
// reads the public events of ONE workspace: the page host's (the Origin of a
// WUI tenant host, the apex tenant on the apex), else a legacy tenant Host.
// That host only selects the workspace; it grants nothing else, and no query
// parameter can name another one. The answer carries only the fields that
// are safe for the internet (store.WebCalendarEvent); the store reads
// public rows only (web, their name before rdb 0159, until 0161), in the
// workspace's RLS scope. Per client
// address it is rate-limited like the other anonymous routes (join redeem).

// calendarWebPerMin is the per-address read window.
const calendarWebPerMin = 60

// webCalendarEventOut is one web event on the wire.
type webCalendarEventOut struct {
	Title       string `json:"title"`
	Description string `json:"description"`
	StartsAt    string `json:"starts_at"`
	EndsAt      string `json:"ends_at"`
	AllDay      bool   `json:"all_day"`
}

func (s *Server) routeCalendarWeb(mux *http.ServeMux) {
	s.calWebLim = edge.NewWindow(time.Minute, s.o.Now)
	mux.HandleFunc("GET /v1/public/calendar/events", s.handleCalendarWeb)
	mux.HandleFunc("OPTIONS /v1/public/calendar/events", s.preflight)
}

// webCalendarTenant is the workspace a signed-out request reads: the page
// host first, then a legacy tenant Host; "" when neither names one.
func (s *Server) webCalendarTenant(r *http.Request) string {
	if id := s.o.OriginTenant.Request(r); id != "" {
		return id
	}
	return s.hostTenantID(r)
}

func (s *Server) handleCalendarWeb(w http.ResponseWriter, r *http.Request) {
	s.allowOrigin(w, r)
	w.Header().Set("Cache-Control", "no-store")
	if ok, retry := s.calWebLim.Allow(s.edge.ClientIP(r), calendarWebPerMin); !ok {
		w.Header().Set("Retry-After", strconv.Itoa(int(retry.Seconds())+1))
		writeErr(w, http.StatusTooManyRequests, "rate_limited", "too many calendar reads from this address")
		return
	}
	id := s.webCalendarTenant(r)
	if id == "" {
		writeErr(w, http.StatusNotFound, "unknown_tenant", "no workspace on this host")
		return
	}
	t, ok := s.loadTenant(w, r, id)
	if !ok {
		return
	}
	rg, ie := calendarRange(r, "start", "end", calendarMaxRangeDays)
	if ie != nil {
		writeIssueErr(w, ie)
		return
	}
	web, ok := s.o.Store.(store.CalendarWebReader)
	if !ok {
		writeErr(w, http.StatusServiceUnavailable, "calendar_off", "this hub's store keeps no calendar")
		return
	}
	evs, err := web.WebCalendarEvents(r.Context(), t.ID, rg)
	if err != nil {
		writeErrCause(w, http.StatusInternalServerError, "internal", "calendar not read", err)
		return
	}
	out := make([]webCalendarEventOut, 0, len(evs))
	for _, e := range evs {
		out = append(out, webCalendarEventOut{Title: e.Title, Description: e.Description,
			StartsAt: rfc(e.StartsAt), EndsAt: rfc(e.EndsAt), AllDay: e.AllDay})
	}
	writeJSON(w, http.StatusOK, map[string]any{"events": out})
}
