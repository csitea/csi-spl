package hub

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"

	"github.com/csitea/csi-spl/spool-hub-api/internal/agentid"
	"github.com/csitea/csi-spl/spool-hub-api/internal/billing"
	"github.com/csitea/csi-spl/spool-hub-api/internal/blob"
	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// maxFrameBytes bounds one inbound frame: a 64 KiB body plus envelope overhead.
const maxFrameBytes = 512 << 10

// writeTimeout bounds one frame write; a stuck peer is dropped.
const writeTimeout = 10 * time.Second

// session is one authenticated socket.
type session struct {
	srv    *Server
	conn   *websocket.Conn
	tenant string
	box    string
	role   string
	// msgVersions: the inner versions this box's reader accepts (hello
	// msg_versions, specs/020); a pre-020 box sends none and gets v:1 only.
	msgVersions []int
	// features: what the box client's hello said it understands beyond the
	// base protocol (SPL-987 FeatureBackfill); fixed after hello.
	features []string
	// since: when this socket said hello; the fallback responder prefers the
	// longest-online box (SPL-997).
	since time.Time

	upload tokenSlot // one live upload token per socket
	// agents is this box's seated roster, sorted: what onSend checks a
	// sender against. It is read from the welcome's roster at hello and
	// replaced by a stored announce, both on this session's read goroutine,
	// which is also the only one that reads it (onSend).
	agents []string
	// run is the box's last report of which roster agents run (agent_run.go,
	// t1 bc1a43e1); nil = not reported. Guarded by srv.mu once registered.
	run map[string]bool

	wmu     sync.Mutex
	follows map[string]bool // task ids tailed with follow=true; guarded by srv.mu
	once    sync.Once

	// welcomed is closed once the welcome frame has been written (or failed).
	// The session is registered before its welcome, so another goroutine (a
	// roster broadcast, a live recv push) can target it early; every frame but
	// the welcome waits here, so the box always reads welcome first.
	welcomed    chan struct{}
	welcomeOnce sync.Once
}

// accepts reports whether this box's reader takes inner version v. No
// msg_versions in hello = a pre-020 box = v:1 only.
func (x *session) accepts(v int) bool {
	if v == 0 { // unreadable v: not this guard's call, push as before
		return true
	}
	if len(x.msgVersions) == 0 {
		return v == msg.V1
	}
	for _, a := range x.msgVersions {
		if a == v {
			return true
		}
	}
	return false
}

func (x *session) markWelcomed() { x.welcomeOnce.Do(func() { close(x.welcomed) }) }

func (x *session) write(ctx context.Context, f wire.Frame) error {
	if f.Type != wire.TWelcome {
		wctx, cancel := context.WithTimeout(ctx, writeTimeout)
		select {
		case <-x.welcomed:
			cancel()
		case <-wctx.Done():
			cancel()
			return wctx.Err()
		}
	}
	x.wmu.Lock()
	defer x.wmu.Unlock()
	ctx, cancel := context.WithTimeout(ctx, writeTimeout)
	defer cancel()
	return wsjson.Write(ctx, x.conn, f)
}

func (x *session) close(code websocket.StatusCode, reason string) {
	x.once.Do(func() { x.conn.Close(code, reason) }) //nolint:errcheck
}

func (x *session) fail(ctx context.Context, msgID, token string, status int, detail string) {
	x.write(ctx, wire.Frame{Type: wire.TError, MsgID: msgID, Error: token, Status: status, Detail: detail}) //nolint:errcheck
}

func (s *Server) handleWS(w http.ResponseWriter, r *http.Request) {
	t, ok := s.boxTenant(w, r) // specs/026: named by the box, proven by the hello below
	if !ok {
		return
	}
	conn, err := websocket.Accept(w, r, nil)
	if err != nil {
		return // Accept already answered the request
	}
	conn.SetReadLimit(maxFrameBytes)
	ctx := context.WithoutCancel(r.Context())

	x, ok := s.hello(ctx, conn, t)
	if !ok {
		return
	}
	defer s.drop(x)
	s.o.Log.Info().Str("tenant", x.tenant).Str("box", x.box).Str("role", x.role).Msg("ws hello accepted")
	kctx, stopPing := context.WithCancel(ctx)
	defer stopPing()
	s.keepalive(kctx, conn)
	if x.role == wire.RoleBox {
		go s.stampPresence(kctx, x)
	}

	for {
		var f wire.Frame
		if err := wsjson.Read(ctx, conn, &f); err != nil {
			return
		}
		switch f.Type {
		case wire.TSend:
			s.onSend(ctx, x, f)
		case wire.TAnnounce:
			s.onAnnounce(ctx, x, f.Agents, f.Channels, f.AgentRun)
		case wire.TTail:
			s.onTail(ctx, x, f)
		case wire.TIssue: // specs/039 §6
			s.onIssue(ctx, x, f)
		case wire.TEdit: // specs/032 §10: a box edits its own message
			s.onEdit(ctx, x, f)
		case wire.TDelete:
			s.onDelete(ctx, x, f)
		case wire.TArchive: // CLE-77869: a box agent archives a topic
			s.onArchive(ctx, x, f)
		case wire.TMove: // a box agent moves a topic to another channel
			s.onMove(ctx, x, f)
		case wire.TReact: // CLE-77895: a box agent adds / removes an emoji
			s.onReact(ctx, x, f)
		case wire.TLease: // CLE-77911: the fleet-wide lease, compare-and-set
			s.onLease(ctx, x, f)
		case wire.TLane: // CLE-77920: the fleet-wide lane map
			s.onLane(ctx, x, f)
		case wire.TAsk: // CLE-77929: asks to the orchestrator, tracked until closed
			s.onAsk(ctx, x, f)
		case wire.TClaim: // spec 068 4.1: a peer seat's claim on messages
			s.onClaim(ctx, x, f)
		case wire.TCommit: // spec 059 S2: the box wrote a delivery's inbox copy
			s.onCommit(ctx, x, f)
		case wire.TToken:
			tok, exp := s.slotToken(&x.upload, x.tenant, x.box, "")
			x.write(ctx, wire.Frame{Type: wire.TToken, UploadToken: tok, UploadTokenExpiresAt: exp.UTC().Format(time.RFC3339)}) //nolint:errcheck
		default:
			x.fail(ctx, f.MsgID, "bad_frame", http.StatusBadRequest, "unknown frame type")
		}
	}
}

