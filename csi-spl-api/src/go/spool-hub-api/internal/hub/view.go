package hub

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/http"
	"net/url"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
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
	mux.HandleFunc("GET /v1/view/topics", s.viewHandler(s.handleViewTopics))
	mux.HandleFunc("GET /v1/view/topics/{task_id}", s.viewHandler(s.handleViewTopic))
	mux.HandleFunc("GET /v1/view/topics/{task_id}/children", s.viewHandler(s.handleViewChildren))
	mux.HandleFunc("GET /v1/view/locate/{id}", s.handleViewLocate)               // SPL-959 old links
	mux.HandleFunc("GET /v1/view/archived", s.viewHandler(s.handleViewArchived)) // specs/041
	mux.HandleFunc("GET /v1/view/messages/{msg_id}/topic", s.handleViewTopicSize)
	mux.HandleFunc("GET /v1/view/messages/{msg_id}/move", s.handleViewMove) // specs/045
	s.routeSearch(mux)                                                      // search-v1.md
	s.routeAgentAliases(mux)                                                // spec 061
	mux.HandleFunc("GET /v1/me/reads", s.handleReadMarks)                   // CLE-77930, rdb 0098
	mux.HandleFunc("PUT /v1/me/reads", s.handleReadMarks)
	mux.HandleFunc("OPTIONS /v1/me/reads", s.readMarksPreflight)
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
	if !s.originAllowed(o) {
		return false
	}
	h := w.Header()
	h.Set("Access-Control-Allow-Origin", o)
	h.Add("Vary", "Origin")
	if s.o.ViewDoor == ViewDoorSession {
		h.Set("Access-Control-Allow-Credentials", "true")
	}
	return true
}

// corsMaxAge is how long a browser may reuse a CORS preflight answer: the
// longest Chrome honours (2 h; Firefox allows 24 h). At 600 s nearly every
// write after ten quiet minutes paid an extra OPTIONS round trip first (prd
// 24 h to 2026-09-28: 67 OPTIONS for 63 POST /api/v1/auth/events). A browser
// re-asks on its own whenever a request needs a method or header the cached
// answer did not list, so a longer life never admits anything new.
const corsMaxAge = "7200"

func (s *Server) preflight(w http.ResponseWriter, r *http.Request) {
	if s.allowOrigin(w, r) {
		h := w.Header()
		h.Set("Access-Control-Allow-Methods", "GET")
		h.Set("Access-Control-Allow-Headers", "Authorization, X-Locale")
		h.Set("Access-Control-Max-Age", corsMaxAge)
	}
	w.WriteHeader(http.StatusNoContent)
}

// viewHandler resolves the tenant, applies CORS and the view door.
func (s *Server) viewHandler(next func(http.ResponseWriter, *http.Request, store.Tenant)) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		// A view is a read: the door, the permit and the handler share one
		// membership lookup (store.WithMemo).
		r = r.WithContext(store.WithMemo(r.Context()))
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

// parseTriBool applies a "true"/"false"/absent query flag to dst, writing 400
// and returning false on anything else. It replaces a per-request
// map[string]*bool literal that existed only to loop over two flags.
func parseTriBool(w http.ResponseWriter, v, name string, dst *bool) bool {
	switch v {
	case "":
	case "true":
		*dst = true
	case "false":
		*dst = false
	default:
		writeErr(w, http.StatusBadRequest, "bad_json", name+" must be true or false")
		return false
	}
	return true
}

// ---- handlers ------------------------------------------------------------------

type viewBox struct {
	BoxID       string   `json:"box_id"`
	PubKey      string   `json:"pubkey"`
	Revoked     bool     `json:"revoked"`
	LastHelloAt *string  `json:"last_hello_at"`
	Online      bool     `json:"online"`
	Agents      []string `json:"agents"`
}

// rosterBody is GET /v1/view/roster (view-v1 §4.1). A typed envelope, not a
// map[string]any: json encodes a struct through a cached field encoder with no
// map allocation and no per-key interface boxing.
type rosterBody struct {
	Boxes  []viewBox   `json:"boxes"`
	Humans []viewHuman `json:"humans"`
}

