package mail

import (
	"regexp"
	"strings"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/i18n"
)

const fedSignIn = "https://example.com/login"

// CLE-3451 defect 1: every locale renders, in its own words, the provider the
// address signs in with and the sign-in page - and nothing else. This template
// carries no bearer link and no TTL, which is why TestEveryLocaleRendersItsLink
// skips it.
func TestFederatedSignInEveryLocale(t *testing.T) {
	for _, loc := range i18n.Supported {
		m, err := FederatedSignIn("person@example.com", loc, []string{"google"}, fedSignIn)
		if err != nil || m.Locale != loc || m.Template != TemplateFederatedSignIn {
			t.Fatalf("%s: %+v %v", loc, m, err)
		}
		if !strings.Contains(m.Subject, "Google") || strings.ContainsAny(m.Subject, "\r\n") {
			t.Errorf("%s: subject %q", loc, m.Subject)
		}
		if !strings.Contains(m.TextBody, "Google") {
			t.Errorf("%s: body does not name the provider:\n%s", loc, m.TextBody)
		}
		onItsOwnLine := false
		for _, l := range strings.Split(m.TextBody, "\n") {
			onItsOwnLine = onItsOwnLine || l == fedSignIn
		}
		if !onItsOwnLine {
			t.Errorf("%s: sign-in URL not on a line of its own:\n%s", loc, m.TextBody)
		}
		if strings.Contains(m.TextBody+m.Subject, "{{") || strings.Contains(m.TextBody+m.Subject, "<no value>") {
			t.Errorf("%s: unrendered template:\n%s", loc, m.TextBody)
		}
	}
	// Several providers read as a list, in every locale.
	m, err := FederatedSignIn("person@example.com", "en", []string{"facebook", "google"}, fedSignIn)
	if err != nil || !strings.Contains(m.TextBody, "Facebook + Google") {
		t.Fatalf("two providers: %q %v", m.TextBody, err)
	}
}

// CONTROL: this mail goes out on an UNAUTHENTICATED route, so it must carry
// nothing that could sign anyone in. No token-shaped run, and the only URL is
// the sign-in page the caller passed.
func TestFederatedSignInCarriesNoSecret(t *testing.T) {
	tokenish := regexp.MustCompile(`[A-Za-z0-9_\-]{20,}`)
	urls := regexp.MustCompile(`https?://\S+`)
	for _, loc := range i18n.Supported {
		m, err := FederatedSignIn("person@example.com", loc, []string{"google"}, fedSignIn)
		if err != nil {
			t.Fatal(err)
		}
		all := m.Subject + "\n" + m.TextBody
		if got := tokenish.FindString(all); got != "" {
			t.Errorf("%s: token-shaped run %q", loc, got)
		}
		for _, u := range urls.FindAllString(all, -1) {
			if u != fedSignIn {
				t.Errorf("%s: unexpected URL %q", loc, u)
			}
		}
	}
	if tokenish.FindString("open https://x/reset?token=Zm9vYmFyYmF6cXV4cXV1eGZvbw") == "" {
		t.Fatal("control: tokenish missed a token")
	}
}

func TestProviderNameWording(t *testing.T) {
	for slug, want := range map[string]string{
		"google": "Google", "facebook": "Facebook", "microsoft": "Microsoft",
		"linkedin": "LinkedIn", "xai": "xAI", "": "",
		"someidp": "Someidp", // an IdP nobody worded yet still reads sanely
	} {
		if got := ProviderName(slug); got != want {
			t.Errorf("ProviderName(%q) = %q, want %q", slug, got, want)
		}
	}
	if got := providerList([]string{"google", "microsoft"}); got != "Google + Microsoft" {
		t.Errorf("providerList = %q", got)
	}
	if got := providerList(nil); got != "" {
		t.Errorf("providerList(nil) = %q", got)
	}
}

// The English wording, byte for byte (the sibling of TestEnglishWordingUnchanged).
func TestFederatedSignInEnglishWording(t *testing.T) {
	m, err := FederatedSignIn("person@example.com", "en", []string{"google"}, "LINK")
	if err != nil {
		t.Fatal(err)
	}
	if m.Subject != "Sign in to spool with Google" || m.TextBody != strings.Join([]string{
		"Someone asked to reset the spool password for this address, but it has no password.",
		"",
		"This address signs in with: Google",
		"",
		"Use that button on the sign-in page:",
		"LINK",
		"",
		"If you would rather have a password too, register with this address and confirm it from the mail we send you - the password is added to the same account.",
		"",
		"If this was not you, ignore this mail: nothing changed.",
	}, "\n") {
		t.Fatalf("%+v", m)
	}
}
