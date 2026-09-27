// Package hub is the spool hub process (`spool serve`, spec 003): a stateless
// HTTPS + WebSocket server. Boxes authenticate with a challenge-response hello
// signed by their box key, send box-signed envelopes, and receive recv / tail
// frames on the same socket; REST carries files and pins (contracts/
// http-v1.md) and, when 008 is enabled, POST /v1/cicd-logs. State lives in internal/store (Postgres) and internal/blob
// (GCS); the live-socket map and upload tokens are per-process memory, which
// M1 makes sound by running with max-instances=1 (OQ-05).
package hub

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/coder/websocket"
	"github.com/rs/zerolog"

	"github.com/csitea/csi-spl/spool-hub-api/internal/auth"
	"github.com/csitea/csi-spl/spool-hub-api/internal/billing"
	"github.com/csitea/csi-spl/spool-hub-api/internal/blob"
	"github.com/csitea/csi-spl/spool-hub-api/internal/cicdlogs"
	"github.com/csitea/csi-spl/spool-hub-api/internal/edge"
	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// Options configures a Server. Every duration and limit comes from cnf
// (config.Hub); tests set them directly.
type Options struct {
	Store             store.Store
	Blob              blob.Store
	Log               zerolog.Logger
	TenantHostPattern string // "{tenant}.<fqdn>"
	HelloSkew         time.Duration
	HelloTimeout      time.Duration
	UploadTokenTTL    time.Duration
	QueueTTL          time.Duration
	QueueMaxPerBox    int
	// SPL-987 back-fill of a newly seated channel agent (backfill.go):
	// topics active within BackfillWindow, newest BackfillMax messages.
	// 0 window = the 168h default; BackfillMax 0 = no back-fill.
	BackfillWindow time.Duration
	BackfillMax    int
	// SPL-997: a human post that no agent it was meant for could hear goes to
	// ONE online fallback agent of the tenant (fallback.go). Zero = off, so a
	// rig that does not ask for it sees no extra frame.
	Fallback bool

	RetentionAlerts   time.Duration
	RetentionChannels time.Duration
	AllowTextOnly     bool // hub.allow_text_only_when_file_missing (OQ-11)
	Version           string
	Commit            string // -ldflags main.commit; "unknown" in dev builds
	BuiltAt           string // -ldflags main.builtAt (RFC3339 UTC)
	Env               string // lde | dev | prd; shown by GET / only
	Now               func() time.Time
	// Quota: 0 = unlimited. Enforced on send / pin / PUT file (006 T012).
	QuotaMessagesPerMonth int
	QuotaPins             int
	QuotaFileBytes        int64
	CICD                  *cicdlogs.Service // nil = 008 route not registered (M1 default)
	// Viewer API (contracts/view-v1.md): door mode ("" = token) and the CORS
	// allow-list (empty = same-origin only).
	ViewDoor        string
	ViewCORSOrigins []string
	// OriginTenant (SPL-959): the WUI tenant hosts; nil = off (the session's
	// tenant, and only the exact CORS entries).
	OriginTenant *OriginTenant
	// LobbyTaskID is cnf SPOOL_HUB_LOBBY_TASK_ID (wui-live-ws.md §1); "" = lobby off.
	LobbyTaskID string
	// Auth is the social sign-in surface (spec 010, /api/v1/auth/*); nil = not
	// mounted. It is not tenant-scoped: the routes answer on any Host.
	Auth *auth.Handler
	// WUIKey is the box-wui signing key (specs/014); nil = no key: box-wui
	// cannot be pinned and nothing is dispatched. WUIDispatch signs and
	// delivers a browser send that names an agent (SPOOL_HUB_WUI_DISPATCH).
	WUIKey      ed25519.PrivateKey
	WUIDispatch bool
	// Payments is the M2 checkout surface (006 checkout-v1, /api/v1/checkout*
	// and /api/v1/webhooks/payment); nil = not mounted. Not tenant-scoped.
	Payments interface{ Register(mux *http.ServeMux) }
	// Edge is the in-app edge protection (017 FR-SEC-004, cnf
	// SPOOL_HUB_EDGE_* + SPOOL_HUB_TRUSTED_PROXY_HOPS); zero = every limit off.
	Edge edge.Limits
	// ClientIPProbe mounts GET /v1/debug/client-ip (SPOOL_HUB_CLIENT_IP_PROBE).
	ClientIPProbe bool
	// PingInterval / PingTimeout: socket liveness on /v1/ws and /v1/wui/ws. A
	// peer that misses a pong for PingTimeout is closed. 0 interval = no pings.
	PingInterval time.Duration
	PingTimeout  time.Duration
	// MsgVersion is the v of the messages the hub composes itself (WUI posts,
	// dispatch), cnf SPOOL_HUB_MSG_VERSION (specs/020); 0 = msg.Version.
	MsgVersion int
	// Authorizer answers a human's permissions in a tenant (specs/025); nil =
	// the store-backed rbac.Authorizer. Set by code only (a test seam).
	Authorizer Authorizer
	// SessionID returns the member-session human id of a browser request; nil
	// = Auth.SessionForTenant. Set by code only (a test seam), never by env.
	SessionID func(r *http.Request, tenant string) (string, error)
	// SearchRatePerMin caps GET /v1/view/search per (tenant, reader) per
	// minute (search-v1 §5.1); 0 = 30. SearchBudget is the per-statement time
	// budget; 0 = 2 s.
	SearchRatePerMin int
	SearchBudget     time.Duration
	// KeysWriteLimit is the per-human hourly ceiling on key writes (specs/023
	// FR-008); 0 = keysWritesPerHour.
	KeysWriteLimit int
	// EventsWriteLimit is the per-human hourly ceiling on event-log writes
	// (specs/005 events-v1); 0 = eventsWritesPerHour.
	EventsWriteLimit int
	// FileUsageTTL: how long a tenant's listed file bytes are trusted by the
	// upload quota (fileusage.go); 0 = defaultFileUsageTTL. Code only.
	FileUsageTTL time.Duration
	// InviteMail mails the invitation after POST /v1/members/invites stored
	// it (010 FR-016 via invitemail.Send); nil = the invite is stored, no mail.
	InviteMail InviteMailer
}

