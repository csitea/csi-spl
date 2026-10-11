package invitemail

import (
	"context"
	"errors"
	"fmt"
	"net/url"
	"strings"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/mail"
)

// The embed relink mail (specs/121 4.1, T206): a visitor of an embedded chat
// who left an e-mail asks, from a new device, to continue the same chat; this
// mail carries the single-use link that binds a new token to that visitor.
// The link IS a bearer credential for 15 minutes: it is never logged, and
// the hub logs mail.Digest(to) only.
//
// The text is mail's templates/embed_relink/<locale>.{subject,txt} (T206b),
// one pair per i18n.Supported locale; a translation is multilingual user
// text and gets the agy review last (the language rule).

// TemplateEmbedRelink names the mail in logs and Message.Template.
const TemplateEmbedRelink = mail.TemplateEmbedRelink

// relinkLocaleKey carries the chat page's locale to SendEmbedRelink.
type relinkLocaleKey struct{}

// WithRelinkLocale is ctx carrying the locale the relink mail renders in;
// the hub sets it from the request (hub.EmbedRelinkMailer has no locale).
func WithRelinkLocale(ctx context.Context, locale string) context.Context {
	return context.WithValue(ctx, relinkLocaleKey{}, locale)
}

// RelinkLocale is the locale WithRelinkLocale put on ctx, "" when none.
func RelinkLocale(ctx context.Context) string {
	l, _ := ctx.Value(relinkLocaleKey{}).(string)
	return l
}

// EmbedRelinkMessage renders the relink mail to to in locale (unknown or ""
// renders mail.FallbackLocale). link is the single-use link (an https URL on
// the embedding site); its host names the site.
func EmbedRelinkMessage(to, locale, link string, ttl time.Duration) (mail.Message, error) {
	u, err := url.Parse(link)
	if err != nil || u.Hostname() == "" {
		return mail.Message{}, errors.New("invitemail: the relink link must be an absolute URL")
	}
	msg, err := mail.EmbedRelink(to, locale, u.Hostname(), link, ttl)
	if err != nil {
		return mail.Message{}, fmt.Errorf("invitemail: relink: %w", err)
	}
	msg.MessageID = relinkMessageID(link)
	return msg, nil
}

// SendEmbedRelink renders the relink mail in RelinkLocale(ctx) and sends it
// through sender.
func SendEmbedRelink(ctx context.Context, sender mail.Sender, to, link string, ttl time.Duration) error {
	if sender == nil {
		return errors.New("invitemail: a sender is required")
	}
	msg, err := EmbedRelinkMessage(to, RelinkLocale(ctx), link, ttl)
	if err != nil {
		return err
	}
	if err := sender.Send(ctx, msg); err != nil {
		return fmt.Errorf("invitemail: relay: %w", err)
	}
	return nil
}

// relinkMessageID is messageID's form for this template, host = the site.
func relinkMessageID(link string) string {
	id := messageID(link)
	return strings.Replace(id, "."+mail.TemplateTenantInvite+"@", "."+TemplateEmbedRelink+"@", 1)
}
