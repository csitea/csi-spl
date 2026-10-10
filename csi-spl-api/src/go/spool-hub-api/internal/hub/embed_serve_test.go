package hub

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"runtime"
	"testing"
	"testing/fstest"

	"github.com/csitea/csi-spl/spool-hub-api/internal/blob"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// embedFake is a store with embed_customers rows (store.Postgres has the
// real read; TestEmbedServePostgres drives it).
type embedFake struct {
	*store.Memory
	rows map[string]store.EmbedCustomer
	err  error
}

func (f embedFake) EmbedCustomer(_ context.Context, id string) (store.EmbedCustomer, error) {
	if f.err != nil {
		return store.EmbedCustomer{}, f.err
	}
	e, ok := f.rows[id]
	if !ok {
		return e, store.ErrNotFound
	}
	return e, nil
}

var embedTestAssets = fstest.MapFS{
	"loader.js": {Data: []byte("/* loader */")},
	"chat.html": {Data: []byte("<!doctype html><title>chat</title>")},
}

// embedHandler is the T201 slice of Handler(): another route, /embed/* when
// on, all behind frameGuard.
func embedHandler(t *testing.T, st store.Store, on bool) http.Handler {
	t.Helper()
	s, err := New(Options{Store: st, Blob: blob.Dir{Root: t.TempDir()}, TenantHostPattern: "{tenant}.example.test"})
	if err != nil {
		t.Fatal(err)
	}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /v1/health", func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(http.StatusOK) })
	mux.HandleFunc("GET /v1/docs/x", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Security-Policy", "sandbox; default-src 'none'")
		w.WriteHeader(http.StatusOK)
	})
	s.routeEmbedServe(mux, on, embedTestAssets)
	return frameGuard(mux)
}

func embedGet(t *testing.T, h http.Handler, path string) *httptest.ResponseRecorder {
	t.Helper()
	r := httptest.NewRequest(http.MethodGet, path, nil)
	// A customer page's fetch: the hub must not answer it with CORS.
	r.Header.Set("Origin", "https://shop.example.com")
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	return w
}

func embedRows() embedFake {
	return embedFake{Memory: store.NewMemory(), rows: map[string]store.EmbedCustomer{
		"shop": {EmbedID: "shop", Enabled: true, AllowedOrigins: []string{"https://shop.example.com", "https://*.example.org:8443"}},
		"off":  {EmbedID: "off", Enabled: false, AllowedOrigins: []string{"https://shop.example.com"}},
		"bad": {EmbedID: "bad", Enabled: true, AllowedOrigins: []string{
			"https://a.example.com; script-src *", "https://b.example.com/path", "http://c.example.com",
			"javascript:alert(1)", "https://u@d.example.com", "https://E.example.com", "*",
		}},
		"mix": {EmbedID: "mix", Enabled: true, AllowedOrigins: []string{"https://ok.example.com", "https://x.example.com 'unsafe-inline'", "http://localhost:3000"}},
	}}
}

func wantNone(t *testing.T, what string, w *httptest.ResponseRecorder) {
	t.Helper()
	if got := w.Header().Get("Content-Security-Policy"); got != frameNone {
		t.Errorf("%s: CSP %q, want %q", what, got, frameNone)
	}
	if got := w.Header().Get("X-Frame-Options"); got != "DENY" {
		t.Errorf("%s: X-Frame-Options %q, want DENY", what, got)
	}
}

func wantNoCORS(t *testing.T, what string, w *httptest.ResponseRecorder) {
	t.Helper()
	for k := range w.Header() {
		if len(k) > 12 && k[:12] == "Access-Contr" {
			t.Errorf("%s: carries %s: %q (no CORS for a customer site)", what, k, w.Header().Get(k))
		}
	}
}

// TestEmbedChatFrameAncestors: the chat page of an enabled embed may be
// framed by its allowed origins alone, and carries no X-Frame-Options.
func TestEmbedChatFrameAncestors(t *testing.T) {
	h := embedHandler(t, embedRows(), true)
	w := embedGet(t, h, "/embed/v1/chat?e=shop")
	if w.Code != http.StatusOK || w.Body.String() != "<!doctype html><title>chat</title>" {
		t.Fatalf("chat page: %d %q", w.Code, w.Body.String())
	}
	if got, want := w.Header().Get("Content-Security-Policy"), "frame-ancestors https://shop.example.com https://*.example.org:8443"; got != want {
		t.Errorf("CSP %q, want %q", got, want)
	}
	if got := w.Header().Values("X-Frame-Options"); len(got) != 0 {
		t.Errorf("X-Frame-Options %q on a framable chat page", got)
	}
	if got := w.Header().Get("Cache-Control"); got != "no-store" {
		t.Errorf("Cache-Control %q, want no-store (the policy is per embed)", got)
	}
	if got := w.Header().Get("Content-Type"); got != "text/html; charset=utf-8" {
		t.Errorf("Content-Type %q", got)
	}
	wantNoCORS(t, "chat page", w)
}

