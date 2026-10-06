package hub

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"
	"unicode/utf8"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"

	"github.com/csitea/csi-spl/spool-hub-api/internal/agentid"
	"github.com/csitea/csi-spl/spool-hub-api/internal/billing"
	"github.com/csitea/csi-spl/spool-hub-api/internal/blob"
	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/uid"
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
	peers  map[string]bool // DM peers, "<id>" or "<id>@<box>" (v0.5), guarded by srv.mu
	all    bool            // topic-list follow (v0.5), guarded by srv.mu
	upload tokenSlot       // one live upload token per socket
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

// encodeFrame is v as wsjson.Write puts it on the wire (the JSON plus the
// Encoder's newline), so a fan-out encodes one frame once for N sockets
// (perf round 4, G8) and sends each the bytes with writeRaw.
func encodeFrame(v any) ([]byte, error) {
	var b bytes.Buffer
	if err := json.NewEncoder(&b).Encode(v); err != nil {
		return nil, err
	}
	return b.Bytes(), nil
}

// writeRaw is write for a frame encodeFrame already encoded: the same lock
// and write timeout, no marshal.
func (c *wuiConn) writeRaw(ctx context.Context, p []byte) error {
	c.wmu.Lock()
	defer c.wmu.Unlock()
	ctx, cancel := context.WithTimeout(ctx, writeTimeout)
	defer cancel()
	return c.conn.Write(ctx, websocket.MessageText, p)
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
	ToBox  string    `json:"to_box,omitempty"` // specs/058: the box of an <ID>@<box> address
	Files  []wuiFile `json:"files,omitempty"`
	// Hub-envelope tags (wui-live-ws.md §4, channels-v1 §2).
	Channel      string `json:"channel,omitempty"`
	ParentTaskID string `json:"parent_task_id,omitempty"`
	// rdb 0034. Absent on a box or agent send. 0 or 1 from the browser.
	IsParent *int `json:"is_parent,omitempty"`
	// Spec 067 3.3: the channel topic a DM is about (dm_ref.go). Untrusted.
	RefTaskID string `json:"ref_task_id,omitempty"`
	// Subscription targets beyond task_id / channel (wui-live-ws.md v0.5).
	Peer string `json:"peer,omitempty"`
	All  bool   `json:"all,omitempty"`
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

// wuiOrigins turns the view CORS allow-list into websocket origin patterns,
// plus this request's Origin when it is a tenant host of this env (SPL-959:
// exact, never a *.<fqdn> glob, which would also admit the other env).
func (s *Server) wuiOrigins(r *http.Request) []string {
	var out []string
	for _, o := range s.o.ViewCORSOrigins {
		if u, err := url.Parse(o); err == nil && u.Host != "" {
			out = append(out, u.Host)
		}
	}
	if o := r.Header.Get("Origin"); s.o.OriginTenant.TenantHost(o) {
		if h, ok := originHost(o); ok {
			out = append(out, h)
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
	t, hum, ok := s.humanTenant(w, r) // specs/026: the session's active tenant
	if !ok {
		return
	}
	// permessage-deflate, without context takeover (db-payload-audit-round2
	// R2-1): a ~675 B message frame goes out as ~440 B. Takeover would reach
	// ~130..310 B but pins a 1.2 MB flate.Writer per open socket (measured
	// +258 MB heap at 200 sockets) against the hub's 512Mi single instance.
	// Browsers negotiate it themselves; Safari and old clients get plain frames.
	// The library compresses no-takeover messages only from 512 B; the R2-3
	// trimmed message frame is ~480 B, so below that it would go out plain and
	// LARGER than the old frame compressed. From 128 B, as with takeover.
	conn, err := websocket.Accept(w, r, &websocket.AcceptOptions{
		OriginPatterns:       s.wuiOrigins(r),
		CompressionMode:      websocket.CompressionNoContextTakeover,
		CompressionThreshold: wuiFlateThreshold,
	})
	if err != nil {
		return
	}
	conn.SetReadLimit(maxFrameBytes)
	ctx := context.WithoutCancel(r.Context())
	c, ok := s.wuiHello(ctx, conn, t.ID, hum)
	if !ok {
		return
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
	if !s.wuiWelcome(ctx, c) {
		return
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
		if s.demoFrameEnded(ctx, c) { // specs/077 T009: every frame of an ended stay
			return
		}
		s.wuiFrame(ctx, c, f)
	}
}

// wuiHello reads the browser's hello within HelloTimeout and names the
// socket. The member humanTenant PROVED is authoritative (spec 010); hello.as
// never is. CLE-34986: this re-read the session through a second membership
// query and dropped its error, so a failed or racing lookup left c.member ""
// and c.from = the client's own hello.as ("HUM-3"): the socket then spoke as
// that human and every read door was off.
func (s *Server) wuiHello(ctx context.Context, conn *websocket.Conn, tenant, hum string) (*wuiConn, bool) {
	hctx, cancel := context.WithTimeout(ctx, s.o.HelloTimeout)
	var h wuiIn
	err := wsjson.Read(hctx, conn, &h)
	cancel()
	if err != nil {
		conn.Close(wire.CloseHelloTimeout, "hello_timeout") //nolint:errcheck
		return nil, false
	}
	if h.Type != "hello" || len(h.As) > 64 {
		conn.Close(wire.CloseBadFrame, "bad_frame") //nolint:errcheck
		return nil, false
	}
	c := &wuiConn{conn: conn, tenant: tenant, as: h.As, subs: map[string]bool{}, chans: map[string]bool{}, peers: map[string]bool{}}
	switch {
	case msg.ValidID(h.As):
		c.from = h.As
	case strings.TrimSpace(h.As) == "":
		c.from = s.humans.id(tenant, "#"+uid.Hex(6))
	default:
		c.from = s.humans.id(tenant, strings.TrimSpace(h.As))
	}
	switch {
	case hum != "":
		c.member, c.from = hum, hum
		if !msg.ValidID(hum) {
			c.from = s.humans.session(tenant, hum)
		}
	case s.o.ViewDoor != ViewDoorOff:
		conn.Close(wire.CloseUnauthorized, "view_door") //nolint:errcheck
		return nil, false
	}
	return c, true
}

// wuiWelcome writes the welcome (the socket's id, its upload token, the
// lobby), the presence snapshot (wui-live-ws.md §3.2) and one `status` frame
// per live manual status (spec 096).
func (s *Server) wuiWelcome(ctx context.Context, c *wuiConn) bool {
	tok, exp := s.slotToken(&c.upload, c.tenant, WUIBox, c.member)
	welcome := map[string]any{"type": "welcome", "as": c.from, "name": c.as,
		"upload_token": tok, "upload_token_expires_at": exp.UTC().Format(time.RFC3339),
		"revision": s.o.Revision} // bug B: the browser compares it with GET /v1/wui/revision
	if s.o.LobbyTaskID != "" {
		welcome["lobby_task_id"] = s.o.LobbyTaskID
	}
	if err := c.write(ctx, welcome); err != nil {
		return false
	}
	for _, p := range s.onlinePeers(ctx, c.tenant) {
		c.write(ctx, presenceFrame(p, "online")) //nolint:errcheck
	}
	s.statusSnapshot(ctx, c) // spec 096: after the presence snapshot
	return true
}

// wuiFrame answers one browser frame.
func (s *Server) wuiFrame(ctx context.Context, c *wuiConn, f wuiIn) {
	switch f.Type {
	case "subscribe", "unsubscribe":
		switch {
		case f.Channel != "":
			s.wuiSubscribeChannel(ctx, c, f)
		case f.Peer != "" || f.All:
			s.wuiSubscribeFollow(ctx, c, f)
		default:
			s.wuiSubscribeTask(ctx, c, f)
		}
	case "send":
		// One frame, one membership lookup (store.WithMemo): the channel
		// door and both permission checks share it, and the next frame
		// reads it again, so a demotion still bites on an open socket.
		// Perf edition 20261004 E13: the channel's members too (the request
		// memo of privacy.go, G1) - the post door (wuiMayPost) and the live
		// fan-out (fanoutWUI) read channel_humans once per frame, not twice.
		// The socket's context never ends, so the frame gets one that does:
		// the memo is dropped with the frame.
		fctx, done := context.WithCancel(store.WithMemo(ctx))
		s.openMembersMemo(fctx)
		s.wuiSend(fctx, c, f)
		done()
	case "token":
		tok, exp := s.slotToken(&c.upload, c.tenant, WUIBox, c.member)
		c.write(ctx, map[string]string{"type": "token", "upload_token": tok, "upload_token_expires_at": exp.UTC().Format(time.RFC3339)}) //nolint:errcheck
	default:
		c.write(ctx, wuiErr{"error", "bad_frame", http.StatusBadRequest, "unknown frame type", ""}) //nolint:errcheck
	}
}

// wuiSubscribeTask (un)subscribes a socket to one topic ("lobby" is the
// lobby). The read door (rdb 0028): subscribing by task_id used to be enough
// to follow another member's DM or a private channel live. An unknown topic
// is allowed - the lobby, and any new topic, has no message yet - and
// wants() vetoes per message.
func (s *Server) wuiSubscribeTask(ctx context.Context, c *wuiConn, f wuiIn) {
	task, ok := s.lobbyAlias(f.TaskID)
	if !ok {
		c.write(ctx, wuiErr{"error", "lobby_disabled", http.StatusBadRequest, "the hub runs without SPOOL_HUB_LOBBY_TASK_ID", ""}) //nolint:errcheck
		return
	}
	if !uuidRe.MatchString(task) {
		c.write(ctx, wuiErr{"error", "bad_frame", http.StatusBadRequest, "task_id must be a UUID or \"lobby\"", ""}) //nolint:errcheck
		return
	}
	if f.Type == "subscribe" {
		switch may, found, err := s.canReadTopic(ctx, c.tenant, task, c.member); {
		case err != nil:
			c.write(ctx, wuiErr{"error", "internal", http.StatusInternalServerError, "topic lookup failed", ""}) //nolint:errcheck
			return
		case found && !may:
			c.write(ctx, wuiErr{"error", "not_found", http.StatusNotFound, "no such topic", ""}) //nolint:errcheck
			return
		}
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
		// The read door (rdb 0028, privacy.go). The refusal is the SAME
		// unknown_channel a non-existent channel gets: a non-member must not
		// be able to tell the two apart, or the id becomes an oracle for
		// which private channels exist.
		switch may, err := s.canReadChannel(ctx, c.tenant, ch, c.member); {
		case err != nil:
			c.write(ctx, wuiErr{"error", "internal", http.StatusInternalServerError, "channel lookup failed", ""}) //nolint:errcheck
			return
		case !may:
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

// wuiSubscribeFollow (un)subscribes a socket to a DM peer or to the whole
// tenant for the topic list (wui-live-ws.md v0.5 §3.1). Which DMs a socket
// then receives is decided per message in wants.
func (s *Server) wuiSubscribeFollow(ctx context.Context, c *wuiConn, f wuiIn) {
	if f.Peer != "" {
		id, box, _ := strings.Cut(f.Peer, "@")
		if !msg.ValidID(id) || (strings.Contains(f.Peer, "@") && !msg.ValidBoxID(box)) {
			c.write(ctx, wuiErr{"error", "bad_frame", http.StatusBadRequest, "peer must be <agent-id> or <agent-id>@<box-id>", ""}) //nolint:errcheck
			return
		}
	}
	s.mu.Lock()
	switch {
	case f.Peer != "" && f.Type == "subscribe":
		c.peers[f.Peer] = true
	case f.Peer != "":
		delete(c.peers, f.Peer)
	default:
		c.all = f.Type == "subscribe"
	}
	s.mu.Unlock()
	if f.Type != "subscribe" {
		return
	}
	if f.Peer != "" {
		c.write(ctx, map[string]string{"type": "subscribed", "peer": f.Peer}) //nolint:errcheck
	} else {
		c.write(ctx, map[string]any{"type": "subscribed", "all": true}) //nolint:errcheck
	}
}

// parties are the ends of one stored message, for the DM fan-out rules.
type parties struct{ fromID, fromBox, toID, toBox string }

// is reports whether a DM peer key ("<id>" or "<id>@<box>") is either end.
func (p parties) is(key string) bool {
	id, box, withBox := strings.Cut(key, "@")
	return (p.fromID == id && (!withBox || p.fromBox == box)) || (p.toID == id && (!withBox || p.toBox == box))
}

// wants is the per-socket fan-out rule (caller holds srv.mu). A DM (no
// channel) reaches a peer or `all` follower only when the socket is party to
// it, except a peer follow without a member session (door off: the same as
// view-v1 dm=true without a viewer).
// members is the channel's human members (rdb 0028), or nil when no
// membership rule applies - a DM, or one of the public default channels.
func (c *wuiConn) wants(taskID, channel string, p parties, members map[string]bool) bool {
	party := p.is(c.from) || c.member != "" && p.is(c.member)
	// The read door runs FIRST and only ever refuses. A socket may subscribe
	// to a task_id while the topic is still empty (the lobby, a new topic),
	// so a grant taken then must not carry a later post out of a channel this
	// socket is not in.
	switch {
	case channel == "":
		if c.member != "" && !party {
			return false
		}
	case members != nil && c.member != "":
		// c.member == "" is a socket with no sign-in session: the door-off
		// rig (lde), where privacy.go filters nothing either. In the session
		// door humanTenant has already refused an upgrade without one.
		if !members[c.member] && !members[c.from] {
			return false
		}
	}
	if c.subs[taskID] || channel != "" && c.chans[channel] {
		return true
	}
	if channel != "" {
		return c.all
	}
	if c.all && party {
		return true
	}
	if !party && c.member != "" {
		return false
	}
	for k := range c.peers {
		if p.is(k) {
			return true
		}
	}
	return false
}

// uiParent reads the browser is_parent flag. Absent is 1: an older browser's
// send is not a reply, and is_parent 0 is hidden from the middle pane. A box
// send never comes through here; its level is boxLevel's (channels.go). An explicit 0 is a reply written with the topics pane open. Any other
// number is refused.
func uiParent(v *int) (int, bool) {
	if v == nil {
		return 1, true
	}
	if *v != 0 && *v != 1 {
		return 0, false
	}
	return *v, true
}

// wuiSend builds the v:1 object for a browser send and stores it through the
// shared commit path (messages + deliveries rows).
func (s *Server) wuiSend(ctx context.Context, c *wuiConn, f wuiIn) {
	fail := func(rf *frameRefusal) {
		// a refusal used to leave no line in the hub log, and the
		// WUI shows every refusal as "did not reach the hub" - so the owner's
		// ERR-CLIENT-20260927-204316-6D9A could not be joined to a reason on
		// either side. One line per refusal: the token names the check.
		s.o.Log.Info().Str("tenant", c.tenant).Str("member", c.member).Str("msg_id", f.MsgID).
			Str("task_id", f.TaskID).Str("channel", f.Channel).Str("token", rf.token).Int("status", rf.status).
			Str("detail", rf.detail).Msg("wui send refused")
		c.write(ctx, wuiErr{"error", rf.token, rf.status, rf.detail, f.MsgID}) //nolint:errcheck
	}
	task, id, isParent, tok, status, detail := s.wuiIDs(f)
	if tok != "" {
		fail(&frameRefusal{tok, status, detail})
		return
	}
	f.MsgID = id
	to, agent, rf := s.wuiRecipient(ctx, c.tenant, f)
	if rf != nil {
		fail(rf)
		return
	}
	m, rf := s.wuiMessage(ctx, c, f, task, to)
	if rf != nil {
		fail(rf)
		return
	}
	f.ParentTaskID = strings.ToLower(f.ParentTaskID)
	rt, rf := s.wuiRoute(ctx, c, f, m, isParent, agent)
	if rf == nil { // specs/077 T014, demo_dm.go
		rf = frameRefusalOf(s.demoDM(ctx, c, rt.channel, m))
	}
	if rf == nil {
		rf = frameRefusalOf(s.admit(ctx, c.tenant, c.member, m))
	}
	if rf == nil && (rt.signing.agent != "" || rt.signing.fanOut) { // specs/077 T013, before any delivery is built
		rf = frameRefusalOf(s.demoAgentTurn(ctx, c.tenant, c.member, m.MsgID))
	}
	if rf == nil { // specs/077 T025: the demo audit, last check before the store write
		rf = frameRefusalOf(s.demoAuditPost(ctx, c.tenant, c.member, rt.channel, m))
	}
	if rf != nil {
		fail(rf)
		return
	}
	env, tok, status, detail := s.wuiEnvelope(ctx, c.tenant, m, rt.signing, rt.channel, f.ParentTaskID)
	if tok != "" {
		fail(&frameRefusal{tok, status, detail})
		return
	}
	ref := s.wuiDMRef(ctx, c, f.RefTaskID) // spec 067 3.3, dm_ref.go
	s.shareMembersMemo(ctx, ref)
	ctx = ref
	r, err := s.commitRow(ctx, c.tenant, env, m, isParent)
	if errors.Is(err, store.ErrConflict) {
		fail(&frameRefusal{"conflict_msg", http.StatusConflict, "msg_id exists with a different message"})
		return
	}
	if err != nil {
		s.o.Log.Error().Err(err).Str("msg_id", id).Msg("wui store message")
		fail(&frameRefusal{"internal", http.StatusInternalServerError, "message not stored"})
		return
	}
	ack, rf := s.wuiAck(ctx, c, m, rt, r)
	if rf != nil {
		fail(rf)
		return
	}
	c.write(ctx, ack) //nolint:errcheck
	// SPL-997: after the ack, so the sender never waits on it.
	if r.inserted {
		s.fallback(ctx, c.tenant, rt.channel, env, m)
	}
}

// shareMembersMemo makes the request memo of from (privacy.go) the memo of
// to as well: it is keyed on the context, so the one wuiDMRef derives would
// otherwise read channel_humans again in fanoutWUI. to ends with from.
func (s *Server) shareMembersMemo(from, to context.Context) {
	mm := s.requestMemo(from)
	if mm == nil || to.Done() == nil {
		return
	}
	k := membersMemoKey{s, to}
	if _, loaded := membersMemos.LoadOrStore(k, mm); !loaded {
		context.AfterFunc(to, func() { membersMemos.Delete(k) })
	}
}

// frameRefusalOf is the (token, status, detail) triple of the older check
// helpers as a frameRefusal; nil when token is "".
func frameRefusalOf(token string, status int, detail string) *frameRefusal {
	if token == "" {
		return nil
	}
	return &frameRefusal{token, status, detail}
}

// wuiMessage is the v:1 object of a browser send. A resend of a stored
// msg_id reuses its ts, so the rebuilt envelope is byte-identical and
// re-acks instead of conflicting (003 wui-live-ws §4).
func (s *Server) wuiMessage(ctx context.Context, c *wuiConn, f wuiIn, task, to string) (*msg.Message, *frameRefusal) {
	ts := s.o.Now()
	if prev, _, err := s.o.Store.MessageTimes(ctx, c.tenant, f.MsgID); err == nil {
		ts = prev
	} else if !errors.Is(err, store.ErrNotFound) {
		return nil, &frameRefusal{"internal", http.StatusInternalServerError, "message lookup failed"}
	}
	m := &msg.Message{V: s.writeVersion(), MsgID: f.MsgID, TaskID: task, TS: ts.UTC().Format(time.RFC3339),
		From: c.from, To: to, Kind: wuiKind(f.Kind), Body: f.Body, Files: wuiAttachments(f.Files)}
	if err := m.Validate(); err != nil {
		return nil, &frameRefusal{"bad_json", http.StatusBadRequest, err.Error()}
	}
	return m, nil
}

// wuiRouted is where a browser send goes: its channel, and for an agent
// dispatch the box and pin it is signed for.
type wuiRouted struct {
	channel string
	signing wuiSigning
}

// wuiRoute checks the channel / parent tags and the poster's rights and
// resolves the route. Owner rule 2026-09-22: a channel post reaches every
// agent member of the channel, @mention or not - so a plain post now lands
// in agent inboxes, which is what agents.command guards (025 §3.1, "command
// an agent through box-wui dispatch"). POSTING stays notes.send: a tester
// must still be able to chat in #lobby, and #lobby may have agent members,
// so raising the post itself to agents.command would silence the role
// altogether. The FAN-OUT is what the stronger permission buys - without it
// the post is stored and shown in every browser (fanoutWUI) and no box
// delivery is built, which is exactly the pre-fan-out behaviour. Same
// identity rule as a dispatch (014 §3 step 1): a signed-in member, never a
// door-off anonymous socket.
func (s *Server) wuiRoute(ctx context.Context, c *wuiConn, f wuiIn, m *msg.Message, isParent int, agent string) (wuiRouted, *frameRefusal) {
	var rt wuiRouted
	if rf := frameRefusalOf(s.checkTags(ctx, c.tenant, f.Channel, f.ParentTaskID, m.TaskID)); rf != nil {
		return rt, rf
	}
	rt.channel = s.wuiChannel(ctx, c.tenant, f.Channel, m.TaskID, isParent)
	if rf := frameRefusalOf(s.wuiMayPost(ctx, c, rt.channel, f.Channel, agent)); rf != nil {
		return rt, rf
	}
	if agent == "" { // a channel-less ALL-0 reply goes to the topic's agent (topic_reply.go)
		if rt.signing = s.topicReplyAgent(ctx, c, m, rt.channel, isParent); rt.signing.agent != "" {
			m.To = rt.signing.agent
			return rt, nil
		}
	}
	rt.signing = wuiSigning{agent: agent, fanOut: agent == "" && rt.channel != "" && s.o.WUIDispatch && c.member != "" &&
		s.allowed(ctx, c.member, c.tenant, rbac.AgentsCommand)}
	if agent != "" {
		box, pin, tok, status, detail := s.dispatchCheck(ctx, c, m, dispatchBox(f))
		if tok != "" {
			return rt, &frameRefusal{tok, status, detail}
		}
		rt.signing.box, rt.signing.pin = box, pin
	}
	return rt, nil
}

// wuiAck is the browser's ack; a duplicate acks with the stored row's
// cursor, and an agent dispatch names its box and delivery.
func (s *Server) wuiAck(ctx context.Context, c *wuiConn, m *msg.Message, rt wuiRouted, r committed) (map[string]any, *frameRefusal) {
	receivedAt := r.receivedAt
	if !r.inserted {
		var err error
		if _, receivedAt, err = s.o.Store.MessageTimes(ctx, c.tenant, m.MsgID); err != nil {
			s.o.Log.Error().Err(err).Str("msg_id", m.MsgID).Msg("wui duplicate lookup")
			return nil, &frameRefusal{"internal", http.StatusInternalServerError, "message lookup failed"}
		}
	}
	ack := map[string]any{"type": "ack", "msg_id": m.MsgID, "task_id": m.TaskID,
		"cursor": encCursor(receivedAt, m.MsgID), "received_at": rfc(receivedAt)}
	if rt.signing.agent != "" {
		ack["to_box"], ack["delivery"] = rt.signing.box, r.delivery
		s.o.Log.Info().Str("tenant", c.tenant).Str("msg_id", m.MsgID).Str("from", m.From).
			Str("to", m.To).Str("to_box", rt.signing.box).Str("delivery", r.delivery).Msg("wui dispatch")
	}
	return ack, nil
}

// wuiIDs checks the ids of a browser send: the task ("lobby" resolved), the
// msg id (minted when the browser sent none) and the panel flag. A refusal
// comes back as the hub's (tok, status, detail) triple.
func (s *Server) wuiIDs(f wuiIn) (task, id string, isParent int, tok string, status int, detail string) {
	task, ok := s.lobbyAlias(f.TaskID)
	if !ok {
		return "", "", 0, "lobby_disabled", http.StatusBadRequest, "the hub runs without SPOOL_HUB_LOBBY_TASK_ID"
	}
	if !uuidRe.MatchString(task) {
		return "", "", 0, "bad_json", http.StatusBadRequest, "task_id must be a UUID or \"lobby\""
	}
	id = strings.ToLower(f.MsgID)
	if id == "" {
		id = uid.New()
	} else if !uuidRe.MatchString(id) {
		return "", "", 0, "bad_json", http.StatusBadRequest, "msg_id must be a UUID"
	}
	isParent, ok = uiParent(f.IsParent)
	if !ok {
		return "", "", 0, "bad_json", http.StatusBadRequest, "is_parent must be 0 or 1"
	}
	return task, id, isParent, "", 0, ""
}

// wuiMayPost checks that c may post into channel (asked for as asked):
// rdb 0028 - posting into a channel you are not in would both leak the post
// to its members and place you in a conversation you cannot read back (same
// unknown_channel token as a channel that does not exist); specs/025 - a
// note needs notes.send, commanding an agent agents.command (checked per
// send, so a demotion bites on the open socket too).
func (s *Server) wuiMayPost(ctx context.Context, c *wuiConn, channel, asked, agent string) (string, int, string) {
	switch may, err := s.canReadChannel(ctx, c.tenant, channel, c.member); {
	case err != nil:
		return "internal", http.StatusInternalServerError, "channel lookup failed"
	case !may:
		return "unknown_channel", http.StatusNotFound, "no channel " + asked + " in this tenant"
	}
	perm := rbac.NotesSend
	if agent != "" {
		perm = rbac.AgentsCommand
	}
	if c.member != "" && !s.allowed(ctx, c.member, c.tenant, perm) {
		return "forbidden", http.StatusForbidden, "your role in this tenant does not grant " + perm
	}
	return "", 0, ""
}

// wuiRecipient is the v:1 `to` of a browser send and, when box-wui dispatch
// is on and the body addresses an agent, that agent (else "").
//
// Owner 2026-10-05 (t1 dc6d5e3f: "I should be able to tag only currently
// active agents"): a legacy id (spec 061) is resolved here, as a box frame's
// is (resolveAgent). One with an alias goes to its successor, in the same
// topic; one without is refused after agentid.LegacyUntil, so the sender
// sees "not sent" instead of a delivery a box drops ("AGY-3499 is retired as
// an id", csi-rel prd 5f0d5200).
func (s *Server) wuiRecipient(ctx context.Context, tenant string, f wuiIn) (to, agent string, rf *frameRefusal) {
	to = f.To
	if s.o.WUIDispatch {
		if agent = dispatchAgent(to, f.Body); agent != "" {
			to = agent
		}
	}
	if to == "" {
		return BroadcastID, agent, nil
	}
	got, err := agentid.ResolveOn(to, dispatchBox(f), s.aliasLookup(ctx, tenant))
	var re *agentid.RetiredError
	switch {
	case errors.As(err, &re) && agentid.IsNew(re.New):
		got = re.New
	case err != nil:
		return "", "", &frameRefusal{TokenRetiredID, http.StatusGone, err.Error() + "; that agent is no longer active"}
	}
	if agent != "" {
		agent = got
	}
	return got, agent, nil
}

// wuiKind maps the browser's kind onto v:1: it has no chat kind (NFR-003),
// so a chat line is a note.
func wuiKind(kind string) string {
	if kind == "" || kind == "chat" {
		return "note"
	}
	return kind
}

// wuiAttachments turns the browser's file list into v:1 attachments: an
// uploaded blob unless it says otherwise, keyed by its file id when the
// browser sent no digest.
func wuiAttachments(files []wuiFile) []msg.Attachment {
	out := []msg.Attachment{}
	for _, a := range files {
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
		out = append(out, msg.Attachment{Mode: mode, Kind: k, FileID: a.FileID, Name: a.Name, Bytes: a.Bytes, SHA256: sum})
	}
	return out
}

// wuiSigning is how wuiSend decided to sign a browser post: a dispatch to
// agent on box (pinned key pin), a channel fan-out, or neither.
type wuiSigning struct {
	agent, box string
	pin        ed25519.PublicKey
	fanOut     bool
}

// wuiEnvelope wraps m for storage: box-wui-signed to the agent's box for a
// dispatch, box-wui-signed to box-wui for a channel fan-out, else the
// unsigned browser-only envelope.
func (s *Server) wuiEnvelope(ctx context.Context, tenant string, m *msg.Message, sg wuiSigning, channel, parentTaskID string) (*wire.Envelope, string, int, string) {
	if sg.agent != "" {
		env, err := s.dispatchEnvelope(sg.box, channel, parentTaskID, sg.pin, m)
		if err != nil {
			s.o.Log.Error().Err(err).Str("msg_id", m.MsgID).Msg("wui dispatch sign")
			return nil, "wui_unpinned", http.StatusConflict, "the box-wui signature does not verify against this tenant's pin"
		}
		return env, "", 0, ""
	}
	if sg.fanOut {
		// The same signer as a dispatch, to_box box-wui: no single box owns a
		// channel post, and routeChannel builds one delivery per member box.
		// A tenant that has not pinned box-wui gets the old browser-only post
		// rather than a refusal - it never asked for agents to read its chat.
		if p := s.wuiPin(ctx, tenant); p != nil {
			signed, err := s.dispatchEnvelope(WUIBox, channel, parentTaskID, p, m)
			if err == nil {
				return signed, "", 0, ""
			}
			s.o.Log.Error().Err(err).Str("msg_id", m.MsgID).Msg("wui channel sign")
		} else {
			s.warnUnpinnedAgents(ctx, tenant, channel, m.MsgID)
		}
	}
	inner, err := msg.Canonical(m)
	if err != nil {
		return nil, "bad_json", http.StatusBadRequest, "message does not encode"
	}
	return &wire.Envelope{FromBox: WUIBox, ToBox: WUIBox, Channel: channel,
		ParentTaskID: parentTaskID, Msg: inner, Sig: ""}, "", 0, ""
}

// admit applies the 006 billing / quota rules and the OQ-11 file rule to a
// hub-built message (the box path runs the same checks inline in onSend),
// and a demo_user's size cap and post quota (demo_post_quota.go).
func (s *Server) admit(ctx context.Context, tenant, member string, m *msg.Message) (string, int, string) {
	trow, err := s.o.Store.GetTenant(ctx, tenant)
	if err != nil {
		return "internal", http.StatusInternalServerError, "tenant unavailable"
	}
	if !billing.AllowsWrite(trow.BillingStatus) {
		return billing.TokenUnpaid, billing.HTTPUnpaid, "tenant billing is unpaid"
	}
	if tok, status, detail := s.messageQuota(ctx, tenant, m.MsgID); tok != "" {
		return tok, status, detail
	}
	if missing := s.missingFile(ctx, tenant, m.Files); missing != "" {
		return "missing_file", http.StatusBadRequest, "file_id " + missing + " is not held by the hub"
	}
	if member != "" { // "" = the door-off anonymous rig, which reads everything
		switch f, err := s.unreadableFile(ctx, tenant, m.Files, "", member); {
		case err != nil:
			return "internal", http.StatusInternalServerError, "file lookup failed"
		case f != "":
			return "missing_file", http.StatusBadRequest, "file_id " + f + " is not held by the hub"
		}
	}
	return s.demoSend(ctx, tenant, member, m) // specs/077 T012: before the store write
}

// fanoutWUI pushes one stored message row to every browser subscribed to its task,
// its stored channel, one of its DM ends, or the whole tenant (once per socket).
func (s *Server) fanoutWUI(ctx context.Context, row store.Message) {
	tenant, taskID, channel := row.TenantID, row.TaskID, row.Channel
	p := parties{row.FromID, row.FromBox, row.ToID, row.ToBox}
	receivedAt, env, isParent, typedBy := row.ReceivedAt, row.Env, row.IsParent, row.TypedBy
	// One membership lookup per stored message, outside the lock: wants()
	// runs under srv.mu and cannot go to the store, and a set cached on the
	// socket would keep delivering to someone removed from the channel
	// seconds ago.
	members := s.channelMemberSet(ctx, tenant, channel)
	s.fanoutFlow(ctx, row) // spec 062: the line's flow events, to their members' sockets
	s.mu.Lock()
	var targets []*wuiConn
	for c := range s.wui {
		if c.tenant == tenant && c.wants(taskID, channel, p, members) {
			targets = append(targets, c)
		}
	}
	s.mu.Unlock()
	if len(targets) == 0 {
		return
	}
	trimmed, parent, ok := wuiFrameEnv(env, taskID, channel)
	if !ok {
		return
	}
	// No `envelope` copy of env.msg (db-payload-audit-2026-10-02 cut 3): the
	// WUI reads only `env`, and the copy was 36 % of every frame per tab.
	// No `cursor` either (round 2, R2-3): the WUI rebuilds it, see trimWUIEnv.
	frame := map[string]any{"type": "message", "task_id": taskID,
		"received_at": rfc(receivedAt), "env": trimmed,
		"is_parent": isParent}
	if channel != "" {
		frame["channel"] = channel
	}
	if parent != "" {
		frame["parent_task_id"] = parent
	}
	if typedBy != "" { // specs/036 FR-011: top level, like edited_by
		frame["typed_by"] = typedBy
	}
	// Spec 068: the responsible seat, as the view row carries it. A stored
	// row may not hand it back (the 0110 trigger sets it), so derive it the
	// way the insert does.
	responsible := row.Responsible
	if responsible == "" {
		responsible = store.InsertResponsible(row.ToID, row.ToBox)
	}
	if responsible != "" {
		frame["responsible"] = responsible
	}
	// Spec 067: as the view row carries them; the frame only, never a box's
	// envelope (dm_ref.go).
	if row.RefTaskID != "" {
		frame["ref_task_id"] = row.RefTaskID
	}
	if row.MirrorOf != "" {
		frame["mirror_of"] = row.MirrorOf
	}
	b, err := encodeFrame(frame)
	if err != nil {
		return
	}
	for _, c := range targets {
		c.writeRaw(ctx, b) //nolint:errcheck
	}
}

// wuiFlateThreshold is the smallest browser frame the hub deflates (R2-3).
const wuiFlateThreshold = 128

// trimWUIEnv is env as the `message` frame carries it (db-payload audit
// round 2, R2-3): without what the frame or a default already says. Each is
// dropped only when redundant: env.channel equal to the frame's channel,
// msg.task_id equal to the frame's task_id, files `[]`, sig "", from_box /
// to_box "box-wui". The WUI's messageFromFrame (utils/live-ws.mjs) puts each
// back and rebuilds the frame's `cursor` from received_at + msg_id
// (encCursor), so its stores hold the same message as before. A shape it
// cannot parse is sent unchanged.
//
// It rewrites env in one pass (perf edition 20261004 E13, view.go's G9
// shape) instead of decoding env and msg into maps and encoding both back;
// trimWUIEnvMap is that reference, byte for byte, and still handles what
// the one pass declines.
func trimWUIEnv(env []byte, taskID, channel string) json.RawMessage {
	if b, _, ok := trimWUIEnvFast(env, taskID, channel); ok {
		return b
	}
	return trimWUIEnvMap(env, taskID, channel)
}

// wuiFrameEnv is a `message` frame's env (trimWUIEnv) and parent_task_id
// from one stored envelope, in the one pass when it can (E13): no
// wire.Envelope decode beside it. ok=false exactly where that decode
// failed, which sends no frame.
func wuiFrameEnv(env []byte, taskID, channel string) (trimmed json.RawMessage, parent string, ok bool) {
	if b, parent, ok := trimWUIEnvFast(env, taskID, channel); ok {
		return b, parent, true
	}
	var e wire.Envelope
	if err := json.Unmarshal(env, &e); err != nil {
		return nil, "", false
	}
	return trimWUIEnvMap(env, taskID, channel), e.ParentTaskID, true
}

// envStringFields are wire.Envelope's string members. encoding/json fills
// a field from a key equal to its name under ASCII case folding, and fails
// on a value that is neither a string nor null.
var envStringFields = [...]string{"from_box", "to_box", "channel", "parent_task_id", "sig"}

// trimWUIEnvFast is trimWUIEnv without maps: what json.Marshal of the
// trimmed maps returns (keys sorted, values compacted with HTML escaping),
// and the parent_task_id a wire.Envelope decode of env reads. It declines
// (false) what trimEnvFast declines - not valid JSON, not an object, or an
// object (top or msg) with a repeated key or a key that is not plain
// printable ASCII free of <, > and & - and an env whose wire.Envelope
// decode would fail or would read a member by another case of its name.
func trimWUIEnvFast(env []byte, taskID, channel string) (json.RawMessage, string, bool) {
	if !json.Valid(env) {
		return nil, "", false
	}
	var topBuf, msgBuf [16]envMember
	top, ok := envMembers(topBuf[:0], env)
	if !ok {
		return nil, "", false
	}
	var inner []envMember
	parent, hasMsg, plain := "", false, true
	for _, m := range top {
		p, isParent, ok := wuiEnvField(m)
		if !ok {
			return nil, "", false
		}
		if isParent {
			parent = p
		}
		if strings.EqualFold(string(m.key), "msg") {
			if string(m.key) != "msg" {
				return nil, "", false
			}
			hasMsg = true
			if m.val[0] != '{' { // null, or not an object: sent unchanged
				plain = false
				continue
			}
			if inner, ok = envMembers(msgBuf[:0], m.val); !ok {
				return nil, "", false
			}
		}
	}
	if !hasMsg || !plain {
		return env, parent, true
	}
	out := make([]byte, 0, len(env))
	out = append(out, '{')
	for _, m := range top {
		switch string(m.key) {
		case "sig":
			if wuiStringIs(m.val, "") {
				continue
			}
		case "from_box", "to_box":
			if wuiStringIs(m.val, WUIBox) {
				continue
			}
		case "channel":
			if channel != "" && wuiStringIs(m.val, channel) {
				continue
			}
		}
		if len(out) > 1 {
			out = append(out, ',')
		}
		out = append(append(append(out, '"'), m.key...), '"', ':')
		if string(m.key) != "msg" {
			out = appendCompactHTML(out, m.val)
			continue
		}
		out = append(out, '{')
		first := true
		for _, f := range inner {
			if string(f.key) == "files" && string(f.val) == "[]" ||
				string(f.key) == "task_id" && wuiStringIs(f.val, taskID) {
				continue
			}
			if !first {
				out = append(out, ',')
			}
			first = false
			out = append(append(append(out, '"'), f.key...), '"', ':')
			out = appendCompactHTML(out, f.val)
		}
		out = append(out, '}')
	}
	return append(out, '}'), parent, true
}

// wuiEnvField checks one top member as a wire.Envelope decode reads it:
// ok=false where that decode fails on it, or would read it by another case
// of a field name; isParent when it is parent_task_id (a string).
func wuiEnvField(m envMember) (parent string, isParent, ok bool) {
	for _, f := range envStringFields {
		if !strings.EqualFold(string(m.key), f) {
			continue
		}
		if string(m.key) != f || m.val[0] != '"' && string(m.val) != "null" {
			return "", false, false
		}
		if f == "parent_task_id" && m.val[0] == '"' {
			parent, ok = envString(m.val)
			return parent, true, ok
		}
	}
	return "", false, true
}

// envString decodes the JSON string v as encoding/json does.
func envString(v []byte) (string, bool) {
	if bytes.IndexByte(v, '\\') < 0 && utf8.Valid(v) {
		return string(v[1 : len(v)-1]), true
	}
	var s string
	return s, json.Unmarshal(v, &s) == nil
}

// wuiStringIs is trimWUIEnvMap's test of one member against s: the value
// decodes into a Go string equal to s, and JSON null decodes into "".
func wuiStringIs(v []byte, s string) bool {
	if string(v) == "null" {
		return s == ""
	}
	return envStringIs(v, s)
}

// trimWUIEnvMap is trimWUIEnv by decoding into maps (the shape before
// E13): the reference the one pass matches, and its fallback.
func trimWUIEnvMap(env []byte, taskID, channel string) json.RawMessage {
	var e map[string]json.RawMessage
	if json.Unmarshal(env, &e) != nil {
		return env
	}
	var m map[string]json.RawMessage
	if json.Unmarshal(e["msg"], &m) != nil || m == nil {
		return env
	}
	dropIf := func(o map[string]json.RawMessage, k, v string) {
		var got string
		if raw, ok := o[k]; ok && json.Unmarshal(raw, &got) == nil && got == v {
			delete(o, k)
		}
	}
	dropIf(e, "sig", "")
	dropIf(e, "from_box", WUIBox)
	dropIf(e, "to_box", WUIBox)
	if channel != "" {
		dropIf(e, "channel", channel)
	}
	dropIf(m, "task_id", taskID)
	if f, ok := m["files"]; ok && strings.TrimSpace(string(f)) == "[]" {
		delete(m, "files")
	}
	mb, err := json.Marshal(m)
	if err != nil {
		return env
	}
	e["msg"] = mb
	out, err := json.Marshal(e)
	if err != nil {
		return env
	}
	return out
}

// fanoutChannel pushes one `channel` frame to every browser socket of the
// tenant (wui-live-ws v0.6 §3.3). A channel created in one session has
// to appear in every other session's sidebar without a reload, and it carries no
// message yet, so the message fan-out cannot carry it.
//
// Tenant-scoped and door-gated by construction: s.wui only holds sockets that
// passed humanTenant, and the frame says nothing a member of the tenant cannot
// read from GET /v1/view/channels.
func (s *Server) fanoutChannel(ctx context.Context, tenant string, c store.Channel) {
	frame := map[string]any{"type": "channel", "channel": c.ChannelID, "name": c.Name,
		"description": c.Description, "created_by": c.CreatedBy, "created_at": rfc(c.CreatedAt)}
	// rdb 0028: the sidebar event carries the channel's NAME and description,
	// so it goes to its members only - a fresh channel means its creator.
	s.fanoutChannelFrame(ctx, tenant, s.channelMemberSet(ctx, tenant, c.ChannelID), frame)
}

// fanoutChannelFrame writes frame to every browser socket of tenant whose
// member is in members; nil members (a default channel) is every socket.
func (s *Server) fanoutChannelFrame(ctx context.Context, tenant string, members map[string]bool, frame map[string]any) {
	s.mu.Lock()
	var targets []*wuiConn
	for w := range s.wui {
		if w.tenant != tenant {
			continue
		}
		if members != nil && w.member != "" && !members[w.member] && !members[w.from] {
			continue
		}
		targets = append(targets, w)
	}
	s.mu.Unlock()
	for _, w := range targets {
		w.write(ctx, frame) //nolint:errcheck
	}
}

// DELETE /v1/files/{file_id}: owner-requested; needs a valid upload token of
// the tenant. 204, or 404 when absent / another tenant's / not the caller's.
//
// any upload token of the tenant deleted any blob of it - the
// box-wui token every signed-in browser gets in its welcome included - so a
// member outside #hr could delete an #hr attachment or another member's DM
// file, and 204 vs 404 told them whether a known sha256 existed. The delete
// now needs the READ door the download has (mayDeleteFile), and answers a
// refusal exactly as a missing file.
func (s *Server) handleDeleteFile(w http.ResponseWriter, r *http.Request) {
	s.allowOrigin(w, r)
	t, _, ok := s.tokenTenant(w, r) // specs/026: the token's tenant
	if !ok || !s.tokenMayWriteFiles(w, r, t.ID) {
		return
	}
	fileID := r.PathValue("file_id")
	key, err := blob.Key(t.ID, fileID)
	if err != nil {
		writeErr(w, http.StatusNotFound, "not_found", "no such file")
		return
	}
	switch may, err := s.mayDeleteFile(r, t.ID, fileID); {
	case err != nil:
		writeErr(w, http.StatusInternalServerError, "internal", "delete failed")
		return
	case !may:
		writeErr(w, http.StatusNotFound, "not_found", "no such file")
		return
	}
	switch err := s.o.Blob.Delete(r.Context(), key); {
	case errors.Is(err, blob.ErrNotFound):
		writeErr(w, http.StatusNotFound, "not_found", "no such file")
	case err != nil:
		writeErr(w, http.StatusInternalServerError, "internal", "delete failed")
	default:
		s.fileUsage.forget(t.ID) // the next upload lists the prefix afresh
		w.WriteHeader(http.StatusNoContent)
	}
}

// mayDeleteFile is mayReadFile for a delete. A box token is judged as the
// box (the files it may read); the box-wui token names no one - every
// signed-in browser holds it - so the browser's delete is judged as the
// SIGNED-IN HUMAN whose session cookie rides with it, by the same door their
// download passes. No session in the session door = refused.
func (s *Server) mayDeleteFile(r *http.Request, tenant, fileID string) (bool, error) {
	if _, box, _, ok := s.bearerAny(r); ok && box == WUIBox {
		asHuman := r.Clone(r.Context())
		asHuman.Header.Del("Authorization")
		return s.mayReadFile(asHuman, tenant, fileID)
	}
	return s.mayReadFile(r, tenant, fileID)
}

// filesPreflight answers CORS preflight for POST /v1/files and
// GET/DELETE /v1/files/{file_id} (the WUI uploads, downloads and deletes).
func (s *Server) filesPreflight(w http.ResponseWriter, r *http.Request) {
	if s.allowOrigin(w, r) {
		h := w.Header()
		h.Set("Access-Control-Allow-Methods", "GET, POST, DELETE")
		h.Set("Access-Control-Allow-Headers", "Authorization, Content-Type, X-Locale")
		h.Set("Access-Control-Max-Age", corsMaxAge)
	}
	w.WriteHeader(http.StatusNoContent)
}
