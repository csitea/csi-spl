package invitemail

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"net/url"
	"strings"
	"text/template"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/mail"
)

// The embed relink mail (specs/121 4.1, T206): a visitor of an embedded chat
// who left an e-mail asks, from a new device, to continue the same chat; this
// mail carries the single-use link that binds a new token to that visitor.
// The link IS a bearer credential for 15 minutes: it is never logged, and
// the hub logs mail.Digest(to) only.
//
// One English template for now. A translation is multilingual user text:
// it gets the agy review last (the language rule) before it ships.

// TemplateEmbedRelink names the mail in logs and Message.Template.
const TemplateEmbedRelink = "embed_relink"

// embedRelinkLocale is the one locale the template ships in.
const embedRelinkLocale = "en"

var embedRelinkSubject = template.Must(template.New("subject").Option("missingkey=error").Parse(
	`Continue your chat on {{.Site}}`))

var embedRelinkBody = template.Must(template.New("body").Option("missingkey=error").Parse(
	`You asked to continue your chat on {{.Site}} on another device or browser.

Open this link within {{.TTL}} to continue there:

{{.Link}}

The link works once. Using it ends the chat's sign-in on the device you used before.
If you did not ask for this, ignore this mail: nothing changes.

You gave this address in the chat on {{.Site}} for one purpose only: to get
such a link back to your chat. It is not used for anything else.
`))

// EmbedRelinkMessage renders the relink mail to to. link is the single-use
// link (an https URL on the embedding site); its host names the site.
func EmbedRelinkMessage(to, link string, ttl time.Duration) (mail.Message, error) {
	u, err := url.Parse(link)
	if err != nil || u.Hostname() == "" {
		return mail.Message{}, errors.New("invitemail: the relink link must be an absolute URL")
	}
	data := struct{ Site, Link, TTL string }{u.Hostname(), link, mail.Duration(embedRelinkLocale, ttl)}
	var subj, body bytes.Buffer
	if err := embedRelinkSubject.Execute(&subj, data); err != nil {
		return mail.Message{}, fmt.Errorf("invitemail: relink subject: %w", err)
	}
	if err := embedRelinkBody.Execute(&body, data); err != nil {
		return mail.Message{}, fmt.Errorf("invitemail: relink body: %w", err)
	}
	return mail.Message{To: to, Subject: strings.Join(strings.Fields(subj.String()), " "),
		TextBody: strings.TrimRight(body.String(), "\n"), Template: TemplateEmbedRelink,
		Locale: embedRelinkLocale, MessageID: relinkMessageID(link)}, nil
}

// SendEmbedRelink renders and sends the relink mail through sender.
func SendEmbedRelink(ctx context.Context, sender mail.Sender, to, link string, ttl time.Duration) error {
	if sender == nil {
		return errors.New("invitemail: a sender is required")
	}
	msg, err := EmbedRelinkMessage(to, link, ttl)
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