func (s *Server) handleViewRoster(w http.ResponseWriter, r *http.Request, t store.Tenant) {
	rs, err := s.readRoster(r.Context(), t.ID)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "roster unavailable")
		return
	}
	// Online presence for every box under ONE hub-mutex hold (map reads only),
	// so the mutex that also guards routing is not taken once per box and never
	// held across the base64 / time formatting below.
	online := make([]bool, len(rs.Boxes))
	s.mu.Lock()
	for i, b := range rs.Boxes {
		if !b.Revoked {
			online[i] = s.boxes[[2]string{t.ID, b.BoxID}] != nil
		}
	}
	s.mu.Unlock()
	out := make([]viewBox, 0, len(rs.Boxes))
	for i, b := range rs.Boxes {
		v := viewBox{BoxID: b.BoxID, PubKey: base64.StdEncoding.EncodeToString(b.PubKey), Revoked: b.Revoked, Agents: b.Agents, Online: online[i]}
		if v.Agents == nil {
			v.Agents = []string{}
		}
		if !b.LastHelloAt.IsZero() {
			at := rfc(b.LastHelloAt)
			v.LastHelloAt = &at
		}
		out = append(out, v)
	}
	writeJSON(w, http.StatusOK, rosterBody{Boxes: out, Humans: viewHumans(rs)})
}

// readRoster is the roster's three reads: in ONE store call when the store
// batches them (store.RosterReader, SPL-1111: one round trip, it was three),
// else one by one. A store without the 010 tables has no avatars (and so
// lists no humans); one without a member directory names no one.
func (s *Server) readRoster(ctx context.Context, tenant string) (rs store.Roster, err error) {
	if rr, ok := s.o.Store.(store.RosterReader); ok {
		return rr.ViewRoster(ctx, tenant)
	}
	if rs.Boxes, err = s.o.Store.ViewBoxes(ctx, tenant); err != nil {
		return rs, err
	}
	if h, ok := s.o.Store.(store.Humans); ok {
		if rs.Avatars, err = h.TenantAvatars(ctx, tenant); err != nil {
			return rs, err
		}
	}
	if md, ok := s.o.Store.(store.MemberDirectory); ok {
		rs.Members, err = md.ListMembers(ctx, tenant)
	}
	return rs, err
}

type viewHuman struct {
	HumanID      string  `json:"human_id"`
	AvatarFileID *string `json:"avatar_file_id"`
	// DisplayName is the name the human chose (humans.display_name, set in
	// Settings > Profile); null = none, and the WUI shows the member id.
	DisplayName *string `json:"display_name"`
	// Owner marks a business owner (role biz_owner): the member the WUI
	// always offers in the #feedback @ picker, online or not (owner,
	// 2026-09-25). Omitted for everyone else; the roster never exposes any
	// other role (TestViewRosterHumanOwnerFlag), so the People card shows only
	// this coarse owner/member distinction, not the RBAC role.
	Owner bool `json:"owner,omitempty"`
	// Interests is the member's free-text interests (humans.interests, rdb
	// 0086); omitted when none. Every tenant member reads it (People card).
	Interests *string `json:"interests,omitempty"`
	// LastSeen is when the member last switched into this tenant
	// (tenant_memberships.last_active_at); omitted when never. Like the online
	// flag it is presence, not a role, so it is not covered by the role guard.
	LastSeen *string `json:"last_seen,omitempty"`
}

// viewHumans lists the tenant's member HUM-* with the stored IdP picture
// (view-v1 §4.1; 010 T044): a file_id the WUI loads with GET /v1/files/{id}
// on this same tenant host, null = draw the deterministic default. Members
// of this tenant only; a store without the 010 tables lists none.
func viewHumans(rs store.Roster) []viewHuman {
	out := make([]viewHuman, 0, len(rs.Avatars))
	names := map[string]string{}
	owners := map[string]bool{}
	byID := make(map[string]store.Member, len(rs.Members))
	for _, m := range rs.Members {
		names[m.HumanID] = strings.TrimSpace(m.DisplayName)
		if m.Role == rbac.BizOwner && !m.Disabled {
			owners[m.HumanID] = true
		}
		byID[m.HumanID] = m
	}
	for id, fid := range rs.Avatars {
		v := viewHuman{HumanID: id}
		if fid != "" {
			f := fid
			v.AvatarFileID = &f
		}
		if n := names[id]; n != "" {
			v.DisplayName = &n
		}
		v.Owner = owners[id]
		if m, ok := byID[id]; ok {
			if s := strings.TrimSpace(m.Interests); s != "" {
				v.Interests = &s
			}
			if !m.LastSeen.IsZero() {
				at := rfc(m.LastSeen)
				v.LastSeen = &at
			}
		}
		out = append(out, v)
	}
	/* newest member first, by the HUM-<n> the hub hands out in order
	   (so HUM-10 before HUM-2, which a plain string sort gets backwards). */
	sort.Slice(out, func(i, j int) bool { return humNumber(out[i].HumanID) > humNumber(out[j].HumanID) })
	return out
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
	reads, ok := parseReadMarks(r.URL.Query()["read"])
	if !ok {
		writeErr(w, http.StatusBadRequest, "bad_cursor", "read must be <channel>~<cursor from this API>")
		return
	}
	// CLE-77889: the reader's own lines are never unread for them (store.OwnLine)
	hum, member := s.readerID(r, t.ID)
	var rows []store.ChannelStat
	err := errChannelsDoor
	if member {
		rows, err = s.o.Store.ViewChannelStats(r.Context(), t.ID, s.o.Now(), reads, hum, s.o.LobbyTaskID)
	}
	if err == nil {
		rows, err = s.visibleChannels(r.Context(), t.ID, hum, rows)
	}
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "channels unavailable")
		return
	}
	out := make([]viewChannel, 0, len(rows))
	for _, c := range rows {
		out = append(out, s.toViewChannel(c))
	}
	writeJSON(w, http.StatusOK, channelsBody{Channels: out})
}

