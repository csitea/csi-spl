package hub

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"

	"github.com/csitea/csi-spl/spool-hub-api/internal/billing"
	"github.com/csitea/csi-spl/spool-hub-api/internal/blob"
	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// Browser live WebSocket (specs/003 contracts/wui-live-ws.md): hello/welcome,
// subscribe, send, and live fan-out of every stored message of a subscribed
// task_id. Browsers hold no key: a browser-only send is box-wui -> box-wui
// with an empty sig. A signed-in member's send that names an agent is signed
// by the hub-held box-wui key and delivered to its box (specs/014, dispatch.go,
// behind SPOOL_HUB_WUI_DISPATCH).

const (
	// WUIBox is the reserved virtual box of the browser audience: no pin
	// needed as a to_box, delivered by the fan-out. Pinnable only with the
	// hub's own box-wui key (specs/014); never a box session.
	WUIBox = "box-wui"
	// BroadcastID is the v:1 `to` of a lobby post with no single recipient.
	BroadcastID = "ALL-0"
	// LobbyChannel is the channel lobby messages are stored under (#lobby;
	// "general" is the pre-M3 name, an accepted input alias, channels-v1 §1).
	LobbyChannel = store.ChannelLobby
)

// toBoxKnown: a pinned box of the tenant, or the virtual browser box.
func (s *Server) toBoxKnown(ctx context.Context, tenant, box string) bool {
	if box == WUIBox {
		return true
	}
	_, err := s.o.Store.GetPin(ctx, tenant, box)
	return err == nil
}

type wuiConn struct {
	conn   *websocket.Conn
	tenant string
	as     string          // display name the browser gave (or the id)
	from   string          // v:1 agent id stamped as `from`
	member string          // member-session human id ("" = none); dispatch needs it
	subs   map[string]bool // task ids, guarded by srv.mu
	chans  map[string]bool // channel ids (stored form), guarded by srv.mu
	wmu    sync.Mutex
	once   sync.Once
}

func (c *wuiConn) write(ctx context.Context, v any) error {
	c.wmu.Lock()
	defer c.wmu.Unlock()
	ctx, cancel := context.WithTimeout(ctx, writeTimeout)
	defer cancel()
	return wsjson.Write(ctx, c.conn, v)
}

func (c *wuiConn) close(code websocket.StatusCode, reason string) {
	c.once.Do(func() { c.conn.Close(code, reason) }) //nolint:errcheck
}

type wuiFile struct {
	Mode   string `json:"mode,omitempty"`
	Kind   string `json:"kind,omitempty"`
	FileID string `json:"file_id"`
	Name   string `json:"name"`
	Bytes  int64  `json:"bytes,omitempty"`
	SHA256 string `json:"sha256,omitempty"`
}

type wuiIn struct {
	Type   string    `json:"type"`
	As     string    `json:"as,omitempty"`
	Token  string    `json:"token,omitempty"`
	TaskID string    `json:"task_id,omitempty"`
	MsgID  string    `json:"msg_id,omitempty"`
	Kind   string    `json:"kind,omitempty"`
	Body   string    `json:"body,omitempty"`
	To     string    `json:"to,omitempty"`
	Files  []wuiFile `json:"files,omitempty"`
	// Hub-envelope tags (wui-live-ws.md §4, channels-v1 §2).
	Channel      string `json:"channel,omitempty"`
	ParentTaskID string `json:"parent_task_id,omitempty"`
}

type wuiErr struct {
	Type   string `json:"type"`
	Error  string `json:"error"`
	Status int    `json:"status"`
	Detail string `json:"detail"`
	MsgID  string `json:"msg_id,omitempty"`
}

// GuestPrefix is the id prefix of an anonymous door-off browser human
// (wui-live-ws §3.1): a v:1 agent id outside the member HUM-<n> namespace
// (rdb 0006 humans.human_id CHECK '^HUM-[0-9]+$'), so a guest can never take
// a member's id, name or picture.
const GuestPrefix = "GST-"

// humanIDs maps a display name to a stable GST-<n> per (tenant, name) for the
// life of the process, so two tabs using one name share an id. Session human
// ids live in their own namespace (HUM-<n>), so no display name can take one.
type humanIDs struct {
	mu   sync.Mutex
	next int
	ids  map[[3]string]string
}

func (h *humanIDs) id(tenant, name string) string { return h.get("name", tenant, name) }

// session maps a member-session human id that is not a v:1 id (010 ids such
// as HUM-google-sub-1@t1) to a HUM-<n> (specs/014 OQ-014-3).
func (h *humanIDs) session(tenant, humanID string) string { return h.get("session", tenant, humanID) }

