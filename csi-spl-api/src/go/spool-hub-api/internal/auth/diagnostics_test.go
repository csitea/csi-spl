package auth_test

import (
	"encoding/json"
	"errors"
	"net/http"
	"net/url"
	"strings"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/auth"
)

// 005 T035 / 010 auth-v1 section 3 / CLE-34963: the hub tells the WUI whether
// THIS human ticked "Debug pane" in their settings. The setting is the human's
// own (humans.diagnostics_enabled, rdb 0038), written by PUT preferences, read
// on every session call, never a claim of the signed cookie — and the SOLE
// gate: the operator list SPOOL_HUB_AUTH_DIAGNOSTICS_EMAILS is retired.

// retiredVar is the operator list the setting replaced; it must grant nothing.
const retiredVar = "SPOOL_HUB_AUTH_DIAGNOSTICS_EMAILS"

// sessionJSON reads GET /session as the wire sees it: a map, not auth.Session,
// so a claim the struct does not have is still visible to the assertion.
func sessionJSON(t *testing.T, c *http.Client, hub string) (int, map[string]any) {
	t.Helper()
	resp, err := c.Get(hub + "/api/v1/auth/session")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	out := map[string]any{}
	json.NewDecoder(resp.Body).Decode(&out) //nolint:errcheck
	return resp.StatusCode, out
}

func mustParse(t *testing.T, raw string) *url.URL {
	t.Helper()
	u, err := url.Parse(raw)
	if err != nil {
		t.Fatal(err)
	}
	return u
}

func TestSessionCarriesDiagnosticsSetting(t *testing.T) {
	r, _ := newPRig(t, "", true)
	c := browser(t)
	r.signedIn(t, c, "person@example.com")

	// The key is always present and always a boolean: the WUI's gate admits
	// only the literal `true`, and a missing key would read the same as false
	// — but then a hub that lost the feature would look exactly like a human
	// who never ticked the box.
	if code, got := sessionJSON(t, c, r.url); code != http.StatusOK || got["diagnostics_enabled"] != false {
		t.Fatalf("default: %d %v", code, got)
	}

	got := r.call(t, c, http.MethodPut, "preferences", `{"diagnostics_enabled":true}`)
	if got.code != http.StatusOK || got.body["diagnostics_enabled"] != true {
		t.Fatalf("tick: %d %s", got.code, got.raw)
	}
	// Only the key that was sent is stored and echoed: the language is untouched.
	if _, ok := got.body["preferred_locale"]; ok {
		t.Fatalf("tick echoed a locale it was not sent: %s", got.raw)
	}
	if _, s := sessionJSON(t, c, r.url); s["diagnostics_enabled"] != true || s["preferred_locale"] != nil {
		t.Fatalf("session after tick: %v", s)
	}

	// Unticking hides it at the very next read, on the SAME cookie: nothing
	// waits for the session to expire. This is why it is not a signed claim.
	if got = r.call(t, c, http.MethodPut, "preferences", `{"diagnostics_enabled":false}`); got.code != http.StatusOK || got.body["diagnostics_enabled"] != false {
		t.Fatalf("untick: %d %s", got.code, got.raw)
	}
	if _, s := sessionJSON(t, c, r.url); s["diagnostics_enabled"] != false {
		t.Fatalf("session after untick: %v", s)
	}

	// Both keys in one body are both stored.
	if got = r.call(t, c, http.MethodPut, "preferences", `{"preferred_locale":"fi","diagnostics_enabled":true}`); got.code != http.StatusOK ||
		got.body["preferred_locale"] != "fi" || got.body["diagnostics_enabled"] != true {
		t.Fatalf("both: %d %s", got.code, got.raw)
	}
	// ...and a locale-only save leaves the checkbox where it was.
	if got = r.call(t, c, http.MethodPut, "preferences", `{"preferred_locale":"sv"}`); got.code != http.StatusOK {
		t.Fatalf("locale only: %d %s", got.code, got.raw)
	}
	if _, s := sessionJSON(t, c, r.url); s["diagnostics_enabled"] != true || s["preferred_locale"] != "sv" {
		t.Fatalf("a locale save moved the checkbox: %v", s)
	}
}