// hello runs the challenge-response (OQ-03b) and registers the session.
func (s *Server) hello(ctx context.Context, conn *websocket.Conn, t store.Tenant) (*session, bool) {
	nonce, ok := sendChallenge(ctx, conn)
	if !ok {
		return nil, false
	}
	f, ok := s.readHello(ctx, conn, t.ID)
	if !ok {
		return nil, false
	}
	if code, token := s.helloRefusal(ctx, t.ID, f, nonce); token != "" {
		s.o.Log.Warn().Str("tenant", t.ID).Str("box", f.BoxID).Str("reason", token).Msg("ws hello refused")
		conn.Close(code, token) //nolint:errcheck
		return nil, false
	}
	x, ok := s.seatSession(ctx, conn, t.ID, &f)
	if !ok {
		return nil, false
	}
	if f.Role == wire.RoleBox {
		s.keepHostFacts(ctx, t.ID, f.BoxID, f.Host) // before the welcome: a roster read after it sees them
	}
	if !s.register(x) {
		conn.Close(websocket.StatusGoingAway, "shutdown") //nolint:errcheck
		return nil, false
	}
	if !s.welcome(ctx, x) {
		return nil, false
	}
	if f.Role == wire.RoleBox {
		s.broadcastRoster(ctx, t.ID, x)
		on, idle := splitRun(f.Agents, x.run)
		s.presence(ctx, t.ID, f.BoxID, on, "online")
		s.presence(ctx, t.ID, f.BoxID, idle, presenceNotRunning)
		s.drain(ctx, x)
		s.backfillBox(ctx, t.ID, f.BoxID) // SPL-987: seats owed a back-fill
	}
	return x, true
}

// sendChallenge writes a fresh 32-byte nonce as the challenge frame.
func sendChallenge(ctx context.Context, conn *websocket.Conn) (string, bool) {
	nb := make([]byte, 32)
	if _, err := rand.Read(nb); err != nil {
		conn.CloseNow() //nolint:errcheck
		return "", false
	}
	nonce := base64.StdEncoding.EncodeToString(nb)
	if err := wsjson.Write(ctx, conn, wire.Frame{Type: wire.TChallenge, Nonce: nonce}); err != nil {
		conn.CloseNow() //nolint:errcheck
		return "", false
	}
	return nonce, true
}

// readHello reads the answer to the challenge within HelloTimeout. A Read
// whose ctx expires kills the socket without a close frame, so the deadline
// is a timer that sends a proper 4408 close instead.
func (s *Server) readHello(ctx context.Context, conn *websocket.Conn, tenant string) (wire.Frame, bool) {
	var timedOut atomic.Bool
	timer := time.AfterFunc(s.o.HelloTimeout, func() {
		timedOut.Store(true)
		conn.Close(wire.CloseHelloTimeout, "hello_timeout") //nolint:errcheck
	})
	var f wire.Frame
	err := wsjson.Read(ctx, conn, &f)
	switch {
	case !timer.Stop() && err == nil:
		return f, false // the deadline fired as the hello arrived; the socket is closed
	case err != nil && timedOut.Load():
		s.o.Log.Warn().Str("tenant", tenant).Str("reason", "hello_timeout").Msg("ws hello refused")
		return f, false
	case err != nil:
		conn.CloseNow() //nolint:errcheck
		return f, false
	}
	return f, true
}

// helloRefusal checks the hello: its shape, never box-wui (the hub holds
// box-wui's key; it is never a box session, specs/014), the nonce, the
// clock skew, the pin and signature, and a box's roster. It answers the
// close code and reason, or "" when the hello is good.
func (s *Server) helloRefusal(ctx context.Context, tenant string, f wire.Frame, nonce string) (websocket.StatusCode, string) {
	switch {
	case f.Type != wire.THello || (f.Role != wire.RoleBox && f.Role != wire.RoleCLI) || !msg.ValidBoxID(f.BoxID):
		return wire.CloseBadFrame, "bad_frame"
	case f.BoxID == WUIBox:
		return wire.CloseUnauthorized, "unauthorized"
	case f.Nonce != nonce:
		return wire.CloseUnauthorized, "bad_nonce"
	case !s.skewOK(f.TS):
		return wire.CloseUnauthorized, "stale_hello"
	}
	pub, err := s.o.Store.GetPin(ctx, tenant, f.BoxID)
	if err != nil {
		return wire.CloseUnauthorized, "unpinned_box"
	}
	payload, err := wire.HelloPayload(f.BoxID, f.Nonce, f.TS)
	if err != nil {
		return wire.CloseBadFrame, "bad_frame"
	}
	if err := verify(pub, payload, f.Sig); err != nil {
		return wire.CloseUnauthorized, "bad_sig"
	}
	if f.Role == wire.RoleBox && !validRoster(f.Agents) {
		return wire.CloseBadFrame, "roster_duplicate"
	}
	return 0, ""
}

