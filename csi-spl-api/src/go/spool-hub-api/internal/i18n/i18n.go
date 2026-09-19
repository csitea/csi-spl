// Package i18n is the hub's locale negotiation (CLE-3403), ported from csi-rel
// internal/i18n: the same 19 locales, golang.org/x/text/language matching,
// and X-Locale over Accept-Language (a browser fetch may not override
// Accept-Language, so the cross-origin WUI sends its active locale in
// X-Locale). The default locale is cnf (SPOOL_HUB_DEFAULT_LOCALE, config.Hub),
// "en" (owner 2026-09-19, spec 021 OQ-1); the WUI reads the same cnf value.
package i18n

import (
	"fmt"
	"net/http"
	"net/url"
	"strings"

	"golang.org/x/text/language"
)

// Supported is every locale the hub and the WUI ship, as bare ISO 639-1
// codes. rdb 0017's CHECK constraints list the same 19.
var Supported = []string{"bg", "fi", "ru", "en", "sv", "he", "tr", "mk", "el", "lt", "et", "lv",
	"sr", "ro", "uk", "sk", "pl", "es", "nl"}

// DefaultLocale is SPOOL_HUB_DEFAULT_LOCALE's envDefault (cnf env.i18n.default_locale).
const DefaultLocale = "en"

// HeaderLocale is the WUI's explicit locale header; it wins over Accept-Language.
const HeaderLocale = "X-Locale"

var (
	supported = map[string]bool{}
	tags      []language.Tag
	matcher   language.Matcher
)

func init() {
	for _, c := range Supported {
		supported[c] = true
		tags = append(tags, language.MustParse(c))
	}
	matcher = language.NewMatcher(tags)
}

// IsSupported reports whether code is one of the 19 bare codes, exactly.
func IsSupported(code string) bool { return supported[code] }

// Normalize maps a code to one of Supported, or "": case and surrounding
// space are ignored and a region / script subtag is dropped ("sv-SE",
// "sr_Latn" -> "sv", "sr").
func Normalize(code string) string {
	c := strings.ToLower(strings.TrimSpace(code))
	if i := strings.IndexAny(c, "-_"); i > 0 {
		c = c[:i]
	}
	if supported[c] {
		return c
	}
	return ""
}

// Validate is the startup check of a configured default locale.
func Validate(name, code string) error {
	if !IsSupported(code) {
		return fmt.Errorf("%s %q must be one of %s", name, code, strings.Join(Supported, ","))
	}
	return nil
}

// Match picks the request locale: a supported X-Locale wins; otherwise the
// best Accept-Language match; otherwise def. An X-Locale the hub does not
// ship is ignored rather than trusted, so Accept-Language still gets a say.
func Match(xLocale, acceptLanguage, def string) string {
	if c := Normalize(xLocale); c != "" {
		return c
	}
	if strings.TrimSpace(acceptLanguage) != "" {
		if want, _, err := language.ParseAcceptLanguage(acceptLanguage); err == nil && len(want) > 0 {
			if _, idx, conf := matcher.Match(want...); conf != language.No && idx >= 0 && idx < len(Supported) {
				return Supported[idx]
			}
		}
	}
	return def
}

// FromRequest is Match over r's headers.
func FromRequest(r *http.Request, def string) string {
	return Match(r.Header.Get(HeaderLocale), r.Header.Get("Accept-Language"), def)
}

// URLPrefix is the WUI route prefix of loc under prefix_except_default
// routing: "" for the default locale (and anything unsupported), "/<loc>"
// otherwise.
func URLPrefix(loc, def string) string {
	loc = Normalize(loc)
	if loc == "" || loc == def {
		return ""
	}
	return "/" + loc
}

// LocalizeURL puts URLPrefix(loc, def) in front of an absolute WUI URL's path
// ("https://h/checkout/claim" -> "https://h/fi/checkout/claim"); query and
// fragment are kept. An unparsable URL is returned unchanged.
func LocalizeURL(raw, loc, def string) string {
	p := URLPrefix(loc, def)
	if p == "" {
		return raw
	}
	u, err := url.Parse(raw)
	if err != nil || u.Host == "" {
		return raw
	}
	u.Path = p + "/" + strings.TrimLeft(u.Path, "/")
	if u.RawPath != "" {
		u.RawPath = p + "/" + strings.TrimLeft(u.RawPath, "/")
	}
	return u.String()
}