// The native login answers with the claims the WUI adopts without a second
// probe (015 native-auth-v1 section 2), so the setting is in THAT body too.
func TestNativeLoginCarriesDiagnosticsSetting(t *testing.T) {
	r, _ := newPRig(t, "", true)
	c := browser(t)
	r.signedIn(t, c, "person@example.com")
	login := func() resp {
		return r.post(t, c, "login", map[string]string{"email": "person@example.com", "password": pwA, "tenant": "acme"})
	}
	if g := login(); g.code != http.StatusOK || g.body["diagnostics_enabled"] != false {
		t.Fatalf("login before: %d %s", g.code, g.raw)
	}
	if got := r.call(t, c, http.MethodPut, "preferences", `{"diagnostics_enabled":true}`); got.code != http.StatusOK {
		t.Fatalf("tick: %d %s", got.code, got.raw)
	}
	if g := login(); g.code != http.StatusOK || g.body["diagnostics_enabled"] != true {
		t.Fatalf("login after: %d %s", g.code, g.raw)
	}
}

func TestDiagnosticsSettingFailsShut(t *testing.T) {
	t.Run("no preferences store wired", func(t *testing.T) {
		r := newRig(t, registrar{})
		c := browser(t)
		signIn(t, c, r, "google", "?redirect=/c/general")
		if code, got := sessionJSON(t, c, r.hub); code != http.StatusOK || got["diagnostics_enabled"] != false {
			t.Fatalf("%d %v", code, got)
		}
	})

	t.Run("no registered human", func(t *testing.T) {
		r, _ := newPRig(t, "", false)
		c := browser(t)
		r.signedIn(t, c, "person@example.com")
		if got := r.call(t, c, http.MethodPut, "preferences", `{"diagnostics_enabled":true}`); got.code != http.StatusConflict || got.body["error"] != "no_human" {
			t.Fatalf("put: %d %s", got.code, got.raw)
		}
		if _, got := sessionJSON(t, c, r.url); got["diagnostics_enabled"] != false {
			t.Fatalf("session: %v", got)
		}
	})

	// A store that cannot answer is "no", even where the row reads true.
	t.Run("store error", func(t *testing.T) {
		r, prefs := newPRig(t, "", true)
		c := browser(t)
		r.signedIn(t, c, "person@example.com")
		if got := r.call(t, c, http.MethodPut, "preferences", `{"diagnostics_enabled":true}`); got.code != http.StatusOK {
			t.Fatalf("tick: %d %s", got.code, got.raw)
		}
		prefs.mu.Lock()
		prefs.fail = errors.New("store down")
		prefs.mu.Unlock()
		if code, got := sessionJSON(t, c, r.url); code != http.StatusOK || got["diagnostics_enabled"] != false {
			t.Fatalf("a failing store granted the panel: %d %v", code, got)
		}
	})

	// Only the literal booleans are a setting; nothing is coerced and a
	// refused body stores nothing (including its valid locale half).
	t.Run("bad values are refused", func(t *testing.T) {
		r, prefs := newPRig(t, "", true)
		c := browser(t)
		r.signedIn(t, c, "person@example.com")
		for _, body := range []string{
			`{"diagnostics_enabled":"true"}`, `{"diagnostics_enabled":1}`, `{"diagnostics_enabled":null}`,
			`{"diagnostics_enabled":"yes"}`, `{"diagnostics_enabled":[true]}`,
			`{"preferred_locale":"fi","diagnostics_enabled":"true"}`, `{}`,
		} {
			if got := r.call(t, c, http.MethodPut, "preferences", body); got.code != http.StatusBadRequest {
				t.Errorf("%s: %d %s", body, got.code, got.raw)
			}
		}
		if len(prefs.diag) != 0 || len(prefs.loc) != 0 {
			t.Fatalf("a refused PUT stored something: %v %v", prefs.diag, prefs.loc)
		}
	})

	t.Run("no session", func(t *testing.T) {
		r, prefs := newPRig(t, "", true)
		if got := r.call(t, nil, http.MethodPut, "preferences", `{"diagnostics_enabled":true}`); got.code != http.StatusUnauthorized {
			t.Fatalf("%d %s", got.code, got.raw)
		}
		if len(prefs.diag) != 0 {
			t.Fatalf("stored without a session: %v", prefs.diag)
		}
	})
}

