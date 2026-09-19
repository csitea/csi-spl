// Package invitemail sends the invitation email (specs/010 FR-016): claim the
// send in the store (open invite, resend gap and cap), render tenant_invite,
// hand it to the relay. The operator CLI (`spool hub-invite`,
// `spool hub-invite-mail`) calls Send today; an in-app owner invite calls the
// same function.
//
// The mail carries no bearer token: admission matches the invitee's verified
// email (FR-014), so the sign-in URL names only the tenant. Logs carry
// mail.Digest(email), never the address or the body.
package invitemail

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"net/url"
	"strings"
	"time"

	"github.com/rs/zerolog"

	"github.com/csitea/csi-spl/spool-hub-api/internal/i18n"
	"github.com/csitea/csi-spl/spool-hub-api/internal/mail"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// Outcomes beyond the store's claim outcomes.
const (
	// Sent: the relay accepted the message (Delivered says whether the
	// transport reaches an inbox; "log" does not).
	Sent = "sent"
	// SendFailed: the relay refused; the claim was released.
	SendFailed = "send_failed"
)

// Default resend limits (FR-016).
const (
	DefaultMinGap   = 10 * time.Minute
	DefaultMaxSends = 5
)

// Deps is what Send needs.
type Deps struct {
	Store  store.InviteMails
	Sender mail.Sender
	// Delivers is mail.Config.Delivers(): false for the log / none sinks.
	Delivers bool
	Log      zerolog.Logger
	// AppURL is the env's WUI origin, https://<fqdn> (http only for loopback).
	AppURL string
	// Locale renders the mail; DefaultLocale is the WUI's unprefixed locale.
	Locale, DefaultLocale string
	Limits                store.InviteMailLimits
	Now                   func() time.Time
}

// Result says what happened; it never carries the address.
type Result struct {
	Outcome   string    `json:"outcome"`
	To        string    `json:"to"` // mail.Digest
	Locale    string    `json:"locale,omitempty"`
	SignInURL string    `json:"sign_in_url,omitempty"`
	ExpiresAt time.Time `json:"expires_at,omitempty"`
	MessageID string    `json:"message_id,omitempty"`
	Delivered bool      `json:"delivered"`
	MailCount int       `json:"mail_count,omitempty"`
}

// SignInURL is <app>[/<locale>]/login?tenant=<tenant>: the WUI serves the
// default locale unprefixed (prefix_except_default).
func SignInURL(appURL, locale, defaultLocale, tenant string) (string, error) {
	u, err := url.Parse(strings.TrimRight(strings.TrimSpace(appURL), "/"))
	if err != nil || u.Host == "" || u.RawQuery != "" || u.Fragment != "" || (u.Path != "" && u.Path != "/") {
		return "", fmt.Errorf("app URL must be a bare origin, got %q", appURL)
	}
	host := u.Hostname()
	if u.Scheme != "https" && !(u.Scheme == "http" && (host == "localhost" || host == "127.0.0.1" || strings.HasSuffix(host, ".localhost"))) {
		return "", fmt.Errorf("app URL must be https (http only for loopback), got %q", appURL)
	}
	path := "/login"
	if locale != "" && locale != defaultLocale {
		path = "/" + locale + "/login"
	}
	return u.Scheme + "://" + u.Host + path + "?tenant=" + url.QueryEscape(tenant), nil
}

func messageID(appURL string) string {
	b := make([]byte, 12)
	_, _ = rand.Read(b)
	host := "spool-hub.invalid"
	if u, err := url.Parse(appURL); err == nil && u.Hostname() != "" {
		host = u.Hostname()
	}
	return "<" + hex.EncodeToString(b) + "." + mail.TemplateTenantInvite + "@" + host + ">"
}

// Send mails the (tenant, email) invite once, if the store allows it now.
// A non-nil error is a store or render fault, or the relay's refusal
// (Outcome SendFailed); a skip (accepted, expired, rate limited, not found)
// is a nil error with that Outcome.
func Send(ctx context.Context, d Deps, tenant, email string) (Result, error) {
	email = strings.ToLower(strings.TrimSpace(email))
	res := Result{To: mail.Digest(email)}
	if d.Store == nil || d.Sender == nil {
		return res, errors.New("invitemail: store and sender are required")
	}
	now := time.Now
	if d.Now != nil {
		now = d.Now
	}
	// The invitee has no stored locale (FR-016): the caller's pick, else the
	// hub default, else the mail fallback.
	loc := i18n.Normalize(d.Locale)
	if loc == "" {
		loc = i18n.Normalize(d.DefaultLocale)
	}
	if loc == "" {
		loc = mail.FallbackLocale
	}
	signIn, err := SignInURL(d.AppURL, loc, d.DefaultLocale, tenant)
	if err != nil {
		return res, err
	}
	lim := d.Limits
	if lim.MaxSends == 0 {
		lim.MaxSends = DefaultMaxSends
	}
	log := d.Log.With().Str("component", "invitemail").Str("tenant", tenant).Str("to", res.To).Logger()

	c, err := d.Store.ClaimInviteMail(ctx, tenant, email, lim, now().UTC())
	if err != nil {
		return res, err
	}
	res.Outcome, res.ExpiresAt, res.MailCount = c.Outcome, c.Invite.ExpiresAt.UTC(), c.PrevMailCount
	if c.Outcome != store.InviteMailClaimed {
		log.Info().Str("outcome", c.Outcome).Msg("invite.mail_skipped")
		return res, nil
	}
	msg, err := mail.TenantInvite(email, loc, mail.InviteData{TenantID: tenant, Role: c.Invite.Role,
		Email: email, SignInURL: signIn, ExpiresAt: c.Invite.ExpiresAt})
	if err != nil {
		_ = d.Store.ReleaseInviteMail(ctx, c)
		return res, err
	}
	msg.MessageID = messageID(d.AppURL)
	res.Locale, res.SignInURL, res.MessageID = msg.Locale, signIn, msg.MessageID
	if err := d.Sender.Send(ctx, msg); err != nil {
		res.Outcome = SendFailed
		if rerr := d.Store.ReleaseInviteMail(ctx, c); rerr != nil {
			log.Warn().Err(rerr).Msg("invite.mail_release_failed")
		}
		log.Error().Err(err).Str("message_id", msg.MessageID).Msg("invite.mail_send_failed")
		return res, fmt.Errorf("invitemail: relay: %w", err)
	}
	res.Outcome, res.Delivered, res.MailCount = Sent, d.Delivers, c.PrevMailCount+1
	log.Info().Str("outcome", Sent).Bool("delivered", d.Delivers).Str("locale", msg.Locale).
		Str("message_id", msg.MessageID).Int("mail_count", res.MailCount).Msg("invite.mail_sent")
	return res, nil
}
