// Package hub is the spool hub process (`spool serve`, spec 003): a stateless
// HTTPS + WebSocket server. Boxes authenticate with a challenge-response hello
// signed by their box key, send box-signed envelopes, and receive recv / tail
// frames on the same socket; REST carries files and pins only (contracts/
// http-v1.md). State lives in internal/store (Postgres) and internal/blob
// (GCS); the live-socket map and upload tokens are per-process memory, which
// M1 makes sound by running with max-instances=1 (OQ-05).
package hub

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/coder/websocket"
	"github.com/rs/zerolog"

	"github.com/csitea/csi-spl/spool-hub-api/internal/blob"
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
	RetentionAlerts   time.Duration
	RetentionChannels time.Duration
	AllowTextOnly     bool // hub.allow_text_only_when_file_missing (OQ-11)
	Version           string
	Now               func() time.Time
}

// Server is one hub process.
type Server struct {
	o      Options
	suffix string // TenantHostPattern without "{tenant}"

	mu       sync.Mutex
	boxes    map[[2]string]*session // (tenant, box) → the role=box session
	sessions map[*session]struct{}  // every live socket (both roles)
	tokens   map[string]uploadToken
	closing  bool
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
	if o.HelloTimeout == 0 {
		o.HelloTimeout = 10 * time.Second
	}
	return &Server{
		o: o, suffix: strings.ToLower(strings.TrimPrefix(o.TenantHostPattern, "{tenant}")),
		boxes: map[[2]string]*session{}, sessions: map[*session]struct{}{},
		tokens: map[string]uploadToken{},
	}, nil
}

// Handler returns the HTTP surface (http-v1.md §1) behind the shared middleware.
func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) {
		writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
	})
	mux.HandleFunc("GET /version", func(w http.ResponseWriter, _ *http.Request) {
		writeJSON(w, http.StatusOK, map[string]string{"version": s.o.Version})
	})
	mux.HandleFunc("GET /v1/ws", s.handleWS)
	mux.HandleFunc("POST /v1/files", s.handlePutFile)
	mux.HandleFunc("GET /v1/files/{file_id}", s.handleGetFile)
	mux.HandleFunc("GET /v1/pins", s.handleListPins)
	mux.HandleFunc("POST /v1/pins", s.handlePin)
	mux.HandleFunc("DELETE /v1/pins/{box_id}", s.handleRevoke)
	return s.middleware(mux)
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
	s.mu.Unlock()
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

// RunSweeper applies retention every interval until ctx ends.
func (s *Server) RunSweeper(ctx context.Context, interval time.Duration) {
	t := time.NewTicker(interval)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
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

// tenantOf resolves the tenant from the request Host (FR-015).
func (s *Server) tenantOf(r *http.Request) (store.Tenant, error) {
	host := strings.ToLower(r.Host)
	if h, _, err := net.SplitHostPort(host); err == nil {
		host = h
	}
	if !strings.HasSuffix(host, s.suffix) {
		return store.Tenant{}, store.ErrNotFound
	}
	id := strings.TrimSuffix(host, s.suffix)
	if !msg.ValidBoxID(id) { // the tenant id shares the box-id alphabet (006)
		return store.Tenant{}, store.ErrNotFound
	}
	return s.o.Store.GetTenant(r.Context(), id)
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
	for k, v := range s.tokens { // lazy cleanup
		if now.After(v.expires) {
			delete(s.tokens, k)
		}
	}
	s.tokens[tok] = uploadToken{tenant: tenant, box: box, expires: exp}
	return tok, exp
}

// bearer checks the WS-issued upload token (OQ-10) and returns its box.
func (s *Server) bearer(r *http.Request, tenant string) (string, bool) {
	h := r.Header.Get("Authorization")
	tok, ok := strings.CutPrefix(h, "Bearer ")
	if !ok || tok == "" {
		return "", false
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	t, ok := s.tokens[tok]
	if !ok || t.tenant != tenant || s.o.Now().After(t.expires) {
		return "", false
	}
	return t.box, true
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

// ---- middleware: recover, request id, access log (pas-psf pattern) ----------

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
