package mail

import (
	"io/fs"
	"strings"
	"testing"
	"testing/fstest"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/i18n"
)

// missingVariants lists every templates/<id>/<locale>.{subject,txt} of
// Templates x i18n.Supported that fsys lacks, plus any stray file.
func missingVariants(fsys fs.FS) []string {
	var out []string
	want := map[string]bool{}
	for _, id := range Templates {
		for _, loc := range i18n.Supported {
			for _, ext := range []string{".subject", ".txt"} {
				p := "templates/" + id + "/" + loc + ext
				want[p] = true
				if b, err := fs.ReadFile(fsys, p); err != nil || strings.TrimSpace(string(b)) == "" {
					out = append(out, "missing "+p)
				}
			}
		}
	}
	_ = fs.WalkDir(fsys, "templates", func(p string, d fs.DirEntry, err error) error {
		if err == nil && !d.IsDir() && !want[p] {
			out = append(out, "stray "+p)
		}
		return nil
	})
	return out
}

func TestEveryTemplateShipsAllNineteenLocales(t *testing.T) {
	if got := missingVariants(templateFS); len(got) != 0 {
		t.Fatalf("template files: %v", got)
	}
}

// CONTROL: the completeness check does fail when one locale file is gone.
func TestMissingVariantControl(t *testing.T) {
	m := fstest.MapFS{}
	_ = fs.WalkDir(templateFS, "templates", func(p string, d fs.DirEntry, err error) error {
		if err == nil && !d.IsDir() {
			b, _ := fs.ReadFile(templateFS, p)
			m[p] = &fstest.MapFile{Data: b}
		}
		return nil
	})
	delete(m, "templates/password_reset/lv.txt")
	got := missingVariants(m)
	if len(got) != 1 || got[0] != "missing templates/password_reset/lv.txt" {
		t.Fatalf("control: %v", got)
	}
}

// Every locale of every template renders in its own locale, carries its link
// (and tenant URL), leaves no template syntax, and words the TTL.
func TestEveryLocaleRendersItsLink(t *testing.T) {
	const link = "https://app.example.com/fi/verify-email?token=0123abcd"
	for _, id := range Templates {
		if id == TemplateTenantInvite {
			continue // no bearer link and no TTL by design: TestTenantInviteEveryLocale
		}
		for _, loc := range i18n.Supported {
			subj, body, used, err := Render(id, loc, TemplateData{Link: link, TTL: 24 * time.Hour,
				TenantID: "acme", TenantURL: "https://acme.example.com"})
			if err != nil || used != loc {
				t.Fatalf("%s/%s: used=%s err=%v", id, loc, used, err)
			}
			if subj == "" || strings.ContainsAny(subj, "\r\n") {
				t.Errorf("%s/%s: subject %q", id, loc, subj)
			}
			lines := strings.Split(body, "\n")
			found := false
			for _, l := range lines {
				found = found || l == link // the link sits on a line of its own
			}
			if !found {
				t.Errorf("%s/%s: link not on its own line:\n%s", id, loc, body)
			}
			if strings.Contains(body+subj, "{{") || strings.Contains(body+subj, "<no value>") {
				t.Errorf("%s/%s: unrendered template:\n%s", id, loc, body)
			}
			if !strings.Contains(body, Duration(loc, 24*time.Hour)) {
				t.Errorf("%s/%s: TTL wording %q missing:\n%s", id, loc, Duration(loc, 24*time.Hour), body)
			}
			if id == TemplateTenantPaid && (!strings.Contains(body, "https://acme.example.com") ||
				!strings.Contains(subj, "acme") || !strings.Contains(body, "$SPOOL_TENANT_ROOT_KEY") || !strings.Contains(body, "0600")) {
				t.Errorf("%s/%s: tenant fields:\n%s\n%s", id, loc, subj, body)
			}
		}
	}
}

func TestRenderFallsBackToEnglish(t *testing.T) {
	for _, loc := range []string{"de", "", "xx-YY"} {
		_, body, used, err := Render(TemplatePasswordReset, loc, TemplateData{Link: "https://x.example.com/l", TTL: time.Hour})
		if err != nil || used != FallbackLocale || !strings.Contains(body, "Choose a new password here:") {
			t.Fatalf("%q: used=%s err=%v %s", loc, used, err, body)
		}
	}
	// a region tag renders its language, not the fallback
	if _, _, used, _ := Render(TemplatePasswordReset, "sv-SE", TemplateData{Link: "l", TTL: time.Hour}); used != "sv" {
		t.Fatalf("sv-SE rendered %s", used)
	}
}