// CONTROL: the retired operator list grants nothing any more. Under
// "list OR checkbox" unticking would change nothing for a listed address.
func TestRetiredDiagnosticsListGrantsNothing(t *testing.T) {
	r := newRigFront(t, auth.Options{Registrar: registrar{}}, map[string]string{retiredVar: "alice@example.com"}, "")
	c := browser(t)
	signIn(t, c, r, "google", "?redirect=/c/general")
	if code, got := sessionJSON(t, c, r.hub); code != http.StatusOK || got["diagnostics_enabled"] != false {
		t.Fatalf("the retired list still grants: %d %v", code, got)
	}
}

// CONTROL: nothing the browser sends can assert the setting.
func TestDiagnosticsNotSettableFromTheBrowser(t *testing.T) {
	r, _ := newPRig(t, "", true)
	c := browser(t)
	r.signedIn(t, c, "person@example.com")
	_, me := sessionJSON(t, c, r.url)
	hum, _ := me["hum"].(string)
	if hum == "" {
		t.Fatalf("no human on the session — the controls below would prove nothing: %v", me)
	}

	// A cookie the hub itself would accept — right key, valid MAC, unexpired —
	// for a real human who never ticked the box, whose payload carries the
	// claim. The Session struct has no such field, so it is dropped on the way in.
	t.Run("a validly signed cookie that names the claim", func(t *testing.T) {
		ck := auth.MintSessionCookie(r.h, map[string]any{
			"v": 1, "p": "password", "sub": "person@example.com", "email": "person@example.com", "hum": hum,
			"diagnostics_enabled": true,
			"iat":                 time.Now().Unix(), "exp": time.Now().Add(time.Hour).Unix(),
		})
		cc := browser(t)
		cc.Jar.SetCookies(mustParse(t, r.url), []*http.Cookie{ck})
		code, got := sessionJSON(t, cc, r.url)
		if code != http.StatusOK || got["hum"] != hum {
			t.Fatalf("the crafted cookie was not accepted as that human (%d %v) — the control needs it to be", code, got)
		}
		if got["diagnostics_enabled"] != false {
			t.Fatalf("a browser-supplied claim was echoed back: %v", got)
		}
	})

	t.Run("query, header and cookie tricks", func(t *testing.T) {
		for _, q := range []string{"?diagnostics_enabled=true", "?debug=1", "?diagnostics_enabled=1&debug=true"} {
			resp, err := c.Get(r.url + "/api/v1/auth/session" + q)
			if err != nil {
				t.Fatal(err)
			}
			out := map[string]any{}
			json.NewDecoder(resp.Body).Decode(&out) //nolint:errcheck
			resp.Body.Close()
			if out["diagnostics_enabled"] != false {
				t.Fatalf("query %q granted the panel: %v", q, out)
			}
		}
		req, _ := http.NewRequest(http.MethodGet, r.url+"/api/v1/auth/session", nil)
		req.Header.Set("X-Diagnostics-Enabled", "true")
		req.Header.Set("X-Spool-Diagnostics", "true")
		req.AddCookie(&http.Cookie{Name: "diagnostics_enabled", Value: "true"})
		resp, err := c.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		out := map[string]any{}
		json.NewDecoder(resp.Body).Decode(&out) //nolint:errcheck
		resp.Body.Close()
		if out["diagnostics_enabled"] != false {
			t.Fatalf("a header or a second cookie granted the panel: %v", out)
		}
	})

	// A GET, a form post and a text/plain PUT are not a way to set it: the
	// write door is JSON only (the native CSRF posture).
	t.Run("only the JSON PUT writes it", func(t *testing.T) {
		for _, ct := range []string{"application/x-www-form-urlencoded", "text/plain"} {
			req, _ := http.NewRequest(http.MethodPut, r.url+"/api/v1/auth/preferences", strings.NewReader(`{"diagnostics_enabled":true}`))
			req.Header.Set("Content-Type", ct)
			res, err := c.Do(req)
			if err != nil {
				t.Fatal(err)
			}
			res.Body.Close()
			if res.StatusCode == http.StatusOK {
				t.Fatalf("%s wrote the setting", ct)
			}
		}
		if _, got := sessionJSON(t, c, r.url); got["diagnostics_enabled"] != false {
			t.Fatalf("a non-JSON write went through: %v", got)
		}
	})
}
