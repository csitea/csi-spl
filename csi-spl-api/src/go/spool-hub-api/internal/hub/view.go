package hub

import (
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/http"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// Read-only viewer API for the WUI (specs/003 contracts/view-v1.md, US7).
// GET only; a read never delivers, drains, claims or touches roster/pins
// (FR-019). The browser never uses /v1/ws.

// View door modes (Options.ViewDoor).
const (
	ViewDoorToken = "token" // default: a view token is required (OQ-16)
	ViewDoorOff   = "off"   // lde only (config refuses it elsewhere): no door
)

const (
	viewLimitDefault = 50
	viewLimitMax     = 200
	subjectMax       = 140
)

var uuidRe = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`)

func (s *Server) routeView(mux *http.ServeMux) {
	mux.HandleFunc("GET /v1/view/roster", s.viewHandler(s.handleViewRoster))
	mux.HandleFunc("GET /v1/view/channels", s.viewHandler(s.handleViewChannels))
	mux.HandleFunc("GET /v1/view/threads", s.viewHandler(s.handleViewThreads))
	mux.HandleFunc("GET /v1/view/threads/{task_id}", s.viewHandler(s.handleViewThread))
	mux.HandleFunc("/v1/view/", func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodOptions {
			s.preflight(w, r)
			return
		}
		if r.Method == http.MethodGet || r.Method == http.MethodHead {
			writeErr(w, http.StatusNotFound, "not_found", "no such view")
			return
		}
		w.Header().Set("Allow", "GET, OPTIONS")
		writeErr(w, http.StatusMethodNotAllowed, "method_not_allowed", "the viewer API is read-only")
	})
	mux.HandleFunc("OPTIONS /v1/files/{file_id}", s.filesPreflight)
}

// allowOrigin sets the CORS response headers when Origin is on the cnf
// allow-list (FR-021). Never "*", never credentials.
func (s *Server) allowOrigin(w http.ResponseWriter, r *http.Request) bool {
	o := r.Header.Get("Origin")
	if o == "" {
		return false
	}
	for _, a := range s.o.ViewCORSOrigins {
		if o == a {
			h := w.Header()
			h.Set("Access-Control-Allow-Origin", o)
			h.Add("Vary", "Origin")
			return true
		}
	}
	return false
}

func (s *Server) preflight(w http.ResponseWriter, r *http.Request) {
	if s.allowOrigin(w, r) {
		h := w.Header()
		h.Set("Access-Control-Allow-Methods", "GET")
		h.Set("Access-Control-Allow-Headers", "Authorization")
		h.Set("Access-Control-Max-Age", "600")
	}
	w.WriteHeader(http.StatusNoContent)
}

// viewHandler resolves the tenant, applies CORS and the view door.
func (s *Server) viewHandler(next func(http.ResponseWriter, *http.Request, store.Tenant)) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		s.allowOrigin(w, r)
		t, err := s.tenantOf(r)
		if err != nil {
			writeErr(w, http.StatusNotFound, "unknown_tenant", "no tenant for this host")
			return
		}
		if s.o.ViewDoor == ViewDoorOff || s.sessionMayRead(r, t.ID) {
			next(w, r, t)
			return
		}
		// The view token format is owner question OQ-16; until it is decided
		// the token door admits nobody (fail closed).
		writeErr(w, http.StatusUnauthorized, "view_door", "a view token or a member session is required")
	}
}

// sessionMayRead is the M3 session door (view-v1 §2, OQ-A1): a signed-in human
// who is a member of the Host tenant. Every auth error (no session, no HUM-*,
// no membership check configured, not a member) refuses — fail closed.
// sessionFor returns the HUM-* id of a member session of tenant, or "".
func (s *Server) sessionFor(r *http.Request, tenant string) (string, error) {
	if s.o.Auth == nil {
		return "", nil
	}
	sess, err := s.o.Auth.SessionForTenant(r, tenant)
	if err != nil {
		return "", err
	}
	return sess.HumanID, nil
}

func (s *Server) sessionMayRead(r *http.Request, tenant string) bool {
	if s.o.Auth == nil {
		return false
	}
	_, err := s.o.Auth.SessionForTenant(r, tenant)
	return err == nil
}

// ---- cursors ------------------------------------------------------------------

func encCursor(at time.Time, id string) string {
	return base64.RawURLEncoding.EncodeToString([]byte(at.UTC().Format(time.RFC3339Nano) + "|" + id))
}

func decCursor(c string) (time.Time, string, error) {
	b, err := base64.RawURLEncoding.DecodeString(c)
	if err != nil {
		return time.Time{}, "", err
	}
	ts, id, ok := strings.Cut(string(b), "|")
	if !ok || id == "" {
		return time.Time{}, "", errors.New("cursor")
	}
	at, err := time.Parse(time.RFC3339Nano, ts)
	return at, id, err
}

func viewLimit(r *http.Request) int {
	n, err := strconv.Atoi(r.URL.Query().Get("limit"))
	switch {
	case err != nil || n <= 0:
		return viewLimitDefault
	case n > viewLimitMax:
		return viewLimitMax
	}
	return n
}

func rfc(t time.Time) string { return t.UTC().Format(time.RFC3339Nano) }

// ---- handlers ------------------------------------------------------------------

type viewBox struct {
	BoxID       string   `json:"box_id"`
	PubKey      string   `json:"pubkey"`
	Revoked     bool     `json:"revoked"`
	LastHelloAt *string  `json:"last_hello_at"`
	Online      bool     `json:"online"`
	Agents      []string `json:"agents"`
}

func (s *Server) handleViewRoster(w http.ResponseWriter, r *http.Request, t store.Tenant) {
	boxes, err := s.o.Store.ViewBoxes(r.Context(), t.ID)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "roster unavailable")
		return
	}
	out := []viewBox{}
	for _, b := range boxes {
		v := viewBox{BoxID: b.BoxID, PubKey: base64.StdEncoding.EncodeToString(b.PubKey), Revoked: b.Revoked, Agents: b.Agents}
		if v.Agents == nil {
			v.Agents = []string{}
		}
		if !b.LastHelloAt.IsZero() {
			at := rfc(b.LastHelloAt)
			v.LastHelloAt = &at
		}
		if !b.Revoked {
			s.mu.Lock()
			v.Online = s.boxes[[2]string{t.ID, b.BoxID}] != nil
			s.mu.Unlock()
		}
		out = append(out, v)
	}
	writeJSON(w, http.StatusOK, map[string]any{"boxes": out})
}

func (s *Server) handleViewChannels(w http.ResponseWriter, r *http.Request, t store.Tenant) {
	rows, err := s.o.Store.ViewChannels(r.Context(), t.ID, s.o.Now())
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "channels unavailable")
		return
	}
	type ch struct {
		Channel string `json:"channel"`
		Count   int    `json:"count"`
		LastTS  string `json:"last_ts"`
	}
	out := []ch{}
	for _, c := range rows {
		out = append(out, ch{Channel: c.Channel, Count: c.Count, LastTS: rfc(c.LastAt)})
	}
	writeJSON(w, http.StatusOK, map[string]any{"channels": out})
}

type viewThread struct {
	TaskID       string         `json:"task_id"`
	ParentTaskID *string        `json:"parent_task_id"`
	Channel      *string        `json:"channel"`
	FirstTS      string         `json:"first_ts"`
	LastTS       string         `json:"last_ts"`
	Count        int            `json:"count"`
	Kinds        map[string]int `json:"kinds"`
	Participants []string       `json:"participants"`
	Subject      string         `json:"subject"`
}

func (s *Server) handleViewThreads(w http.ResponseWriter, r *http.Request, t store.Tenant) {
	q := r.URL.Query()
	sq := store.ThreadQuery{Channel: q.Get("channel"), Agent: q.Get("agent"), Limit: viewLimit(r) + 1, Now: s.o.Now()}
	if c := q.Get("before"); c != "" {
		at, id, err := decCursor(c)
		if err != nil {
			writeErr(w, http.StatusBadRequest, "bad_cursor", "before is not a cursor from this API")
			return
		}
		sq.BeforeAt, sq.BeforeTask = at, id
	}
	rows, err := s.o.Store.ViewThreads(r.Context(), t.ID, sq)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "threads unavailable")
		return
	}
	var next *string
	if len(rows) == sq.Limit {
		rows = rows[:sq.Limit-1]
		c := encCursor(rows[len(rows)-1].LastAt, rows[len(rows)-1].TaskID)
		next = &c
	}
	out := []viewThread{}
	for _, row := range rows {
		out = append(out, threadView(row))
	}
	writeJSON(w, http.StatusOK, map[string]any{"threads": out, "next": next})
}

func threadView(row store.ThreadRow) viewThread {
	v := viewThread{TaskID: row.TaskID, FirstTS: rfc(row.FirstAt), LastTS: rfc(row.LastAt),
		Count: row.Count, Kinds: map[string]int{}}
	if row.Channel != "" {
		c := row.Channel
		v.Channel = &c
	}
	for _, k := range row.Kinds {
		v.Kinds[k]++
	}
	seen := map[string]bool{}
	for _, p := range row.Parties {
		if !seen[p] {
			seen[p] = true
			v.Participants = append(v.Participants, p)
		}
	}
	sort.Strings(v.Participants)
	var first struct {
		Body         string `json:"body"`
		ParentTaskID string `json:"parent_task_id"`
	}
	if json.Unmarshal(row.FirstMsg, &first) == nil {
		if first.ParentTaskID != "" {
			p := first.ParentTaskID
			v.ParentTaskID = &p
		}
		v.Subject = subject(first.Body)
	}
	return v
}

// subject is the first line of body, at most subjectMax runes.
func subject(body string) string {
	line, _, _ := strings.Cut(body, "\n")
	line = strings.TrimSpace(line)
	if utf8.RuneCountInString(line) > subjectMax {
		line = string([]rune(line)[:subjectMax])
	}
	return line
}

type viewDelivery struct {
	ToBox string `json:"to_box"`
	State string `json:"state"`
}

type viewMsg struct {
	Cursor     string          `json:"cursor"`
	ReceivedAt string          `json:"received_at"`
	Env        json.RawMessage `json:"env"`
	Deliveries []viewDelivery  `json:"deliveries"`
}

func (s *Server) handleViewThread(w http.ResponseWriter, r *http.Request, t store.Tenant) {
	task := r.PathValue("task_id")
	if !uuidRe.MatchString(task) {
		writeErr(w, http.StatusNotFound, "not_found", "no such thread")
		return
	}
	sq := store.ThreadMsgQuery{TaskID: task, Limit: viewLimit(r) + 1, Now: s.o.Now()}
	if c := r.URL.Query().Get("after"); c != "" {
		at, id, err := decCursor(c)
		if err != nil {
			writeErr(w, http.StatusBadRequest, "bad_cursor", "after is not a cursor from this API")
			return
		}
		sq.AfterAt, sq.AfterID = at, id
	}
	rows, err := s.o.Store.ViewThread(r.Context(), t.ID, sq)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "thread unavailable")
		return
	}
	if len(rows) == 0 && sq.AfterAt.IsZero() && task != s.o.LobbyTaskID {
		// the lobby exists before its first post (wui-live-ws.md §1)
		writeErr(w, http.StatusNotFound, "not_found", "no such thread")
		return
	}
	var next *string
	if len(rows) == sq.Limit {
		rows = rows[:sq.Limit-1]
		c := encCursor(rows[len(rows)-1].ReceivedAt, rows[len(rows)-1].MsgID)
		next = &c
	}
	out := []viewMsg{}
	for _, m := range rows {
		v := viewMsg{Cursor: encCursor(m.ReceivedAt, m.MsgID), ReceivedAt: rfc(m.ReceivedAt),
			Env: json.RawMessage(m.Env), Deliveries: []viewDelivery{}}
		for _, d := range m.Deliveries {
			v.Deliveries = append(v.Deliveries, viewDelivery{ToBox: d.ToBox, State: d.State})
		}
		out = append(out, v)
	}
	writeJSON(w, http.StatusOK, map[string]any{"task_id": task, "messages": out, "next": next})
}
