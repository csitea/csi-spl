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

	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// Read-only viewer API for the WUI (specs/003 contracts/view-v1.md, US7).
// GET only; a read never delivers, drains, claims or touches roster/pins
// (FR-019). The browser never uses /v1/ws.

// View door modes (Options.ViewDoor).
const (
	ViewDoorToken = "token" // default: a view token is required (OQ-16)
	ViewDoorOff   = "off"   // lde only (config refuses it elsewhere): no door
	// ViewDoorSession: member sessions only, credentialed CORS (010 FR-009).
	ViewDoorSession = "session"
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
	mux.HandleFunc("GET /v1/view/threads/{task_id}/children", s.viewHandler(s.handleViewChildren))
	s.routeSearch(mux) // search-v1.md
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
// allow-list (FR-021). Never "*"; credentials only in the session door, and
// only for an exact allow-listed origin (010 OQ-A1 (a)).
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
			if s.o.ViewDoor == ViewDoorSession {
				h.Set("Access-Control-Allow-Credentials", "true")
			}
			return true
		}
	}
	return false
}

func (s *Server) preflight(w http.ResponseWriter, r *http.Request) {
	if s.allowOrigin(w, r) {
		h := w.Header()
		h.Set("Access-Control-Allow-Methods", "GET")
		h.Set("Access-Control-Allow-Headers", "Authorization, X-Locale")
		h.Set("Access-Control-Max-Age", "600")
	}
	w.WriteHeader(http.StatusNoContent)
}

// viewHandler resolves the tenant, applies CORS and the view door.
func (s *Server) viewHandler(next func(http.ResponseWriter, *http.Request, store.Tenant)) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		s.allowOrigin(w, r)
		// specs/026: the session's active tenant (the view token format is
		// owner question OQ-16; until it is decided the token door admits
		// nobody, fail closed).
		if t, _, ok := s.humanTenant(w, r); ok {
			next(w, r, t)
		}
	}
}

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
	humans, err := s.viewHumans(r, t.ID)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "roster unavailable")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"boxes": out, "humans": humans})
}

type viewHuman struct {
	HumanID      string  `json:"human_id"`
	AvatarFileID *string `json:"avatar_file_id"`
}

// viewHumans lists the tenant's member HUM-* with the stored IdP picture
// (view-v1 §4.1; 010 T044): a file_id the WUI loads with GET /v1/files/{id}
// on this same tenant host, null = draw the deterministic default. Members
// of this tenant only; a store without the 010 tables lists none.
func (s *Server) viewHumans(r *http.Request, tenant string) ([]viewHuman, error) {
	out := []viewHuman{}
	h, ok := s.o.Store.(store.Humans)
	if !ok {
		return out, nil
	}
	avatars, err := h.TenantAvatars(r.Context(), tenant)
	if err != nil {
		return nil, err
	}
	for id, fid := range avatars {
		v := viewHuman{HumanID: id}
		if fid != "" {
			f := fid
			v.AvatarFileID = &f
		}
		out = append(out, v)
	}
	/* CLE-3425: newest member first, by the HUM-<n> the hub hands out in order
	   (so HUM-10 before HUM-2, which a plain string sort gets backwards). */
	sort.Slice(out, func(i, j int) bool { return humNumber(out[i].HumanID) > humNumber(out[j].HumanID) })
	return out, nil
}

// humNumber is the <n> of a HUM-<n> member id; 0 for anything else (a 010 id
// such as HUM-google-sub-1@t1 keeps a stable a-z position at the tail).
func humNumber(id string) int {
	rest, ok := strings.CutPrefix(id, "HUM-")
	if !ok {
		return 0
	}
	n := 0
	for _, r := range rest {
		if r < '0' || r > '9' {
			return 0
		}
		n = n*10 + int(r-'0')
	}
	return n
}