// seatSession stamps the box's hello and, for a box, seats its roster and
// channel subscriptions (f.Agents becomes the seated roster). It answers
// the session, not yet registered.
func (s *Server) seatSession(ctx context.Context, conn *websocket.Conn, tenant string, f *wire.Frame) (*session, bool) {
	now := s.o.Now()
	if err := s.o.Store.TouchBox(ctx, tenant, f.BoxID, now); err != nil {
		conn.CloseNow() //nolint:errcheck
		return nil, false
	}
	x := &session{srv: s, conn: conn, tenant: tenant, box: f.BoxID, role: f.Role, follows: map[string]bool{},
		msgVersions: f.MsgVersions, features: f.Features, since: now, welcomed: make(chan struct{})}
	if f.Role != wire.RoleBox {
		return x, true
	}
	agents, err := s.seatRoster(ctx, tenant, f.BoxID, f.Agents, now)
	if err != nil {
		conn.CloseNow() //nolint:errcheck
		return nil, false
	}
	f.Agents = agents
	if err := s.o.Store.SetSubscriptions(ctx, tenant, f.BoxID, f.Agents, f.Channels, now); err != nil {
		conn.CloseNow() //nolint:errcheck
		return nil, false
	}
	x.run = cleanAgentRun(f.Agents, f.AgentRun) // not registered yet: no lock
	s.keepAgentRun(ctx, tenant, f.BoxID, x.run)
	return x, true
}

// welcome answers the registered session with the roster and its upload
// token; false has dropped it.
func (s *Server) welcome(ctx context.Context, x *session) bool {
	roster, _ := s.o.Store.Roster(ctx, x.tenant)
	x.agents = roster[x.box] // Roster sorts each box's list
	tok, exp := s.slotToken(&x.upload, x.tenant, x.box, "")
	err := x.write(ctx, wire.Frame{Type: wire.TWelcome, BoxID: x.box, Roster: roster,
		UploadToken: tok, UploadTokenExpiresAt: exp.UTC().Format(time.RFC3339)})
	x.markWelcomed()
	if err != nil {
		s.drop(x)
		return false
	}
	return true
}

// register adds x; a role=box session evicts the previous one of the same box
// (last hello wins). role=cli never evicts and is never a delivery target.
func (s *Server) register(x *session) bool {
	s.mu.Lock()
	if s.closing {
		s.mu.Unlock()
		return false
	}
	var old *session
	if x.role == wire.RoleBox {
		k := [2]string{x.tenant, x.box}
		old = s.boxes[k]
		s.boxes[k] = x
		delete(s.left, k)
	}
	s.sessions[x] = struct{}{}
	s.mu.Unlock()
	if old != nil {
		old.close(wire.CloseSuperseded, "superseded")
	}
	return true
}

func (s *Server) drop(x *session) {
	s.mu.Lock()
	k := [2]string{x.tenant, x.box}
	gone := s.boxes[k] == x // false for a superseded socket: its box stays online
	if gone {
		delete(s.boxes, k)
		if x.role == wire.RoleBox && !s.closing {
			s.left[k] = s.o.Now() // a shutdown is a roll: the box redials elsewhere
		}
	}
	delete(s.sessions, x)
	s.mu.Unlock()
	x.close(websocket.StatusNormalClosure, "")
	if gone && x.role == wire.RoleBox {
		ctx := context.Background()
		roster, _ := s.o.Store.Roster(ctx, x.tenant)
		s.presence(ctx, x.tenant, x.box, roster[x.box], "offline")
	}
}

func (s *Server) boxSession(tenant, box string) *session {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.boxes[[2]string{tenant, box}]
}

// drain pushes the box's queued deliveries, oldest first, then queue_end.
func (s *Server) drain(ctx context.Context, x *session) {
	q, err := s.o.Store.QueuedFor(ctx, x.tenant, x.box, s.o.Now())
	if err != nil {
		s.o.Log.Error().Err(err).Msg("queue drain")
	}
	// A committing box first gets what it was sent but never acked: the
	// frames its last session lost (spec 059 S2).
	n := s.pushUnacked(ctx, x, s.o.Now())
	for _, d := range q {
		if s.push(ctx, x, d.MsgID, s.retaskEnv(ctx, x.tenant, d.Env, d.TaskID)) {
			n++
		}
	}
	x.write(ctx, wire.Frame{Type: wire.TQueueEnd, Count: n}) //nolint:errcheck
}

// push claims a queued delivery and writes the recv frame; a failed write
// returns the row to queued. Claim-before-push makes a concurrent drain and a
// live send unable to deliver the same row twice.
func (s *Server) push(ctx context.Context, x *session, msgID string, env []byte) bool {
	if !x.accepts(wire.InnerVersion(env)) {
		// A reader that would refuse this v drops it with a log line only,
		// after the row is already sent: silent loss. Keep it queued; the box's
		// next hello from an upgraded binary drains it (specs/020 migration.md §3).
		return false
	}
	agents, ok := s.recvAgents(ctx, x, env)
	if !ok {
		return false
	}
	claim := s.o.Store.ClaimSent
	if a := s.acks(x); a != nil {
		claim = a.ClaimSentUnacked // acked by the box's commit frame (commit.go)
	}
	ok, err := claim(ctx, x.tenant, msgID, x.box, s.o.Now())
	if err != nil || !ok {
		return false
	}
	if err := x.write(ctx, wire.Frame{Type: wire.TRecv, Env: env, Agents: agents}); err != nil {
		s.o.Store.Unclaim(ctx, x.tenant, msgID, x.box) //nolint:errcheck
		return false
	}
	return true
}

