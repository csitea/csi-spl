package auth_test

import (
	"net/http"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/auth"
	"github.com/csitea/csi-spl/spool-hub-api/internal/mail"
)

// SPL-6182 defect 4, as prd logged it on 2026-11-21: the person's
// credential was unverified and its October link long expired. Each sign-in
// with the RIGHT password answered 403 email_unverified and mailed nothing,
// so the only way through was a resend control the person never found. The
// right-password 403 must mail a fresh link, and the link must sign in.
func TestNativeUnverifiedLoginMailsAFreshLink(t *testing.T) {
	r := newNRig(t, nil, nil, true)
	if got := r.post(t, nil, "register", map[string]string{"email": "late@example.com", "password": pwA}); got.code != http.StatusAccepted {
		t.Fatalf("register: %d %s", got.code, got.raw)
	}
	r.advance(45 * 24 * 60 * 60 * 1e9) // the first link is long expired
	before := r.mails(mail.TemplateEmailVerification)
	got := r.post(t, nil, "login", map[string]string{"email": "late@example.com", "password": pwA})
	if got.code != http.StatusForbidden || got.body["error"] != auth.ErrTokEmailUnverified {
		t.Fatalf("login: %d %s", got.code, got.raw)
	}
	if r.mails(mail.TemplateEmailVerification) != before+1 {
		t.Fatalf("defect 4: a right-password login of an unverified credential mailed no fresh link (%d mails)", r.mails(mail.TemplateEmailVerification))
	}
	c := browser(t)
	v := r.post(t, c, "email/verify", map[string]string{"token": r.lastToken(t, mail.TemplateEmailVerification), "password": pwA})
	if v.code != http.StatusOK {
		t.Fatalf("defect 4: the verify link did not sign the person in: %d %s", v.code, v.raw)
	}
	if code, s := sessionAt(t, c, r.url); code != http.StatusOK || s.Subject != "late@example.com" {
		t.Fatalf("session after verify: %d %+v", code, s)
	}
}

// SPL-6182 defect 4, second half: the right password on an unverified
// credential spent the per-email ceiling, so ten honest tries locked the
// person out. Only a WRONG password may count.
func TestNativeRightPasswordNeverLocksOut(t *testing.T) {
	r := newNRig(t, nil, nil, true)
	r.post(t, nil, "register", map[string]string{"email": "late@example.com", "password": pwA})
	for i := 0; i < 12; i++ {
		got := r.post(t, nil, "login", map[string]string{"email": "late@example.com", "password": pwA})
		if got.code == http.StatusTooManyRequests {
			t.Fatalf("defect 4: try %d with the right password answered 429", i+1)
		}
	}
}
