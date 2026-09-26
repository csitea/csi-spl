package hub

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"math"
	"net/http"
	"sort"
	"strconv"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/search"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// GET /v1/view/search and /v1/view/search/operators (specs/003
// contracts/search-v1.md, FR-029 – FR-032): one Gmail-style grammar parsed
// here, never in the browser; grouped sections; the view door, the Host
// tenant, read-only.

const (
	searchRateDefault    = 30 // per (tenant, reader) per minute (search-v1 §5.1)
	searchBudgetDefault  = 2 * time.Second
	searchGroupedDefault = 5
	searchGroupedMax     = 20
)

func (s *Server) routeSearch(mux interface {
	HandleFunc(string, func(http.ResponseWriter, *http.Request))
}) {
	mux.HandleFunc("GET /v1/view/search", s.viewHandler(s.handleSearch))
	mux.HandleFunc("GET /v1/view/search/operators", s.viewHandler(s.handleSearchOperators))
}

// searchCursor is the opaque per-section cursor, bound to q + sort.
type searchCursor struct {
	T   search.Type `json:"t"`
	H   string      `json:"h"`
	At  time.Time   `json:"a,omitempty"`
	ID  string      `json:"i,omitempty"`
	Idx int         `json:"x,omitempty"`
	Off int         `json:"o,omitempty"`
}

func queryHash(q, sort string) string {
	h := sha256.Sum256([]byte(sort + "\n" + q))
	return hex.EncodeToString(h[:6])
}

func (c searchCursor) enc() *string {
	b, _ := json.Marshal(c)
	s := base64.RawURLEncoding.EncodeToString(b)
	return &s
}

func decSearchCursor(s string) (searchCursor, error) {
	var c searchCursor
	b, err := base64.RawURLEncoding.DecodeString(s)
	if err == nil {
		err = json.Unmarshal(b, &c)
	}
	if err == nil && (c.T == "" || c.H == "") {
		err = errors.New("cursor")
	}
	return c, err
}

type badQuery struct {
	Error  string `json:"error"`
	Detail string `json:"detail"`
	Pos    int    `json:"pos"`
	Token  string `json:"token"`
}

type hl struct {
	Text       string        `json:"text"`
	Highlights []search.Span `json:"highlights"`
}

type section struct {
	Results []any   `json:"results"`
	Next    *string `json:"next"`
}

// searchReader is who is asking: the member HUM-* (also the DM filter), or
// "" with the door off. ok=false fails closed (CLE-34986): it returned ""
// on a lookup error, and "" searched the whole tenant, DMs included.
func (s *Server) searchReader(r *http.Request, tenant string) (string, bool) {
	return s.readerID(r, tenant)
}

