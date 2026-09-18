package hub

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/http"
	"sort"
	"sync"
	"sync/atomic"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"

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

	wmu     sync.Mutex
	follows map[string]bool // task ids tailed with follow=true; guarded by srv.mu
	once    sync.Once
}

func (x *session) write(ctx context.Context, f wire.Frame) error {
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
	t, err := s.tenantOf(r)
	if err != nil {
		writeErr(w, http.StatusNotFound, "unknown_tenant", "no tenant for this host")
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

	for {
		var f wire.Frame
		if err := wsjson.Read(ctx, conn, &f); err != nil {
			return
		}
		switch f.Type {
		case wire.TSend:
			s.onSend(ctx, x, f)
		case wire.TAnnounce:
			s.onAnnounce(ctx, x, f.Agents)
		case wire.TTail:
			s.onTail(ctx, x, f)
		case wire.TToken:
			tok, exp := s.mintToken(x.tenant, x.box)
			x.write(ctx, wire.Frame{Type: wire.TToken, UploadToken: tok, UploadTokenExpiresAt: exp.UTC().Format(time.RFC3339)}) //nolint:errcheck
		default:
			x.fail(ctx, f.MsgID, "bad_frame", http.StatusBadRequest, "unknown frame type")
		}
	}
}

// hello runs the challenge-response (OQ-03b) and registers the session.
func (s *Server) hello(ctx context.Context, conn *websocket.Conn, t store.Tenant) (*session, bool) {
	nb := make([]byte, 32)
	if _, err := rand.Read(nb); err != nil {
		conn.CloseNow() //nolint:errcheck
		return nil, false
	}
	nonce := base64.StdEncoding.EncodeToString(nb)
	if err := wsjson.Write(ctx, conn, wire.Frame{Type: wire.TChallenge, Nonce: nonce}); err != nil {
		conn.CloseNow() //nolint:errcheck
		return nil, false
	}

	// A Read whose ctx expires kills the socket without a close frame, so the
	// hello deadline is a timer that sends a proper 4408 close instead.
	var timedOut atomic.Bool
	timer := time.AfterFunc(s.o.HelloTimeout, func() {
		timedOut.Store(true)
		conn.Close(wire.CloseHelloTimeout, "hello_timeout") //nolint:errcheck
	})
	var f wire.Frame
	err := wsjson.Read(ctx, conn, &f)
	if !timer.Stop() && err == nil {
		return nil, false // the deadline fired as the hello arrived; the socket is closed
	}
	refuse := func(code websocket.StatusCode, token string) (*session, bool) {
		s.o.Log.Warn().Str("tenant", t.ID).Str("box", f.BoxID).Str("reason", token).Msg("ws hello refused")
		conn.Close(code, token) //nolint:errcheck
		return nil, false
	}
	switch {
	case err != nil && timedOut.Load():
		s.o.Log.Warn().Str("tenant", t.ID).Str("reason", "hello_timeout").Msg("ws hello refused")
		return nil, false
	case err != nil:
		conn.CloseNow() //nolint:errcheck
		return nil, false
	case f.Type != wire.THello || (f.Role != wire.RoleBox && f.Role != wire.RoleCLI) || !msg.ValidBoxID(f.BoxID):
		return refuse(wire.CloseBadFrame, "bad_frame")
	case f.Nonce != nonce:
		return refuse(wire.CloseUnauthorized, "bad_nonce")
	case !s.skewOK(f.TS):
		return refuse(wire.CloseUnauthorized, "stale_hello")
	}
	pub, err := s.o.Store.GetPin(ctx, t.ID, f.BoxID)
	if err != nil {
		return refuse(wire.CloseUnauthorized, "unpinned_box")
	}
	payload, err := wire.HelloPayload(f.BoxID, f.Nonce, f.TS)
	if err != nil {
		return refuse(wire.CloseBadFrame, "bad_frame")
	}
	if err := verify(pub, payload, f.Sig); err != nil {
		return refuse(wire.CloseUnauthorized, "bad_sig")
	}
	if f.Role == wire.RoleBox {
		if !validRoster(f.Agents) {
			return refuse(wire.CloseBadFrame, "roster_duplicate")
		}
	}

	now := s.o.Now()
	if err := s.o.Store.TouchBox(ctx, t.ID, f.BoxID, now); err != nil {
		conn.CloseNow() //nolint:errcheck
		return nil, false
	}
	x := &session{srv: s, conn: conn, tenant: t.ID, box: f.BoxID, role: f.Role, follows: map[string]bool{}}
	if f.Role == wire.RoleBox {
		if err := s.o.Store.SetRoster(ctx, t.ID, f.BoxID, f.Agents, now); err != nil {
			conn.CloseNow() //nolint:errcheck
			return nil, false
		}
	}
	if !s.register(x) {
		conn.Close(websocket.StatusGoingAway, "shutdown") //nolint:errcheck
		return nil, false
	}

	roster, _ := s.o.Store.Roster(ctx, t.ID)
	tok, exp := s.mintToken(t.ID, f.BoxID)
	if err := x.write(ctx, wire.Frame{Type: wire.TWelcome, BoxID: f.BoxID, Roster: roster,
		UploadToken: tok, UploadTokenExpiresAt: exp.UTC().Format(time.RFC3339)}); err != nil {
		s.drop(x)
		return nil, false
	}
	if f.Role == wire.RoleBox {
		s.broadcastRoster(ctx, t.ID, x)
		s.drain(ctx, x)
	}
	return x, true
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
	if s.boxes[k] == x {
		delete(s.boxes, k)
	}
	delete(s.sessions, x)
	s.mu.Unlock()
	x.close(websocket.StatusNormalClosure, "")
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
	n := 0
	for _, d := range q {
		if s.push(ctx, x, d.MsgID, d.Env) {
			n++
		}
	}
	x.write(ctx, wire.Frame{Type: wire.TQueueEnd, Count: n}) //nolint:errcheck
}

// push claims a queued delivery and writes the recv frame; a failed write
// returns the row to queued. Claim-before-push makes a concurrent drain and a
// live send unable to deliver the same row twice.
func (s *Server) push(ctx context.Context, x *session, msgID string, env []byte) bool {
	ok, err := s.o.Store.ClaimSent(ctx, x.tenant, msgID, x.box, s.o.Now())
	if err != nil || !ok {
		return false
	}
	if err := x.write(ctx, wire.Frame{Type: wire.TRecv, Env: env}); err != nil {
		s.o.Store.Unclaim(ctx, x.tenant, msgID, x.box) //nolint:errcheck
		return false
	}
	return true
}

func (s *Server) onAnnounce(ctx context.Context, x *session, agents []string) {
	if x.role != wire.RoleBox {
		x.fail(ctx, "", "bad_frame", http.StatusBadRequest, "announce needs role=box")
		return
	}
	if !validRoster(agents) {
		x.fail(ctx, "", "roster_duplicate", http.StatusConflict, "invalid or duplicate agent id in roster")
		return
	}
	if err := s.o.Store.SetRoster(ctx, x.tenant, x.box, agents, s.o.Now()); err != nil {
		x.fail(ctx, "", "internal", http.StatusInternalServerError, "roster not stored")
		return
	}
	s.broadcastRoster(ctx, x.tenant, nil)
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
	if env.FromBox != x.box {
		x.fail(ctx, id, "bad_sig", http.StatusBadRequest, "from_box is not the hello box")
		return
	}
	pub, err := s.o.Store.GetPin(ctx, x.tenant, env.FromBox)
	if err != nil {
		x.fail(ctx, id, "unpinned_box", http.StatusBadRequest, "from_box is no longer pinned")
		return
	}
	if err := env.Verify(pub); err != nil {
		x.fail(ctx, id, "bad_sig", http.StatusBadRequest, "envelope sig does not verify against the from_box pin")
		return
	}
	if env.ToBox == "" {
		roster, _ := s.o.Store.Roster(ctx, x.tenant)
		n := 0
		for _, agents := range roster {
			if contains(agents, m.To) {
				n++
			}
		}
		if n > 1 {
			x.fail(ctx, id, "ambiguous_to_box", http.StatusConflict, m.To+" is announced on more than one box; the sender must sign to_box")
		} else {
			x.fail(ctx, id, "missing_to_box", http.StatusBadRequest, "the sender must resolve and sign to_box")
		}
		return
	}
	if !msg.ValidBoxID(env.ToBox) {
		x.fail(ctx, id, "bad_json", http.StatusBadRequest, "to_box is not a valid box id")
		return
	}
	if _, err := s.o.Store.GetPin(ctx, x.tenant, env.ToBox); err != nil {
		x.fail(ctx, id, "unpinned_box", http.StatusNotFound, "to_box is not pinned in this tenant")
		return
	}
	trow, err := s.o.Store.GetTenant(ctx, x.tenant)
	if err != nil {
		x.fail(ctx, id, "internal", http.StatusInternalServerError, "tenant unavailable")
		return
	}
	if !billing.AllowsWrite(trow.BillingStatus) {
		x.fail(ctx, id, billing.TokenUnpaid, billing.HTTPUnpaid, "tenant billing is unpaid")
		return
	}
	has, err := s.o.Store.HasMessage(ctx, x.tenant, id)
	if err != nil {
		x.fail(ctx, id, "internal", http.StatusInternalServerError, "message lookup failed")
		return
	}
	if !has {
		n, err := s.o.Store.CountMessagesSince(ctx, x.tenant, billing.PeriodStart(s.o.Now()))
		if err != nil {
			x.fail(ctx, id, "internal", http.StatusInternalServerError, "quota lookup failed")
			return
		}
		if s.quota().Over(billing.Usage{MessagesThisPeriod: n}, 1, 0, 0) != "" {
			x.fail(ctx, id, billing.TokenQuota, billing.HTTPQuota, "message quota for this period is exceeded")
			return
		}
	}
	if !s.o.AllowTextOnly {
		for _, a := range m.Files {
			if a.Mode != "blob" {
				continue
			}
			key, kerr := blob.Key(x.tenant, a.FileID)
			ok := false
			if kerr == nil {
				ok, _ = s.o.Blob.Exists(ctx, key)
			}
			if !ok {
				x.fail(ctx, id, "missing_file", http.StatusBadRequest, "file_id "+a.FileID+" is not held by the hub")
				return
			}
		}
	}
	ts, err := time.Parse(time.RFC3339, m.TS)
	if err != nil {
		x.fail(ctx, id, "bad_json", http.StatusBadRequest, "ts is not RFC3339")
		return
	}
	canon, err := env.Marshal()
	if err != nil {
		x.fail(ctx, id, "bad_json", http.StatusBadRequest, "envelope does not re-encode")
		return
	}
	filesJSON, _ := json.Marshal(m.Files)
	if m.Files == nil {
		filesJSON = []byte(`[]`)
	}
	now := s.o.Now()
	row := store.Message{
		TenantID: x.tenant, MsgID: id, TaskID: m.TaskID, TS: ts,
		FromBox: env.FromBox, FromID: m.From, ToBox: env.ToBox, ToID: m.To, Kind: m.Kind, Body: m.Body,
		Files: filesJSON, Msg: env.Msg, EnvSig: env.Sig, Env: canon,
		ReceivedAt: now, ExpiresAt: now.Add(s.retention("")),
	}
	inserted, err := s.o.Store.InsertMessage(ctx, row)
	if errors.Is(err, store.ErrConflict) {
		x.fail(ctx, id, "conflict_msg", http.StatusConflict, "msg_id exists with a different envelope")
		return
	}
	if err != nil {
		s.o.Log.Error().Err(err).Str("msg_id", id).Msg("store message")
		x.fail(ctx, id, "internal", http.StatusInternalServerError, "message not stored")
		return
	}
	if err := s.o.Store.Enqueue(ctx, x.tenant, id, env.ToBox, now, now.Add(s.o.QueueTTL), s.o.QueueMaxPerBox); err != nil {
		s.o.Log.Error().Err(err).Str("msg_id", id).Msg("enqueue")
		x.fail(ctx, id, "internal", http.StatusInternalServerError, "delivery not queued")
		return
	}
	if inserted {
		s.notifyTail(ctx, x.tenant, m.TaskID, canon)
	}

	delivery := wire.DeliveryQueued
	if target := s.boxSession(x.tenant, env.ToBox); target != nil && s.push(ctx, target, id, canon) {
		delivery = wire.DeliverySent
	} else if st, _ := s.o.Store.DeliveryState(ctx, x.tenant, id, env.ToBox); st == store.StateSent {
		delivery = wire.DeliverySent // an idempotent replay of an already-delivered message
	}
	x.write(ctx, wire.Frame{Type: wire.TSent, MsgID: id, TaskID: m.TaskID, TS: m.TS, ToBox: env.ToBox, Delivery: delivery}) //nolint:errcheck
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
	envs, err := s.o.Store.TaskEnvelopes(ctx, x.tenant, f.TaskID)
	if err != nil {
		x.fail(ctx, "", "internal", http.StatusInternalServerError, "tail read failed")
		return
	}
	for _, e := range envs {
		if err := x.write(ctx, wire.Frame{Type: wire.TTailMsg, Env: e}); err != nil {
			return
		}
	}
	x.write(ctx, wire.Frame{Type: wire.TTailEnd, TaskID: f.TaskID, Count: len(envs)}) //nolint:errcheck
}

// notifyTail sends a newly stored envelope to every follower of its task in
// the same tenant (no cross-tenant delivery, FR-011).
func (s *Server) notifyTail(ctx context.Context, tenant, taskID string, env []byte) {
	s.mu.Lock()
	var targets []*session
	for x := range s.sessions {
		if x.tenant == tenant && x.follows[taskID] {
			targets = append(targets, x)
		}
	}
	s.mu.Unlock()
	for _, x := range targets {
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
