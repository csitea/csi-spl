package hub

import (
	"errors"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/auth"
	"github.com/csitea/csi-spl/spool-hub-api/internal/edge"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// A human's personal event log (specs/005 FR-WUI-EVLOG, contracts/events-v1.md,
// CLE-34990). Mounted under the auth prefix, like keys-v1, so the credentialed
// CORS of /api/v1/auth/* covers it (GET and POST only: no CORS change).
// Member session with a HUM-*; the human reads and writes only their own log.
//
// The WUI's error journal redacts every field at capture (no body, header,
// query string or stack ever reaches it); the hub stores exactly those
// fields, refuses any other (DisallowUnknownFields) and enforces rdb 0045's
// caps, so a client cannot widen what is kept.

const (
	eventsPrefix = auth.RoutePrefix + "events"
	// eventsWritesPerHour is the per-human POST ceiling when
	// Options.EventsWriteLimit is 0. The WUI batches (<= 20 per POST, one
	// POST per 1.5 s burst), so this is ~4800 errors an hour.
	eventsWritesPerHour = 240
	// eventsBatchMax is the most events one POST may carry.
	eventsBatchMax = 20
	eventsMaxBody  = 64 << 10
	// eventsPageDefault / eventsPageMax bound GET ?limit.
	eventsPageDefault = 50
	eventsPageMax     = 200
)

type eventJSON struct {
	ID         int64      `json:"id"`
	Kind       string     `json:"kind"`
	ErrorID    string     `json:"error_id"`
	At         *time.Time `json:"at"`
	ReceivedAt time.Time  `json:"received_at"`
	Source     string     `json:"source"`
	Method     string     `json:"method"`
	Origin     string     `json:"origin"`
	Path       string     `json:"path"`
	Status     int        `json:"status"`
	Code       string     `json:"code"`
	Message    string     `json:"message"`
	Name       string     `json:"name"`
	Route      string     `json:"route"`
}

func toEventJSON(e store.HumanEvent) eventJSON {
	var at *time.Time
	if e.OccurredAt != nil {
		u := e.OccurredAt.UTC()
		at = &u
	}
	return eventJSON{ID: e.ID, Kind: e.Kind, ErrorID: e.ErrorID, At: at, ReceivedAt: e.ReceivedAt.UTC(),
		Source: e.Source, Method: e.Method, Origin: e.Origin, Path: e.Path, Status: e.Status, Code: e.Code,
		Message: e.Message, Name: e.Name, Route: e.Route}
}

// eventInJSON is one event as the WUI sends it (event-log.mjs toEventPayload).
type eventInJSON struct {
	ErrorID string `json:"error_id"`
	At      string `json:"at"`
	Source  string `json:"source"`
	Method  string `json:"method"`
	Origin  string `json:"origin"`
	Path    string `json:"path"`
	Status  int    `json:"status"`
	Code    string `json:"code"`
	Message string `json:"message"`
	Name    string `json:"name"`
	Route   string `json:"route"`
}

func (s *Server) registerEvents(mux *http.ServeMux) {
	s.evLim = edge.NewWindow(time.Hour, s.o.Now)
	mux.HandleFunc("GET "+eventsPrefix, s.handleEventsList)
	mux.HandleFunc("POST "+eventsPrefix, s.handleEventsAdd)
	mux.HandleFunc("POST "+eventsPrefix+"/clear", s.handleEventsClear)
}

// eventsHuman answers the caller's HUM-* and the event store, or writes the error.
func (s *Server) eventsHuman(w http.ResponseWriter, r *http.Request) (string, store.HumanEvents, bool) {
	w.Header().Set("Cache-Control", "no-store")
	var hum string
	if s.o.SessionID != nil {
		hum, _ = s.o.SessionID(r, "")
	} else if sess, ok := s.o.Auth.SessionFromRequest(r); ok {
		hum = sess.HumanID
	}
	if !humanIDRe.MatchString(hum) {
		writeErr(w, http.StatusUnauthorized, "unauthenticated", "sign in first")
		return "", nil, false
	}
	es, ok := s.o.Store.(store.HumanEvents)
	if !ok {
		writeErr(w, http.StatusServiceUnavailable, "unavailable", "this hub keeps no event log")
		return "", nil, false
	}
	return hum, es, true
}

// eventsWrite applies the per-human write window; false = 429 answered.
func (s *Server) eventsWrite(w http.ResponseWriter, hum string) bool {
	max := s.o.EventsWriteLimit
	if max <= 0 {
		max = eventsWritesPerHour
	}
	ok, retry := s.evLim.Allow(hum, max)
	if ok {
		return true
	}
	w.Header().Set("Retry-After", strconv.Itoa(int(retry.Seconds())+1))
	writeErr(w, http.StatusTooManyRequests, "rate_limited", "too many event-log writes")
	s.o.Log.Warn().Str("human_id", hum).Msg("events.rate_limited")
	return false
}

func (s *Server) handleEventsList(w http.ResponseWriter, r *http.Request) {
	hum, es, ok := s.eventsHuman(w, r)
	if !ok {
		return
	}
	q := r.URL.Query()
	limit := eventsPageDefault
	if v := q.Get("limit"); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil || n < 1 {
			writeErr(w, http.StatusBadRequest, "bad_request", "limit must be a positive integer")
			return
		}
		limit = min(n, eventsPageMax)
	}
	var before int64
	if v := q.Get("before"); v != "" {
		n, err := strconv.ParseInt(v, 10, 64)
		if err != nil || n < 1 {
			writeErr(w, http.StatusBadRequest, "bad_request", "before must be a positive event id")
			return
		}
		before = n
	}
	// One extra row says whether an older page exists.
	list, err := es.HumanEventsPage(r.Context(), hum, before, limit+1)
	if err != nil {
		writeErr(w, http.StatusServiceUnavailable, "unavailable", "event store")
		return
	}
	out := struct {
		Events     []eventJSON `json:"events"`
		NextBefore int64       `json:"next_before"`
	}{Events: []eventJSON{}}
	if len(list) > limit {
		list = list[:limit]
		out.NextBefore = list[limit-1].ID
	}
	for _, e := range list {
		out.Events = append(out.Events, toEventJSON(e))
	}
	writeJSON(w, http.StatusOK, out)
}