func (s *Server) handleSearch(w http.ResponseWriter, r *http.Request, t store.Tenant) {
	qs := r.URL.Query()
	raw, sortBy := qs.Get("q"), qs.Get("sort")
	switch sortBy {
	case "":
		sortBy = "newest"
	case "newest", "relevance":
	default:
		writeJSON(w, http.StatusBadRequest, badQuery{"bad_query", "sort must be newest or relevance", 0, sortBy})
		return
	}
	reader, ok := s.searchReader(r, t.ID)
	if !ok {
		writeErr(w, http.StatusInternalServerError, "internal", "search unavailable")
		return
	}
	key := t.ID + "|"
	if reader != "" {
		key += reader
	} else {
		key += "ip:" + s.edge.ClientIP(r)
	}
	if ok, retry := s.searchRate.Allow(key, s.o.SearchRatePerMin); !ok {
		w.Header().Set("Retry-After", strconv.Itoa(int(math.Ceil(retry.Seconds()))))
		w.Header().Set("Access-Control-Expose-Headers", "Retry-After") // the WUI backs off by it
		writeErr(w, http.StatusTooManyRequests, "rate_limited", "too many searches; retry later")
		return
	}
	now := s.o.Now()
	q, err := search.Parse(raw, now)
	if err != nil {
		var pe *search.Error
		if errors.As(err, &pe) {
			writeJSON(w, http.StatusBadRequest, badQuery{"bad_query", pe.Detail, pe.Pos, pe.Token})
			return
		}
		writeErr(w, http.StatusInternalServerError, "internal", "search unavailable")
		return
	}
	hash := queryHash(raw, sortBy)
	types := q.Types
	var cur *searchCursor
	if c := qs.Get("cursor"); c != "" {
		dc, err := decSearchCursor(c)
		ok := err == nil && dc.H == hash
		if ok {
			ok = false
			for _, ty := range q.Types {
				ok = ok || ty == dc.T
			}
		}
		if !ok {
			writeErr(w, http.StatusBadRequest, "bad_cursor", "cursor is not from this API for this q and sort")
			return
		}
		cur, types = &dc, []search.Type{dc.T}
	}
	limit := viewLimit(r)
	if len(types) > 1 {
		limit = searchGroupedDefault
		if n, err := strconv.Atoi(qs.Get("limit")); err == nil && n > 0 {
			limit = min(n, searchGroupedMax)
		}
	}
	ctx, cancel := context.WithTimeout(r.Context(), s.o.SearchBudget+time.Second)
	defer cancel()
	mine, err := s.readerChannels(ctx, t.ID, reader) // rdb 0028, the read door
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "search unavailable")
		return
	}
	base := store.SearchQuery{Q: q, Now: now, Viewer: reader, ViewerChannels: mine,
		Limit: limit + 1, Budget: s.o.SearchBudget, Relevance: sortBy == "relevance"}
	groups := map[string]section{}
	names := []string{}
	for _, ty := range types {
		sq := base
		c := searchCursor{T: ty, H: hash}
		if cur != nil {
			c = *cur
			sq.AfterAt, sq.AfterID, sq.AfterIdx, sq.Offset = c.At, c.ID, c.Idx, c.Off
		}
		sec, err := s.searchSection(ctx, t, q, sq, c, limit)
		if errors.Is(err, store.ErrSearchBudget) || errors.Is(ctx.Err(), context.DeadlineExceeded) {
			writeErr(w, http.StatusServiceUnavailable, "search_budget", "the search ran past its time budget; narrow the query")
			return
		}
		if err != nil {
			s.o.Log.Error().Err(err).Str("tenant", t.ID).Str("type", string(ty)).Msg("search failed")
			writeErr(w, http.StatusInternalServerError, "internal", "search unavailable")
			return
		}
		groups[ty.Group()] = sec
		names = append(names, string(ty))
	}
	warnings := q.Warnings
	if warnings == nil {
		warnings = []search.Warning{}
	}
	writeJSON(w, http.StatusOK, map[string]any{"query": raw, "sort": sortBy, "types": names,
		"warnings": warnings, "groups": groups})
}

func strPtr(s string) *string {
	if s == "" {
		return nil
	}
	return &s
}

// searchSection answers one type's page. The keyset types page by the last
// row; the small entity types (and relevance) by offset.
func (s *Server) searchSection(ctx context.Context, t store.Tenant, q *search.Query, sq store.SearchQuery, c searchCursor, limit int) (section, error) {
	out := section{Results: []any{}}
	se, ok := s.o.Store.(store.Searcher)
	if !ok {
		return out, errors.New("store cannot search")
	}
	more := func(n int) bool { return n > limit }
	switch c.T {
	case search.TypeMessage:
		rows, err := se.SearchMessages(ctx, t.ID, sq)
		if err != nil {
			return out, err
		}
		if more(len(rows)) {
			rows = rows[:limit]
			last := rows[limit-1]
			nc := searchCursor{T: c.T, H: c.H, At: last.ReceivedAt, ID: last.MsgID}
			if sq.Relevance {
				nc = searchCursor{T: c.T, H: c.H, Off: sq.Offset + limit}
			}
			out.Next = nc.enc()
		}
		for _, m := range rows {
			text, hs := q.Snippet(m.Body)
			out.Results = append(out.Results, map[string]any{
				"msg_id": m.MsgID, "task_id": m.TaskID, "parent_task_id": strPtr(m.Parent), "channel": strPtr(m.Channel),
				"kind": m.Kind, "from": m.FromID, "from_box": m.FromBox, "to": m.ToID, "to_box": m.ToBox,
				"created_at": rfc(m.TS), "received_at": rfc(m.ReceivedAt), "files": m.Files,
				"snippet": hl{text, hs}})
		}
	case search.TypeTopic:
		sq.Relevance = false
		rows, err := se.SearchTopics(ctx, t.ID, sq)
		if err != nil {
			return out, err
		}
		if more(len(rows)) {
			rows = rows[:limit]
			out.Next = searchCursor{T: c.T, H: c.H, At: rows[limit-1].LastAt, ID: rows[limit-1].TaskID}.enc()
		}
		for _, th := range rows {
			out.Results = append(out.Results, map[string]any{
				"task_id": th.TaskID, "parent_task_id": strPtr(th.Parent), "channel": strPtr(th.Channel),
				"title":    hl{th.Title, q.HighlightWords(th.Title)},
				"first_ts": rfc(th.FirstAt), "last_ts": rfc(th.LastAt), "count": th.Count})
		}
	case search.TypeFile:
		sq.Relevance = false
		rows, err := se.SearchFiles(ctx, t.ID, sq)
		if err != nil {
			return out, err
		}
		if more(len(rows)) {
			rows = rows[:limit]
			last := rows[limit-1]
			out.Next = searchCursor{T: c.T, H: c.H, At: last.Msg.ReceivedAt, ID: last.Msg.MsgID, Idx: last.Idx}.enc()
		}
		for _, f := range rows {
			var bytes *int64
			if f.HasBytes {
				b := f.Bytes
				bytes = &b
			}
			out.Results = append(out.Results, map[string]any{
				"file_id": strPtr(f.FileID), "kind": f.Kind, "mode": f.Mode, "bytes": bytes,
				"name":   hl{f.Name, q.HighlightSubstrings(f.Name)},
				"msg_id": f.Msg.MsgID, "task_id": f.Msg.TaskID, "channel": strPtr(f.Msg.Channel),
				"from": f.Msg.FromID, "from_box": f.Msg.FromBox, "received_at": rfc(f.Msg.ReceivedAt)})
		}
	default:
		rows, err := s.searchEntities(ctx, t.ID, q, c.T, sq)
		if err != nil {
			return out, err
		}
		off := min(sq.Offset, len(rows))
		rows = rows[off:]
		if more(len(rows)) {
			rows = rows[:limit]
			out.Next = searchCursor{T: c.T, H: c.H, Off: off + limit}.enc()
		}
		out.Results = rows
	}
	return out, nil
}