func (s *Server) onAnnounce(ctx context.Context, x *session, agents, channels []string, run map[string]bool) {
	if x.role != wire.RoleBox {
		x.fail(ctx, "", "bad_frame", http.StatusBadRequest, "announce needs role=box")
		return
	}
	if !validRoster(agents) {
		x.fail(ctx, "", "roster_duplicate", http.StatusConflict, "invalid or duplicate agent id in roster")
		return
	}
	before, _ := s.o.Store.Roster(ctx, x.tenant)
	if err := s.o.Store.SetRoster(ctx, x.tenant, x.box, agents, s.o.Now()); errors.Is(err, store.ErrSeatQuota) {
		// A new bot seat over the M4 cap (009 D-3): the previous roster stands.
		x.fail(ctx, "", billing.TokenQuota, billing.HTTPSeatQuota, "bot seat cap reached: roster not updated")
		return
	} else if err != nil {
		x.fail(ctx, "", "internal", http.StatusInternalServerError, "roster not stored")
		return
	}
	x.agents = append([]string(nil), agents...)
	sort.Strings(x.agents)
	if err := s.o.Store.SetSubscriptions(ctx, x.tenant, x.box, agents, channels, s.o.Now()); err != nil {
		x.fail(ctx, "", "internal", http.StatusInternalServerError, "subscriptions not stored")
		return
	}
	run = cleanAgentRun(agents, run)
	s.keepAgentRun(ctx, x.tenant, x.box, run)
	s.mu.Lock()
	wasRun := x.run
	x.run = run
	s.mu.Unlock()
	s.broadcastRoster(ctx, x.tenant, nil)
	wasOn, wasIdle := splitRun(before[x.box], wasRun)
	on, idle := splitRun(agents, run)
	s.presence(ctx, x.tenant, x.box, diffAgents(on, wasOn), "online")
	s.presence(ctx, x.tenant, x.box, diffAgents(idle, wasIdle), presenceNotRunning)
	s.presence(ctx, x.tenant, x.box, diffAgents(before[x.box], agents), "offline")
}

// seatRoster stores a hello's roster. Over the M4 bot-seat cap (009 D-5) it
// keeps the box's already-seated agents (old ∩ new) and drops the additions,
// so existing peers keep working; the next announce is answered 402 quota.
// It returns the agents actually stored.
func (s *Server) seatRoster(ctx context.Context, tenant, box string, agents []string, now time.Time) ([]string, error) {
	err := s.o.Store.SetRoster(ctx, tenant, box, agents, now)
	if !errors.Is(err, store.ErrSeatQuota) {
		return agents, err
	}
	before, err := s.o.Store.Roster(ctx, tenant)
	if err != nil {
		return nil, err
	}
	had := map[string]bool{}
	for _, a := range before[box] {
		had[a] = true
	}
	keep := []string{}
	for _, a := range agents {
		if had[a] {
			keep = append(keep, a)
		}
	}
	s.o.Log.Warn().Str("tenant", tenant).Str("box", box).Int("announced", len(agents)).Int("seated", len(keep)).
		Msg("ws hello over bot seat cap: new agents not seated")
	return keep, s.o.Store.SetRoster(ctx, tenant, box, keep, now)
}

// broadcastRoster pushes the tenant roster to every role=box session except skip.
func (s *Server) broadcastRoster(ctx context.Context, tenant string, skip *session) {
	roster, err := s.o.Store.Roster(ctx, tenant)
	if err != nil {
		return
	}
	s.mu.Lock()
	var targets []*session
	for k, x := range s.boxes {
		if k[0] == tenant && x != skip {
			targets = append(targets, x)
		}
	}
	s.mu.Unlock()
	for _, x := range targets {
		x.write(ctx, wire.Frame{Type: wire.TRoster, Roster: roster}) //nolint:errcheck
	}
}

