package mail

import (
	"regexp"
	"strings"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/i18n"
)

var inviteData = InviteData{TenantID: "t1", Role: "member", Email: "invitee@example.com",
	SignInURL: "https://example.com/login?tenant=t1", ExpiresAt: time.Date(2026, 9, 26, 16, 22, 44, 0, time.UTC)}

// 010 FR-016 / T061: every locale renders, in its own words, the tenant, the
// address, the sign-in URL and the UTC expiry; the role is worded, never the
// raw id.
func TestTenantInviteEveryLocale(t *testing.T) {
	for _, loc := range i18n.Supported {
		for _, role := range []string{"owner", "member"} {
			d := inviteData
			d.Role = role
			m, err := TenantInvite("invitee@example.com", loc, d)
			if err != nil || m.Locale != loc || m.Template != TemplateTenantInvite {
				t.Fatalf("%s: %+v %v", loc, m, err)
			}
			for _, want := range []string{"t1", "invitee@example.com", "https://example.com/login?tenant=t1", "2026-09-26 16:22 UTC"} {
				if !strings.Contains(m.TextBody, want) {
					t.Errorf("%s/%s body lacks %q", loc, role, want)
				}
			}
			if !strings.Contains(m.Subject, "t1") || strings.Contains(m.TextBody, "{{") {
				t.Errorf("%s/%s: subject %q / unrendered action", loc, role, m.Subject)
			}
			if strings.Contains(m.TextBody, " "+role+".") && loc != "en" {
				t.Errorf("%s/%s: raw role id in the body", loc, role)
			}
		}
		o, _ := TenantInvite("x@example.com", loc, InviteData{TenantID: "t1", Role: "owner", ExpiresAt: inviteData.ExpiresAt})
		m, _ := TenantInvite("x@example.com", loc, InviteData{TenantID: "t1", Role: "member", ExpiresAt: inviteData.ExpiresAt})
		if o.TextBody == m.TextBody {
			t.Errorf("%s: owner and member read the same", loc)
		}
	}
}

// Spec 044 FR-OS-003 (self-hosted, fully parameterised): the invitation names
// the hub by the host of the sign-in URL it was given - the operator's own
// domain - in subject and body, in every locale. Every upper-case host the
// mail names is that one, so no hosted domain is baked into a template.
func TestTenantInviteNamesTheOperatorsHost(t *testing.T) {
	hostish := regexp.MustCompile(`\b[A-Z0-9-]+(?:\.[A-Z0-9-]+)*\.[A-Z]{2,}\b`)
	named := func(m Message) []string { return hostish.FindAllString(m.Subject+"\n"+m.TextBody, -1) }
	for _, loc := range i18n.Supported {
		m, err := TenantInvite("invitee@example.com", loc, inviteData)
		if err != nil {
			t.Fatal(err)
		}
		if !strings.Contains(m.Subject, "EXAMPLE.COM") || !strings.Contains(m.TextBody, "EXAMPLE.COM") {
			t.Errorf("%s: subject %q / body do not name the sign-in host", loc, m.Subject)
		}
		for _, h := range named(m) {
			if h != "EXAMPLE.COM" {
				t.Errorf("%s: names a host that is not the sign-in host: %q", loc, h)
			}
		}
	}
	// CONTROLS: another sign-in host changes the name, so it is not a
	// literal; and a baked-in host would be caught by the scan above
	d := inviteData
	d.SignInURL = "https://chat.example.org/login?tenant=t1"
	if m, _ := TenantInvite("invitee@example.com", "en", d); !strings.Contains(m.Subject, "CHAT.EXAMPLE.ORG") {
		t.Fatalf("control: subject %q ignores the sign-in host", m.Subject)
	}
	if got := named(Message{Subject: "Invitation on HOSTED.EXAMPLE"}); len(got) != 1 {
		t.Fatalf("control: the host scan missed a baked host: %v", got)
	}
}

// CONTROL: the invitation carries no secret. The only URL is the sign-in URL
// the caller passed (no query value beyond the tenant), and no token-shaped
// run (>= 20 base64url/hex chars) appears anywhere in subject or body.
func TestTenantInviteCarriesNoSecret(t *testing.T) {
	tokenish := regexp.MustCompile(`[A-Za-z0-9_\-]{20,}`)
	urls := regexp.MustCompile(`https?://\S+`)
	for _, loc := range i18n.Supported {
		m, err := TenantInvite("invitee@example.com", loc, inviteData)
		if err != nil {
			t.Fatal(err)
		}
		all := m.Subject + "\n" + m.TextBody
		if got := tokenish.FindString(all); got != "" {
			t.Errorf("%s: token-shaped run %q", loc, got)
		}
		for _, u := range urls.FindAllString(all, -1) {
			if u != inviteData.SignInURL {
				t.Errorf("%s: unexpected URL %q", loc, u)
			}
		}
	}
	// the control fires: a body that did carry a token is caught
	if tokenish.FindString("open https://x/claim?t=Zm9vYmFyYmF6cXV4cXV1eGZvbw") == "" {
		t.Fatal("control: tokenish missed a token")
	}
}

func TestMessageIDHeader(t *testing.T) {
	raw := string(buildRFC822("a@example.com", Message{To: "b@example.com", Subject: "s", TextBody: "x", MessageID: "<abc.tenant_invite@example.com>"}))
	if !strings.Contains(raw, "\r\nMessage-ID: <abc.tenant_invite@example.com>\r\n") {
		t.Fatalf("no Message-ID: %q", raw)
	}
	if raw := string(buildRFC822("a@example.com", Message{To: "b@example.com", TextBody: "x"})); strings.Contains(raw, "Message-ID") {
		t.Fatalf("Message-ID without one set: %q", raw)
	}
	if raw := string(buildRFC822("a@example.com", Message{To: "b@example.com", TextBody: "x", MessageID: "<a>\r\nBcc: c@example.com"})); strings.Contains(raw, "Bcc") {
		t.Fatalf("header injection: %q", raw)
	}
}