// handleViewChannels is view-v1 §4.2 / channels-v1 §5.2: every default,
// created and seen channel, with unread against the reader's read= cursors.
func (s *Server) handleViewChannels(w http.ResponseWriter, r *http.Request, t store.Tenant) {
	reads := map[string]store.ReadMark{}
	for _, rd := range r.URL.Query()["read"] {
		id, cur, ok := strings.Cut(rd, "~")
		at, msgID, err := decCursor(cur)
		if !ok || err != nil {
			writeErr(w, http.StatusBadRequest, "bad_cursor", "read must be <channel>~<cursor from this API>")
			return
		}
		reads[store.NormalizeChannel(id)] = store.ReadMark{At: at, MsgID: msgID}
	}
	now := s.o.Now()
	rows, err := s.o.Store.ViewChannelStats(r.Context(), t.ID, now, reads)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "channels unavailable")
		return
	}
	type members struct {
		Agents  int `json:"agents"`
		Boxes   int `json:"boxes"`
		Posters int `json:"posters"`
	}
	type ch struct {
		Channel       string  `json:"channel"`
		Name          string  `json:"name"`
		Default       bool    `json:"default"`
		RetentionDays int     `json:"retention_days"`
		CreatedBy     string  `json:"created_by"`
		CreatedAt     *string `json:"created_at"`
		Count         int     `json:"count"`
		LastTS        *string `json:"last_ts"`
		LastCursor    *string `json:"last_cursor"`
		Unread        int     `json:"unread"`
		Members       members `json:"members"`
	}
	out := []ch{}
	for _, c := range rows {
		v := ch{Channel: c.ChannelID, Name: c.Name, Default: c.Default, CreatedBy: c.CreatedBy,
			RetentionDays: int(s.retention(c.ChannelID) / (24 * time.Hour)), Count: c.Count, Unread: c.Unread,
			Members: members{Agents: c.Agents, Boxes: c.Boxes, Posters: c.Posters}}
		if !c.LastAt.IsZero() {
			ts, cur := rfc(c.LastAt), encCursor(c.LastAt, c.LastMsgID)
			v.LastTS, v.LastCursor = &ts, &cur
		}
		/* CLE-3425: a channel created seconds ago has no message yet, and the
		   client ranks it by this. Rows arrive newest activity first (the store
		   sorts them); created_at is what makes an EMPTY new channel rank. */
		if !c.CreatedAt.IsZero() {
			at := rfc(c.CreatedAt)
			v.CreatedAt = &at
		}
		out = append(out, v)
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
	sq := store.ThreadQuery{Channel: store.NormalizeChannel(q.Get("channel")), Agent: q.Get("agent"),
		Roots: true, Limit: viewLimit(r) + 1, Now: s.o.Now()}
	for name, dst := range map[string]*bool{"roots": &sq.Roots, "dm": &sq.DM} {
		switch q.Get(name) {
		case "":
		case "true":
			*dst = true
		case "false":
			*dst = false
		default:
			writeErr(w, http.StatusBadRequest, "bad_json", name+" must be true or false")
			return
		}
	}
	if p := q.Get("peer"); p != "" { // DMs: an agent id or <id>@<box> (view-v1 §4.3)
		id, box, _ := strings.Cut(p, "@")
		if !msg.ValidID(id) || (box != "" && !msg.ValidBoxID(box)) {
			writeErr(w, http.StatusBadRequest, "bad_json", "peer must be <agent-id> or <agent-id>@<box-id>")
			return
		}
		sq.Agent, sq.AgentBox = id, box
	}
	if sq.DM { // private delivery: a signed-in reader sees only DMs it is party to
		if id, err := s.sessionFor(r, t.ID); err == nil && id != "" {
			sq.Viewer = id
		}
	}
	s.listThreads(w, r, t, sq)
}

// GET /v1/view/threads/{task_id}/children (view-v1 §4.5).
func (s *Server) handleViewChildren(w http.ResponseWriter, r *http.Request, t store.Tenant) {
	task := r.PathValue("task_id")
	if !uuidRe.MatchString(task) {
		writeErr(w, http.StatusNotFound, "not_found", "no such thread")
		return
	}
	s.listThreads(w, r, t, store.ThreadQuery{Parent: task, Limit: viewLimit(r) + 1, Now: s.o.Now()})
}

// listThreads pages one thread-list query (§4.3 shape) with the before= cursor.
func (s *Server) listThreads(w http.ResponseWriter, r *http.Request, t store.Tenant, sq store.ThreadQuery) {
	if c := r.URL.Query().Get("before"); c != "" {
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
	if row.Parent != "" { // the hub-envelope field (channels-v1 §2), never v:1
		p := row.Parent
		v.ParentTaskID = &p
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
		Body string `json:"body"`
	}
	if json.Unmarshal(row.FirstMsg, &first) == nil {
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
	q := r.URL.Query()
	sq := store.ThreadMsgQuery{TaskID: task, Limit: viewLimit(r) + 1, Now: s.o.Now()}
	switch q.Get("order") {
	case "", "asc":
	case "desc":
		sq.Desc = true
	default:
		writeErr(w, http.StatusBadRequest, "bad_json", "order must be asc or desc")
		return
	}
	// after= is the oldest-first catch-up cursor; before= pages newest-first
	// windows backwards (view-v1 §4.4). Each belongs to one order only.
	if c := q.Get("after"); c != "" {
		if sq.Desc {
			writeErr(w, http.StatusBadRequest, "bad_json", "after is for order=asc; use before with order=desc")
			return
		}
		at, id, err := decCursor(c)
		if err != nil {
			writeErr(w, http.StatusBadRequest, "bad_cursor", "after is not a cursor from this API")
			return
		}
		sq.AfterAt, sq.AfterID = at, id
	}
	if c := q.Get("before"); c != "" {
		if !sq.Desc {
			writeErr(w, http.StatusBadRequest, "bad_json", "before is for order=desc; use after with order=asc")
			return
		}
		at, id, err := decCursor(c)
		if err != nil {
			writeErr(w, http.StatusBadRequest, "bad_cursor", "before is not a cursor from this API")
			return
		}
		sq.BeforeAt, sq.BeforeID = at, id
	}
	rows, err := s.o.Store.ViewThread(r.Context(), t.ID, sq)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "thread unavailable")
		return
	}
	if len(rows) == 0 && sq.AfterAt.IsZero() && sq.BeforeAt.IsZero() && task != s.o.LobbyTaskID {
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
