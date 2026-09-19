package i18n

import (
	"net/http/httptest"
	"testing"
)

func TestSupportedIsTheNineteen(t *testing.T) {
	want := "bg fi ru en sv he tr mk el lt et lv sr ro uk sk pl es nl"
	got := ""
	for i, c := range Supported {
		if i > 0 {
			got += " "
		}
		got += c
	}
	if got != want || len(Supported) != 19 {
		t.Fatalf("Supported = %q", got)
	}
	if err := Validate("X", DefaultLocale); err != nil {
		t.Fatal(err)
	}
}

func TestNormalize(t *testing.T) {
	for in, want := range map[string]string{
		"fi": "fi", " FI ": "fi", "sv-SE": "sv", "sr_Latn": "sr", "en-US": "en", "he-IL": "he",
		"de": "", "": "", "-": "", "xx-fi": "", "iw": "",
	} {
		if got := Normalize(in); got != want {
			t.Errorf("Normalize(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestMatch(t *testing.T) {
	cases := []struct{ x, al, def, want string }{
		{"fi", "sv-SE,sv;q=0.9", "bg", "fi"},        // X-Locale wins
		{"", "sv-SE,sv;q=0.9,en;q=0.8", "bg", "sv"}, // region tag
		{"", "de-DE,de;q=0.9", "bg", "bg"},          // unsupported -> default
		{"", "de-DE,de;q=0.9", "en", "en"},          // the default is the caller's
		{"", "", "bg", "bg"},                        // nothing sent
		{"de", "nl-NL", "bg", "nl"},                 // unsupported X-Locale is ignored
		{"", "de;q=0.9,uk;q=0.5", "bg", "uk"},       // q ordering, first supported
		{"", "garbage;;;q=x", "fi", "fi"},           // malformed header
		{"PL", "", "bg", "pl"},                      // case
		{"", "es-419", "bg", "es"},                  // Latin American Spanish
	}
	for _, c := range cases {
		if got := Match(c.x, c.al, c.def); got != c.want {
			t.Errorf("Match(%q, %q, %q) = %q, want %q", c.x, c.al, c.def, got, c.want)
		}
	}
}

// CONTROL: without the X-Locale header the same request follows
// Accept-Language, so the precedence test above is not passing by accident.
func TestFromRequestControl(t *testing.T) {
	r := httptest.NewRequest("GET", "/", nil)
	r.Header.Set("Accept-Language", "ru-RU,ru;q=0.9")
	if got := FromRequest(r, "bg"); got != "ru" {
		t.Fatalf("without X-Locale: %q", got)
	}
	r.Header.Set(HeaderLocale, "lt")
	if got := FromRequest(r, "bg"); got != "lt" {
		t.Fatalf("with X-Locale: %q", got)
	}
}

func TestURLPrefix(t *testing.T) {
	for _, c := range []struct{ loc, def, want string }{
		{"bg", "bg", ""}, {"fi", "bg", "/fi"}, {"en", "en", ""}, {"bg", "en", "/bg"}, {"de", "bg", ""}, {"", "bg", ""},
	} {
		if got := URLPrefix(c.loc, c.def); got != c.want {
			t.Errorf("URLPrefix(%q, %q) = %q, want %q", c.loc, c.def, got, c.want)
		}
	}
}

func TestValidateRefuses(t *testing.T) {
	for _, bad := range []string{"", "de", "BG", "en-US"} {
		if Validate("SPOOL_HUB_DEFAULT_LOCALE", bad) == nil {
			t.Errorf("Validate(%q) accepted", bad)
		}
	}
}

func TestLocalizeURL(t *testing.T) {
	for _, c := range []struct{ raw, loc, def, want string }{
		{"https://app.example.com/checkout/claim", "fi", "bg", "https://app.example.com/fi/checkout/claim"},
		{"https://app.example.com/checkout/claim", "bg", "bg", "https://app.example.com/checkout/claim"},
		{"https://app.example.com", "sv", "bg", "https://app.example.com/sv/"},
		{"https://app.example.com/claim?x=1#a=b", "he", "bg", "https://app.example.com/he/claim?x=1#a=b"},
		{"not a url", "fi", "bg", "not a url"},
	} {
		if got := LocalizeURL(c.raw, c.loc, c.def); got != c.want {
			t.Errorf("LocalizeURL(%q, %q) = %q, want %q", c.raw, c.loc, got, c.want)
		}
	}
}