// Server is one hub process.
type Server struct {
	o      Options
	suffix string // TenantHostPattern without "{tenant}"

	mu       sync.Mutex
	boxes    map[[2]string]*session // (tenant, box) → the role=box session
	sessions map[*session]struct{}  // every live socket (both roles)
	tokens   map[string]uploadToken
	// tokenSweptAt: when mintToken last dropped expired tokens (CLE-34986:
	// it walked the whole map on EVERY mint, under mu).
	tokenSweptAt time.Time
	wui          map[*wuiConn]struct{} // browser live sockets (wui.go)
	humans       humanIDs
	online       map[[2]string]int // (tenant, HUM-*) → open browser sockets (presence)
	closing      bool
	cicd         *cicdlogs.Service
	edge         *edge.Guard
	keysLim      *edge.Window // keys.go, per-human writes
	evLim        *edge.Window // events.go, per-human writes

	searchRate *edge.Window // search.go, per (tenant, reader)
	fileUsage  *fileUsage   // fileusage.go, per-tenant stored file bytes

	backfilling sync.Map // backfill.go: [4]string seat -> in flight
}

type uploadToken struct {
	tenant, box string
	expires     time.Time
}

// New returns a Server. It fails fast on a malformed option.
func New(o Options) (*Server, error) {
	if o.Store == nil || o.Blob == nil {
		return nil, errors.New("hub: store and blob are required")
	}
	if !strings.HasPrefix(o.TenantHostPattern, "{tenant}.") {
		return nil, fmt.Errorf("hub: tenant host pattern %q must start with {tenant}.", o.TenantHostPattern)
	}
	if o.Now == nil {
		o.Now = time.Now
	}
	if o.Authorizer == nil {
		o.Authorizer = defaultAuthorizer(o.Store)
	}
	switch o.ViewDoor {
	case "":
		o.ViewDoor = ViewDoorToken
	case ViewDoorToken, ViewDoorOff:
	case ViewDoorSession:
		if o.Auth == nil {
			return nil, errors.New("hub: view door session needs the sign-in surface (Options.Auth)")
		}
	default:
		return nil, fmt.Errorf("hub: view door %q must be token, session or off", o.ViewDoor)
	}
	if o.WUIDispatch && len(o.WUIKey) != ed25519.PrivateKeySize {
		return nil, errors.New("hub: WUI dispatch needs a box-wui ed25519 private key")
	}
	if o.SearchRatePerMin <= 0 {
		o.SearchRatePerMin = searchRateDefault
	}
	if o.SearchBudget <= 0 {
		o.SearchBudget = searchBudgetDefault
	}
	if o.HelloTimeout == 0 {
		o.HelloTimeout = 10 * time.Second
	}
	if o.PingInterval > 0 && o.PingTimeout <= 0 {
		o.PingTimeout = writeTimeout
	}
	s := &Server{
		o: o, suffix: strings.ToLower(strings.TrimPrefix(o.TenantHostPattern, "{tenant}")),
		boxes: map[[2]string]*session{}, sessions: map[*session]struct{}{},
		tokens: map[string]uploadToken{}, wui: map[*wuiConn]struct{}{}, online: map[[2]string]int{},
		edge: edge.NewGuard(o.Edge, o.Log, o.Now), searchRate: edge.NewWindow(time.Minute, o.Now),
		fileUsage: newFileUsage(o.FileUsageTTL),
	}
	if o.CICD != nil {
		o.CICD.Bus = s
		s.cicd = o.CICD
	}
	return s, nil
}