// parseReadMarks reads the read=<channel>~<cursor> marks, keyed by the
// normalized channel; false when one is malformed.
func parseReadMarks(marks []string) (map[string]store.ReadMark, bool) {
	reads := map[string]store.ReadMark{}
	for _, rd := range marks {
		id, cur, ok := strings.Cut(rd, "~")
		at, msgID, err := decCursor(cur)
		if !ok || err != nil {
			return nil, false
		}
		reads[store.NormalizeChannel(id)] = store.ReadMark{At: at, MsgID: msgID}
	}
	return reads, true
}

// errChannelsDoor is a reader lookup that failed: the listing fails closed.
var errChannelsDoor = errors.New("channels: reader unavailable")

// visibleChannels is the read door (rdb 0028): a created channel the reader
// is not in is omitted entirely - not greyed out, not listed as joinable. Its
// name and description are as private as its messages.
func (s *Server) visibleChannels(ctx context.Context, tenant, hum string, rows []store.ChannelStat) ([]store.ChannelStat, error) {
	if hum == "" {
		return rows, nil
	}
	mine, err := s.readerChannels(ctx, tenant, hum)
	if err != nil {
		return nil, err
	}
	in := map[string]bool{}
	for _, c := range mine {
		in[c] = true
	}
	kept := rows[:0]
	for _, c := range rows {
		if store.ChannelPublic(c.ChannelID) || in[c.ChannelID] {
			kept = append(kept, c)
		}
	}
	return kept, nil
}

// viewChannel is one row of GET /v1/view/channels.
type viewChannel struct {
	Channel           string         `json:"channel"`
	Name              string         `json:"name"`
	Description       string         `json:"description"`
	MembersOpenInvite bool           `json:"members_open_invite"`
	Default           bool           `json:"default"`
	RetentionDays     int            `json:"retention_days"`
	CreatedBy         string         `json:"created_by"`
	CreatedAt         *string        `json:"created_at"`
	Count             int            `json:"count"`
	LastTS            *string        `json:"last_ts"`
	LastCursor        *string        `json:"last_cursor"`
	Unread            int            `json:"unread"`
	Members           channelMembers `json:"members"`
}

type channelMembers struct {
	Agents  int `json:"agents"`
	Boxes   int `json:"boxes"`
	Posters int `json:"posters"`
}

func (s *Server) toViewChannel(c store.ChannelStat) viewChannel {
	v := viewChannel{Channel: c.ChannelID, Name: c.Name, Description: c.Description, MembersOpenInvite: c.MembersOpenInvite, Default: c.Default, CreatedBy: c.CreatedBy,
		RetentionDays: int(s.retention(c.ChannelID) / (24 * time.Hour)), Count: c.Count, Unread: c.Unread,
		Members: channelMembers{Agents: c.Agents, Boxes: c.Boxes, Posters: c.Posters}}
	if !c.LastAt.IsZero() {
		ts, cur := rfc(c.LastAt), encCursor(c.LastAt, c.LastMsgID)
		v.LastTS, v.LastCursor = &ts, &cur
	}
	/* a channel created seconds ago has no message yet, and the
	   client ranks it by this. Rows arrive newest activity first (the store
	   sorts them); created_at is what makes an EMPTY new channel rank. */
	if !c.CreatedAt.IsZero() {
		at := rfc(c.CreatedAt)
		v.CreatedAt = &at
	}
	return v
}

type viewTopic struct {
	TaskID       string         `json:"task_id"`
	ParentTaskID *string        `json:"parent_task_id"`
	Channel      *string        `json:"channel"`
	FirstTS      string         `json:"first_ts"`
	LastTS       string         `json:"last_ts"`
	Count        int            `json:"count"`
	Kinds        map[string]int `json:"kinds"`
	Participants []string       `json:"participants"`
	Subject      string         `json:"subject"`
	// per_topic=N only: the topic's newest N messages, exactly
	// GET /v1/view/topics/{task_id}?order=desc&limit=N, and that read's next.
	Messages     *[]viewMsg `json:"messages,omitempty"`
	MessagesNext *string    `json:"messages_next,omitempty"`
	// dm_counts=true only: the reader's per-peer DM unread and total
	// (view_dm_counts.go), so the DM seed needs no per_topic page.
	DM *viewDMCounts `json:"dm,omitempty"`
}

