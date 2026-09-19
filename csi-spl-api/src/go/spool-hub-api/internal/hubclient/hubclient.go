// Package hubclient is the box side of the hub (spec 003): the WS hello over the
// hub's nonce, envelope signing with the one box key, recv-frame verification
// against locally synced pins, pin sync, file upload/fetch, tail, and the
// pending-flush queue with reconnect backoff (OQ-05, OQ-09, OQ-15). Agents
// never call it; the spool CLI/MCP does, and only when $SPOOL_HUB_URL is set.
package hubclient

import (
	"context"
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"
	"github.com/rs/zerolog"

	"github.com/csitea/csi-spl/spool-hub-api/internal/config"
	"github.com/csitea/csi-spl/spool-hub-api/internal/files"
	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
	"github.com/csitea/csi-spl/spool-hub-api/internal/sign"
	"github.com/csitea/csi-spl/spool-hub-api/internal/spool"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// ErrUnreachable wraps every failure to reach the hub (dial, dropped socket,
// timeout). A send that hits it is kept pending-flush (delivery=pending).
var ErrUnreachable = errors.New("hub unreachable")

// ErrSuperseded is returned by Run when a newer role=box hello took the box.
var ErrSuperseded = errors.New("session superseded by a newer hello for this box")

// HubError is a refusal from the hub: an error frame, a REST error body, or a
// 44xx close of the hello. Verify-class tokens unwrap to sign.ErrVerify, so
// the CLI maps them to exit 78.
type HubError struct {
	Token  string
	Status int
	Detail string
}

func (e *HubError) Error() string {
	if e.Detail != "" {
		return fmt.Sprintf("hub refused: %s (%s)", e.Token, e.Detail)
	}
	return "hub refused: " + e.Token
}

func (e *HubError) Unwrap() error {
	if wire.VerifyTokens[e.Token] {
		return sign.ErrVerify
	}
	return nil
}

// clientError reports a 4xx refusal (the envelope will never be accepted).
func (e *HubError) clientError() bool { return e.Status >= 400 && e.Status < 500 }

// Client talks to the hub named by cfg.HubURL as box cfg.BoxID.
type Client struct {
	Cfg *config.Config
	// HTTP carries both the WS upgrade and REST. nil = a default client that
	// also resolves *.localhost to loopback (lde).
	HTTP *http.Client
	Log  zerolog.Logger
	Now  func() time.Time
	// PinRefresh is the daemon's authorized_keys refresh interval.
	PinRefresh time.Duration
	// ReadyTimeout bounds each wait for a hub reply.
	ReadyTimeout time.Duration
}

// New returns a Client for cfg with production defaults.
func New(cfg *config.Config) *Client {
	return &Client{Cfg: cfg, Log: zerolog.Nop(), Now: time.Now, PinRefresh: 5 * time.Minute, ReadyTimeout: 30 * time.Second}
}

func (c *Client) now() time.Time {
	if c.Now == nil {
		return time.Now()
	}
	return c.Now()
}

func (c *Client) timeout() time.Duration {
	if c.ReadyTimeout <= 0 {
		return 30 * time.Second
	}
	return c.ReadyTimeout
}

// HTTPClient is the client used for the WS upgrade and REST calls.
func (c *Client) HTTPClient() *http.Client { return c.http() }

func (c *Client) http() *http.Client {
	if c.HTTP != nil {
		return c.HTTP
	}
	d := &net.Dialer{Timeout: 10 * time.Second}
	tr := http.DefaultTransport.(*http.Transport).Clone()
	tr.DialContext = func(ctx context.Context, network, addr string) (net.Conn, error) {
		if h, p, err := net.SplitHostPort(addr); err == nil && strings.HasSuffix(h, ".localhost") {
			addr = net.JoinHostPort("127.0.0.1", p)
		}
		return d.DialContext(ctx, network, addr)
	}
	return &http.Client{Transport: tr, Timeout: 0}
}

func (c *Client) endpoint(path string) (string, error) {
	u, err := url.Parse(c.Cfg.HubURL)
	if err != nil || u.Host == "" {
		return "", fmt.Errorf("SPOOL_HUB_URL %q is not a URL", c.Cfg.HubURL)
	}
	u.Path = strings.TrimSuffix(u.Path, "/") + path
	return u.String(), nil
}

func (c *Client) box() (string, ed25519.PrivateKey, error) {
	b := c.Cfg.BoxID
	if !msg.ValidBoxID(b) {
		return "", nil, fmt.Errorf("hub mode needs $SPOOL_BOX_ID (a valid box id)")
	}
	priv, err := sign.LoadPrivate(c.Cfg.KeysDir, b)
	if err != nil {
		return "", nil, err
	}
	return b, priv, nil
}

// ---- session -----------------------------------------------------------------

// Session is one authenticated socket.
type Session struct {
	c    *Client
	conn *websocket.Conn
	box  string
	priv ed25519.PrivateKey
	role string

	mu        sync.Mutex
	token     string
	tokenExp  time.Time
	recvErrs  []error
	delivered int

	replies  chan wire.Frame
	queueEnd chan int
	done     chan struct{}
	closeErr error
}

// Dial connects, answers the hub's challenge and waits for welcome. For
// role=box it then syncs pins BEFORE reading further frames, so the queued
// recv frames the hub pushes right after welcome verify against fresh pins.
func (c *Client) Dial(ctx context.Context, role string) (*Session, error) {
	box, priv, err := c.box()
	if err != nil {
		return nil, err
	}
	wsURL, err := c.endpoint("/v1/ws")
	if err != nil {
		return nil, err
	}
	wsURL = "ws" + strings.TrimPrefix(wsURL, "http")
	dctx, cancel := context.WithTimeout(ctx, c.timeout())
	defer cancel()
	conn, _, err := websocket.Dial(dctx, wsURL, &websocket.DialOptions{HTTPClient: c.http()})
	if err != nil {
		return nil, fmt.Errorf("%w: %v", ErrUnreachable, err)
	}
	conn.SetReadLimit(1 << 20)
	fail := func(err error) (*Session, error) {
		conn.CloseNow() //nolint:errcheck
		return nil, err
	}

	var ch wire.Frame
	if err := wsjson.Read(dctx, conn, &ch); err != nil || ch.Type != wire.TChallenge {
		return fail(fmt.Errorf("%w: no challenge: %v", ErrUnreachable, err))
	}
	ts := c.now().UTC().Format(time.RFC3339)
	payload, _ := wire.HelloPayload(box, ch.Nonce, ts)
	hello := wire.Frame{Type: wire.THello, BoxID: box, TS: ts, Nonce: ch.Nonce, Role: role, Sig: sign.Sign(priv, payload)}
	if role == wire.RoleBox {
		agents, err := c.scanAgents()
		if err != nil {
			return fail(err)
		}
		hello.Agents = agents
		hello.Channels = c.Cfg.ChannelList()
	}
	if err := wsjson.Write(dctx, conn, hello); err != nil {
		return fail(fmt.Errorf("%w: %v", ErrUnreachable, err))
	}
	var wel wire.Frame
	if err := wsjson.Read(dctx, conn, &wel); err != nil {
		var ce websocket.CloseError
		if errors.As(err, &ce) && ce.Code >= 4000 {
			return fail(&HubError{Token: ce.Reason, Status: int(ce.Code)})
		}
		return fail(fmt.Errorf("%w: %v", ErrUnreachable, err))
	}
	if wel.Type != wire.TWelcome {
		return fail(fmt.Errorf("%w: expected welcome, got %q", ErrUnreachable, wel.Type))
	}
	s := &Session{
		c: c, conn: conn, box: box, priv: priv, role: role,
		token: wel.UploadToken, replies: make(chan wire.Frame, 64), queueEnd: make(chan int, 1),
		done: make(chan struct{}),
	}
	s.tokenExp, _ = time.Parse(time.RFC3339, wel.UploadTokenExpiresAt)
	c.saveRoster(wel.Roster)
	if role == wire.RoleBox {
		if err := s.SyncPins(ctx); err != nil {
			return fail(err)
		}
	}
	go s.readLoop()
	return s, nil
}

func (s *Session) readLoop() {
	defer close(s.done)
	for {
		var f wire.Frame
		if err := wsjson.Read(context.Background(), s.conn, &f); err != nil {
			s.mu.Lock()
			s.closeErr = err
			s.mu.Unlock()
			return
		}
		switch f.Type {
		case wire.TRecv:
			if err := s.receive(context.Background(), f.Env, f.Agents); err != nil {
				s.c.Log.Warn().Err(err).Msg("recv frame refused")
				s.mu.Lock()
				s.recvErrs = append(s.recvErrs, err)
				s.mu.Unlock()
			}
		case wire.TRoster:
			s.c.saveRoster(f.Roster)
		case wire.TQueueEnd:
			select {
			case s.queueEnd <- f.Count:
			default:
			}
		default:
			select {
			case s.replies <- f:
			case <-time.After(s.c.timeout()):
			}
		}
	}
}

// Close ends the session normally.
func (s *Session) Close() { s.conn.Close(websocket.StatusNormalClosure, "") } //nolint:errcheck

// Done is closed when the socket ends; CloseCode then reports why.
func (s *Session) Done() <-chan struct{} { return s.done }

// CloseCode is the close status of an ended socket (-1 if none).
func (s *Session) CloseCode() websocket.StatusCode {
	s.mu.Lock()
	defer s.mu.Unlock()
	return websocket.CloseStatus(s.closeErr)
}

// RecvErrors returns the recv frames refused so far (e.g. an unsynced sender pin).
func (s *Session) RecvErrors() []error {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]error(nil), s.recvErrs...)
}