func (h *humanIDs) get(ns, tenant, name string) string {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.ids == nil {
		h.ids = map[[3]string]string{}
		h.next = 1
	}
	k := [3]string{ns, tenant, name}
	if v, ok := h.ids[k]; ok {
		return v
	}
	prefix := "HUM-"
	if ns == "name" {
		prefix = GuestPrefix
	}
	v := fmt.Sprintf("%s%d", prefix, h.next)
	h.next++
	h.ids[k] = v
	return v
}

// wuiOrigins turns the view CORS allow-list into websocket origin patterns.
func (s *Server) wuiOrigins() []string {
	var out []string
	for _, o := range s.o.ViewCORSOrigins {
		if u, err := url.Parse(o); err == nil && u.Host != "" {
			out = append(out, u.Host)
		}
	}
	return out
}

// lobbyAlias resolves "LOBBY"/"lobby" to the lobby task id.
func (s *Server) lobbyAlias(task string) (string, bool) {
	if strings.EqualFold(task, "lobby") {
		return s.o.LobbyTaskID, s.o.LobbyTaskID != ""
	}
	return task, true
}

func (s *Server) handleWUIWS(w http.ResponseWriter, r *http.Request) {
	t, err := s.tenantOf(r)
	if err != nil {
		writeErr(w, http.StatusNotFound, "unknown_tenant", "no tenant for this host")
		return
	}
	if s.o.ViewDoor != ViewDoorOff && !s.sessionMayRead(r, t.ID) {
		writeErr(w, http.StatusUnauthorized, "view_door", "a view token or a member session is required")
		return
	}
	conn, err := websocket.Accept(w, r, &websocket.AcceptOptions{OriginPatterns: s.wuiOrigins()})
	if err != nil {
		return
	}
	conn.SetReadLimit(maxFrameBytes)
	ctx := context.WithoutCancel(r.Context())

	hctx, cancel := context.WithTimeout(ctx, s.o.HelloTimeout)
	var h wuiIn
	err = wsjson.Read(hctx, conn, &h)
	cancel()
	if err != nil {
		conn.Close(wire.CloseHelloTimeout, "hello_timeout") //nolint:errcheck
		return
	}
	if h.Type != "hello" || len(h.As) > 64 {
		conn.Close(wire.CloseBadFrame, "bad_frame") //nolint:errcheck
		return
	}
	c := &wuiConn{conn: conn, tenant: t.ID, as: h.As, subs: map[string]bool{}, chans: map[string]bool{}}
	switch {
	case msg.ValidID(h.As):
		c.from = h.As
	case strings.TrimSpace(h.As) == "":
		c.from = s.humans.id(t.ID, "#"+randHex(6))
	default:
		c.from = s.humans.id(t.ID, strings.TrimSpace(h.As))
	}
	if sess, err := s.wuiSession(r, t.ID); err == nil && sess != "" {
		// A member sign-in session is authoritative (spec 010); hello.as never is.
		c.member, c.from = sess, sess
		if !msg.ValidID(sess) {
			c.from = s.humans.session(t.ID, sess)
		}
	}
	s.mu.Lock()
	if s.closing {
		s.mu.Unlock()
		conn.Close(websocket.StatusGoingAway, "shutdown") //nolint:errcheck
		return
	}
	s.wui[c] = struct{}{}
	s.mu.Unlock()
	defer func() {
		s.mu.Lock()
		delete(s.wui, c)
		s.mu.Unlock()
		c.close(websocket.StatusNormalClosure, "")
	}()

	tok, exp := s.mintToken(t.ID, WUIBox)
	welcome := map[string]any{"type": "welcome", "as": c.from, "name": c.as,
		"upload_token": tok, "upload_token_expires_at": exp.UTC().Format(time.RFC3339)}
	if s.o.LobbyTaskID != "" {
		welcome["lobby_task_id"] = s.o.LobbyTaskID
	}
	if err := c.write(ctx, welcome); err != nil {
		return
	}
	for _, p := range s.onlinePeers(ctx, t.ID) { // presence snapshot (wui-live-ws.md §3.2)
		c.write(ctx, presenceFrame(p, "online")) //nolint:errcheck
	}
	s.humanOnline(ctx, t.ID, c.from, 1)
	kctx, stopPing := context.WithCancel(ctx)
	defer stopPing()
	s.keepalive(kctx, conn)
	defer func() { // unregister first so the offline frame is not written to this closing socket
		s.mu.Lock()
		delete(s.wui, c)
		s.mu.Unlock()
		s.humanOnline(ctx, t.ID, c.from, -1)
	}()
	for {
		var f wuiIn
		if err := wsjson.Read(ctx, conn, &f); err != nil {
			return
		}
		switch f.Type {
		case "subscribe", "unsubscribe":
			if f.Channel != "" {
				s.wuiSubscribeChannel(ctx, c, f)
				continue
			}
			task, ok := s.lobbyAlias(f.TaskID)
			if !ok {
				c.write(ctx, wuiErr{"error", "lobby_disabled", http.StatusBadRequest, "the hub runs without SPOOL_HUB_LOBBY_TASK_ID", ""}) //nolint:errcheck
				continue
			}
			if !uuidRe.MatchString(task) {
				c.write(ctx, wuiErr{"error", "bad_frame", http.StatusBadRequest, "task_id must be a UUID or \"lobby\"", ""}) //nolint:errcheck
				continue
			}
			s.mu.Lock()
			if f.Type == "subscribe" {
				c.subs[task] = true
			} else {
				delete(c.subs, task)
			}
			s.mu.Unlock()
			if f.Type == "subscribe" {
				c.write(ctx, map[string]string{"type": "subscribed", "task_id": task}) //nolint:errcheck
			}
		case "send":
			s.wuiSend(ctx, c, f)
		case "token":
			tok, exp := s.mintToken(t.ID, WUIBox)
			c.write(ctx, map[string]string{"type": "token", "upload_token": tok, "upload_token_expires_at": exp.UTC().Format(time.RFC3339)}) //nolint:errcheck
		default:
			c.write(ctx, wuiErr{"error", "bad_frame", http.StatusBadRequest, "unknown frame type", ""}) //nolint:errcheck
		}
	}
}