// TestEmbedChatRefusesFraming: an unknown, disabled, unnamed or unreadable
// embed, or one whose origins are all invalid, gets 'none' + DENY.
func TestEmbedChatRefusesFraming(t *testing.T) {
	h := embedHandler(t, embedRows(), true)
	for _, path := range []string{"/embed/v1/chat?e=nope", "/embed/v1/chat?e=off", "/embed/v1/chat", "/embed/v1/chat?e=bad"} {
		w := embedGet(t, h, path)
		if w.Code != http.StatusOK {
			t.Errorf("%s: %d", path, w.Code)
		}
		wantNone(t, path, w)
		wantNoCORS(t, path, w)
	}
	broken := embedRows()
	broken.err = errors.New("db down")
	wantNone(t, "store error", embedGet(t, embedHandler(t, broken, true), "/embed/v1/chat?e=shop"))
	// A store without the embed read (store.Memory) frames nothing.
	wantNone(t, "memory store", embedGet(t, embedHandler(t, store.NewMemory(), true), "/embed/v1/chat?e=shop"))
}

// TestEmbedChatDropsInvalidOrigins: an invalid stored origin never reaches
// the header (no directive or source injection); the valid ones stay.
func TestEmbedChatDropsInvalidOrigins(t *testing.T) {
	w := embedGet(t, embedHandler(t, embedRows(), true), "/embed/v1/chat?e=mix")
	if got, want := w.Header().Get("Content-Security-Policy"), "frame-ancestors https://ok.example.com http://localhost:3000"; got != want {
		t.Errorf("CSP %q, want %q", got, want)
	}
}

// TestEmbedLoaderHeaders: the loader is cross-origin readable (CORP), not
// framable, and carries no CORS.
func TestEmbedLoaderHeaders(t *testing.T) {
	w := embedGet(t, embedHandler(t, embedRows(), true), "/embed/v1/loader.js")
	if w.Code != http.StatusOK || w.Body.String() != "/* loader */" {
		t.Fatalf("loader: %d %q", w.Code, w.Body.String())
	}
	if got := w.Header().Get("Cross-Origin-Resource-Policy"); got != "cross-origin" {
		t.Errorf("CORP %q, want cross-origin", got)
	}
	if got := w.Header().Get("Content-Type"); got != "text/javascript; charset=utf-8" {
		t.Errorf("Content-Type %q", got)
	}
	if got := w.Header().Get("X-Content-Type-Options"); got != "nosniff" {
		t.Errorf("X-Content-Type-Options %q", got)
	}
	wantNone(t, "loader", w)
	wantNoCORS(t, "loader", w)
}

// TestEmbedOtherPathsRefuseFraming: every other path keeps 'none' and DENY:
// an API route, a route that sets its own CSP (DENY still holds), an unknown
// /embed/ file, and all of /embed/* while the cnf flag is off.
func TestEmbedOtherPathsRefuseFraming(t *testing.T) {
	on := embedHandler(t, embedRows(), true)
	wantNone(t, "/v1/health", embedGet(t, on, "/v1/health"))
	if w := embedGet(t, on, "/v1/docs/x"); w.Header().Get("X-Frame-Options") != "DENY" {
		t.Errorf("/v1/docs/x: X-Frame-Options %q, want DENY under its own CSP", w.Header().Get("X-Frame-Options"))
	}
	if w := embedGet(t, on, "/embed/v1/other?e=shop"); w.Code != http.StatusNotFound {
		t.Errorf("unknown embed file: %d, want 404", w.Code)
	} else {
		wantNone(t, "unknown embed file", w)
	}
	off := embedHandler(t, embedRows(), false)
	for _, path := range []string{"/embed/v1/chat?e=shop", "/embed/v1/loader.js"} {
		w := embedGet(t, off, path)
		if w.Code != http.StatusNotFound {
			t.Errorf("flag off %s: %d, want 404", path, w.Code)
		}
		if w.Header().Get("Cross-Origin-Resource-Policy") != "" {
			t.Errorf("flag off %s: CORP set", path)
		}
		wantNone(t, "flag off "+path, w)
	}
}