// Delivered counts recv frames written into local inboxes.
func (s *Session) Delivered() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.delivered
}

// WaitQueueEnd waits for the hub's queue_end after a role=box welcome.
func (s *Session) WaitQueueEnd(ctx context.Context) (int, error) {
	select {
	case n := <-s.queueEnd:
		return n, nil
	case <-s.done:
		return 0, fmt.Errorf("%w: socket closed before queue_end", ErrUnreachable)
	case <-ctx.Done():
		return 0, ctx.Err()
	case <-time.After(s.c.timeout()):
		return 0, fmt.Errorf("%w: no queue_end", ErrUnreachable)
	}
}

func (s *Session) request(ctx context.Context, f wire.Frame, want string, match func(wire.Frame) bool) (wire.Frame, error) {
	wctx, cancel := context.WithTimeout(ctx, s.c.timeout())
	defer cancel()
	if err := wsjson.Write(wctx, s.conn, f); err != nil {
		return wire.Frame{}, fmt.Errorf("%w: %v", ErrUnreachable, err)
	}
	for {
		select {
		case r := <-s.replies:
			if r.Type == wire.TError && (match == nil || match(r)) {
				return r, &HubError{Token: r.Error, Status: r.Status, Detail: r.Detail}
			}
			if r.Type == want && (match == nil || match(r)) {
				return r, nil
			}
		case <-s.done:
			return wire.Frame{}, fmt.Errorf("%w: socket closed", ErrUnreachable)
		case <-wctx.Done():
			return wire.Frame{}, fmt.Errorf("%w: no %s reply", ErrUnreachable, want)
		}
	}
}