// wuiSubscribeChannel (un)subscribes a socket to every message stored in a
// channel, new roots included (wui-live-ws.md §3.1). `general` is the lobby.
func (s *Server) wuiSubscribeChannel(ctx context.Context, c *wuiConn, f wuiIn) {
	ch := store.NormalizeChannel(f.Channel)
	if f.Type == "subscribe" {
		ok, err := s.o.Store.ChannelKnown(ctx, c.tenant, ch)
		if err != nil {
			c.write(ctx, wuiErr{"error", "internal", http.StatusInternalServerError, "channel lookup failed", ""}) //nolint:errcheck
			return
		}
		if !store.ValidChannelID(ch) || !ok {
			c.write(ctx, wuiErr{"error", "unknown_channel", http.StatusNotFound, "no channel " + f.Channel + " in this tenant", ""}) //nolint:errcheck
			return
		}
	}
	s.mu.Lock()
	if f.Type == "subscribe" {
		c.chans[ch] = true
	} else {
		delete(c.chans, ch)
	}
	s.mu.Unlock()
	if f.Type == "subscribe" {
		c.write(ctx, map[string]string{"type": "subscribed", "channel": ch}) //nolint:errcheck
	}
}

// wuiSend builds the v:1 object for a browser send and stores it through the
// shared commit path (messages + deliveries rows).
func (s *Server) wuiSend(ctx context.Context, c *wuiConn, f wuiIn) {
	fail := func(tok string, status int, detail string) {
		c.write(ctx, wuiErr{"error", tok, status, detail, f.MsgID}) //nolint:errcheck
	}
	task, ok := s.lobbyAlias(f.TaskID)
	if !ok {
		fail("lobby_disabled", http.StatusBadRequest, "the hub runs without SPOOL_HUB_LOBBY_TASK_ID")
		return
	}
	if !uuidRe.MatchString(task) {
		fail("bad_json", http.StatusBadRequest, "task_id must be a UUID or \"lobby\"")
		return
	}
	id := strings.ToLower(f.MsgID)
	if id == "" {
		id = newUUID()
	} else if !uuidRe.MatchString(id) {
		fail("bad_json", http.StatusBadRequest, "msg_id must be a UUID")
		return
	}
	f.MsgID = id
	kind := f.Kind
	switch kind {
	case "", "chat": // v:1 has no chat kind (NFR-003): a chat line is a note
		kind = "note"
	}
	to := f.To
	agent := ""
	if s.o.WUIDispatch {
		if agent = dispatchAgent(to, f.Body); agent != "" {
			to = agent
		}
	}
	if to == "" {
		to = BroadcastID
	}
	// A resend of a stored msg_id reuses its ts, so the rebuilt envelope is
	// byte-identical and re-acks instead of conflicting (003 wui-live-ws §4).
	ts := s.o.Now()
	if prev, _, err := s.o.Store.MessageTimes(ctx, c.tenant, id); err == nil {
		ts = prev
	} else if !errors.Is(err, store.ErrNotFound) {
		fail("internal", http.StatusInternalServerError, "message lookup failed")
		return
	}
	m := &msg.Message{V: msg.Version, MsgID: id, TaskID: task, TS: ts.UTC().Format(time.RFC3339),
		From: c.from, To: to, Kind: kind, Body: f.Body, Files: []msg.Attachment{}}
	for _, a := range f.Files {
		mode, k := a.Mode, a.Kind
		if mode == "" {
			mode = "blob"
		}
		if k == "" {
			k = "file"
		}
		sum := a.SHA256
		if sum == "" {
			sum = a.FileID
		}
		m.Files = append(m.Files, msg.Attachment{Mode: mode, Kind: k, FileID: a.FileID, Name: a.Name, Bytes: a.Bytes, SHA256: sum})
	}
	if err := m.Validate(); err != nil {
		fail("bad_json", http.StatusBadRequest, err.Error())
		return
	}
	f.ParentTaskID = strings.ToLower(f.ParentTaskID)
	if tok, status, detail := s.checkTags(ctx, c.tenant, f.Channel, f.ParentTaskID, task); tok != "" {
		fail(tok, status, detail)
		return
	}
	channel := store.NormalizeChannel(f.Channel)
	var box string
	var pin ed25519.PublicKey
	if agent != "" {
		var tok string
		var status int
		var detail string
		if box, pin, tok, status, detail = s.dispatchCheck(ctx, c, m); tok != "" {
			fail(tok, status, detail)
			return
		}
	}
	if tok, status, detail := s.admit(ctx, c.tenant, m); tok != "" {
		fail(tok, status, detail)
		return
	}
	var env *wire.Envelope
	if agent != "" {
		var err error
		if env, err = s.dispatchEnvelope(box, channel, f.ParentTaskID, pin, m); err != nil {
			s.o.Log.Error().Err(err).Str("msg_id", id).Msg("wui dispatch sign")
			fail("wui_unpinned", http.StatusConflict, "the box-wui signature does not verify against this tenant's pin")
			return
		}
	} else {
		inner, err := msg.Canonical(m)
		if err != nil {
			fail("bad_json", http.StatusBadRequest, "message does not encode")
			return
		}
		env = &wire.Envelope{FromBox: WUIBox, ToBox: WUIBox, Channel: channel,
			ParentTaskID: f.ParentTaskID, Msg: inner, Sig: ""}
	}
	r, err := s.commitRow(ctx, c.tenant, env, m)
	if errors.Is(err, store.ErrConflict) {
		fail("conflict_msg", http.StatusConflict, "msg_id exists with a different message")
		return
	}
	if err != nil {
		s.o.Log.Error().Err(err).Str("msg_id", id).Msg("wui store message")
		fail("internal", http.StatusInternalServerError, "message not stored")
		return
	}
	receivedAt := r.receivedAt
	if !r.inserted { // a duplicate acks with the stored row's cursor
		if _, receivedAt, err = s.o.Store.MessageTimes(ctx, c.tenant, id); err != nil {
			s.o.Log.Error().Err(err).Str("msg_id", id).Msg("wui duplicate lookup")
			fail("internal", http.StatusInternalServerError, "message lookup failed")
			return
		}
	}
	ack := map[string]any{"type": "ack", "msg_id": id, "task_id": task,
		"cursor": encCursor(receivedAt, id), "received_at": rfc(receivedAt)}
	if agent != "" {
		ack["to_box"], ack["delivery"] = box, r.delivery
		s.o.Log.Info().Str("tenant", c.tenant).Str("msg_id", id).Str("from", m.From).
			Str("to", m.To).Str("to_box", box).Str("delivery", r.delivery).Msg("wui dispatch")
	}
	c.write(ctx, ack) //nolint:errcheck
}