// TestEmbedNoAssets: before T202's assets are wired, /embed/* answers 404
// with the same headers.
func TestEmbedNoAssets(t *testing.T) {
	s, err := New(Options{Store: embedRows(), Blob: blob.Dir{Root: t.TempDir()}, TenantHostPattern: "{tenant}.example.test"})
	if err != nil {
		t.Fatal(err)
	}
	mux := http.NewServeMux()
	s.routeEmbedServe(mux, true, nil)
	w := embedGet(t, frameGuard(mux), "/embed/v1/chat?e=shop")
	if w.Code != http.StatusNotFound || w.Header().Get("Content-Security-Policy") != "frame-ancestors https://shop.example.com https://*.example.org:8443" {
		t.Errorf("no assets: %d %q", w.Code, w.Header().Get("Content-Security-Policy"))
	}
}

// TestEmbedServePostgres drives the real embed_customers read (rdb 0169)
// under the runtime store: an enabled row frames its origin, a disabled row
// and an unknown id get 'none'. Skipped without SPOOL_TEST_PG_DSN.
func TestEmbedServePostgres(t *testing.T) {
	dsn := os.Getenv("SPOOL_TEST_PG_DSN")
	if dsn == "" {
		t.Skip("SPOOL_TEST_PG_DSN unset")
	}
	ctx := context.Background()
	pg, err := store.OpenPostgres(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(pg.Close)
	_, f, _, _ := runtime.Caller(0)
	dir := os.Getenv("SPOOL_TEST_SQL_DIR")
	if dir == "" {
		dir = filepath.Join(filepath.Dir(f), "..", "..", "..", "..", "..", "..", "csi-spl-rdb", "src", "sql", "postgres", "spool-hub")
	}
	if _, err := store.Migrate(ctx, pg.Pool(), dir); err != nil {
		t.Fatal(err)
	}
	b := make([]byte, 4)
	rand.Read(b) //nolint:errcheck
	tenant := "t" + hex.EncodeToString(b)
	pub, _, _ := ed25519.GenerateKey(nil)
	if err := pg.CreateTenant(ctx, store.Tenant{ID: tenant, RootPubKey: pub}); err != nil {
		t.Fatal(err)
	}
	on, off := "e-on-"+hex.EncodeToString(b), "e-off-"+hex.EncodeToString(b)
	tx, err := pg.Pool().Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback(ctx) //nolint:errcheck
	if _, err := tx.Exec(ctx, `SELECT set_config('app.tenant_id', $1, true)`, tenant); err != nil {
		t.Fatal(err)
	}
	if _, err := tx.Exec(ctx, `INSERT INTO embed_customers (tenant_id, embed_id, allowed_origins, enabled)
		VALUES ($1, $2, '{https://shop.example.com}', true), ($1, $3, '{https://shop.example.com}', false)`, tenant, on, off); err != nil {
		t.Fatal(err)
	}
	if err := tx.Commit(ctx); err != nil {
		t.Fatal(err)
	}
	h := embedHandler(t, pg, true)
	if got := embedGet(t, h, "/embed/v1/chat?e="+on).Header().Get("Content-Security-Policy"); got != "frame-ancestors https://shop.example.com" {
		t.Errorf("enabled embed: CSP %q", got)
	}
	wantNone(t, "disabled embed", embedGet(t, h, "/embed/v1/chat?e="+off))
	wantNone(t, "unknown embed", embedGet(t, h, "/embed/v1/chat?e=e-none-"+hex.EncodeToString(b)))
}

// TestEmbedHandlerWired: the hub's real Handler() refuses framing on every
// path and mounts /embed/* only when Options.EmbedEnabled is on.
func TestEmbedHandlerWired(t *testing.T) {
	for _, on := range []bool{true, false} {
		s, err := New(Options{Store: embedRows(), Blob: blob.Dir{Root: t.TempDir()}, TenantHostPattern: "{tenant}.example.test",
			EmbedEnabled: on})
		if err != nil {
			t.Fatal(err)
		}
		h := s.Handler()
		wantNone(t, "Handler /v1/health", embedGet(t, h, "/v1/health"))
		wantNone(t, "Handler /version", embedGet(t, h, "/version"))
		w := embedGet(t, h, "/embed/v1/chat?e=shop")
		// Until T202 passes its assets the page is a 404, but an enabled
		// embed's policy is already on it.
		want := frameNone
		if on {
			want = "frame-ancestors https://shop.example.com https://*.example.org:8443"
		}
		if w.Code != http.StatusNotFound || w.Header().Get("Content-Security-Policy") != want {
			t.Errorf("Handler on=%v chat: %d %q, want 404 %q", on, w.Code, w.Header().Get("Content-Security-Policy"), want)
		}
		wantNoCORS(t, "Handler chat", w)
	}
}