// onSend verifies and routes one envelope (http-v1.md §2.4).
func (s *Server) onSend(ctx context.Context, x *session, f wire.Frame) {
	env, err := wire.ParseEnvelope(f.Env)
	if err != nil {
		x.fail(ctx, f.MsgID, "bad_json", http.StatusBadRequest, "envelope does not parse")
		return
	}
	m, err := env.Inner()
	if err != nil {
		x.fail(ctx, "", "bad_json", http.StatusBadRequest, err.Error())
		return
	}
	id := m.MsgID
	rf := s.sendIDRefusal(ctx, x, m.From, m.To, env.ToBox)
	if rf == nil {
		rf = s.sendSenderRefusal(ctx, x, env, m)
	}
	if rf == nil {
		rf = s.sendRouteRefusal(ctx, x, env, m)
	}
	if rf == nil {
		rf = s.sendTenantRefusal(ctx, x, id)
	}
	if rf == nil {
		rf = s.sendContentRefusal(ctx, x, env, m, f.TypedBy)
	}
	var undo func()
	if rf == nil {
		rf, undo = s.claimAnswer(ctx, x, env, m, f)
	}
	if rf != nil {
		x.fail(ctx, id, rf.token, rf.status, rf.detail)
		return
	}
	ctx = s.boxDMRef(ctx, x, m.From, f.RefTaskID) // spec 067 3.3, dm_ref.go
	r, err := s.commitRowTyped(ctx, x.tenant, env, m, s.boxLevel(ctx, x.tenant, m.TaskID), f.TypedBy)
	if err != nil && undo != nil {
		undo()
	}
	if errors.Is(err, store.ErrConflict) {
		x.fail(ctx, id, "conflict_msg", http.StatusConflict, "msg_id exists with a different envelope")
		return
	}
	if err != nil {
		s.o.Log.Error().Err(err).Str("msg_id", id).Msg("store message")
		x.fail(ctx, id, "internal", http.StatusInternalServerError, "message not stored")
		return
	}
	x.write(ctx, wire.Frame{Type: wire.TSent, MsgID: id, TaskID: m.TaskID, TS: m.TS, ToBox: env.ToBox, Delivery: r.delivery}) //nolint:errcheck
}

// frameRefusal is an error frame's token, status and detail.
type frameRefusal struct {
	token  string
	status int
	detail string
}

// sendSenderRefusal: the envelope is the hello box's, still pinned, signed
// by that pin, and from an agent the box announced.
func (s *Server) sendSenderRefusal(ctx context.Context, x *session, env *wire.Envelope, m *msg.Message) *frameRefusal {
	if env.FromBox != x.box {
		return &frameRefusal{"bad_sig", http.StatusBadRequest, "from_box is not the hello box"}
	}
	pub, err := s.o.Store.GetPin(ctx, x.tenant, env.FromBox)
	if err != nil {
		return &frameRefusal{"unpinned_box", http.StatusBadRequest, "from_box is no longer pinned"}
	}
	if err := env.Verify(pub); err != nil {
		return &frameRefusal{"bad_sig", http.StatusBadRequest, "envelope sig does not verify against the from_box pin"}
	}
	if detail := senderRefusal(x, m.From); detail != "" {
		return &frameRefusal{TokenFromNotAnnounced, http.StatusForbidden, detail}
	}
	return nil
}

// sendRouteRefusal: the sender resolved and signed a valid to_box that is
// pinned in this tenant; a message to the peers is signed to the hub's box.
func (s *Server) sendRouteRefusal(ctx context.Context, x *session, env *wire.Envelope, m *msg.Message) *frameRefusal {
	if env.ToBox == "" {
		roster, _ := s.o.Store.Roster(ctx, x.tenant)
		n := 0
		for _, agents := range roster {
			if contains(agents, m.To) {
				n++
			}
		}
		if n > 1 {
			return &frameRefusal{"ambiguous_to_box", http.StatusConflict, m.To + " is announced on more than one box; the sender must sign to_box"}
		}
		return &frameRefusal{"missing_to_box", http.StatusBadRequest, "the sender must resolve and sign to_box"}
	}
	if !msg.ValidBoxID(env.ToBox) {
		return &frameRefusal{"bad_json", http.StatusBadRequest, "to_box is not a valid box id"}
	}
	if m.To == msg.PeersID && env.ToBox != msg.PeersToBox {
		// spec 068 4.1: no box owns a message to the peers; a seat claims it
		return &frameRefusal{"bad_json", http.StatusBadRequest, "a message to " + msg.PeersID + " is signed to_box " + msg.PeersToBox}
	}
	if !s.toBoxKnown(ctx, x.tenant, env.ToBox) {
		return &frameRefusal{"unpinned_box", http.StatusNotFound, "to_box is not pinned in this tenant"}
	}
	return nil
}

// sendTenantRefusal: the tenant pays and is within its message quota.
func (s *Server) sendTenantRefusal(ctx context.Context, x *session, id string) *frameRefusal {
	trow, err := s.o.Store.GetTenant(ctx, x.tenant)
	if err != nil {
		return &frameRefusal{"internal", http.StatusInternalServerError, "tenant unavailable"}
	}
	if !billing.AllowsWrite(trow.BillingStatus) {
		return &frameRefusal{billing.TokenUnpaid, billing.HTTPUnpaid, "tenant billing is unpaid"}
	}
	if trow.Suspended() { // spec 074: an open socket outlives the suspend; its sends do not
		return &frameRefusal{tokenWorkspaceSuspended, http.StatusForbidden, "this workspace is suspended by the operator"}
	}
	if tok, status, detail := s.messageQuota(ctx, x.tenant, id); tok != "" {
		return &frameRefusal{tok, status, detail}
	}
	return nil
}

