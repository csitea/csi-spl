package auth_test

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/rs/zerolog"

	"github.com/csitea/csi-spl/spool-hub-api/internal/auth"
)

// SPL-4456 (SPL-4422 row 10): the WUI's session probe on a signed-out page
// was a 401, and Chrome logs every 4xx fetch as a red console line, so each
// visitor's console opened with one. The probe now asks with
// ?signed_out=ok and a signed-out answer is 200 {"signed_in":false}.
// Without the query the route keeps its 401 (the CLI scripts, e2e helpers
// and a WUI tab still running the old bundle read the status, and an old
// bundle would read any 200 as signed in).

const signedOutQuery = "?signed_out=ok"

func signedOutHandler(t *testing.T) *auth.Handler {
	t.Helper()
	cfg, err := auth.LoadFrom("lde", map[string]string{"SPOOL_HUB_AUTH_SESSION_KEY": strings.Repeat("k", 32),
		"SPOOL_HUB_AUTH_APP_URL": "http://app.example.test", "SPOOL_HUB_AUTH_COOKIE_SECURE": "false"})
	if err != nil {
		t.Fatal(err)
	}
	h := auth.New(cfg, zerolog.Nop(), auth.Options{})
	// a session key exists only once a sign-in door is on
	nc, err := auth.LoadNativeFrom("lde", map[string]string{"SPOOL_HUB_AUTH_NATIVE_ENABLED": "true"})
	if err != nil {
		t.Fatal(err)
	}
	if err := h.EnableNative(nc, auth.NativeDeps{Store: auth.NewMemoryCredStore()}); err != nil {
		t.Fatal(err)
	}
	return h
}

func sessionCall(h *auth.Handler, path string, ck *http.Cookie) *httptest.ResponseRecorder {
	req := httptest.NewRequest(http.MethodGet, path, nil)
	if ck != nil {
		req.AddCookie(ck)
	}
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	return rec
}

func mintSession(h *auth.Handler, exp time.Time) *http.Cookie {
	return auth.MintSessionCookie(h, auth.Session{V: 1, Provider: "google", Subject: "s", HumanID: "HUM-1",
		Email: "person@example.com", IssuedAt: exp.Add(-time.Hour).Unix(), Exp: exp.Unix()})
}

// tamperMAC changes one character in the middle of the signature. Every bit
// of that character is data, so the MAC bytes always change; the last
// character carries 2 spare bits a decoder ignores (SPL-5100).
func tamperMAC(value string) string {
	dot := strings.LastIndexByte(value, '.')
	mid := dot + (len(value)-dot)/2
	repl := "A"
	if value[mid] == 'A' {
		repl = "B"
	}
	return value[:mid] + repl + value[mid+1:]
}

func TestSessionProbeSignedOutIs200(t *testing.T) {
	h := signedOutHandler(t)
	live := mintSession(h, time.Now().Add(time.Hour))
	tampered := *live
	tampered.Value = tamperMAC(live.Value)
	cases := map[string]*http.Cookie{
		"no cookie":       nil,
		"expired cookie":  mintSession(h, time.Now().Add(-time.Minute)),
		"tampered cookie": &tampered,
		"garbage cookie":  {Name: live.Name, Value: "not-a-token"},
	}
	for name, ck := range cases {
		t.Run(name, func(t *testing.T) {
			rec := sessionCall(h, "/api/v1/auth/session"+signedOutQuery, ck)
			if rec.Code != http.StatusOK {
				t.Fatalf("signed-out probe = %d %s, want 200", rec.Code, rec.Body)
			}
			if got := strings.TrimSpace(rec.Body.String()); got != `{"signed_in":false}` {
				t.Fatalf("signed-out body %s, want {\"signed_in\":false}", got)
			}
			if cc := rec.Header().Get("Cache-Control"); cc != "no-store" {
				t.Fatalf("signed-out Cache-Control %q, want no-store", cc)
			}
			if sc := rec.Header().Get("Set-Cookie"); sc != "" {
				t.Fatalf("the signed-out answer set a cookie: %q", sc)
			}
			// without the opt-in the route keeps its 401
			if rec := sessionCall(h, "/api/v1/auth/session", ck); rec.Code != http.StatusUnauthorized {
				t.Fatalf("plain probe = %d %s, want 401", rec.Code, rec.Body)
			}
		})
	}
}

// SPL-5100: overwriting the last two characters with "xx" left the MAC valid
// for a signature ending in "xw", about 1 mint in 1024. A fixed far-future
// expiry per mint makes the walk over those cookies the same on every run.
func TestTamperMACAlwaysInvalidates(t *testing.T) {
	h := signedOutHandler(t)
	base := time.Unix(4102444800, 0)
	xw := 0
	for i := range 20000 {
		ck := mintSession(h, base.Add(time.Duration(i)*time.Second))
		if !strings.HasSuffix(ck.Value, "xw") {
			continue
		}
		xw++
		tampered := *ck
		tampered.Value = tamperMAC(ck.Value)
		if rec := sessionCall(h, "/api/v1/auth/session", &tampered); rec.Code != http.StatusUnauthorized {
			t.Fatalf("mint %d: tampered cookie = %d, want 401", i, rec.Code)
		}
	}
	if xw == 0 {
		t.Fatal("no mint ended in xw: this walk proves nothing")
	}
}

func TestSessionProbeSignedInUnchanged(t *testing.T) {
	h := signedOutHandler(t)
	ck := mintSession(h, time.Now().Add(time.Hour))
	plain := sessionCall(h, "/api/v1/auth/session", ck)
	quiet := sessionCall(h, "/api/v1/auth/session"+signedOutQuery, ck)
	if plain.Code != http.StatusOK || quiet.Code != http.StatusOK {
		t.Fatalf("signed in: plain %d, quiet %d, want 200 both", plain.Code, quiet.Code)
	}
	if plain.Body.String() != quiet.Body.String() {
		t.Fatalf("the query changed the signed-in answer:\n plain %s\n quiet %s", plain.Body, quiet.Body)
	}
	out := map[string]any{}
	if err := json.Unmarshal(quiet.Body.Bytes(), &out); err != nil {
		t.Fatal(err)
	}
	if out["hum"] != "HUM-1" {
		t.Fatalf("signed-in claims lost the human: %v", out)
	}
	if _, has := out["signed_in"]; has {
		t.Fatalf("a signed-in answer carries signed_in: %v", out)
	}
}

// Only GET /session takes the opt-in: another auth route with no session
// keeps its 401.
func TestSignedOutQueryLeavesOtherRoutes401(t *testing.T) {
	h := signedOutHandler(t)
	req := httptest.NewRequest(http.MethodPut, "/api/v1/auth/preferences"+signedOutQuery, strings.NewReader(`{"diagnostics_enabled":true}`))
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("PUT preferences signed out with the query = %d %s, want 401", rec.Code, rec.Body)
	}
}
