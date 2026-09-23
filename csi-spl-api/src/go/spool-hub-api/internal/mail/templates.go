package mail

import (
	"bytes"
	"embed"
	"fmt"
	"strings"
	"text/template"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/i18n"
)

// Per-locale mail templates, csi-rel internal/mail/templates.go's layout:
// templates/<template>/<locale>.subject and .txt, text/template, rendered by
// Render with an "en" fallback. Every template ships all 19 i18n.Supported
// locales (templates_test.go fails on a missing file).
//
//go:embed templates/*/*
var templateFS embed.FS

// Template names (Message.Template, logs, the templates/<name>/ directory).
const (
	TemplateEmailVerification = "email_verification"
	TemplatePasswordReset     = "password_reset"
	// TemplateTenantPaid is the M2 claim mail: tenant URL + single-use claim
	// link, NEVER key material (017 T008 / SEC-03).
	TemplateTenantPaid = "tenant_paid"
	// TemplateTenantInvite is the invitation mail (010 FR-016): tenant, role,
	// address, sign-in URL, expiry. It carries NO bearer token.
	TemplateTenantInvite = "tenant_invite"
	// TemplateFederatedSignIn is CLE-3451 defect 1: "forgot password" on an
	// address that has no password but DOES sign in with an IdP. It names the
	// provider and the sign-in page. NO bearer token and no TTL.
	TemplateFederatedSignIn = "federated_signin"
)

// Templates lists every template id (tests iterate it).
var Templates = []string{TemplateEmailVerification, TemplatePasswordReset, TemplateTenantPaid,
	TemplateTenantInvite, TemplateFederatedSignIn}

// FallbackLocale renders when a locale variant is missing (csi-rel G-02).
const FallbackLocale = "en"

// TemplateData is every variable a template may use.
type TemplateData struct {
	// Link is the single-use bearer link (never logged).
	Link string
	// TTL is the link lifetime; templates word it with {{duration .TTL}}.
	TTL       time.Duration
	TenantID  string
	TenantURL string
	// Invite fields (TemplateTenantInvite). SignInURL is not a bearer link:
	// admission matches the verified Email (010 FR-014).
	Role      string
	Email     string
	SignInURL string
	// ExpiresAt is pre-formatted (UTC) by the caller.
	ExpiresAt string
	// Providers is the worded provider list of TemplateFederatedSignIn
	// ("Google", "Google and Microsoft"), never raw slugs.
	Providers string
}

// providerNames words a provider slug for a mail. An unknown slug is title-cased
// so a new IdP reads sanely before anyone adds it here.
var providerNames = map[string]string{
	"google": "Google", "facebook": "Facebook", "microsoft": "Microsoft",
	"linkedin": "LinkedIn", "xai": "xAI", "apple": "Apple", "github": "GitHub",
}

// ProviderName is the human wording of one provider slug.
func ProviderName(slug string) string {
	if n, ok := providerNames[slug]; ok {
		return n
	}
	if slug == "" {
		return ""
	}
	return strings.ToUpper(slug[:1]) + slug[1:]
}

// providerList joins the worded names. The separator is "+" in every locale on
// purpose: an "and" per language is 19 more strings to keep right, and the list
// is almost always one provider.
func providerList(slugs []string) string {
	out := make([]string, 0, len(slugs))
	for _, s := range slugs {
		if n := ProviderName(s); n != "" {
			out = append(out, n)
		}
	}
	return strings.Join(out, " + ")
}

// Render loads templates/<id>/<locale>.{subject,txt}. An unknown or missing
// locale renders FallbackLocale; usedLocale says which one was rendered.
func Render(templateID, locale string, data TemplateData) (subject, text, usedLocale string, err error) {
	usedLocale = i18n.Normalize(locale)
	if usedLocale == "" {
		usedLocale = FallbackLocale
	}
	subject, text, err = loadAndExec(templateID, usedLocale, data)
	if err != nil && usedLocale != FallbackLocale {
		usedLocale = FallbackLocale
		subject, text, err = loadAndExec(templateID, usedLocale, data)
	}
	return subject, text, usedLocale, err
}