// sendContentRefusal: every attached file is held and readable by the box
// (an unreadable one answers as missing: no oracle for what the box may not
// read), the ts parses, the channel / parent tags fit, the agent is in the
// channel it posts to (specs/038 FR-004), and a typed_by claim is bound.
func (s *Server) sendContentRefusal(ctx context.Context, x *session, env *wire.Envelope, m *msg.Message, typedBy string) *frameRefusal {
	if missing := s.missingFile(ctx, x.tenant, m.Files); missing != "" {
		return &frameRefusal{"missing_file", http.StatusBadRequest, "file_id " + missing + " is not held by the hub"}
	}
	switch f, err := s.unreadableFile(ctx, x.tenant, m.Files, x.box, ""); {
	case err != nil:
		return &frameRefusal{"internal", http.StatusInternalServerError, "file lookup failed"}
	case f != "":
		return &frameRefusal{"missing_file", http.StatusBadRequest, "file_id " + f + " is not held by the hub"}
	}
	if _, err := time.Parse(time.RFC3339, m.TS); err != nil {
		return &frameRefusal{"bad_json", http.StatusBadRequest, "ts is not RFC3339"}
	}
	if tok, status, detail := s.checkTags(ctx, x.tenant, env.Channel, env.ParentTaskID, m.TaskID); tok != "" {
		return &frameRefusal{tok, status, detail}
	}
	if env.Channel != "" {
		switch in, err := s.agentInChannel(ctx, x.tenant, env.Channel, env.FromBox, m.From); {
		case err != nil:
			return &frameRefusal{"internal", http.StatusInternalServerError, "channel lookup failed"}
		case !in:
			return &frameRefusal{"unknown_channel", http.StatusNotFound, "no channel " + env.Channel + " in this tenant"}
		}
	}
	if typedBy != "" {
		if detail := s.typedByRefusal(ctx, x, m.From, typedBy); detail != "" {
			return &frameRefusal{"typed_by_not_bound", http.StatusForbidden, detail}
		}
	}
	return nil
}

// TokenFromNotAnnounced refuses a box send whose msg.from is not an agent
// that box announced. The box key signs the envelope, not the agent, so
// without it any pinned box could post as another box's agent (or as a
// human): the recipient would read, and answer, the wrong author.
const TokenFromNotAnnounced = wire.TokenFromNotAnnounced

// senderRefusal is the sender half of onSend's authz: msg.from must be in
// the sending box's seated roster, and never a human or guest id, which only
// the hub itself writes (browser sends, box-wui). "" = accepted. A new
// agent's first line can beat its box's next announce; the box client
// re-announces and resends on this token (hubclient.SendTyped).
func senderRefusal(x *session, from string) string {
	if strings.HasPrefix(from, "HUM-") || strings.HasPrefix(from, GuestPrefix) {
		return "a box cannot send as " + from
	}
	if !contains(x.agents, from) {
		return from + " is not an agent announced by " + x.box
	}
	return ""
}

// typedByRefusal is specs/036 FR-010: a send frame's typed_by is accepted
// only when the sending agent is one this box announced (roster), the human
// is a member of the tenant, and a box_operators binding (rdb 0040, granted
// by a tenant owner / admin, never by a box) says that human operates this
// box. "" = accepted; otherwise why not. Every refusal is the one token
// typed_by_not_bound, so the mirror re-posts without the claim.
func (s *Server) typedByRefusal(ctx context.Context, x *session, from, human string) string {
	if !humanIDRe.MatchString(human) {
		return "typed_by must be a HUM-* id"
	}
	if senderRefusal(x, from) != "" { // onSend refused it already; kept for any other caller
		return from + " is not an agent announced by " + x.box
	}
	h, hasHumans := s.o.Store.(store.Humans)
	ops, hasOps := s.o.Store.(store.BoxOperators)
	if !hasHumans || !hasOps {
		return "box operators are not available on this hub"
	}
	if _, err := h.MemberRole(ctx, human, x.tenant); err != nil {
		return human + " is not a member of this tenant"
	}
	if ok, err := ops.BoxOperatorBound(ctx, x.tenant, x.box, human); err != nil || !ok {
		return human + " is not bound as an operator of " + x.box
	}
	return ""
}

// messageQuota is the 006 month quota for one new message (onSend, admit).
// A resend of a stored msg_id is never refused by it: it adds nothing. The
// stored-id lookup runs only when the send would be over, so an under-quota
// send pays one read (027 T040), and an unlimited quota pays none.
func (s *Server) messageQuota(ctx context.Context, tenant, msgID string) (string, int, string) {
	q := s.quota()
	if q.MessagesPerMonth <= 0 {
		return "", 0, ""
	}
	n, err := s.o.Store.CountMessagesSince(ctx, tenant, billing.PeriodStart(s.o.Now()))
	if err != nil {
		return "internal", http.StatusInternalServerError, "quota lookup failed"
	}
	if q.Over(billing.Usage{MessagesThisPeriod: n}, 1, 0, 0) == "" {
		return "", 0, ""
	}
	has, err := s.o.Store.HasMessage(ctx, tenant, msgID)
	if err != nil {
		return "internal", http.StatusInternalServerError, "message lookup failed"
	}
	if has {
		return "", 0, ""
	}
	return billing.TokenQuota, billing.HTTPQuota, "message quota for this period is exceeded"
}

// missingFile is the OQ-11 file rule: the first blob attachment (in message
// order) whose object this tenant's prefix does not hold, or "" when all are
// held or text-only mode is on. The checks run concurrently: each is a GCS
// metadata call in production (027 T040), and one message carries up to
// msg.MaxFiles of them.
func (s *Server) missingFile(ctx context.Context, tenant string, files []msg.Attachment) string {
	if s.o.AllowTextOnly {
		return ""
	}
	held := make([]bool, len(files))
	var wg sync.WaitGroup
	for i, a := range files {
		if a.Mode != "blob" {
			held[i] = true
			continue
		}
		key, err := blob.Key(tenant, a.FileID)
		if err != nil {
			continue
		}
		wg.Add(1)
		go func(i int, key string) {
			defer wg.Done()
			held[i], _ = s.o.Blob.Exists(ctx, key)
		}(i, key)
	}
	wg.Wait()
	for i, ok := range held {
		if !ok {
			return files[i].FileID
		}
	}
	return ""
}