func (s *Server) handleEventsAdd(w http.ResponseWriter, r *http.Request) {
	hum, es, ok := s.eventsHuman(w, r)
	if !ok || !s.selfKeys(w, r, hum) || !s.eventsWrite(w, hum) {
		return
	}
	var req struct {
		Events []eventInJSON `json:"events"`
	}
	if !readJSONStrict(w, r, &req, eventsMaxBody, "invalid JSON body (only events[] with the events-v1 fields)") {
		return
	}
	if len(req.Events) == 0 || len(req.Events) > eventsBatchMax {
		writeErr(w, http.StatusBadRequest, "bad_request", "events must hold 1.."+strconv.Itoa(eventsBatchMax)+" entries")
		return
	}
	evs := make([]store.HumanEvent, 0, len(req.Events))
	for i, in := range req.Events {
		e := store.HumanEvent{ErrorID: strings.TrimSpace(in.ErrorID), Source: in.Source, Method: in.Method,
			Origin: in.Origin, Path: in.Path, Status: in.Status, Code: in.Code, Message: in.Message, Name: in.Name, Route: in.Route}
		if in.At != "" {
			t, err := time.Parse(time.RFC3339Nano, in.At)
			if err != nil {
				writeErr(w, http.StatusBadRequest, "bad_request", "events["+strconv.Itoa(i)+"].at must be RFC 3339")
				return
			}
			t = t.UTC()
			e.OccurredAt = &t
		}
		if err := store.CheckHumanEvent(e); err != nil {
			writeErr(w, http.StatusBadRequest, "bad_request", "events["+strconv.Itoa(i)+"]: "+err.Error())
			return
		}
		evs = append(evs, e)
	}
	n, err := es.AddHumanEvents(r.Context(), hum, evs, s.o.Now().UTC())
	switch {
	case errors.Is(err, store.ErrNotFound):
		writeErr(w, http.StatusUnauthorized, "unauthenticated", "no such human")
		return
	case err != nil:
		writeErr(w, http.StatusServiceUnavailable, "unavailable", "event store")
		return
	}
	writeJSON(w, http.StatusCreated, map[string]int{"added": n})
}

func (s *Server) handleEventsClear(w http.ResponseWriter, r *http.Request) {
	hum, es, ok := s.eventsHuman(w, r)
	if !ok || !s.selfKeys(w, r, hum) || !s.eventsWrite(w, hum) {
		return
	}
	var req struct{}
	if !readJSONStrict(w, r, &req, keysMaxBody, "invalid JSON body (expected {})") {
		return
	}
	n, err := es.ClearHumanEvents(r.Context(), hum)
	if err != nil {
		writeErr(w, http.StatusServiceUnavailable, "unavailable", "event store")
		return
	}
	s.o.Log.Info().Str("human_id", hum).Int("rows", n).Msg("events.cleared")
	writeJSON(w, http.StatusOK, map[string]int{"cleared": n})
}