// Typed envelopes for the hottest view reads (channels, topics, one topic
// page), instead of map[string]any: json encodes a struct through a cached
// field encoder with no map allocation and no per-key interface boxing.
type channelsBody struct {
	Channels []viewChannel `json:"channels"`
}

type topicsBody struct {
	Topics []viewTopic `json:"topics"`
	Next   *string     `json:"next"`
	// since= only (view_delta.go): true = only the changed topics, false =
	// the full page.
	Delta     *bool    `json:"delta,omitempty"`
	GoneTasks []string `json:"gone_tasks,omitempty"`
	GoneMsgs  []string `json:"gone_msgs,omitempty"`
	// Sync is the hub's clock at this read as a cursor: the next since= may
	// start here, so a change already caught up is not sent again.
	Sync *string `json:"sync,omitempty"`
}

type topicBody struct {
	TaskID   string    `json:"task_id"`
	Messages []viewMsg `json:"messages"`
	Next     *string   `json:"next"`
}

// perTopicMax caps per_topic: a page of viewLimitMax topics at this many
// messages each is the most one read returns.
const perTopicMax = 50

func (s *Server) handleViewTopics(w http.ResponseWriter, r *http.Request, t store.Tenant) {
	q := r.URL.Query()
	sq := store.TopicQuery{Channel: store.NormalizeChannel(q.Get("channel")), Agent: q.Get("agent"),
		Roots: true, NoIssues: true, Limit: viewLimit(r) + 1, Now: s.o.Now()} // specs/039: issue talk stays in its issue
	// No map[string]*bool literal per request: parse the two tri-state flags directly.
	if !parseTriBool(w, q.Get("roots"), "roots", &sq.Roots) || !parseTriBool(w, q.Get("dm"), "dm", &sq.DM) {
		return
	}
	if p := q.Get("peer"); p != "" { // DMs: an agent id or <id>@<box> (view-v1 §4.3)
		id, box, _ := strings.Cut(p, "@")
		if !msg.ValidID(id) || (box != "" && !msg.ValidBoxID(box)) {
			writeErr(w, http.StatusBadRequest, "bad_json", "peer must be <agent-id> or <agent-id>@<box-id>")
			return
		}
		sq.Agent, sq.AgentBox = id, box
	}
	// The read door (rdb 0028, privacy.go): a signed-in reader sees the
	// channels it is in plus the DMs it is an end of, and nothing else. This
	// used to run only under dm=true, so an unfiltered list handed every
	// topic of the tenant - DMs included - to any member.
	hum, ok := s.readerID(r, t.ID)
	if !ok {
		writeErr(w, http.StatusInternalServerError, "internal", "topics unavailable")
		return
	}
	// specs/054 (owner 18597eaa: "no of course"): an act-as clone never opens
	// the person's DMs. The DM-list surfaces (dm=true, peer=<id>) refuse it; the
	// unfiltered list already drops DMs the reader is not an end of, and a clone
	// is an end of none.
	if (sq.DM || q.Get("peer") != "") && s.readerIsActAsClone(r.Context(), t.ID, hum) {
		writeErr(w, http.StatusForbidden, "actas_no_dm", "acting-as sessions cannot open direct messages")
		return
	}
	if sq.DM { // dm=true is the explicit "only my DMs" filter, on top of it
		sq.Viewer = hum
	}
	if !s.readerScope(w, r, t.ID, hum, &sq) {
		return
	}
	s.listTopics(w, r, t, sq)
}

// GET /v1/view/topics/{task_id}/children (view-v1 §4.5).
func (s *Server) handleViewChildren(w http.ResponseWriter, r *http.Request, t store.Tenant) {
	task := r.PathValue("task_id")
	if !uuidRe.MatchString(task) {
		writeErr(w, http.StatusNotFound, "not_found", "no such topic")
		return
	}
	hum, ok := s.readerID(r, t.ID)
	if !ok {
		writeErr(w, http.StatusInternalServerError, "internal", "topics unavailable")
		return
	}
	// A parent you cannot read does not exist, so neither do its children -
	// listing them would leak the subjects of a private channel by uuid.
	switch ok, found, err := s.canReadTopic(r.Context(), t.ID, task, hum); {
	case err != nil:
		writeErr(w, http.StatusInternalServerError, "internal", "topics unavailable")
		return
	case found && !ok:
		writeErr(w, http.StatusNotFound, "not_found", "no such topic")
		return
	}
	sq := store.TopicQuery{Parent: task, Limit: viewLimit(r) + 1, Now: s.o.Now()}
	if !s.readerScope(w, r, t.ID, hum, &sq) {
		return
	}
	s.listTopics(w, r, t, sq)
}

