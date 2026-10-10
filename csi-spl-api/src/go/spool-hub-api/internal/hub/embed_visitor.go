package hub

import (
	"errors"
	"net/http"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/auth"
	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/uid"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// The embed visitor API (specs/121 4.1, 4.2, 4.4; T104). An anonymous
// website visitor of an embed gets a bearer token and one channel, and may
// read, post into and erase that channel, nothing else:
//
//	POST   /v1/embed/{embed_id}/visitor   mint: token + a new channel (201)
//	GET    /v1/embed/{embed_id}/messages  its channel's newest lines
//	POST   /v1/embed/{embed_id}/messages  one text post, no file (201)
//	DELETE /v1/embed/{embed_id}/visitor   erasure on request (204)
//
// The token travels as Authorization: Bearer only (auth.EmbedBearer), never
// as a cookie, and no member route reads it: on /v1/view/*, /v1/members,
// search or docs it is no session at all. The visitor's role channel_guest
// holds no permission (rbac), so even its HUM id would open no member route.
// Every store call of a visitor request runs under the channel scope
// (store.EmbedVisitors; TestEmbedVisitorPathNeverInTenant), never inTenant.
// The routes answer as an unknown path while cnf env.hub.embed.enabled is
// off (Options.EmbedEnabled), and under a store without the channel scope.
// Not here: the abuse limits and the challenge (T105). The staff side and
// the #sales triage line are embed_staff.go (T106).

// embedIDRe is rdb 0169's embed_id CHECK.
var embedIDRe = regexp.MustCompile(`^[a-z0-9][a-z0-9-]{2,63}$`)

const (
	// embedReadDefault / embedReadMax: lines per GET .../messages.
	embedReadDefault = 100
	embedReadMax     = 200
	// TokenEmbedToken: no live visitor token for this embed (401).
	TokenEmbedToken = "embed_token"
)

func (s *Server) routeEmbedVisitor(mux *http.ServeMux) {
	mux.HandleFunc("POST /v1/embed/{embed_id}/visitor", s.handleEmbedMint)
	mux.HandleFunc("DELETE /v1/embed/{embed_id}/visitor", s.handleEmbedErase)
	mux.HandleFunc("GET /v1/embed/{embed_id}/messages", s.handleEmbedRead)
	mux.HandleFunc("POST /v1/embed/{embed_id}/messages", s.handleEmbedPost)
}

// embedStore is the visitor store when the embed is on for this request's
// embed id, else nil after answering 404 exactly as an unknown path does.
func (s *Server) embedStore(w http.ResponseWriter, r *http.Request) store.EmbedVisitors {
	es, ok := s.o.Store.(store.EmbedVisitors)
	if !s.o.EmbedEnabled || !ok || !embedIDRe.MatchString(r.PathValue("embed_id")) {
		http.NotFound(w, r)
		return nil
	}
	w.Header().Set("Cache-Control", "no-store")
	return es
}

// embedLife is the token lifetime from cnf (30 d sliding, 180 d cap).
func (s *Server) embedLife() store.EmbedTokenLife { return s.o.EmbedTokenLife }

// handleEmbedMint makes a visitor of an enabled embed: the token is in this
// one response and nowhere else (the hub keeps its sha256).
func (s *Server) handleEmbedMint(w http.ResponseWriter, r *http.Request) {
	es := s.embedStore(w, r)
	if es == nil {
		return
	}
	tenant := s.embedTenant(r, es)
	if tenant == "" {
		http.NotFound(w, r)
		return
	}
	tok, hash, err := auth.NewEmbedToken()
	if err != nil {
		writeErrCause(w, http.StatusInternalServerError, "internal", "token not minted", err)
		return
	}
	v, err := es.MintEmbedVisitor(r.Context(), store.EmbedVisitorMint{TenantID: tenant,
		EmbedID: r.PathValue("embed_id"), TokenHash: hash, Life: s.embedLife()}, s.o.Now().UTC())
	switch {
	case errors.Is(err, store.ErrNotFound):
		http.NotFound(w, r)
		return
	case err != nil:
		writeErrCause(w, http.StatusInternalServerError, "internal", "visitor not stored", err)
		return
	}
	writeJSON(w, http.StatusCreated, map[string]any{"token": tok, "visitor_id": v.VisitorID,
		"channel": v.ChannelID, "expires_at": rfc(v.ExpiresAt)})
	s.embedTriage(r.Context(), v, "") // T106: the #sales line, after the answer
}

// embedTenant is the workspace of the URL's enabled embed; "" when there is
// none (unknown, disabled, or the read failed: logged).
// The mint names no workspace, so the embed row names it (an operator read
// keyed by the embed id, store.EmbedCustomer).
func (s *Server) embedTenant(r *http.Request, es store.EmbedVisitors) string {
	ec, err := es.EmbedCustomer(r.Context(), r.PathValue("embed_id"))
	if err != nil || !ec.Enabled {
		if err != nil && !errors.Is(err, store.ErrNotFound) {
			s.o.Log.Error().Err(err).Msg("embed customer read")
		}
		return ""
	}
	return ec.TenantID
}

// embedVisitor is the live visitor the request's bearer names for the URL's
// embed, its expiry slid to now; false after a 404 or 401.
func (s *Server) embedVisitor(w http.ResponseWriter, r *http.Request) (store.EmbedVisitors, store.EmbedVisitor, bool) {
	es := s.embedStore(w, r)
	if es == nil {
		return nil, store.EmbedVisitor{}, false
	}
	refuse := func() (store.EmbedVisitors, store.EmbedVisitor, bool) {
		w.Header().Set("WWW-Authenticate", `Bearer realm="embed"`)
		writeErr(w, http.StatusUnauthorized, TokenEmbedToken, "no live visitor token for this embed")
		return nil, store.EmbedVisitor{}, false
	}
	hash, err := auth.EmbedBearer(r)
	if err != nil {
		return refuse()
	}
	now := s.o.Now().UTC()
	v, err := es.EmbedVisitorByToken(r.Context(), r.PathValue("embed_id"), hash, now)
	if err == nil {
		v, err = es.SlideEmbedVisitor(r.Context(), v, s.embedLife(), now)
	}
	switch {
	case errors.Is(err, store.ErrNotFound):
		return refuse()
	case err != nil:
		writeErrCause(w, http.StatusInternalServerError, "internal", "visitor lookup failed", err)
		return nil, store.EmbedVisitor{}, false
	}
	return es, v, true
}

// embedLine is one line as the visitor's GET returns it.
type embedLine struct {
	MsgID      string `json:"msg_id"`
	Body       string `json:"body"`
	Mine       bool   `json:"mine"`
	ReceivedAt string `json:"received_at"`
}

func (s *Server) handleEmbedRead(w http.ResponseWriter, r *http.Request) {
	limit := embedReadDefault
	if q := r.URL.Query().Get("limit"); q != "" {
		n, err := strconv.Atoi(q)
		if err != nil || n < 1 || n > embedReadMax {
			writeErr(w, http.StatusBadRequest, "bad_request", "limit must be 1.."+strconv.Itoa(embedReadMax))
			return
		}
		limit = n
	}
	es, v, ok := s.embedVisitor(w, r)
	if !ok {
		return
	}
	got, err := es.EmbedVisitorMessages(r.Context(), v, limit)
	if err != nil {
		writeErrCause(w, http.StatusInternalServerError, "internal", "messages not read", err)
		return
	}
	out := make([]embedLine, 0, len(got))
	for _, m := range got {
		out = append(out, embedLine{m.MsgID, m.Body, m.Mine, rfc(m.ReceivedAt)})
	}
	writeJSON(w, http.StatusOK, map[string]any{"messages": out})
}

// handleEmbedPost stores one text line from the visitor: body only (no
// file, no channel, no recipient: the channel and sender are the token's),
// at most EmbedMessageMaxBytes bytes (413 above).
func (s *Server) handleEmbedPost(w http.ResponseWriter, r *http.Request) {
	es, v, ok := s.embedVisitor(w, r)
	if !ok {
		return
	}
	var in struct {
		Body string `json:"body"`
	}
	max := s.o.EmbedMessageMaxBytes
	// JSON escapes a byte in at most 6 ("\u00XX"): room for any body that
	// fits, and a hard cap on what the hub reads.
	if !readJSONStrict(w, r, &in, int64(max)*6+256, "invalid JSON body (only body)") {
		return
	}
	switch {
	case len(in.Body) > max:
		writeErr(w, http.StatusRequestEntityTooLarge, "too_large", "body is over "+strconv.Itoa(max)+" bytes")
		return
	case strings.TrimSpace(in.Body) == "":
		writeErr(w, http.StatusBadRequest, "bad_request", "body is empty")
		return
	}
	p, err := s.embedPost(v, in.Body)
	if err != nil {
		writeErr(w, http.StatusBadRequest, "bad_json", err.Error())
		return
	}
	if err := es.PostEmbedVisitorMessage(r.Context(), v, p); err != nil {
		writeErrCause(w, http.StatusInternalServerError, "internal", "message not stored", err)
		return
	}
	writeJSON(w, http.StatusCreated, map[string]any{"msg_id": p.MsgID, "received_at": rfc(p.At)})
	s.embedTriage(r.Context(), v, p.MsgID) // T106: a first post after a quiet day
}

// embedPost is the stored form of a visitor's line: a v:1 note from its HUM
// to the channel, in the browser-only envelope (box-wui to box-wui,
// unsigned), one topic per visitor (task_id = visitor_id).
func (s *Server) embedPost(v store.EmbedVisitor, body string) (store.EmbedPost, error) {
	now := s.o.Now().UTC().Truncate(time.Microsecond) // Postgres keeps µs
	m := &msg.Message{V: s.writeVersion(), MsgID: uid.New(), TaskID: v.VisitorID, TS: now.Format(time.RFC3339),
		From: v.HumanID, To: BroadcastID, Kind: "note", Body: body, Files: []msg.Attachment{}}
	if err := m.Validate(); err != nil {
		return store.EmbedPost{}, err
	}
	inner, err := msg.Canonical(m)
	if err != nil {
		return store.EmbedPost{}, err
	}
	env := &wire.Envelope{FromBox: WUIBox, ToBox: WUIBox, Channel: v.ChannelID, Msg: inner}
	canon, err := env.Marshal()
	if err != nil {
		return store.EmbedPost{}, err
	}
	ts, _ := time.Parse(time.RFC3339, m.TS)
	return store.EmbedPost{MsgID: m.MsgID, TaskID: m.TaskID, TS: ts, Body: body, Inner: inner, Canon: canon,
		At: now, Expires: now.Add(s.retention(v.ChannelID))}, nil
}

// handleEmbedErase deletes the visitor's channel, its lines, its token and
// its HUM (spec 4.4, erasure on request).
func (s *Server) handleEmbedErase(w http.ResponseWriter, r *http.Request) {
	es, v, ok := s.embedVisitor(w, r)
	if !ok {
		return
	}
	if err := es.EraseEmbedVisitor(r.Context(), v); err != nil {
		writeErrCause(w, http.StatusInternalServerError, "internal", "visitor not erased", err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}