// Handler returns the HTTP surface (http-v1.md §1) behind the shared middleware.
func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	// GET / is a public hello so the product hosts show something at the root.
	mux.HandleFunc("GET /{$}", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		w.WriteHeader(http.StatusOK)
		fmt.Fprintf(w, "%s ok\n", strings.TrimSpace("spool-hub "+s.o.Env))
	})
	health := func(w http.ResponseWriter, _ *http.Request) {
		writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
	}
	// /healthz for local use; /v1/health because Cloud Run reserves some paths
	// ending in "z" and the LB health check needs one it will pass (FR-023).
	mux.HandleFunc("GET /healthz", health)
	mux.HandleFunc("GET /v1/health", health)
	mux.HandleFunc("GET /version", func(w http.ResponseWriter, _ *http.Request) {
		// Public, like /healthz: the deploy acceptance check (T037).
		writeJSON(w, http.StatusOK, map[string]string{"version": s.o.Version, "commit": s.o.Commit, "built_at": s.o.BuiltAt})
	})
	mux.HandleFunc("GET /v1/ws", s.handleWS)
	mux.HandleFunc("POST /v1/files", s.handlePutFile)
	mux.HandleFunc("GET /v1/files/{file_id}", s.handleGetFile)
	mux.HandleFunc("GET /v1/pins", s.handleListPins)
	mux.HandleFunc("POST /v1/pins", s.handlePin)
	mux.HandleFunc("DELETE /v1/pins/{box_id}", s.handleRevoke)
	if s.cicd != nil {
		mux.HandleFunc("POST /v1/cicd-logs", s.handleCICDLogs)
	}
	s.routeView(mux)
	mux.HandleFunc("GET /v1/wui/ws", s.handleWUIWS)
	mux.HandleFunc("GET /v1/wui/pubkey", s.handleWUIPubkey)
	mux.HandleFunc("DELETE /v1/files/{file_id}", s.handleDeleteFile)
	mux.HandleFunc("POST /v1/channels", s.handleCreateChannel)
	mux.HandleFunc("PATCH /v1/messages/{msg_id}", s.handleEditMessage) // specs/032
	mux.HandleFunc("DELETE /v1/messages/{msg_id}", s.handleDeleteMessage)
	mux.HandleFunc("OPTIONS /v1/messages/{msg_id}", s.editPreflight)
	mux.HandleFunc("PATCH /v1/messages/{msg_id}/kind", s.handleSetMessageKind) // SPL-952
	mux.HandleFunc("OPTIONS /v1/messages/{msg_id}/kind", s.kindPreflight)
	mux.HandleFunc("PUT /v1/messages/{msg_id}/reactions", s.handlePutReaction)
	mux.HandleFunc("PUT /v1/messages/{msg_id}/archive", s.handleArchiveTopic) // specs/041
	mux.HandleFunc("DELETE /v1/messages/{msg_id}/archive", s.handleArchiveTopic)
	mux.HandleFunc("DELETE /v1/messages/{msg_id}/topic", s.handleDeleteTopic)
	mux.HandleFunc("OPTIONS /v1/messages/{msg_id}/archive", s.topicPreflight)
	mux.HandleFunc("OPTIONS /v1/messages/{msg_id}/topic", s.topicPreflight)
	mux.HandleFunc("DELETE /v1/messages/{msg_id}/reactions", s.handleDeleteReaction)
	mux.HandleFunc("OPTIONS /v1/messages/{msg_id}/reactions", s.reactionPreflight)
	mux.HandleFunc("OPTIONS /v1/channels", s.channelsPreflight)
	s.routeChannelMembers(mux)
	s.routeMembers(mux)
	s.routeIssues(mux) // specs/039
	mux.HandleFunc("OPTIONS /v1/files", s.filesPreflight)
	if s.o.Auth != nil {
		s.o.Auth.Register(mux)
		s.registerKeys(mux)
		s.registerEvents(mux)
	}
	if s.o.Payments != nil {
		s.o.Payments.Register(mux)
	}
	if s.o.ClientIPProbe {
		mux.HandleFunc("GET "+edge.PathProbe, s.edge.Probe)
		mux.HandleFunc("GET "+edge.PathProbeAuth, s.edge.Probe)
	}
	// The edge limits sit inside authCORS so a 429 on /api/v1/auth/* still
	// carries the CORS headers the WUI needs to read it.
	inner := s.edge.Wrap(mux)
	if s.o.Auth != nil {
		return s.middleware(compressJSON(s.authCORS(inner)))
	}
	return s.middleware(compressJSON(inner))
}