// Send sends one signed envelope and returns the hub's sent frame.
func (s *Session) Send(ctx context.Context, env *wire.Envelope) (wire.Frame, error) {
	raw, err := env.Marshal()
	if err != nil {
		return wire.Frame{}, err
	}
	m, err := env.Inner()
	if err != nil {
		return wire.Frame{}, err
	}
	id := m.MsgID
	return s.request(ctx, wire.Frame{Type: wire.TSend, Env: raw}, wire.TSent,
		func(r wire.Frame) bool { return r.MsgID == id || (r.Type == wire.TError && r.MsgID == "") })
}

// Tail streams a task's stored envelopes to fn, oldest first; with follow it
// keeps streaming live ones until ctx ends.
func (s *Session) Tail(ctx context.Context, taskID string, follow bool, fn func(*wire.Envelope)) (int, error) {
	wctx, cancel := context.WithTimeout(ctx, s.c.timeout())
	err := wsjson.Write(wctx, s.conn, wire.Frame{Type: wire.TTail, TaskID: taskID, Follow: follow})
	cancel()
	if err != nil {
		return 0, fmt.Errorf("%w: %v", ErrUnreachable, err)
	}
	n := 0
	ended := false
	for {
		var timeout <-chan time.Time
		if !ended {
			timeout = time.After(s.c.timeout())
		}
		select {
		case r := <-s.replies:
			switch r.Type {
			case wire.TTailMsg:
				if e, err := wire.ParseEnvelope(r.Env); err == nil {
					fn(e)
					n++
				}
			case wire.TTailEnd:
				ended = true
				if !follow {
					return n, nil
				}
			case wire.TError:
				return n, &HubError{Token: r.Error, Status: r.Status, Detail: r.Detail}
			}
		case <-s.done:
			return n, fmt.Errorf("%w: socket closed", ErrUnreachable)
		case <-ctx.Done():
			if follow && ended {
				return n, nil
			}
			return n, ctx.Err()
		case <-timeout:
			return n, fmt.Errorf("%w: no tail_end", ErrUnreachable)
		}
	}
}

