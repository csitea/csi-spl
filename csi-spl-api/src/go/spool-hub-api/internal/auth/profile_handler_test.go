package auth_test

import (
	"context"
	"errors"
	"net/http"
	"sync"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/auth"
)

// profilePrefs is fakePrefs plus auth.ProfileStore (SPL-5707).
type profilePrefs struct {
	*fakePrefs
	mu   sync.Mutex
	prof map[string]auth.Profile
	fail error // non-nil: every profile call answers it
}

func (p *profilePrefs) Profile(_ context.Context, hum string) (auth.Profile, error) {
	if p.fail != nil {
		return auth.Profile{}, p.fail
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.prof[hum], nil
}

func (p *profilePrefs) SetProfileName(_ context.Context, hum, first, last string) error {
	if p.fail != nil {
		return p.fail
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	v := p.prof[hum]
	v.FirstName, v.LastName = first, last
	p.prof[hum] = v
	return nil
}

func (p *profilePrefs) SetPhone(_ context.Context, hum, phone string) error {
	if p.fail != nil {
		return p.fail
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	v := p.prof[hum]
	v.Phone = phone
	p.prof[hum] = v
	return nil
}

func newProfileRig(t *testing.T) (*nrig, *profilePrefs) {
	t.Helper()
	var pp *profilePrefs
	r, _ := newPRigWrapped(t, "", true, func(f *fakePrefs) auth.Preferences {
		pp = &profilePrefs{fakePrefs: f, prof: map[string]auth.Profile{}}
		return pp
	})
	return r, pp
}

// SPL-5707: PUT preferences saves first_name + last_name together and the
// phone in its international form; GET profile answers the person's own.
func TestPreferencesProfile(t *testing.T) {
	r, pp := newProfileRig(t)
	c := browser(t)
	r.signedIn(t, c, "person@example.com")

	got := r.call(t, c, http.MethodGet, "profile", "")
	if got.code != http.StatusOK || got.body["first_name"] != nil || got.body["phone"] != nil || got.hdr.Get("Cache-Control") != "no-store" {
		t.Fatalf("profile before: %d %s", got.code, got.raw)
	}
	got = r.call(t, c, http.MethodPut, "preferences", `{"first_name":" FirstName ","last_name":"LastName","phone":"+358 40 123 4567"}`)
	if got.code != http.StatusOK || got.body["first_name"] != "FirstName" || got.body["last_name"] != "LastName" ||
		got.body["display_name"] != "FirstName LastName" || got.body["phone"] != "+358401234567" {
		t.Fatalf("put: %d %s", got.code, got.raw)
	}
	got = r.call(t, c, http.MethodGet, "profile", "")
	if got.body["first_name"] != "FirstName" || got.body["last_name"] != "LastName" || got.body["phone"] != "+358401234567" {
		t.Fatalf("profile after: %s", got.raw)
	}
	// last_name null or "" and phone null or "" clear them
	for _, body := range []string{`{"first_name":"Solo","last_name":null,"phone":null}`, `{"first_name":"Solo","last_name":"","phone":""}`} {
		got = r.call(t, c, http.MethodPut, "preferences", body)
		if got.code != http.StatusOK || got.body["last_name"] != nil || got.body["display_name"] != "Solo" || got.body["phone"] != nil {
			t.Fatalf("%s: %d %s", body, got.code, got.raw)
		}
	}
	if got = r.call(t, c, http.MethodGet, "profile", ""); got.body["first_name"] != "Solo" || got.body["last_name"] != nil || got.body["phone"] != nil {
		t.Fatalf("profile after clear: %s", got.raw)
	}

	before := map[string]auth.Profile{}
	for k, v := range pp.prof {
		before[k] = v
	}
	for body, code := range map[string]string{
		`{"first_name":"A"}`:                             auth.ErrCodeInvalidName,
		`{"last_name":"B"}`:                              auth.ErrCodeInvalidName,
		`{"first_name":null,"last_name":"B"}`:            auth.ErrCodeInvalidName,
		`{"first_name":"","last_name":"B"}`:              auth.ErrCodeInvalidName,
		`{"first_name":7,"last_name":"B"}`:               auth.ErrCodeInvalidName,
		`{"first_name":"A","last_name":7}`:               auth.ErrCodeInvalidName,
		`{"first_name":"A\nB","last_name":"C"}`:          auth.ErrCodeInvalidName,
		`{"phone":"040 123 4567"}`:                       auth.ErrCodeInvalidPhone,
		`{"phone":7}`:                                    auth.ErrCodeInvalidPhone,
		`{"first_name":"A","last_name":"B","phone":"x"}`: auth.ErrCodeInvalidPhone,
	} {
		if got := r.call(t, c, http.MethodPut, "preferences", body); got.code != http.StatusBadRequest || got.body["error"] != code {
			t.Errorf("%s: %d %s", body, got.code, got.raw)
		}
	}
	for k, v := range pp.prof {
		if before[k] != v {
			t.Fatalf("a refused PUT stored a profile: %v", pp.prof)
		}
	}

	// a store error is answered, never a 200
	pp.fail = errors.New("db down")
	if got := r.call(t, c, http.MethodPut, "preferences", `{"phone":"+3584000000"}`); got.code < 500 {
		t.Errorf("phone on a failing store: %d %s", got.code, got.raw)
	}
	if got := r.call(t, c, http.MethodPut, "preferences", `{"first_name":"A","last_name":"B"}`); got.code < 500 {
		t.Errorf("name on a failing store: %d %s", got.code, got.raw)
	}
	if got := r.call(t, c, http.MethodGet, "profile", ""); got.code < 500 {
		t.Errorf("profile on a failing store: %d %s", got.code, got.raw)
	}

	if got := r.call(t, nil, http.MethodGet, "profile", ""); got.code != http.StatusUnauthorized {
		t.Fatalf("no session: %d %s", got.code, got.raw)
	}
}

// A store that keeps no profile: the PUT is 503, the GET 409 no_human.
func TestPreferencesProfileWithoutProfileStore(t *testing.T) {
	r, _ := newPRig(t, "", true)
	c := browser(t)
	r.signedIn(t, c, "person@example.com")
	if got := r.call(t, c, http.MethodPut, "preferences", `{"phone":"+3584000000"}`); got.code != http.StatusServiceUnavailable {
		t.Fatalf("put: %d %s", got.code, got.raw)
	}
	if got := r.call(t, c, http.MethodGet, "profile", ""); got.code != http.StatusConflict || got.body["error"] != "no_human" {
		t.Fatalf("get: %d %s", got.code, got.raw)
	}
}