// admit applies the 006 billing / quota rules and the OQ-11 file rule to a
// hub-built message (the box path runs the same checks inline in onSend).
func (s *Server) admit(ctx context.Context, tenant string, m *msg.Message) (string, int, string) {
	trow, err := s.o.Store.GetTenant(ctx, tenant)
	if err != nil {
		return "internal", http.StatusInternalServerError, "tenant unavailable"
	}
	if !billing.AllowsWrite(trow.BillingStatus) {
		return billing.TokenUnpaid, billing.HTTPUnpaid, "tenant billing is unpaid"
	}
	has, err := s.o.Store.HasMessage(ctx, tenant, m.MsgID)
	if err != nil {
		return "internal", http.StatusInternalServerError, "message lookup failed"
	}
	if !has {
		n, err := s.o.Store.CountMessagesSince(ctx, tenant, billing.PeriodStart(s.o.Now()))
		if err != nil {
			return "internal", http.StatusInternalServerError, "quota lookup failed"
		}
		if s.quota().Over(billing.Usage{MessagesThisPeriod: n}, 1, 0, 0) != "" {
			return billing.TokenQuota, billing.HTTPQuota, "message quota for this period is exceeded"
		}
	}
	if !s.o.AllowTextOnly {
		for _, a := range m.Files {
			if a.Mode != "blob" {
				continue
			}
			key, kerr := blob.Key(tenant, a.FileID)
			ok := false
			if kerr == nil {
				ok, _ = s.o.Blob.Exists(ctx, key)
			}
			if !ok {
				return "missing_file", http.StatusBadRequest, "file_id " + a.FileID + " is not held by the hub"
			}
		}
	}
	return "", 0, ""
}

