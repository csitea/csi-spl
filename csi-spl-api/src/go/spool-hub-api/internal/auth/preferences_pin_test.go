package auth_test

import (
	"net/http"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/auth"
)

// SPL-1042 pins, written before putPreferences was split into parse + store:
// the WHOLE body is validated before anything is written (a valid first key
// is not stored when a later key is refused), refusals come in a fixed order,
// and a mixed valid body echoes exactly the stored keys (null when cleared).
func TestPreferencesPinnedContract(t *testing.T) {
	r, prefs := newPRig(t, "", true)
	c := browser(t)
	r.signedIn(t, c, "person@example.com")
	for body, wantErr := range map[string]string{
		`{"preferred_locale":"fi","rail_order":["nope"]}`:      "unsupported_rail_order",
		`{"preferred_locale":"fi","submit_key":"space"}`:       "unsupported_submit_key",
		`{"diagnostics_enabled":true,"preferred_theme":"x"}`:   "unsupported_theme",
		`{"preferred_locale":"de","preferred_theme":"x"}`:      "unsupported_locale",
		`{"preferred_locale":"de","message_order":"sideways"}`: "unsupported_message_order",
		`{"diagnostics_enabled":"true"}`:                       "bad_request",
		`{"display_name":"a\nb","preferred_locale":"fi"}`:      auth.ErrCodeInvalidDisplayName,
	} {
		got := r.call(t, c, http.MethodPut, "preferences", body)
		if got.code != http.StatusBadRequest || got.body["error"] != wantErr {
			t.Errorf("%s: %d %s, want 400 %s", body, got.code, got.raw, wantErr)
		}
	}
	prefs.mu.Lock()
	stored := len(prefs.loc) + len(prefs.diag) + len(prefs.name) + len(prefs.theme) + len(prefs.key) + len(prefs.rail) + len(prefs.view)
	prefs.mu.Unlock()
	if stored != 0 {
		t.Fatalf("a refused PUT stored %d setting(s)", stored)
	}
	got := r.call(t, c, http.MethodPut, "preferences",
		`{"preferred_locale":"fi","diagnostics_enabled":false,"preferred_theme":null,"submit_key":null,"message_order":null}`)
	if got.code != http.StatusOK || len(got.body) != 5 || got.body["preferred_locale"] != "fi" ||
		got.body["diagnostics_enabled"] != false || got.body["preferred_theme"] != nil ||
		got.body["submit_key"] != nil || got.body["message_order"] != nil {
		t.Fatalf("mixed put: %d %s", got.code, got.raw)
	}
	for _, k := range []string{"preferred_theme", "submit_key", "message_order"} {
		if _, ok := got.body[k]; !ok {
			t.Errorf("a cleared %s is not echoed as null: %s", k, got.raw)
		}
	}
}
