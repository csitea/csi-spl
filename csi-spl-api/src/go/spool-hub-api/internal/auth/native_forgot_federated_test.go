package auth_test

import (
	"context"
	"net/http"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/auth"
	"github.com/csitea/csi-spl/spool-hub-api/internal/mail"
)

// CLE-3451 defect 1. "Forgot password" on an address that has no password but
// DOES sign in with an IdP used to do nothing at all: GetCredential returned
// ErrCredNotFound, no token was minted, no mail was sent, and the handler
// still answered 204. From the person's seat that is a broken site with no
// recovery path - which is what the owner hit on deployed hub 0.1.22.
//
// The fix must not buy that at the cost of FR-005: an address that does not
// exist AT ALL still has to be indistinguishable from one that does.

// fedFake is a FederatedLookup over a fixed table. It records every address it
// was asked about, so a test can prove which branch ran.
type fedFake struct {
	mu     sync.Mutex
	by     map[string][]string
	locale map[string]string
	err    error
	asked  []string
}

func newFedFake(by map[string][]string) *fedFake {
	return &fedFake{by: by, locale: map[string]string{}}
}

func (f *fedFake) FederatedAccount(_ context.Context, email string) ([]string, string, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.asked = append(f.asked, email)
	if f.err != nil {
		return nil, "", f.err
	}
	return f.by[email], f.locale[email], nil
}

func (f *fedFake) asks() []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]string(nil), f.asked...)
}

func fedMails(r *nrig) []mail.Message {
	var out []mail.Message
	for _, m := range r.box.Messages() {
		if m.Template == mail.TemplateFederatedSignIn {
			out = append(out, m)
		}
	}
	return out
}

// The defect itself: a Google-only address gets a real signal - a mail naming
// the provider and the sign-in page - while the wire still says 204.
func TestNativeForgotFederatedMailsTheProvider(t *testing.T) {
	const goog = "google-only@example.com"
	fed := newFedFake(map[string][]string{goog: {"google"}})
	r := newNRigWith(t, nil, nil, true, fed)

	g := r.post(t, nil, "password/forgot", map[string]string{"email": goog})
	if g.code != http.StatusNoContent || g.raw != "" {
		t.Fatalf("wire changed: %d %q", g.code, g.raw)
	}
	got := fedMails(r)
	if len(got) != 1 {
		t.Fatalf("federated mails: %d, want 1", len(got))
	}
	m := got[0]
	if m.To != goog {
		t.Fatalf("mailed %q", m.To)
	}
	if !strings.Contains(m.TextBody, "Google") || !strings.Contains(m.Subject, "Google") {
		t.Fatalf("the mail does not name the provider:\n%s\n%s", m.Subject, m.TextBody)
	}
	if !strings.Contains(m.TextBody, "http://app.example.test/login") {
		t.Fatalf("the mail does not carry the sign-in page:\n%s", m.TextBody)
	}
	// It is not a password reset: no token was minted, so nothing in it can
	// set a password.
	if n := r.mails(mail.TemplatePasswordReset); n != 0 {
		t.Fatalf("reset mails: %d, want 0", n)
	}
	if strings.Contains(m.TextBody, "token=") {
		t.Fatalf("the mail carries a token:\n%s", m.TextBody)
	}
}

// CONTROL, and the half that matters: an address that does not exist behaves
// EXACTLY as it did before - same status, same bytes, no mail, and no log
// event that tells it apart. FR-005 is not weakened for a stranger.
func TestNativeForgotUnknownAddressUnchanged(t *testing.T) {
	const goog, ghost = "known@example.com", "nobody@example.com"
	fed := newFedFake(map[string][]string{goog: {"google"}})
	r := newNRigWith(t, map[string]string{"SPOOL_HUB_AUTH_NATIVE_FORM_PER_IP": "100"}, nil, true, fed)

	a := r.post(t, nil, "password/forgot", map[string]string{"email": goog})
	b := r.post(t, nil, "password/forgot", map[string]string{"email": ghost})
	if a.code != b.code || a.raw != b.raw {
		t.Fatalf("the two answers differ: %d %q vs %d %q", a.code, a.raw, b.code, b.raw)
	}
	if a.code != http.StatusNoContent {
		t.Fatalf("status %d", a.code)
	}
	// Exactly one mail in total, and it went to the account that exists.
	if all := r.box.Messages(); len(all) != 1 || all[0].To != goog {
		t.Fatalf("mails: %+v", all)
	}
	// The lookup WAS asked about the stranger (that is how it learns there is
	// nothing); what must not happen is a mail or a different answer.
	if asks := fed.asks(); len(asks) != 2 || asks[1] != ghost {
		t.Fatalf("lookup calls: %v", asks)
	}
}