// fanoutWUI pushes one stored message to every browser subscribed to its task
// or to its stored channel (once per socket).
func (s *Server) fanoutWUI(ctx context.Context, tenant, taskID, channel, msgID string, receivedAt time.Time, env []byte) {
	s.mu.Lock()
	var targets []*wuiConn
	for c := range s.wui {
		if c.tenant == tenant && (c.subs[taskID] || channel != "" && c.chans[channel]) {
			targets = append(targets, c)
		}
	}
	s.mu.Unlock()
	if len(targets) == 0 {
		return
	}
	var e wire.Envelope
	if err := json.Unmarshal(env, &e); err != nil {
		return
	}
	frame := map[string]any{"type": "message", "task_id": taskID, "cursor": encCursor(receivedAt, msgID),
		"received_at": rfc(receivedAt), "envelope": e.Msg, "env": json.RawMessage(env)}
	if channel != "" {
		frame["channel"] = channel
	}
	if e.ParentTaskID != "" {
		frame["parent_task_id"] = e.ParentTaskID
	}
	for _, c := range targets {
		c.write(ctx, frame) //nolint:errcheck
	}
}

// DELETE /v1/files/{file_id}: owner-requested; needs a valid upload token of
// the tenant (box or box-wui). 204, or 404 when absent / another tenant's.
func (s *Server) handleDeleteFile(w http.ResponseWriter, r *http.Request) {
	s.allowOrigin(w, r)
	t, err := s.tenantOf(r)
	if err != nil {
		writeErr(w, http.StatusNotFound, "unknown_tenant", "no tenant for this host")
		return
	}
	if _, ok := s.bearer(r, t.ID); !ok {
		writeErr(w, http.StatusUnauthorized, "door", "a valid upload token is required")
		return
	}
	key, err := blob.Key(t.ID, r.PathValue("file_id"))
	if err != nil {
		writeErr(w, http.StatusNotFound, "not_found", "no such file")
		return
	}
	switch err := s.o.Blob.Delete(r.Context(), key); {
	case errors.Is(err, blob.ErrNotFound):
		writeErr(w, http.StatusNotFound, "not_found", "no such file")
	case err != nil:
		writeErr(w, http.StatusInternalServerError, "internal", "delete failed")
	default:
		w.WriteHeader(http.StatusNoContent)
	}
}

// filesPreflight answers CORS preflight for POST /v1/files and
// GET/DELETE /v1/files/{file_id} (the WUI uploads, downloads and deletes).
func (s *Server) filesPreflight(w http.ResponseWriter, r *http.Request) {
	if s.allowOrigin(w, r) {
		h := w.Header()
		h.Set("Access-Control-Allow-Methods", "GET, POST, DELETE")
		h.Set("Access-Control-Allow-Headers", "Authorization, Content-Type")
		h.Set("Access-Control-Max-Age", "600")
	}
	w.WriteHeader(http.StatusNoContent)
}

func randHex(n int) string {
	b := make([]byte, n)
	rand.Read(b) //nolint:errcheck
	return hex.EncodeToString(b)
}

func newUUID() string {
	b := make([]byte, 16)
	rand.Read(b) //nolint:errcheck
	b[6] = (b[6] & 0x0f) | 0x40
	b[8] = (b[8] & 0x3f) | 0x80
	h := hex.EncodeToString(b)
	return h[0:8] + "-" + h[8:12] + "-" + h[12:16] + "-" + h[16:20] + "-" + h[20:32]
}