// Shutdown closes every live socket with 1001 (graceful drain); the caller
// shuts the http.Server down separately (hijacked sockets are not tracked there).
func (s *Server) Shutdown() {
	s.mu.Lock()
	s.closing = true
	all := make([]*session, 0, len(s.sessions))
	for x := range s.sessions {
		all = append(all, x)
	}
	var browsers []*wuiConn
	for c := range s.wui {
		browsers = append(browsers, c)
	}
	s.mu.Unlock()
	for _, c := range browsers {
		c.close(websocket.StatusGoingAway, "shutdown")
	}
	var wg sync.WaitGroup
	for _, x := range all {
		wg.Add(1)
		go func(x *session) {
			defer wg.Done()
			x.close(websocket.StatusGoingAway, "shutdown")
		}(x)
	}
	wg.Wait()
}

// keepalive pings conn every PingInterval until ctx ends; a missed pong within
// PingTimeout closes the socket (017 FR-SEC-004: a half-open or unread socket does not
// keep its slot until the Cloud Run request timeout). It closes without a
// close handshake: a peer that ignores pings would not answer one either. The
// pong is read by the handler's own read loop, which every socket has.
func (s *Server) keepalive(ctx context.Context, conn *websocket.Conn) {
	if s.o.PingInterval <= 0 {
		return
	}
	go func() {
		t := time.NewTicker(s.o.PingInterval)
		defer t.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-t.C:
				pctx, cancel := context.WithTimeout(ctx, s.o.PingTimeout)
				err := conn.Ping(pctx)
				cancel()
				if err != nil {
					if ctx.Err() == nil {
						conn.CloseNow() //nolint:errcheck
					}
					return
				}
			}
		}
	}()
}

// RunSweeper applies retention every interval until ctx ends, and deletes
// the blobs no retained message carries every fileSweepEvery (SweepFiles).
func (s *Server) RunSweeper(ctx context.Context, interval time.Duration) {
	t := time.NewTicker(interval)
	defer t.Stop()
	ft := time.NewTicker(fileSweepEvery)
	defer ft.Stop()
	bt := time.NewTicker(backfillEvery)
	defer bt.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-bt.C:
			s.backfillLive(ctx)
		case <-ft.C:
			r, err := s.SweepFiles(ctx, s.o.Now())
			if err != nil {
				s.o.Log.Error().Err(err).Int("deleted", r.Deleted).Msg("file retention sweep")
				continue
			}
			if r.Deleted > 0 {
				s.o.Log.Info().Int("scanned", r.Scanned).Int("deleted", r.Deleted).Msg("file retention sweep")
			}
		case <-t.C:
			r, err := s.o.Store.Sweep(ctx, s.o.Now())
			if err != nil {
				s.o.Log.Error().Err(err).Msg("retention sweep")
				continue
			}
			if r.Expired+r.Purged > 0 {
				s.o.Log.Info().Int("expired", r.Expired).Int("purged", r.Purged).Msg("retention sweep")
			}
		}
	}
}