// An address that HAS a password is untouched by defect 1's branch: it still
// gets the reset mail and never the federated note.
func TestNativeForgotWithPasswordStillResets(t *testing.T) {
	const both = "both@example.com"
	fed := newFedFake(map[string][]string{both: {"google"}})
	r := newNRigWith(t, nil, nil, true, fed)
	r.registerVerified(t, both, pwA)
	forgot(t, r, both)
	if n := r.mails(mail.TemplatePasswordReset); n != 1 {
		t.Fatalf("reset mails: %d, want 1", n)
	}
	if got := fedMails(r); len(got) != 0 {
		t.Fatalf("federated mails: %d, want 0", len(got))
	}
	if asks := fed.asks(); len(asks) != 0 {
		t.Fatalf("the lookup ran for an address that has a credential: %v", asks)
	}
}

// CONTROL (the same shape as the credential floor, FR-006a): an always-204
// route must not be a mail amplifier. One note per address per rate window.
func TestNativeForgotFederatedMailFloor(t *testing.T) {
	const goog = "floor-fed@example.com"
	fed := newFedFake(map[string][]string{goog: {"google"}})
	r := newNRigWith(t, map[string]string{"SPOOL_HUB_AUTH_NATIVE_FORM_PER_IP": "100"}, nil, true, fed)
	for i := 0; i < 5; i++ {
		if g := r.post(t, nil, "password/forgot", map[string]string{"email": goog}); g.code != http.StatusNoContent {
			t.Fatalf("attempt %d: %d", i, g.code)
		}
	}
	if n := len(fedMails(r)); n != 1 {
		t.Fatalf("inside one window: %d mails, want 1", n)
	}
	r.advance(16 * time.Minute) // past SPOOL_HUB_AUTH_NATIVE_RATE_WINDOW
	forgot(t, r, goog)
	if n := len(fedMails(r)); n != 2 {
		t.Fatalf("after the window: %d mails, want 2", n)
	}
}

// CONTROL: with no lookup wired (Options.Federated nil) the route is byte for
// byte what it was before CLE-3451 - no mail, no panic.
func TestNativeForgotWithoutFederatedLookup(t *testing.T) {
	r := newNRig(t, nil, nil, true)
	if g := r.post(t, nil, "password/forgot", map[string]string{"email": "idp-only@example.com"}); g.code != http.StatusNoContent || g.raw != "" {
		t.Fatalf("%d %q", g.code, g.raw)
	}
	if n := len(r.box.Messages()); n != 0 {
		t.Fatalf("mails: %d, want 0", n)
	}
}

// A lookup that is down never changes the answer: 204, no mail.
func TestNativeForgotFederatedLookupError(t *testing.T) {
	fed := newFedFake(nil)
	fed.err = context.DeadlineExceeded
	r := newNRigWith(t, nil, nil, true, fed)
	if g := r.post(t, nil, "password/forgot", map[string]string{"email": "down@example.com"}); g.code != http.StatusNoContent || g.raw != "" {
		t.Fatalf("%d %q", g.code, g.raw)
	}
	if n := len(r.box.Messages()); n != 0 {
		t.Fatalf("mails: %d, want 0", n)
	}
}

// The note is written in the human's picked locale when the lookup knows one,
// and in the request's locale otherwise.
func TestNativeForgotFederatedLocale(t *testing.T) {
	const fin, other = "fi-person@example.com", "no-pref@example.com"
	fed := newFedFake(map[string][]string{fin: {"google"}, other: {"microsoft"}})
	fed.locale[fin] = "fi"
	r := newNRigWith(t, map[string]string{"SPOOL_HUB_AUTH_NATIVE_FORM_PER_IP": "100"}, nil, true, fed)

	r.call(t, nil, http.MethodPost, "password/forgot", `{"email":"`+fin+`"}`, "X-Locale", "en")
	r.call(t, nil, http.MethodPost, "password/forgot", `{"email":"`+other+`"}`, "X-Locale", "lt")
	got := fedMails(r)
	if len(got) != 2 {
		t.Fatalf("federated mails: %d", len(got))
	}
	if got[0].Locale != "fi" {
		t.Fatalf("picked locale ignored: %q", got[0].Locale)
	}
	if got[1].Locale != "lt" {
		t.Fatalf("request locale ignored: %q", got[1].Locale)
	}
}

var _ auth.FederatedLookup = (*fedFake)(nil)
