package invitemail

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/i18n"
	"github.com/csitea/csi-spl/spool-hub-api/internal/mail"
)

const relinkLink = "https://www.example.com/contact#spool-relink=AbC-123_x"

// TestEmbedRelinkMail (specs/121 T206): the mail names the site, carries the
// link on a line of its own, words the 15 minutes, says the link works once
// and why the address was asked for, and leaves no template syntax.
func TestEmbedRelinkMail(t *testing.T) {
	rec := &mail.Recorder{}
	if err := SendEmbedRelink(context.Background(), rec, "visitor@example.com", relinkLink, 15*time.Minute); err != nil {
		t.Fatal(err)
	}
	got := rec.Messages()
	if len(got) != 1 {
		t.Fatalf("sent %d mails, want 1", len(got))
	}
	m := got[0]
	if m.To != "visitor@example.com" || m.Template != TemplateEmbedRelink || m.Locale != "en" ||
		m.Subject != "Continue your chat on www.example.com" {
		t.Errorf("headers: %+v", m)
	}
	if !strings.HasSuffix(m.MessageID, "."+TemplateEmbedRelink+"@www.example.com>") {
		t.Errorf("message id %q", m.MessageID)
	}
	own := false
	for _, l := range strings.Split(m.TextBody, "\n") {
		own = own || l == relinkLink
	}
	if !own {
		t.Errorf("the link is not on a line of its own:\n%s", m.TextBody)
	}
	for _, want := range []string{"15 minutes", "works once", "one purpose only", "www.example.com"} {
		if !strings.Contains(m.TextBody, want) {
			t.Errorf("body lacks %q:\n%s", want, m.TextBody)
		}
	}
	if strings.Contains(m.TextBody+m.Subject, "{{") || strings.Contains(m.TextBody, "<no value>") {
		t.Errorf("unrendered template:\n%s", m.TextBody)
	}
}

// TestEmbedRelinkMailRefusals: no sender, a link with no host, and a relay
// refusal are errors; nothing is recorded for the first two.
func TestEmbedRelinkMailRefusals(t *testing.T) {
	ctx := context.Background()
	if err := SendEmbedRelink(ctx, nil, "v@example.com", relinkLink, time.Minute); err == nil {
		t.Error("nil sender: no error")
	}
	rec := &mail.Recorder{}
	if err := SendEmbedRelink(ctx, rec, "v@example.com", "/no-host#x", time.Minute); err == nil || len(rec.Messages()) != 0 {
		t.Errorf("a link with no host: err=%v, %d sent", err, len(rec.Messages()))
	}
	rec.Err = errors.New("550 refused")
	if err := SendEmbedRelink(ctx, rec, "v@example.com", relinkLink, time.Minute); err == nil || !strings.Contains(err.Error(), "550") {
		t.Errorf("relay refusal: %v", err)
	}
}

// relinkFaults lists what a rendered relink mail in loc gets wrong: the link
// not exactly once or not on a line of its own, the TTL not worded in loc,
// the site missing from subject or body, template syntax left over.
func relinkFaults(m mail.Message, loc, link string, ttl time.Duration) []string {
	var out []string
	if n := strings.Count(m.TextBody, link); n != 1 {
		out = append(out, fmt.Sprintf("link %d times, want once", n))
	}
	own := false
	for _, l := range strings.Split(m.TextBody, "\n") {
		own = own || l == link
	}
	if !own {
		out = append(out, "link not on a line of its own")
	}
	if !strings.Contains(m.TextBody, mail.Duration(loc, ttl)) {
		out = append(out, "no TTL "+mail.Duration(loc, ttl))
	}
	if !strings.Contains(m.Subject, "www.example.com") || strings.Count(strings.ReplaceAll(m.TextBody, link, ""), "www.example.com") < 2 {
		out = append(out, "site missing")
	}
	if m.Subject == "" || strings.ContainsAny(m.Subject, "\r\n") {
		out = append(out, "subject not one line")
	}
	if strings.Contains(m.TextBody+m.Subject, "{{") || strings.Contains(m.TextBody+m.Subject, "<no value>") {
		out = append(out, "unrendered template")
	}
	return out
}

// TestEmbedRelinkEveryLocale (specs/121 T206b): every i18n.Supported locale
// renders (mail's templates execute with missingkey=error) in its own
// locale, with the link exactly once and the TTL in that language.
func TestEmbedRelinkEveryLocale(t *testing.T) {
	for _, loc := range i18n.Supported {
		m, err := EmbedRelinkMessage("v@example.com", loc, relinkLink, 15*time.Minute)
		if err != nil || m.Locale != loc || m.Template != TemplateEmbedRelink {
			t.Fatalf("%s: locale %q template %q err %v", loc, m.Locale, m.Template, err)
		}
		if f := relinkFaults(m, loc, relinkLink, 15*time.Minute); len(f) != 0 {
			t.Errorf("%s: %v\n%s\n%s", loc, f, m.Subject, m.TextBody)
		}
	}
}

// CONTROL: a mail rendered without {{.Link}} (the en body, link line gone)
// fails the same check, so a template that drops the link cannot pass.
func TestEmbedRelinkNoLinkControl(t *testing.T) {
	m, err := EmbedRelinkMessage("v@example.com", "en", relinkLink, 15*time.Minute)
	if err != nil {
		t.Fatal(err)
	}
	m.TextBody = strings.Replace(m.TextBody, relinkLink+"\n", "", 1)
	if f := relinkFaults(m, "en", relinkLink, 15*time.Minute); len(f) != 2 {
		t.Fatalf("control: %v, want the link missing and not on its line", f)
	}
}

// TestEmbedRelinkLocaleFallback: the locale on ctx is the mail's; a region
// tag renders its language, an unknown or absent one renders en.
func TestEmbedRelinkLocaleFallback(t *testing.T) {
	for _, c := range []struct{ asked, want string }{
		{"fi", "fi"}, {"sv-SE", "sv"}, {" RU ", "ru"}, {"de", "en"}, {"xx-YY", "en"}, {"", "en"},
	} {
		rec := &mail.Recorder{}
		ctx := WithRelinkLocale(context.Background(), c.asked)
		if err := SendEmbedRelink(ctx, rec, "v@example.com", relinkLink, 15*time.Minute); err != nil {
			t.Fatal(err)
		}
		if got := rec.Messages(); len(got) != 1 || got[0].Locale != c.want {
			t.Errorf("asked %q: %+v, want %s", c.asked, got, c.want)
		}
	}
	if l := RelinkLocale(context.Background()); l != "" {
		t.Errorf("no locale on ctx: %q", l)
	}
}