// unreadableFile is the first blob attachment the sender may NOT read - a
// box (box != "") or a human - or "". An attachment is a read
// capability: a file_id the sender cannot already read would become readable
// to them through their own message. Text-only mode holds no blobs.
func (s *Server) unreadableFile(ctx context.Context, tenant string, files []msg.Attachment, box, hum string) (string, error) {
	if s.o.AllowTextOnly {
		return "", nil
	}
	for _, a := range files {
		if a.Mode != "blob" {
			continue
		}
		ok, err := s.fileReadableBy(ctx, tenant, a.FileID, box, hum)
		if err != nil {
			return "", err
		}
		if !ok {
			return a.FileID, nil
		}
	}
	return "", nil
}

// commit stores the envelope and queues or pushes it. Caller has validated.
func (s *Server) commit(ctx context.Context, tenant string, env *wire.Envelope, m *msg.Message) (string, error) {
	r, err := s.commitRow(ctx, tenant, env, m, 1)
	return r.delivery, err
}

// committed is what one commit did (the browser ack needs the stored time).
type committed struct {
	delivery   string
	receivedAt time.Time
	inserted   bool
}

// commitRow is the one store path for every message: box sends, hub-originated
// envelopes and browser sends (wui.go). A to_box of box-wui is delivered by the
// browser fan-out, so its deliveries row is marked sent at once.
func (s *Server) commitRow(ctx context.Context, tenant string, env *wire.Envelope, m *msg.Message, isParent int) (committed, error) {
	return s.commitRowTyped(ctx, tenant, env, m, isParent, "")
}

// insertRow stores row. DB payload cut 7: box-wui's row is written sent
// with the message (sentInOne), one round trip instead of insert + enqueue +
// claim.
func (s *Server) insertRow(ctx context.Context, row store.Message) (inserted, sentInOne bool, err error) {
	if s.o.WakeWUI { // spec 059 S3: the caller fans it out itself
		s.fanned.add([2]string{row.TenantID, row.MsgID})
	}
	si, sentInOne := s.o.Store.(store.SentInserter)
	if sentInOne = sentInOne && row.ToBox == WUIBox; sentInOne {
		inserted, err = si.InsertMessageSent(ctx, row, row.ReceivedAt.Add(s.o.QueueTTL))
	} else {
		inserted, err = s.o.Store.InsertMessage(ctx, row)
	}
	return inserted, sentInOne, err
}

// commitRowTyped is commitRow with a VERIFIED typed_by (onSend's FR-010
// checks); "" = the agent wrote it. It is stored and fanned out to browsers
// only: the envelope pushed to boxes is the signed one, unchanged.
func (s *Server) commitRowTyped(ctx context.Context, tenant string, env *wire.Envelope, m *msg.Message, isParent int, typedBy string) (committed, error) {
	if isParent != 1 {
		isParent = 0
	}
	var c committed
	ts, err := time.Parse(time.RFC3339, m.TS)
	if err != nil {
		return c, err
	}
	canon, err := env.Marshal()
	if err != nil {
		return c, err
	}
	channel := s.storedChannel(ctx, tenant, env, m)
	if isParent == 0 && env.FromBox != WUIBox {
		channel = s.followMoved(ctx, tenant, m.TaskID, channel)
	}
	filesJSON, _ := json.Marshal(m.Files)
	if m.Files == nil {
		filesJSON = []byte(`[]`)
	}
	// Postgres keeps received_at in µs: an ack / fan-out cursor built from the
	// ns clock would not match the stored row's (nor a resend's re-ack).
	now := s.o.Now().Truncate(time.Microsecond)
	row := store.Message{
		TenantID: tenant, MsgID: m.MsgID, TaskID: m.TaskID, TS: ts,
		FromBox: env.FromBox, FromID: m.From, ToBox: env.ToBox, ToID: m.To, Kind: m.Kind, Body: m.Body,
		Files: filesJSON, Msg: env.Msg, EnvSig: env.Sig, Env: canon, Channel: channel, ParentTaskID: env.ParentTaskID,
		ReceivedAt: now, ExpiresAt: now.Add(s.retention(channel)), IsParent: isParent, TypedBy: typedBy,
	}
	inserted, sentInOne, err := s.insertRowRef(ctx, &row) // spec 067 L4, dm_ref.go
	if err != nil {
		return c, err
	}
	c.inserted, c.receivedAt = inserted, now
	if !sentInOne {
		if err := s.o.Store.Enqueue(ctx, tenant, m.MsgID, env.ToBox, now, now.Add(s.o.QueueTTL), s.o.QueueMaxPerBox); err != nil {
			return c, err
		}
	}
	if inserted {
		s.fanoutWUI(ctx, row)
	}
	// Box fan-out goes by what the SIGNED envelope claims: a box-signed reply
	// that only inherited its topic's channel carries no tag, and a member box
	// refuses a channel delivery without one (channels-v1 §4.5). A browser
	// reply signs the inherited channel (wuiSend), so it routes as tagged.
	s.routeChannel(ctx, tenant, s.tagChannel(env.Channel, m.TaskID), env, m, canon)
	if inserted { // after routing: a channel post's deliveries rows now exist
		s.notifyTail(ctx, tenant, m.TaskID, m.MsgID, env.FromBox, env.ToBox, canon)
	}
	if env.ToBox == WUIBox {
		if !sentInOne {
			if _, err := s.o.Store.ClaimSent(ctx, tenant, m.MsgID, WUIBox, now); err != nil {
				return c, err
			}
		}
		c.delivery = wire.DeliverySent
		return c, nil
	}
	delivery := wire.DeliveryQueued
	if target := s.boxSession(tenant, env.ToBox); target != nil && s.push(ctx, target, m.MsgID, canon) {
		delivery = wire.DeliverySent
	} else if st, _ := s.o.Store.DeliveryState(ctx, tenant, m.MsgID, env.ToBox); st == store.StateSent {
		delivery = wire.DeliverySent
	}
	c.delivery = delivery
	return c, nil
}