func loadAndExec(templateID, locale string, data TemplateData) (subject, text string, err error) {
	base := "templates/" + templateID + "/" + locale
	sb, err := templateFS.ReadFile(base + ".subject")
	if err != nil {
		return "", "", fmt.Errorf("mail: missing %s.subject: %w", base, err)
	}
	tb, err := templateFS.ReadFile(base + ".txt")
	if err != nil {
		return "", "", fmt.Errorf("mail: missing %s.txt: %w", base, err)
	}
	if subject, err = execTmpl(base+".subject", string(sb), locale, data); err != nil {
		return "", "", err
	}
	if text, err = execTmpl(base+".txt", string(tb), locale, data); err != nil {
		return "", "", err
	}
	// A subject is one header line.
	subject = strings.Join(strings.Fields(subject), " ")
	return subject, strings.TrimRight(text, "\n"), nil
}

func execTmpl(name, src, locale string, data TemplateData) (string, error) {
	t, err := template.New(name).Option("missingkey=error").Funcs(template.FuncMap{
		"duration": func(d time.Duration) string { return Duration(locale, d) },
	}).Parse(src)
	if err != nil {
		return "", fmt.Errorf("mail: parse %s: %w", name, err)
	}
	var buf bytes.Buffer
	if err := t.Execute(&buf, data); err != nil {
		return "", fmt.Errorf("mail: exec %s: %w", name, err)
	}
	return buf.String(), nil
}

func build(templateID, to, locale string, data TemplateData) (Message, error) {
	subject, text, used, err := Render(templateID, locale, data)
	if err != nil {
		return Message{}, err
	}
	return Message{To: to, Template: templateID, Locale: used, Subject: subject, TextBody: text}, nil
}

// EmailVerification renders the confirm-your-address mail in locale. link
// carries the plaintext token; it is never logged.
func EmailVerification(to, locale, link string, ttl time.Duration) (Message, error) {
	return build(TemplateEmailVerification, to, locale, TemplateData{Link: link, TTL: ttl})
}

// PasswordReset renders the reset-your-password mail in locale.
func PasswordReset(to, locale, link string, ttl time.Duration) (Message, error) {
	return build(TemplatePasswordReset, to, locale, TemplateData{Link: link, TTL: ttl})
}

// TenantPaid renders the one M2 mail (FR-014 as amended by 017 T008): tenant
// URL + a single-use claim link. It carries NO key material.
func TenantPaid(to, locale, tenantID, tenantURL, claimLink string, ttl time.Duration) (Message, error) {
	return build(TemplateTenantPaid, to, locale,
		TemplateData{Link: claimLink, TTL: ttl, TenantID: tenantID, TenantURL: tenantURL})
}

// InviteData is what the invitation mail says (010 FR-016).
type InviteData struct {
	TenantID  string
	Role      string
	Email     string
	SignInURL string
	ExpiresAt time.Time
}

// TenantInvite renders the invitation mail in locale. The expiry is worded
// in UTC ("2006-01-02 15:04 UTC") in every locale.
func TenantInvite(to, locale string, d InviteData) (Message, error) {
	return build(TemplateTenantInvite, to, locale, TemplateData{TenantID: d.TenantID, Role: d.Role,
		Email: d.Email, SignInURL: d.SignInURL, ExpiresAt: d.ExpiresAt.UTC().Format("2006-01-02 15:04") + " UTC"})
}

// FederatedSignIn renders CLE-3451 defect 1's mail: this address has no
// password, it signs in with these providers, here is the sign-in page.
// It carries no token, so it is safe to send on an unauthenticated route.
func FederatedSignIn(to, locale string, providers []string, signInURL string) (Message, error) {
	return build(TemplateFederatedSignIn, to, locale,
		TemplateData{Providers: providerList(providers), SignInURL: signInURL})
}
