package invitemail

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/rs/zerolog"

	"github.com/csitea/csi-spl/spool-hub-api/internal/mail"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

const who = "Invitee@Example.com"

type rig struct {
	st   *store.Memory
	rec  *mail.Recorder
	logs *bytes.Buffer
	now  time.Time
	d    Deps
}

func newRig(t *testing.T) *rig {
	t.Helper()
	pub, _, _ := ed25519.GenerateKey(nil)
	r := &rig{st: store.NewMemory(), rec: &mail.Recorder{}, logs: &bytes.Buffer{}, now: time.Date(2026, 9, 19, 16, 0, 0, 0, time.UTC)}
	if err := r.st.CreateTenant(context.Background(), store.Tenant{ID: "t1", RootPubKey: pub}); err != nil {
		t.Fatal(err)
	}
	r.d = Deps{Store: r.st, Sender: r.rec, Delivers: true, Log: zerolog.New(r.logs), AppURL: "https://example.com",
		DefaultLocale: "bg", Limits: store.InviteMailLimits{MinGap: DefaultMinGap, MaxSends: DefaultMaxSends},
		Now: func() time.Time { return r.now }}
	return r
}

func (r *rig) invite(t *testing.T, email string, ttl time.Duration) {
	t.Helper()
	if err := r.st.PutInvite(context.Background(), store.Invite{TenantID: "t1", Email: email, Role: store.RoleDefault,
		InvitedBy: store.AdmittedOperator, ExpiresAt: r.now.Add(ttl)}, r.now); err != nil {
		t.Fatal(err)
	}
}

func TestSendOpenInviteOnceThenRateLimited(t *testing.T) {
	r := newRig(t)
	r.invite(t, who, 7*24*time.Hour)
	res, err := Send(context.Background(), r.d, "t1", who)
	if err != nil || res.Outcome != Sent || !res.Delivered || res.MailCount != 1 {
		t.Fatalf("first: %+v %v", res, err)
	}
	msgs := r.rec.Messages()
	if len(msgs) != 1 {
		t.Fatalf("want 1 mail, got %d", len(msgs))
	}
	m := msgs[0]
	// the hub default locale (bg), unprefixed sign-in URL, lower-cased address
	if m.To != "invitee@example.com" || m.Locale != "bg" || m.Template != mail.TemplateTenantInvite ||
		res.SignInURL != "https://example.com/login?tenant=t1" || !strings.Contains(m.TextBody, res.SignInURL) ||
		!strings.Contains(m.TextBody, "2026-09-26 16:00 UTC") || !strings.HasSuffix(m.MessageID, ".tenant_invite@example.com>") {
		t.Fatalf("message: %+v / %+v", m, res)
	}
	// CONTROL: a resend inside the gap sends nothing.
	r.now = r.now.Add(time.Minute)
	if res, err := Send(context.Background(), r.d, "t1", who); err != nil || res.Outcome != store.InviteMailRateLimited {
		t.Fatalf("resend in gap: %+v %v", res, err)
	}
	r.now = r.now.Add(DefaultMinGap)
	if res, err := Send(context.Background(), r.d, "t1", who); err != nil || res.Outcome != Sent || res.MailCount != 2 {
		t.Fatalf("resend after gap: %+v %v", res, err)
	}
	if n := len(r.rec.Messages()); n != 2 {
		t.Fatalf("want 2 mails, got %d", n)
	}
	// logs: a digest, never the address or the body
	if l := r.logs.String(); strings.Contains(strings.ToLower(l), "invitee@example.com") || strings.Contains(l, "example.com/login") ||
		!strings.Contains(l, mail.Digest(who)) {
		t.Fatalf("logs leak or lack the digest: %s", l)
	}
}

// CONTROLS: accepted and expired invites get no mail; unknown is not_found.
func TestSendSkipsClosedInvites(t *testing.T) {
	r := newRig(t)
	r.invite(t, "gone@example.com", -time.Second)
	r.invite(t, "in@example.com", time.Hour)
	if _, err := r.st.Admit(context.Background(), store.Identity{Provider: "google", Subject: "s1", Email: "in@example.com"}, "t1", store.AdmitPolicy{}, r.now); err != nil {
		t.Fatal(err)
	}
	for email, want := range map[string]string{"gone@example.com": store.InviteMailExpired,
		"in@example.com": store.InviteMailAccepted, "nobody@example.com": store.InviteMailNotFound} {
		if res, err := Send(context.Background(), r.d, "t1", email); err != nil || res.Outcome != want {
			t.Fatalf("%s: %+v %v", email, res, err)
		}
	}
	if n := len(r.rec.Messages()); n != 0 {
		t.Fatalf("closed invites were mailed: %d", n)
	}
}

// A relay refusal is reported and releases the claim (an immediate retry is
// not rate limited by a mail that never left).
func TestSendRelayFailureReleases(t *testing.T) {
	r := newRig(t)
	r.invite(t, who, time.Hour)
	r.rec.Err = errors.New("535 auth failed")
	if res, err := Send(context.Background(), r.d, "t1", who); err == nil || res.Outcome != SendFailed {
		t.Fatalf("relay failure: %+v %v", res, err)
	}
	r.rec.Err = nil
	if res, err := Send(context.Background(), r.d, "t1", who); err != nil || res.Outcome != Sent || res.MailCount != 1 {
		t.Fatalf("retry after release: %+v %v", res, err)
	}
}

func TestSendLocaleAndLogSink(t *testing.T) {
	r := newRig(t)
	r.invite(t, who, time.Hour)
	r.d.Locale, r.d.Delivers = "en", false
	res, err := Send(context.Background(), r.d, "t1", who)
	// 047 W13: a sink that reaches no inbox answers "logged", never "sent"
	if err != nil || res.Delivered || res.Outcome != Logged || res.Locale != "en" || res.SignInURL != "https://example.com/en/login?tenant=t1" {
		t.Fatalf("en / log sink: %+v %v", res, err)
	}
}

func TestSignInURL(t *testing.T) {
	for _, c := range []struct{ app, loc, want string }{
		{"https://spool-hub.example/", "bg", "https://spool-hub.example/login?tenant=t1"},
		{"https://dev.spool-hub.example", "fi", "https://dev.spool-hub.example/fi/login?tenant=t1"},
		{"http://localhost:3000", "bg", "http://localhost:3000/login?tenant=t1"},
	} {
		if got, err := SignInURL(c.app, c.loc, "bg", "t1"); err != nil || got != c.want {
			t.Errorf("%s: %q %v", c.app, got, err)
		}
	}
	// CONTROL: plain http to a real host, a path or a query are refused.
	for _, bad := range []string{"http://spool-hub.example", "https://x.example/app", "https://x.example?a=1", "", "spool-hub.example"} {
		if _, err := SignInURL(bad, "bg", "bg", "t1"); err == nil {
			t.Errorf("accepted %q", bad)
		}
	}
}