// The English wording is the pre-i18n wording, byte for byte.
func TestEnglishWordingUnchanged(t *testing.T) {
	ev, err := EmailVerification("a@example.com", "en", "LINK", 24*time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	if ev.Subject != "Confirm your email for spool" || ev.Locale != "en" || ev.Template != TemplateEmailVerification ||
		ev.TextBody != strings.Join([]string{
			"Someone (hopefully you) created a spool sign-in with this address.",
			"",
			"Confirm it by opening this link:",
			"LINK",
			"",
			"The link works once and expires in 24 hours.",
			"If this was not you, ignore this mail: nothing happens without the link.",
		}, "\n") {
		t.Fatalf("%+v", ev)
	}
	pr, _ := PasswordReset("a@example.com", "en", "LINK", time.Hour)
	if pr.Subject != "Reset your spool password" || pr.TextBody != strings.Join([]string{
		"Someone asked to reset the spool password for this address.",
		"",
		"Choose a new password here:",
		"LINK",
		"",
		"The link works once and expires in 1 hour.",
		"If this was not you, ignore this mail: your password is unchanged.",
	}, "\n") {
		t.Fatalf("%+v", pr)
	}
	tp, _ := TenantPaid("a@example.com", "en", "acme", "https://acme.example.com", "LINK", 24*time.Hour)
	if tp.Subject != "Your spool hub tenant acme is paid" || !strings.HasPrefix(tp.TextBody, "Your spool hub tenant is paid and ready.\n\nTenant URL:\nhttps://acme.example.com\n\nCollect your tenant ROOT key by opening this link once:\nLINK\n\nThe link works once and expires in 24 hours. The key is created\n") {
		t.Fatalf("%+v", tp)
	}
}

func TestDurationPlurals(t *testing.T) {
	for _, c := range []struct {
		loc  string
		d    time.Duration
		want string
	}{
		{"en", time.Hour, "1 hour"}, {"en", 24 * time.Hour, "24 hours"}, {"en", 90 * time.Minute, "90 minutes"},
		{"ru", time.Hour, "1 час"}, {"ru", 24 * time.Hour, "24 часа"}, {"ru", 5 * time.Hour, "5 часов"},
		{"ru", 11 * time.Hour, "11 часов"}, {"ru", 21 * time.Hour, "21 час"}, {"ru", 90 * time.Minute, "90 минут"},
		{"pl", 22 * time.Hour, "22 godziny"}, {"pl", 12 * time.Hour, "12 godzin"}, {"pl", 21 * time.Hour, "21 godzin"},
		{"lt", 24 * time.Hour, "24 valandos"}, {"lt", 10 * time.Hour, "10 valandų"}, {"lt", 21 * time.Hour, "21 valanda"},
		{"lv", 24 * time.Hour, "24 stundas"}, {"lv", 10 * time.Hour, "10 stundu"}, {"lv", 21 * time.Hour, "21 stunda"},
		{"ro", 24 * time.Hour, "24 de ore"}, {"ro", 2 * time.Hour, "2 ore"}, {"ro", time.Hour, "1 oră"},
		{"sk", 3 * time.Hour, "3 hodiny"}, {"sk", 24 * time.Hour, "24 hodín"},
		{"he", time.Hour, "שעה אחת"}, {"he", 2 * time.Hour, "שעתיים"}, {"he", 24 * time.Hour, "24 שעות"},
		{"fi", 24 * time.Hour, "24 tuntia"}, {"tr", 24 * time.Hour, "24 saat"}, {"nl", 24 * time.Hour, "24 uur"},
		{"sr", 24 * time.Hour, "24 sata"}, {"uk", 25 * time.Hour, "25 годин"}, {"xx", time.Hour, "1 hour"},
	} {
		if got := Duration(c.loc, c.d); got != c.want {
			t.Errorf("Duration(%s, %v) = %q, want %q", c.loc, c.d, got, c.want)
		}
	}
	for _, loc := range i18n.Supported {
		if _, ok := unitsHour[loc]; !ok {
			t.Errorf("no hour words for %s", loc)
		}
		if _, ok := unitsMinute[loc]; !ok {
			t.Errorf("no minute words for %s", loc)
		}
	}
}