// readerScope loads hum's channel allow-list into sq. false = it answered.
func (s *Server) readerScope(w http.ResponseWriter, r *http.Request, tenant, hum string, sq *store.TopicQuery) bool {
	if hum == "" {
		return true
	}
	chans, err := s.readerChannels(r.Context(), tenant, hum)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "topics unavailable")
		return false
	}
	sq.Reader, sq.ReaderChannels = hum, chans
	return true
}

// listTopics pages one topic-list query (§4.3 shape) with the before= cursor.
func (s *Server) listTopics(w http.ResponseWriter, r *http.Request, t store.Tenant, sq store.TopicQuery) {
	per := 0
	if v := r.URL.Query().Get("per_topic"); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil || n < 1 || n > perTopicMax {
			writeErr(w, http.StatusBadRequest, "bad_json", "per_topic must be 1.."+strconv.Itoa(perTopicMax))
			return
		}
		per = n
	}
	counts, reads, ok := dmCountsWanted(w, r)
	if !ok {
		return
	}
	if c := r.URL.Query().Get("before"); c != "" {
		at, id, err := decCursor(c)
		if err != nil {
			writeErr(w, http.StatusBadRequest, "bad_cursor", "before is not a cursor from this API")
			return
		}
		sq.BeforeAt, sq.BeforeTask = at, id
	}
	sq.Lobby = s.o.LobbyTaskID // specs/041: archived topics leave every list
	body, ok := s.deltaScope(w, r, t, &sq)
	if !ok {
		return
	}
	var rows []store.TopicRow
	var err error
	if body.Delta == nil || !*body.Delta || len(sq.TaskIDs) > 0 { // a delta with no change reads nothing
		rows, err = s.o.Store.ViewTopics(r.Context(), t.ID, sq)
	}
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "topics unavailable")
		return
	}
	var next *string
	if len(rows) == sq.Limit {
		rows = rows[:sq.Limit-1]
		c := encCursor(rows[len(rows)-1].LastAt, rows[len(rows)-1].TaskID)
		next = &c
	}
	out := make([]viewTopic, 0, len(rows))
	for _, row := range rows {
		out = append(out, topicView(row))
	}
	if per > 0 && !s.inlineMessages(w, r, t, sq, per, out) {
		return
	}
	if counts && !s.attachDMCounts(w, r, t, sq, reads, out) {
		return
	}
	body.Topics, body.Next = out, next
	writeJSON(w, http.StatusOK, body)
}

// deltaScope applies since= (view_delta.go) to sq: a delta lists only the
// changed topics, with no page cursor. The body carries the delta flag and
// the gone lists; ok false = it answered.
func (s *Server) deltaScope(w http.ResponseWriter, r *http.Request, t store.Tenant, sq *store.TopicQuery) (topicsBody, bool) {
	var body topicsBody
	d, ok := parseTopicsDelta(w, r)
	if !ok || d == nil {
		return body, ok
	}
	a, err := s.readDelta(r.Context(), t.ID, *sq, d)
	if err != nil {
		s.o.Log.Error().Err(err).Str("tenant", t.ID).Msg("topics since")
		writeErr(w, http.StatusInternalServerError, "internal", "topics unavailable")
		return body, false
	}
	delta, sync := a != nil, encCursor(sq.Now, "sync")
	body.Delta, body.Sync = &delta, &sync
	if a != nil {
		sq.TaskIDs, sq.Limit = a.tasks, len(a.tasks)+1 // never a next page
		body.GoneTasks, body.GoneMsgs = a.goneTasks, a.goneMsgs
	}
	return body, true
}