// searchEntities filters the tenant's robots, users, channels or boxes (small
// sets the viewer already lists) with the parsed query, sorted by name.
func (s *Server) searchEntities(ctx context.Context, tenant string, q *search.Query, ty search.Type, sq store.SearchQuery) ([]any, error) {
	type row struct {
		e search.Entity
		v map[string]any
	}
	var rows []row
	add := func(e search.Entity, v map[string]any) {
		e.Type = ty
		if search.MatchEntity(q.Root, e) {
			v["name"] = hl{e.Name, q.HighlightSubstrings(e.Name)}
			rows = append(rows, row{e, v})
		}
	}
	switch ty {
	case search.TypeRobot, search.TypeBox:
		boxes, err := s.o.Store.ViewBoxes(ctx, tenant)
		if err != nil {
			return nil, err
		}
		for _, b := range boxes {
			online := false
			if !b.Revoked {
				s.mu.Lock()
				online = s.boxes[[2]string{tenant, b.BoxID}] != nil
				s.mu.Unlock()
			}
			if ty == search.TypeBox {
				agents := append([]string{}, b.Agents...)
				var hello *string
				if !b.LastHelloAt.IsZero() {
					h := rfc(b.LastHelloAt)
					hello = &h
				}
				add(search.Entity{Name: b.BoxID, Text: []string{b.BoxID}, Box: b.BoxID, Online: online, Revoked: b.Revoked},
					map[string]any{"box_id": b.BoxID, "online": online, "revoked": b.Revoked, "agents": agents, "last_hello_at": hello})
				continue
			}
			for _, a := range b.Agents {
				add(search.Entity{Name: a + "@" + b.BoxID, Text: []string{a, b.BoxID}, Box: b.BoxID, Online: online, Revoked: b.Revoked},
					map[string]any{"id": a, "box": b.BoxID, "online": online, "revoked": b.Revoked})
			}
		}
	case search.TypeUser:
		se, _ := s.o.Store.(store.Searcher)
		hs, err := se.TenantHumans(ctx, tenant)
		if err != nil {
			return nil, err
		}
		for _, h := range hs {
			s.mu.Lock()
			online := s.online[[2]string{tenant, h.HumanID}] > 0
			s.mu.Unlock()
			label, text := h.HumanID, []string{h.HumanID}
			if h.DisplayName != "" {
				label, text = h.DisplayName+" ("+h.HumanID+")", append(text, h.DisplayName)
			}
			add(search.Entity{Name: label, Text: text, Online: online},
				map[string]any{"id": h.HumanID, "display_name": strPtr(h.DisplayName), "avatar_file_id": strPtr(h.AvatarFileID), "online": online})
		}
	case search.TypeChannel:
		chs, err := s.o.Store.ViewChannelStats(ctx, tenant, sq.Now, nil)
		if err != nil {
			return nil, err
		}
		for _, c := range chs {
			// rdb 0028: searching must not surface the name of a channel the
			// reader is not in - that is exactly what the sidebar hides.
			if sq.Hides(c.ChannelID) {
				continue
			}
			var last *string
			if !c.LastAt.IsZero() {
				l := rfc(c.LastAt)
				last = &l
			}
			add(search.Entity{Name: c.ChannelID, Text: []string{c.ChannelID, c.Name}},
				map[string]any{"channel": c.ChannelID, "default": c.Default, "count": c.Count, "last_ts": last})
		}
	case search.TypeTenant:
		// The reader's OWN memberships only; a door-off or box reader has none.
		ml, ok := s.o.Store.(store.MembershipLister)
		if !ok || sq.Viewer == "" {
			break
		}
		ms, err := ml.Memberships(ctx, sq.Viewer)
		if err != nil {
			return nil, err
		}
		for _, m := range ms {
			name := m.DisplayName
			if name == "" {
				name = m.TenantID
			}
			add(search.Entity{Name: name, Text: []string{m.TenantID, m.DisplayName}},
				map[string]any{"tenant_id": m.TenantID, "role": m.Role, "current": m.TenantID == tenant})
		}
	case search.TypeEvent:
		// The reader's OWN event log (events-v1: same privacy as GET /events).
		he, ok := s.o.Store.(store.HumanEvents)
		if !ok || sq.Viewer == "" {
			break
		}
		evs, err := he.HumanEventsPage(ctx, sq.Viewer, 0, searchEventScan)
		if err != nil {
			return nil, err
		}
		for _, ev := range evs {
			name := ev.Code
			if name == "" {
				name = ev.Message
			}
			if name == "" {
				name = ev.ErrorID
			}
			add(search.Entity{Name: name, Text: []string{ev.ErrorID, ev.Code, ev.Message, ev.Path, ev.Source, ev.Route}, At: ev.ReceivedAt},
				map[string]any{"event_id": ev.ID, "error_id": ev.ErrorID, "code": ev.Code, "message": ev.Message,
					"status": ev.Status, "method": ev.Method, "path": ev.Path, "source": ev.Source, "received_at": rfc(ev.ReceivedAt)})
		}
	}
	if ty == search.TypeIssue {
		// 1.2 (CLE-34992, spec 039): the tenant's issues, readable by every
		// member (topics.read, the view door above). ListIssues is one read,
		// newest number first; an issue's name is its key and title.
		is, ok := s.o.Store.(store.Issues)
		if !ok {
			return []any{}, nil
		}
		list, err := is.ListIssues(ctx, tenant)
		if err != nil {
			return nil, err
		}
		for _, it := range list {
			key := it.Key()
			labels := append([]string{}, it.Labels...)
			add(search.Entity{Name: key + " " + it.Title, Text: []string{key, it.Title, it.Description},
				Status: it.Status, Priority: it.Priority, Assignee: it.Assignee, Labels: labels, Me: sq.Viewer},
				map[string]any{"key": key, "number": it.Number, "title": hl{it.Title, q.HighlightSubstrings(it.Title)},
					"status": it.Status, "priority": it.Priority, "assignee": strPtr(it.Assignee), "labels": labels,
					"task_id": strPtr(it.TaskID), "updated_at": rfc(it.UpdatedAt)})
		}
	}
	if ty == search.TypeEvent || ty == search.TypeIssue { // newest first (HumanEventsPage / ListIssues order)
		out := make([]any, len(rows))
		for i, r := range rows {
			out[i] = r.v
		}
		return out, nil
	}
	sort.SliceStable(rows, func(i, j int) bool { return rows[i].e.Name < rows[j].e.Name })
	out := make([]any, len(rows))
	for i, r := range rows {
		out[i] = r.v
	}
	return out, nil
}

// searchEventScan bounds how many of the reader's newest events one search
// reads (the log itself is trimmed to HumanEventsKeep rows).
const searchEventScan = 500

// handleSearchOperators is search-v1 §6: the grammar as data.
func (s *Server) handleSearchOperators(w http.ResponseWriter, _ *http.Request, _ store.Tenant) {
	type ty struct {
		Type    search.Type `json:"type"`
		Group   string      `json:"group"`
		Aliases []string    `json:"aliases"`
	}
	types := []ty{}
	for _, t := range search.Types {
		types = append(types, ty{t, t.Group(), search.Aliases(t)})
	}
	ops := make([]search.Operator, len(search.Operators))
	copy(ops, search.Operators)
	for i := range ops {
		if ops[i].Aliases == nil {
			ops[i].Aliases = []string{}
		}
		if ops[i].Name == search.OpStatus {
			ops[i].Doc = search.StatusDoc() // the store's current workflow, never a stale list
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{"version": search.Version, "types": types, "operators": ops})
}
