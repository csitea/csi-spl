package mail

import (
	"strings"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/i18n"
)

// Spec 159 section 3: the vendor key notice names the workspace, the kind,
// the change, last4, who and when, in every locale; the three changes read
// differently; it has no link and never more of the key than last4.
func TestVendorKeyChangedEveryLocale(t *testing.T) {
	at := time.Date(2026, 10, 27, 9, 5, 0, 0, time.FixedZone("x", 3*3600))
	for _, loc := range i18n.Supported {
		bodies := map[string]string{}
		for _, action := range []string{"set", "replace", "remove"} {
			m, err := VendorKeyChanged("admin@example.com", loc, VendorKeyNotice{TenantID: "t1", Kind: "claude",
				Action: action, Last4: "0000", ChangedBy: "FirstName LastName", ChangedAt: at})
			if err != nil || m.Locale != loc || m.Template != TemplateVendorKeyChanged {
				t.Fatalf("%s/%s: %+v %v", loc, action, m, err)
			}
			for _, want := range []string{"t1", "claude", "0000", "FirstName LastName", "2026-10-27 06:05 UTC"} {
				if !strings.Contains(m.TextBody, want) {
					t.Errorf("%s/%s: body lacks %q:\n%s", loc, action, want, m.TextBody)
				}
			}
			if !strings.Contains(m.Subject, "t1") || strings.ContainsAny(m.Subject, "\r\n") {
				t.Errorf("%s/%s: subject %q", loc, action, m.Subject)
			}
			if strings.Contains(m.Subject+m.TextBody, "{{") || strings.Contains(m.TextBody, "<no value>") ||
				strings.Contains(m.TextBody, "http") {
				t.Errorf("%s/%s: unrendered, or a link:\n%s", loc, action, m.TextBody)
			}
			bodies[action] = m.TextBody
		}
		if bodies["set"] == bodies["replace"] || bodies["replace"] == bodies["remove"] || bodies["set"] == bodies["remove"] {
			t.Errorf("%s: the three changes do not read differently", loc)
		}
	}
}

// Spec 159 9 point 5 (T5): the refusal mail names the workspace, the kind,
// last4 and when, in every locale; it reads unlike every change notice, has
// no link and no more of the key than last4.
func TestVendorKeyExhaustedEveryLocale(t *testing.T) {
	at := time.Date(2026, 10, 27, 9, 5, 0, 0, time.FixedZone("x", 3*3600))
	for _, loc := range i18n.Supported {
		n := VendorKeyNotice{TenantID: "t1", Kind: "claude", Action: "exhausted", Last4: "0000", ChangedBy: "box-a", ChangedAt: at}
		m, err := VendorKeyExhausted("admin@example.com", loc, n)
		if err != nil || m.Locale != loc || m.Template != TemplateVendorKeyExhausted {
			t.Fatalf("%s: %+v %v", loc, m, err)
		}
		for _, want := range []string{"t1", "claude", "0000", "2026-10-27 06:05 UTC"} {
			if !strings.Contains(m.TextBody, want) {
				t.Errorf("%s: body lacks %q:\n%s", loc, want, m.TextBody)
			}
		}
		if !strings.Contains(m.Subject, "t1") || strings.ContainsAny(m.Subject, "\r\n") {
			t.Errorf("%s: subject %q", loc, m.Subject)
		}
		if strings.Contains(m.Subject+m.TextBody, "{{") || strings.Contains(m.TextBody, "<no value>") ||
			strings.Contains(m.TextBody, "http") || strings.Contains(m.TextBody, "box-a") {
			t.Errorf("%s: unrendered, a link, or the box:\n%s", loc, m.TextBody)
		}
		for _, action := range []string{"set", "replace", "remove"} {
			n.Action = action
			c, _ := VendorKeyChanged("admin@example.com", loc, n)
			if c.Subject == m.Subject || c.TextBody == m.TextBody {
				t.Errorf("%s: the refusal reads like the %s notice", loc, action)
			}
		}
	}
}