// inlineMessages fills each topic's newest per messages (per_topic=,
// CLE-34985): one read for the whole page where the WUI made one request per
// topic. The reader door is sq's, applied per message as ViewTopic applies
// it. false = it answered with an error.
func (s *Server) inlineMessages(w http.ResponseWriter, r *http.Request, t store.Tenant, sq store.TopicQuery, per int, out []viewTopic) bool {
	ids := make([]string, len(out))
	for i := range out {
		ids[i] = out[i].TaskID
	}
	var msgs map[string][]store.ViewMsg
	var react map[string][]store.StoredReaction
	var err error
	if b, ok := s.o.Store.(store.TopicsMessager); ok {
		msgs, react, err = b.ViewTopicsMessages(r.Context(), t.ID, store.TopicsMsgQuery{TaskIDs: ids, PerTopic: per + 1,
			Reader: sq.Reader, ReaderChannels: sq.ReaderChannels, HideArchivedIn: s.o.LobbyTaskID, Now: sq.Now})
	} else {
		msgs, react = map[string][]store.ViewMsg{}, map[string][]store.StoredReaction{}
		for _, id := range ids {
			var rows []store.ViewMsg
			if rows, err = s.o.Store.ViewTopic(r.Context(), t.ID, store.TopicMsgQuery{TaskID: id, Desc: true, Limit: per + 1,
				Reader: sq.Reader, ReaderChannels: sq.ReaderChannels, HideArchived: id == s.o.LobbyTaskID && id != "", Now: sq.Now}); err != nil {
				break
			}
			msgs[id] = rows
			mids := make([]string, len(rows))
			for i := range rows {
				mids[i] = rows[i].MsgID
			}
			var rr map[string][]store.StoredReaction
			if rr, err = s.o.Store.ReactionsFor(r.Context(), t.ID, mids); err != nil {
				break
			}
			for k, v := range rr {
				react[k] = v
			}
		}
	}
	if err != nil {
		s.o.Log.Error().Err(err).Str("tenant", t.ID).Msg("topics per_topic")
		writeErr(w, http.StatusInternalServerError, "internal", "topics unavailable")
		return false
	}
	for i := range out {
		rows := msgs[out[i].TaskID]
		if len(rows) > per {
			rows = rows[:per]
			c := encCursor(rows[per-1].ReceivedAt, rows[per-1].MsgID)
			out[i].MessagesNext = &c
		}
		vs := viewMsgsIn(rows, react, out[i].TaskID)
		out[i].Messages = &vs
	}
	return true
}