func (s *Server) mintToken(tenant, box string) (string, time.Time) {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	tok := base64.RawURLEncoding.EncodeToString(b)
	exp := s.o.Now().Add(s.o.UploadTokenTTL)
	s.mu.Lock()
	defer s.mu.Unlock()
	now := s.o.Now()
	if now.Sub(s.tokenSweptAt) >= tokenSweepEvery { // lazy cleanup, at most once a sweep period
		s.tokenSweptAt = now
		for k, v := range s.tokens {
			if now.After(v.expires) {
				delete(s.tokens, k)
			}
		}
	}
	s.tokens[tok] = uploadToken{tenant: tenant, box: box, expires: exp}
	return tok, exp
}

// tokenSweepEvery bounds how often a mint walks the token map.
const tokenSweepEvery = time.Minute

// tokenSlot is one connection's current upload token (CLE-34986). A `token`
// frame minted a NEW token every time and each mint walked the whole map
// under the hub-wide mutex, so one socket looping {"type":"token"} grew the
// map without bound and stalled routing for every tenant. A connection now
// gets its current token back while more than half its TTL remains; only
// then is a new one minted.
type tokenSlot struct {
	mu  sync.Mutex
	tok string
	exp time.Time
}

// slotToken answers slot's token, minting one when none is left or it is in
// the second half of its life.
func (s *Server) slotToken(slot *tokenSlot, tenant, box string) (string, time.Time) {
	slot.mu.Lock()
	defer slot.mu.Unlock()
	if slot.tok != "" && slot.exp.Sub(s.o.Now()) > s.o.UploadTokenTTL/2 {
		return slot.tok, slot.exp
	}
	slot.tok, slot.exp = s.mintToken(tenant, box)
	return slot.tok, slot.exp
}

func (s *Server) retention(channel string) time.Duration {
	if channel == "alerts" {
		return s.o.RetentionAlerts
	}
	return s.o.RetentionChannels
}

func (s *Server) skewOK(ts string) bool {
	t, err := time.Parse(time.RFC3339, ts)
	if err != nil {
		return false
	}
	d := s.o.Now().Sub(t)
	return d <= s.o.HelloSkew && d >= -s.o.HelloSkew
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(v) //nolint:errcheck
}

func writeErr(w http.ResponseWriter, status int, token, detail string) {
	writeJSON(w, status, wire.ErrorBody{Error: token, Detail: detail})
}

func writeUnpaid(w http.ResponseWriter) {
	writeErr(w, billing.HTTPUnpaid, billing.TokenUnpaid, "tenant billing is unpaid")
}

func writeQuota(w http.ResponseWriter, detail string) {
	writeErr(w, billing.HTTPQuota, billing.TokenQuota, detail)
}

func (s *Server) quota() billing.Quota {
	return billing.Quota{
		MessagesPerMonth: s.o.QuotaMessagesPerMonth,
		Pins:             s.o.QuotaPins,
		FileBytes:        s.o.QuotaFileBytes,
	}
}

// ---- middleware: recover, request id, access log ----------------------------

type statusWriter struct {
	http.ResponseWriter
	status int
}

func (w *statusWriter) WriteHeader(c int) {
	if w.status == 0 {
		w.status = c
	}
	w.ResponseWriter.WriteHeader(c)
}

func (w *statusWriter) Unwrap() http.ResponseWriter { return w.ResponseWriter }

func (s *Server) middleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := s.o.Now()
		rid := r.Header.Get("X-Request-ID")
		if rid == "" {
			b := make([]byte, 8)
			rand.Read(b) //nolint:errcheck
			rid = base64.RawURLEncoding.EncodeToString(b)
		}
		w.Header().Set("X-Request-ID", rid)
		sw := &statusWriter{ResponseWriter: w}
		defer func() {
			if rec := recover(); rec != nil {
				s.o.Log.Error().Str("request_id", rid).Interface("panic", rec).Msg("handler panic")
				if sw.status == 0 {
					writeErr(sw, http.StatusInternalServerError, "internal", "internal error")
				}
			}
			// Path only: no query string, no Authorization, no token (Constitution VII).
			s.o.Log.Info().Str("request_id", rid).Str("method", r.Method).Str("path", r.URL.Path).
				Str("host", r.Host).Int("status", sw.status).Dur("dur", s.o.Now().Sub(start)).Msg("http")
		}()
		next.ServeHTTP(sw, r)
	})
}

// writeVersion is the v the hub stamps on a message it composes (specs/020).
func (s *Server) writeVersion() int {
	if s.o.MsgVersion == 0 {
		return msg.Version
	}
	return s.o.MsgVersion
}
