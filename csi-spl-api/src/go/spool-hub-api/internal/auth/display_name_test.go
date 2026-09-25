package auth_test

import (
	"net/http"
	"strings"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/auth"
)

// CLE-34968: PUT preferences display_name stores the signed-in human's shown
// name, and GET session answers it as `name` from then on - without a new
// sign-in, since the cookie still carries the old name.
func TestDisplayNameSetReflectsInSession(t *testing.T) {
	r, prefs := newPRig(t, "", true)
	c := browser(t)
	r.registerVerified(t, "person@example.com", pwA)
	if got := r.post(t, c, "login", map[string]string{"email": "person@example.com", "password": pwA, "tenant": "acme"}); got.code != http.StatusOK {
		t.Fatalf("login: %d %s", got.code, got.raw)
	}
	other := browser(t)
	r.signedIn(t, other, "other@example.com")

	// CONTROL: before any set the session answers the cookie's name.
	before := r.call(t, c, http.MethodGet, "session", "")
	if before.code != http.StatusOK || before.body["name"] == "Chosen Name" {
		t.Fatalf("session before: %d %s", before.code, before.raw)
	}
	got := r.call(t, c, http.MethodPut, "preferences", `{"display_name":"  Chosen Name  "}`)
	if got.code != http.StatusOK || got.body["display_name"] != "Chosen Name" || len(got.body) != 1 {
		t.Fatalf("put: %d %s", got.code, got.raw)
	}
	if got = r.call(t, c, http.MethodGet, "session", ""); got.body["name"] != "Chosen Name" {
		t.Fatalf("session after: %s", got.raw)
	}
	// The other key is untouched by a name-only PUT.
	if got.body["preferred_locale"] != nil || got.body["diagnostics_enabled"] != false {
		t.Fatalf("a name PUT changed another setting: %s", got.raw)
	}
	// CONTROL: another human's session keeps its own name.
	if got = r.call(t, other, http.MethodGet, "session", ""); got.body["name"] == "Chosen Name" {
		t.Fatalf("name leaked to another human: %s", got.raw)
	}
	// A new native sign-in answers the stored name in its claims too.
	if got = r.post(t, c, "login", map[string]string{"email": "person@example.com", "password": pwA, "tenant": "acme"}); got.body["name"] != "Chosen Name" {
		t.Fatalf("login claims: %d %s", got.code, got.raw)
	}
	if n := len(prefs.name); n != 1 {
		t.Fatalf("stored names: %d", n)
	}
}

func TestDisplayNameRefusals(t *testing.T) {
	r, prefs := newPRig(t, "", true)
	c := browser(t)
	r.signedIn(t, c, "person@example.com")
	for _, body := range []string{
		`{"display_name":""}`,
		`{"display_name":"   "}`,
		`{"display_name":null}`,
		`{"display_name":42}`,
		`{"display_name":true}`,
		`{"display_name":["a"]}`,
		`{"display_name":"a\nb"}`,
		`{"display_name":"a\u0000b"}`,
		`{"display_name":"a\u0007b"}`,
		`{"display_name":"a\u007fb"}`,
		`{"display_name":"a\u0085b"}`,
		`{"display_name":"a b"}`,
		`{"display_name":"` + strings.Repeat("a", auth.MaxDisplayNameLen+1) + `"}`,
	} {
		got := r.call(t, c, http.MethodPut, "preferences", body)
		if got.code != http.StatusBadRequest || got.body["error"] != auth.ErrCodeInvalidDisplayName {
			t.Fatalf("%s: %d %s", body, got.code, got.raw)
		}
	}
	if len(prefs.name) != 0 {
		t.Fatalf("a refused name was stored: %v", prefs.name)
	}
	// A refused name refuses the whole body: the valid key beside it is not stored.
	if got := r.call(t, c, http.MethodPut, "preferences", `{"preferred_locale":"fi","display_name":""}`); got.code != http.StatusBadRequest {
		t.Fatalf("mixed: %d %s", got.code, got.raw)
	}
	if got := r.call(t, c, http.MethodGet, "session", ""); got.body["preferred_locale"] != nil {
		t.Fatalf("mixed body stored the locale: %s", got.raw)
	}
	// CONTROL: the limits admit what they should - 200 characters (not bytes)
	// of multi-byte text, and an emoji with a zero-width joiner.
	for _, name := range []string{strings.Repeat("ä", auth.MaxDisplayNameLen), "Ана 👩‍💻"} {
		if got := r.call(t, c, http.MethodPut, "preferences", jsonBody(map[string]string{"display_name": name})); got.code != http.StatusOK || got.body["display_name"] != name {
			t.Fatalf("%q: %d %s", name, got.code, got.raw)
		}
	}
	// No session: 401, nothing stored.
	if got := r.call(t, nil, http.MethodPut, "preferences", `{"display_name":"x"}`); got.code != http.StatusUnauthorized {
		t.Fatalf("anonymous: %d %s", got.code, got.raw)
	}
}

func TestValidDisplayName(t *testing.T) {
	for in, want := range map[string]string{" a ": "a", "\tName\t": "Name", "O'Neil": "O'Neil"} {
		if got, ok := auth.ValidDisplayName(in); !ok || got != want {
			t.Fatalf("%q: %q %v", in, got, ok)
		}
	}
	for _, in := range []string{"", " ", "a\rb", "\xff", "a\u009fb", "\u202enimda", "a\u2066b", "a\u200fb", "a\u061cb", "a b"} {
		if got, ok := auth.ValidDisplayName(in); ok {
			t.Fatalf("%q admitted as %q", in, got)
		}
	}
}

// CLE-34986: the seed rule for an IdP or register-form name drops what
// ValidDisplayName refuses and cuts at 200 characters, never mid-rune.
func TestCleanDisplayName(t *testing.T) {
	long := strings.Repeat("\u00e4", 250) // 2 bytes each: a byte cut at 200 is 100 runes
	for in, want := range map[string]string{
		" Ann Lee ":          "Ann Lee",
		"\u202enimda":        "nimda",
		"a\u2066b\u2069c":    "abc",
		"a\nb\x00c\u2028d":   "abcd",
		"\xffok":             "ok",
		"\u200f\u202e":       "",
		long:                 strings.Repeat("\u00e4", 200),
		"\u0634\u0627\u0647": "\u0634\u0627\u0647", // RTL letters are names, not controls
	} {
		got := auth.CleanDisplayName(in)
		if got != want {
			t.Errorf("CleanDisplayName(%q) = %q, want %q", in, got, want)
		}
		if got != "" {
			if v, ok := auth.ValidDisplayName(got); !ok || v != got {
				t.Errorf("CleanDisplayName(%q) = %q, which ValidDisplayName refuses", in, got)
			}
		}
	}
}