// Announce re-sends this box's agent roster (role=box).
func (s *Session) Announce(ctx context.Context) error {
	agents, err := s.c.scanAgents()
	if err != nil {
		return err
	}
	wctx, cancel := context.WithTimeout(ctx, s.c.timeout())
	defer cancel()
	return wsjson.Write(wctx, s.conn, wire.Frame{Type: wire.TAnnounce, Agents: agents, Channels: s.c.Cfg.ChannelList()})
}

// uploadToken returns a live upload token, asking the hub for a fresh one
// when the welcome token is about to expire.
func (s *Session) uploadToken(ctx context.Context) (string, error) {
	s.mu.Lock()
	tok, exp := s.token, s.tokenExp
	s.mu.Unlock()
	if tok != "" && s.c.now().Add(30*time.Second).Before(exp) {
		return tok, nil
	}
	r, err := s.request(ctx, wire.Frame{Type: wire.TToken}, wire.TToken, nil)
	if err != nil {
		return "", err
	}
	s.mu.Lock()
	s.token = r.UploadToken
	s.tokenExp, _ = time.Parse(time.RFC3339, r.UploadTokenExpiresAt)
	s.mu.Unlock()
	return r.UploadToken, nil
}

// ---- recv --------------------------------------------------------------------

// wuiBox is the hub-held browser signer (specs/014): its tenant-root-signed
// pin verifies like any box, but its role is restricted to kind task|note.
const wuiBox = "box-wui"

// receive verifies one recv frame against the LOCALLY synced pin of from_box
// and writes the inner v:1 into the recipient's inbox. A missing pin or bad
// sig refuses the frame (exit 78 class) and writes nothing.
//
// A frame whose to_box is another box is accepted only as a mention-routed
// channel delivery (specs/003 channels-v1 §4.5): the envelope carries a signed
// channel and the hub lists the addressed agents; one inbox copy is written
// per listed agent this box hosts.
func (s *Session) receive(ctx context.Context, raw []byte, agents []string) error {
	e, err := wire.ParseEnvelope(raw)
	if err != nil {
		return err
	}
	var targets []string
	if e.ToBox != s.box {
		if e.Channel == "" || len(agents) == 0 {
			return fmt.Errorf("frame for to_box %q arrived at box %q", e.ToBox, s.box)
		}
		local, err := s.c.scanAgents()
		if err != nil {
			return err
		}
		for _, a := range agents {
			for _, l := range local {
				if a == l {
					targets = append(targets, a)
				}
			}
		}
		if len(targets) == 0 {
			return fmt.Errorf("channel frame for agents %v hosts none of them at box %q", agents, s.box)
		}
	}
	pub, err := sign.LoadPin(s.c.Cfg.PinsDir, e.FromBox)
	if err != nil {
		return fmt.Errorf("sender box %s: %w", e.FromBox, err)
	}
	if err := e.Verify(pub); err != nil {
		return fmt.Errorf("envelope from %s: %w", e.FromBox, err)
	}
	m, err := e.Inner()
	if err != nil {
		return err
	}
	if e.FromBox == wuiBox && m.Kind != "task" && m.Kind != "note" {
		return fmt.Errorf("envelope from %s with kind %q: %w", wuiBox, m.Kind, sign.ErrVerify)
	}
	for _, a := range m.Files {
		if a.Mode == "blob" {
			if err := s.fetchFile(ctx, a.FileID); err != nil {
				s.c.Log.Warn().Err(err).Str("file_id", a.FileID).Msg("attachment not fetched")
			}
		}
	}
	if targets == nil {
		targets = []string{m.To}
	}
	for _, id := range targets {
		wrote, err := spool.New(s.c.Cfg).DeliverTo(m, id)
		if err != nil {
			return err
		}
		if wrote {
			s.mu.Lock()
			s.delivered++
			s.mu.Unlock()
		}
	}
	return nil
}

