package auth_test

import (
	"context"
	"errors"
	"net/http"
	"sync/atomic"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/auth"
)

// oneRead is fakePrefs with the one-read form (SPL-1100). It counts the reads
// that reach it: one HumanSettings call, or one call per single reader.
type oneRead struct {
	*fakePrefs
	whole, single atomic.Int64
	fail          error // non-nil: HumanSettings answers it
}

func (o *oneRead) HumanSettings(ctx context.Context, hum string) (auth.HumanSettings, error) {
	o.whole.Add(1)
	if o.fail != nil {
		return auth.HumanSettings{}, o.fail
	}
	var v auth.HumanSettings
	var err error
	if v.Locale, err = o.fakePrefs.PreferredLocale(ctx, hum); err != nil {
		return v, err
	}
	v.Theme, _ = o.fakePrefs.PreferredTheme(ctx, hum)
	v.SubmitKey, _ = o.fakePrefs.SubmitKey(ctx, hum)
	v.RailOrder, _ = o.fakePrefs.RailOrder(ctx, hum)
	v.Diagnostics, _ = o.fakePrefs.DiagnosticsEnabled(ctx, hum)
	v.DisplayName, _ = o.fakePrefs.DisplayName(ctx, hum)
	v.IssueColumns, _ = o.fakePrefs.IssueColumns(ctx, hum)
	v.ViewPrefs = map[string]string{}
	for k := range auth.ViewPrefs {
		v.ViewPrefs[k], _ = o.fakePrefs.ViewPref(ctx, hum, k)
	}
	return v, nil
}

func (o *oneRead) PreferredLocale(ctx context.Context, hum string) (string, error) {
	o.single.Add(1)
	return o.fakePrefs.PreferredLocale(ctx, hum)
}

func (o *oneRead) PreferredTheme(ctx context.Context, hum string) (string, error) {
	o.single.Add(1)
	return o.fakePrefs.PreferredTheme(ctx, hum)
}

func (o *oneRead) SubmitKey(ctx context.Context, hum string) (string, error) {
	o.single.Add(1)
	return o.fakePrefs.SubmitKey(ctx, hum)
}

func (o *oneRead) RailOrder(ctx context.Context, hum string) ([]string, error) {
	o.single.Add(1)
	return o.fakePrefs.RailOrder(ctx, hum)
}

func (o *oneRead) ViewPref(ctx context.Context, hum, key string) (string, error) {
	o.single.Add(1)
	return o.fakePrefs.ViewPref(ctx, hum, key)
}

func (o *oneRead) IssueColumns(ctx context.Context, hum string) (map[string]int, error) {
	o.single.Add(1)
	return o.fakePrefs.IssueColumns(ctx, hum)
}

func (o *oneRead) DiagnosticsEnabled(ctx context.Context, hum string) (bool, error) {
	o.single.Add(1)
	return o.fakePrefs.DiagnosticsEnabled(ctx, hum)
}

func (o *oneRead) DisplayName(ctx context.Context, hum string) (string, error) {
	o.single.Add(1)
	return o.fakePrefs.DisplayName(ctx, hum)
}

// SPL-1100: GET /session and the POST /login answer read the settings ONCE
// when the store can, and answer byte for byte what the per-setting reads
// answer (CONTROL: the same rig without the one-read form). A failed read
// falls back field by field exactly as a failed single read did.
func TestSessionReadsSettingsOnce(t *testing.T) {
	var o *oneRead
	r, _ := newPRigWrapped(t, "", true, func(p *fakePrefs) auth.Preferences { o = &oneRead{fakePrefs: p}; return o })
	ctl, _ := newPRig(t, "", true)
	c, cc := browser(t), browser(t)
	r.signedIn(t, c, "person@example.com")
	ctl.signedIn(t, cc, "person@example.com")
	const put = `{"preferred_locale":"fi","preferred_theme":"light-red","submit_key":"ctrl-enter","display_name":"FirstName LastName",` +
		`"diagnostics_enabled":true,"rail_order":["archive","events","flow","topics","issues","channels","dm"],` +
		`"message_order":"newest-last","composer_position":"bottom","issues_view":"status","close_buttons":"windows","link_previews":"off","issues_columns":{"key":96}}`
	for _, rig := range []struct {
		r *nrig
		c *http.Client
	}{{r, c}, {ctl, cc}} {
		if got := rig.r.call(t, rig.c, http.MethodPut, "preferences", put); got.code != http.StatusOK {
			t.Fatalf("put: %d %s", got.code, got.raw)
		}
	}

	o.whole.Store(0)
	o.single.Store(0)
	got, want := r.call(t, c, http.MethodGet, "session", ""), ctl.call(t, cc, http.MethodGet, "session", "")
	if got.code != http.StatusOK || got.raw != want.raw {
		t.Fatalf("session:\n one read %d %s\n control  %d %s", got.code, got.raw, want.code, want.raw)
	}
	if got.body["preferred_theme"] != "light-red" || got.body["issues_view"] != "status" || got.body["diagnostics_enabled"] != true {
		t.Fatalf("settings missing from the answer: %s", got.raw)
	}
	if o.whole.Load() != 1 || o.single.Load() != 0 {
		t.Fatalf("GET /session: %d one-read calls, %d single reads; want 1 and 0", o.whole.Load(), o.single.Load())
	}

	o.whole.Store(0)
	login := func(rig *nrig, c *http.Client) resp {
		return rig.post(t, c, "login", map[string]string{"email": "person@example.com", "password": pwA, "tenant": "acme"})
	}
	gotL, wantL := login(r, browser(t)), login(ctl, browser(t))
	delete(gotL.body, "exp")
	delete(wantL.body, "exp")
	if gotL.code != http.StatusOK || jsonBody(gotL.body) != jsonBody(wantL.body) {
		t.Fatalf("login answer:\n one read %d %s\n control  %d %s", gotL.code, gotL.raw, wantL.code, wantL.raw)
	}
	if o.whole.Load() != 1 || o.single.Load() != 0 {
		t.Fatalf("POST /login: %d one-read calls, %d single reads; want 1 and 0", o.whole.Load(), o.single.Load())
	}

	// A failed read never fails the session: every setting falls back.
	o.fail = errors.New("db down")
	got = r.call(t, c, http.MethodGet, "session", "")
	if got.code != http.StatusOK || got.body["preferred_locale"] != nil || got.body["preferred_theme"] != nil ||
		got.body["diagnostics_enabled"] != false || got.body["rail_order"] != nil || got.body["issues_columns"] != nil || got.body["name"] == "FirstName LastName" {
		t.Fatalf("failed read: %d %s", got.code, got.raw)
	}
}
