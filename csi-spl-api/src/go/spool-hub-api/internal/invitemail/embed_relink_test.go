package invitemail

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"

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