// ---- REST: pins and files ------------------------------------------------------

func (s *Session) rest(ctx context.Context, method, path string, body io.Reader, out any) error {
	u, err := s.c.endpoint(path)
	if err != nil {
		return err
	}
	tok, err := s.uploadToken(ctx)
	if err != nil {
		return err
	}
	req, err := http.NewRequestWithContext(ctx, method, u, body)
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer "+tok)
	if body != nil {
		req.Header.Set("Content-Type", "application/octet-stream")
	}
	resp, err := s.c.http().Do(req)
	if err != nil {
		return fmt.Errorf("%w: %v", ErrUnreachable, err)
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 300 {
		var eb wire.ErrorBody
		json.NewDecoder(io.LimitReader(resp.Body, 8<<10)).Decode(&eb) //nolint:errcheck
		if resp.StatusCode >= 500 {
			return fmt.Errorf("%w: %s %s -> %d %s", ErrUnreachable, method, path, resp.StatusCode, eb.Error)
		}
		return &HubError{Token: eb.Error, Status: resp.StatusCode, Detail: eb.Detail}
	}
	if w, ok := out.(io.Writer); ok {
		_, err = io.Copy(w, resp.Body)
		return err
	}
	if out != nil {
		return json.NewDecoder(resp.Body).Decode(out)
	}
	return nil
}

// SyncPins installs the tenant's box pubkeys as $SPOOL_ROOT/pins/box-<id>.pub
// (authorized_keys refresh, trust-modes §4). A local pin that differs from the
// hub is not overwritten: pin_conflict, exit 78 (004 T007/T008).
func (s *Session) SyncPins(ctx context.Context) error {
	var list wire.PinList
	if err := s.rest(ctx, http.MethodGet, "/v1/pins", nil, &list); err != nil {
		return err
	}
	for _, p := range list.Pins {
		if !msg.ValidBoxID(p.BoxID) {
			continue
		}
		if err := s.installPin(p.BoxID, p.PubKey); err != nil {
			return err
		}
	}
	return nil
}

// installPin writes a missing pin. Same key is a no-op. Different key refuses
// without clobbering the local file.
func (s *Session) installPin(boxID, pubB64 string) error {
	existing, err := sign.LoadPin(s.c.Cfg.PinsDir, boxID)
	if err == nil {
		if base64.StdEncoding.EncodeToString(existing) != pubB64 {
			return &HubError{Token: "pin_conflict", Status: http.StatusConflict,
				Detail: "local pin for " + boxID + " differs from hub; not clobbering"}
		}
		return nil
	}
	if !errors.Is(err, sign.ErrUnpinned) {
		return err
	}
	return sign.Pin(s.c.Cfg.PinsDir, boxID, pubB64, false)
}

// UploadFile puts the local blob file_id to the hub (POST /v1/files).
func (s *Session) UploadFile(ctx context.Context, fileID string) error {
	f, err := os.Open(filepath.Join(s.c.Cfg.FilesDir(), fileID))
	if err != nil {
		return fmt.Errorf("blob %s is not in the local store: %w", fileID, err)
	}
	defer f.Close()
	var res wire.FileResult
	if err := s.rest(ctx, http.MethodPost, "/v1/files", f, &res); err != nil {
		return err
	}
	if res.FileID != fileID {
		return fmt.Errorf("hub stored %s for local blob %s: %w", res.FileID, fileID, files.ErrHashMismatch)
	}
	return nil
}

// fetchFile downloads file_id into the local blob store unless present,
// re-hashing before it is kept (never a partial file).
func (s *Session) fetchFile(ctx context.Context, fileID string) error {
	dst := filepath.Join(s.c.Cfg.FilesDir(), fileID)
	if _, err := os.Stat(dst); err == nil {
		return nil
	}
	if err := os.MkdirAll(s.c.Cfg.FilesDir(), 0o775); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(s.c.Cfg.FilesDir(), ".fetch-*")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	err = s.rest(ctx, http.MethodGet, "/v1/files/"+url.PathEscape(fileID), nil, tmp)
	tmp.Close()
	if err != nil {
		return err
	}
	a, err := files.PutFile(s.c.Cfg.FilesDir(), tmp.Name())
	if err != nil {
		return err
	}
	if a.FileID != fileID {
		os.Remove(filepath.Join(s.c.Cfg.FilesDir(), a.FileID))
		return fmt.Errorf("fetched %s: %w", fileID, files.ErrHashMismatch)
	}
	return nil
}

// ---- roster ------------------------------------------------------------------

// scanAgents is the $SPOOL_ROOT/*/ dir scan (trust-modes §4.2).
func (c *Client) scanAgents() ([]string, error) {
	ents, err := os.ReadDir(c.Cfg.SpoolRoot)
	if os.IsNotExist(err) {
		return []string{}, nil
	}
	if err != nil {
		return nil, err
	}
	out := []string{}
	for _, e := range ents {
		if e.IsDir() && msg.ValidID(e.Name()) {
			out = append(out, e.Name())
		}
	}
	sort.Strings(out)
	return out, nil
}

func (c *Client) rosterPath() string { return filepath.Join(c.Cfg.HubDir(), "roster.json") }

func (c *Client) saveRoster(r map[string][]string) {
	if r == nil {
		r = map[string][]string{}
	}
	raw, err := json.Marshal(r)
	if err != nil {
		return
	}
	if err := writeAtomic(c.rosterPath(), raw); err != nil {
		c.Log.Warn().Err(err).Msg("roster cache not written")
	}
}

func (c *Client) loadRoster() map[string][]string {
	r := map[string][]string{}
	raw, err := os.ReadFile(c.rosterPath())
	if err == nil {
		json.Unmarshal(raw, &r) //nolint:errcheck
	}
	return r
}

// ResolveToBox picks to_box for agent to BEFORE signing (OQ-03a): explicit wins;
// else a local inbox dir with no other box announcing to → this box; else the
// single announcing box in the cached tenant roster; ambiguity is refused.
func (c *Client) ResolveToBox(to, explicit string) (string, error) {
	if explicit != "" {
		if !msg.ValidBoxID(explicit) {
			return "", fmt.Errorf("--to-box %q is not a valid box id", explicit)
		}
		return explicit, nil
	}
	own := c.Cfg.BoxID
	var remote []string
	for b, agents := range c.loadRoster() {
		if b == own {
			continue
		}
		for _, a := range agents {
			if a == to {
				remote = append(remote, b)
			}
		}
	}
	sort.Strings(remote)
	fi, err := os.Stat(filepath.Join(c.Cfg.SpoolRoot, to))
	local := err == nil && fi.IsDir()
	switch {
	case local && len(remote) == 0:
		return own, nil
	case !local && len(remote) == 1:
		return remote[0], nil
	case local || len(remote) > 1:
		if local {
			remote = append(remote, own)
		}
		return "", &HubError{Token: "ambiguous_to_box", Status: http.StatusConflict,
			Detail: fmt.Sprintf("%s is on boxes %s; pass --to-box", to, strings.Join(remote, ", "))}
	}
	return "", fmt.Errorf("cannot resolve to_box for %s: no box announces it (run `spool hub-sync`, or pass --to-box)", to)
}

func writeAtomic(path string, data []byte) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o775); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(filepath.Dir(path), ".tmp-*")
	if err != nil {
		return err
	}
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		os.Remove(tmp.Name())
		return err
	}
	if err := tmp.Close(); err != nil {
		os.Remove(tmp.Name())
		return err
	}
	return os.Rename(tmp.Name(), path)
}