func topicView(row store.TopicRow) viewTopic {
	v := viewTopic{TaskID: row.TaskID, FirstTS: rfc(row.FirstAt), LastTS: rfc(row.LastAt),
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
	// Dedup the (small) party list by scanning what is kept, not with a
	// throwaway map[string]bool allocated for every one of up to 50 topics on a
	// topics page.
	v.Participants = make([]string, 0, len(row.Parties))
	for _, p := range row.Parties {
		dup := false
		for _, q := range v.Participants {
			if q == p {
				dup = true
				break
			}
		}
		if !dup {
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
	Cursor     string `json:"cursor"`
	ReceivedAt string `json:"received_at"`
	// DB payload cut 4: env leaves out sig, an empty msg.files and a
	// msg.task_id equal to the topic's (trimEnv). The WUI defaults each one.
	Env json.RawMessage `json:"env"`
	// Omitted when it is exactly the default [box-wui sent] (viewDeliveries);
	// [] stays [] - a message with no delivery at all is not the default.
	Deliveries *[]viewDelivery `json:"deliveries,omitempty"`
	// specs/032 §2.1: omitted entirely while the message has never been
	// edited, so a reload renders the marker exactly as the live frame does.
	EditedAt string `json:"edited_at,omitempty"`
	EditedBy string `json:"edited_by,omitempty"`
	Revision int    `json:"revision,omitempty"`
	// rdb 0034. Always present: 0 and 1 are both real values.
	IsParent int `json:"is_parent"`
	// rdb 0037. Omitted while nobody has added an emoji (DB payload cut 4:
	// the WUI reads it as []). The same field is on an is_parent 0 reply and
	// an is_parent 1 opening message.
	Reactions []viewReaction `json:"reactions,omitempty"`
	// rdb 0040 / specs/036 FR-011: the HUM-* the hub verified typed this
	// line at the agent's terminal. Omitted when the agent wrote it.
	TypedBy string `json:"typed_by,omitempty"`
	// SPL-952 (rdb 0060): the kind as set after sending. Omitted while it was
	// never changed; the envelope then carries the truth.
	Kind      string `json:"kind,omitempty"`
	KindSetAt string `json:"kind_set_at,omitempty"`
	KindSetBy string `json:"kind_set_by,omitempty"`
	// SPL-1024 (rdb 0069, move-v1 §5): a moved row's place now and its home.
	// All omitted while the row is at home; the envelope then carries the
	// truth. Channel / TaskID / ParentTaskID win over the envelope's.
	Channel          *string `json:"channel,omitempty"`
	TaskID           string  `json:"task_id,omitempty"`
	ParentTaskID     *string `json:"parent_task_id,omitempty"`
	MovedAt          string  `json:"moved_at,omitempty"`
	MovedBy          string  `json:"moved_by,omitempty"`
	MovedFromChannel *string `json:"moved_from_channel,omitempty"`
	MovedFromTask    string  `json:"moved_from_task,omitempty"`
}

func (s *Server) handleViewTopic(w http.ResponseWriter, r *http.Request, t store.Tenant) {
	task := r.PathValue("task_id")
	hum, ok := s.topicReader(w, r, t.ID, task)
	if !ok {
		return
	}
	// specs/041: the lobby feed leaves its archived cards out; any other
	// topic read by its id answers even while archived (the Archive view).
	sq := store.TopicMsgQuery{TaskID: task, Limit: viewLimit(r) + 1, Now: s.o.Now(),
		HideArchived: s.o.LobbyTaskID != "" && task == s.o.LobbyTaskID}
	if hum != "" {
		mine, err := s.readerChannels(r.Context(), t.ID, hum)
		if err != nil {
			writeErr(w, http.StatusInternalServerError, "internal", "topic unavailable")
			return
		}
		sq.Reader, sq.ReaderChannels = hum, mine
	}
	if rf := topicWindow(r.URL.Query(), &sq); rf != nil {
		writeErr(w, rf.status, rf.token, rf.detail)
		return
	}
	rows, err := s.o.Store.ViewTopic(r.Context(), t.ID, sq)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "topic unavailable")
		return
	}
	if len(rows) == 0 && sq.AfterAt.IsZero() && sq.BeforeAt.IsZero() && task != s.o.LobbyTaskID {
		// the lobby exists before its first post (wui-live-ws.md §1)
		writeErr(w, http.StatusNotFound, "not_found", "no such topic")
		return
	}
	var next *string
	if len(rows) == sq.Limit {
		rows = rows[:sq.Limit-1]
		c := encCursor(rows[len(rows)-1].ReceivedAt, rows[len(rows)-1].MsgID)
		next = &c
	}
	react, err := s.rowReactions(r.Context(), t.ID, rows)
	if err != nil {
		s.o.Log.Error().Err(err).Str("task", task).Msg("reactions")
		writeErr(w, http.StatusInternalServerError, "internal", "topic unavailable")
		return
	}
	writeJSON(w, http.StatusOK, topicBody{TaskID: task, Messages: viewMsgsIn(rows, react, task), Next: next})
}

// topicReader is the read door of one topic (rdb 0028, privacy.go): it
// answers the reader ("" with the door off); false has written the refusal.
// Only rbac.TopicsRead - a TENANT-wide role - stood here before, so knowing
// a task_id was enough to read another member's DM or a channel you were
// never in.
func (s *Server) topicReader(w http.ResponseWriter, r *http.Request, tenant, task string) (string, bool) {
	if !uuidRe.MatchString(task) {
		writeErr(w, http.StatusNotFound, "not_found", "no such topic")
		return "", false
	}
	hum, ok := s.readerID(r, tenant)
	if !ok {
		writeErr(w, http.StatusInternalServerError, "internal", "topic unavailable")
		return "", false
	}
	switch ok, found, err := s.canReadTopic(r.Context(), tenant, task, hum); {
	case err != nil:
		writeErr(w, http.StatusInternalServerError, "internal", "topic unavailable")
		return "", false
	case found && !ok:
		// 404, never 403: a refusal that distinguishes "not yours" from "no
		// such topic" confirms the topic exists to someone who may not
		// know that (owner's call: a non-member cannot learn it exists).
		writeErr(w, http.StatusNotFound, "not_found", "no such topic")
		return "", false
	}
	return hum, true
}

// viewRefusal is a 4xx answer of a view read.
type viewRefusal struct {
	status        int
	token, detail string
}

// topicWindow reads order= and the cursor that belongs to it into sq:
// after= is the oldest-first catch-up cursor, before= pages newest-first
// windows backwards (view-v1 §4.4).
func topicWindow(q url.Values, sq *store.TopicMsgQuery) *viewRefusal {
	switch q.Get("order") {
	case "", "asc":
	case "desc":
		sq.Desc = true
	default:
		return &viewRefusal{http.StatusBadRequest, "bad_json", "order must be asc or desc"}
	}
	if c := q.Get("after"); c != "" {
		if sq.Desc {
			return &viewRefusal{http.StatusBadRequest, "bad_json", "after is for order=asc; use before with order=desc"}
		}
		at, id, err := decCursor(c)
		if err != nil {
			return &viewRefusal{http.StatusBadRequest, "bad_cursor", "after is not a cursor from this API"}
		}
		sq.AfterAt, sq.AfterID = at, id
	}
	if c := q.Get("before"); c != "" {
		if !sq.Desc {
			return &viewRefusal{http.StatusBadRequest, "bad_json", "before is for order=desc; use after with order=asc"}
		}
		at, id, err := decCursor(c)
		if err != nil {
			return &viewRefusal{http.StatusBadRequest, "bad_cursor", "before is not a cursor from this API"}
		}
		sq.BeforeAt, sq.BeforeID = at, id
	}
	return nil
}

// rowReactions reads the reactions of rows in one call (none for no rows).
func (s *Server) rowReactions(ctx context.Context, tenant string, rows []store.ViewMsg) (map[string][]store.StoredReaction, error) {
	if len(rows) == 0 {
		return map[string][]store.StoredReaction{}, nil
	}
	ids := make([]string, len(rows))
	for i := range rows {
		ids[i] = rows[i].MsgID
	}
	return s.o.Store.ReactionsFor(ctx, tenant, ids)
}

// envNames reports whether the canonical envelope env carries channel ch.
// A box reply into a channel topic is stored in that channel (channelOf) but
// its signed envelope names none, so the view emits the row's channel beside
// it: without it the WUI read every desk answer in a channel as a DM and
// raised that agent's DM badge on a DM that holds nothing (CLE-77845, prd
// csitea 2026-10-01). Canonical JSON has no whitespace, and a "channel" key
// inside a string is escaped, so a byte match is exact.
func envNames(env []byte, ch string) bool {
	return bytes.Contains(env, []byte(`"channel":"`+ch+`"`))
}

// viewMsgs is the §4.4 message list of rows, with their reactions, read
// outside one topic (every env keeps its msg.task_id).
func viewMsgs(rows []store.ViewMsg, react map[string][]store.StoredReaction) []viewMsg {
	return viewMsgsIn(rows, react, "")
}

// viewMsgsIn is viewMsgs for the rows of topic: an at-home row whose
// msg.task_id is topic leaves it out (the WUI defaults it to the topic's).
func viewMsgsIn(rows []store.ViewMsg, react map[string][]store.StoredReaction, topic string) []viewMsg {
	out := make([]viewMsg, 0, len(rows))
	for _, m := range rows {
		home := topic
		if m.Move.Moved() {
			home = ""
		}
		v := viewMsg{Cursor: encCursor(m.ReceivedAt, m.MsgID), ReceivedAt: rfc(m.ReceivedAt),
			Env: trimEnv(m.Env, home), Deliveries: viewDeliveries(m.Deliveries), IsParent: m.IsParent,
			TypedBy: m.TypedBy}
		if rs := groupReactions(react[m.MsgID]); len(rs) > 0 {
			v.Reactions = rs
		}
		if !m.EditedAt.IsZero() {
			v.EditedAt, v.EditedBy, v.Revision = rfc(m.EditedAt), m.EditedBy, m.Revision
		}
		if !m.KindSetAt.IsZero() {
			v.Kind, v.KindSetAt, v.KindSetBy = m.Kind, rfc(m.KindSetAt), m.KindSetBy
		}
		if mv := m.Move; mv.Moved() {
			ch, parent, home := mv.Channel, mv.ParentTaskID, mv.FromChannel
			v.Channel, v.TaskID, v.ParentTaskID = &ch, mv.TaskID, &parent
			v.MovedAt, v.MovedBy, v.MovedFromChannel, v.MovedFromTask = rfc(mv.At), mv.By, &home, mv.FromTask
		} else if ch := m.RowChannel; ch != "" && !envNames(m.Env, ch) {
			v.Channel = &ch
		}
		out = append(out, v)
	}
	return out
}

// viewDeliveries is ds for the view; nil (omitted) when ds is exactly the
// default of a WUI post nobody else receives, [box-wui sent], which the WUI
// puts back (utils/view-api.mjs DEFAULT_DELIVERY).
func viewDeliveries(ds []store.ViewDelivery) *[]viewDelivery {
	if len(ds) == 1 && ds[0].ToBox == WUIBox && ds[0].State == store.StateSent {
		return nil
	}
	out := make([]viewDelivery, 0, len(ds))
	for _, d := range ds {
		out = append(out, viewDelivery{ToBox: d.ToBox, State: d.State})
	}
	return &out
}

// trimEnv is the view's copy of a stored envelope (DB payload cut 4): no
// sig (the WUI never verifies it and deleted it on arrival), no empty
// msg.files, and no msg.task_id when it is topic ("" keeps it). Only the
// view JSON is trimmed: the stored row, the WS frame and the spool keep the
// signed envelope whole. An envelope it cannot read passes through as is.
func trimEnv(env []byte, topic string) json.RawMessage {
	var e map[string]json.RawMessage
	if json.Unmarshal(env, &e) != nil {
		return env
	}
	delete(e, "sig")
	var m map[string]json.RawMessage
	if raw, ok := e["msg"]; ok && json.Unmarshal(raw, &m) == nil {
		if f, ok := m["files"]; ok && string(bytes.TrimSpace(f)) == "[]" {
			delete(m, "files")
		}
		var id string
		if t, ok := m["task_id"]; ok && topic != "" && json.Unmarshal(t, &id) == nil && id == topic {
			delete(m, "task_id")
		}
		if b, err := json.Marshal(m); err == nil {
			e["msg"] = b
		}
	}
	b, err := json.Marshal(e)
	if err != nil {
		return env
	}
	return b
}