// Deliver verifies a hub-originated envelope and commits it (cicdlogs.Bus).
func (s *Server) Deliver(ctx context.Context, tenant string, env *wire.Envelope) (string, error) {
	m, err := env.Inner()
	if err != nil {
		return "", err
	}
	pub, err := s.o.Store.GetPin(ctx, tenant, env.FromBox)
	if err != nil {
		return "", err
	}
	if err := env.Verify(pub); err != nil {
		return "", err
	}
	if env.ToBox == "" || !msg.ValidBoxID(env.ToBox) {
		return "", fmt.Errorf("to_box")
	}
	if !s.toBoxKnown(ctx, tenant, env.ToBox) {
		return "", store.ErrNotFound
	}
	if s.missingFile(ctx, tenant, m.Files) != "" {
		return "", fmt.Errorf("missing file")
	}
	return s.commit(ctx, tenant, env, m)
}

func (s *Server) onTail(ctx context.Context, x *session, f wire.Frame) {
	if f.TaskID == "" {
		x.fail(ctx, "", "bad_json", http.StatusBadRequest, "tail needs task_id")
		return
	}
	if f.Follow { // subscribe first so nothing lands between the read and the subscribe unseen
		s.mu.Lock()
		x.follows[f.TaskID] = true
		s.mu.Unlock()
	}
	envs, err := s.o.Store.BoxTaskEnvelopes(ctx, x.tenant, f.TaskID, x.box, s.o.Now())
	if err != nil {
		x.fail(ctx, "", "internal", http.StatusInternalServerError, "tail read failed")
		return
	}
	if f.RSPCount && !f.Follow {
		s.onTailRSPCount(ctx, x, f.TaskID, len(envs) > 0)
		return
	}
	for _, e := range envs {
		// every row read lives in f.TaskID now; a moved one's envelope may not say so
		if err := x.write(ctx, wire.Frame{Type: wire.TTailMsg, Env: s.retaskEnv(ctx, x.tenant, e, f.TaskID)}); err != nil {
			return
		}
	}
	x.write(ctx, wire.Frame{Type: wire.TTailEnd, TaskID: f.TaskID, Count: len(envs)}) //nolint:errcheck
}

// onTailRSPCount answers a rsp_count tail (c-082): how many of the task's
// messages the responder (agentid.IsResponder: c-684, or a stored RSP-*) sent, from ANY box - the one fact a box may
// learn about envelopes it does not hold, and only for a task it holds
// something of (holds=false reads 0, like an unknown task_id).
func (s *Server) onTailRSPCount(ctx context.Context, x *session, taskID string, holds bool) {
	n := 0
	if holds {
		envs, err := s.o.Store.TaskEnvelopes(ctx, x.tenant, taskID)
		if err != nil {
			x.fail(ctx, "", "internal", http.StatusInternalServerError, "tail read failed")
			return
		}
		for _, raw := range envs {
			e, err := wire.ParseEnvelope(raw)
			if err != nil {
				continue
			}
			if m, err := e.Inner(); err == nil && agentid.IsResponder(m.From) {
				n++
			}
		}
	}
	x.write(ctx, wire.Frame{Type: wire.TTailEnd, TaskID: taskID, Count: n, RSPCount: true}) //nolint:errcheck
}

// notifyTail sends a newly stored envelope to every follower of its task in
// the same tenant (no cross-tenant delivery, FR-011) that may read it: the
// box sent it, it is addressed to the box, or the hub delivered it there -
// BoxTaskEnvelopes' rule, so a follow never streams what a tail would not
// return.
func (s *Server) notifyTail(ctx context.Context, tenant, taskID, msgID, fromBox, toBox string, env []byte) {
	s.mu.Lock()
	var targets []*session
	for x := range s.sessions {
		if x.tenant == tenant && x.follows[taskID] {
			targets = append(targets, x)
		}
	}
	s.mu.Unlock()
	for _, x := range targets {
		if x.box != fromBox && x.box != toBox {
			if st, err := s.o.Store.DeliveryState(ctx, tenant, msgID, x.box); err != nil || st == "" {
				continue
			}
		}
		x.write(ctx, wire.Frame{Type: wire.TTailMsg, Env: env}) //nolint:errcheck
	}
}

func validRoster(agents []string) bool {
	seen := map[string]bool{}
	for _, a := range agents {
		if !msg.ValidID(a) || seen[a] {
			return false
		}
		seen[a] = true
	}
	return true
}

func contains(list []string, s string) bool {
	i := sort.SearchStrings(list, s)
	if i < len(list) && list[i] == s {
		return true
	}
	for _, v := range list { // rosters are sorted by the store; be safe anyway
		if v == s {
			return true
		}
	}
	return false
}
