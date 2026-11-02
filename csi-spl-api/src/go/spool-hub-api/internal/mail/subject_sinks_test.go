package mail

import (
	"bytes"
	"context"
	"errors"
	"mime"
	"strings"
	"testing"
	"time"

	"github.com/rs/zerolog"
)

// ssDecode reads a Subject header value the way a mail client does.
func ssDecode(t *testing.T, header string) string {
	t.Helper()
	got, err := new(mime.WordDecoder).DecodeHeader(header)
	if err != nil {
		t.Fatalf("decode %q: %v", header, err)
	}
	return got
}

func ssMessage(subject string) Message {
	return Message{To: "person@example.com", Subject: subject, Template: "t", Locale: "en"}
}

func TestEncodeSubjectASCIIUnchanged(t *testing.T) {
	for _, s := range []string{"", "Continue your chat", "=?UTF-8?B?not-encoded?=", "a\tb~"} {
		if got := encodeSubject(s); got != s {
			t.Errorf("encodeSubject(%q) = %q, want it unchanged", s, got)
		}
	}
}

func TestEncodeSubjectNonASCIIDecodesBack(t *testing.T) {
	for _, s := range []string{"é", "Продължете чата", "המשך את הצ'אט", "chat 🙂 on example.com"} {
		got := encodeSubject(s)
		if !strings.HasPrefix(got, "=?UTF-8?B?") || !strings.HasSuffix(got, "?=") {
			t.Errorf("encodeSubject(%q) = %q, want =?UTF-8?B?...?=", s, got)
			continue
		}
		if back := ssDecode(t, got); back != s {
			t.Errorf("encodeSubject(%q) decodes to %q", s, back)
		}
	}
}

func TestRecorderErrReturnedNothingRecorded(t *testing.T) {
	want := errors.New("relay down")
	r := &Recorder{Err: want}
	if err := r.Send(context.Background(), ssMessage("refused")); !errors.Is(err, want) {
		t.Fatalf("Send = %v, want %v", err, want)
	}
	if got := r.Messages(); len(got) != 0 {
		t.Fatalf("recorded %d messages on an error, want 0: %+v", len(got), got)
	}
}

func TestRecorderMessagesIsACopy(t *testing.T) {
	r := &Recorder{}
	for _, s := range []string{"one", "two"} {
		if err := r.Send(context.Background(), ssMessage(s)); err != nil {
			t.Fatalf("Send(%q): %v", s, err)
		}
	}
	first := r.Messages()
	if len(first) != 2 || first[0].Subject != "one" || first[1].Subject != "two" {
		t.Fatalf("Messages = %+v, want one, two in send order", first)
	}
	first[0].Subject = "edited"
	if again := r.Messages(); again[0].Subject != "one" {
		t.Fatalf("editing the copy reached the recorder: %+v", again)
	}
}

func TestSenderSMTPCarriesTheConfig(t *testing.T) {
	c := &Config{Transport: TransportSMTP, SMTPHost: "relay.example.com", SMTPPort: 587, SMTPUser: "relay-user",
		SMTPPassword: "relay-pass", From: "no-reply@example.com", FromName: "Spool", Timeout: 7 * time.Second,
		SMTPTLS: TLSImplicit}
	got, ok := c.Sender(zerolog.Nop()).(*SMTP)
	if !ok {
		t.Fatalf("Sender = %T, want *SMTP", c.Sender(zerolog.Nop()))
	}
	want := SMTP{Host: "relay.example.com", Port: 587, User: "relay-user", Pass: "relay-pass",
		From: "no-reply@example.com", FromName: "Spool", Timeout: 7 * time.Second, TLSMode: TLSImplicit}
	if *got != want {
		t.Fatalf("Sender = %+v, want %+v", *got, want)
	}
}

func TestSenderLogTagsItsComponent(t *testing.T) {
	var buf bytes.Buffer
	s, ok := (&Config{Transport: TransportLog}).Sender(zerolog.New(&buf)).(Log)
	if !ok {
		t.Fatalf("transport log did not build a Log sender")
	}
	if err := s.Send(context.Background(), ssMessage("logged")); err != nil {
		t.Fatalf("Send: %v", err)
	}
	if !strings.Contains(buf.String(), `"component":"mail"`) {
		t.Fatalf("log line lacks the component: %s", buf.String())
	}
}

func TestSenderAnyOtherTransportIsNone(t *testing.T) {
	for _, transport := range []string{TransportNone, "", "carrier-pigeon"} {
		s := (&Config{Transport: transport}).Sender(zerolog.Nop())
		if _, ok := s.(None); !ok {
			t.Errorf("transport %q: Sender = %T, want None", transport, s)
			continue
		}
		if err := s.Send(context.Background(), ssMessage("dropped")); err != nil {
			t.Errorf("transport %q: Send = %v, want nil", transport, err)
		}
	}
}

// bg is the other locale: its subject is not ASCII, so it also takes the
// encoded-word path end to end.
func TestEmbedRelinkHoldsSiteAndLink(t *testing.T) {
	const (
		to   = "visitor@example.com"
		site = "shop.example.com"
		link = "https://hub.example.com/embed/relink?t=tok-1"
	)
	bodies := map[string]string{}
	for _, locale := range []string{"en", "bg"} {
		m, err := EmbedRelink(to, locale, site, link, 30*time.Minute)
		if err != nil {
			t.Fatalf("%s: %v", locale, err)
		}
		if m.To != to || m.Template != TemplateEmbedRelink || m.Locale != locale {
			t.Errorf("%s: To %q, Template %q, Locale %q", locale, m.To, m.Template, m.Locale)
		}
		if !strings.Contains(m.TextBody, site) || !strings.Contains(m.TextBody, link) {
			t.Errorf("%s: body lacks the site or the link:\n%s", locale, m.TextBody)
		}
		if !strings.Contains(m.Subject, site) {
			t.Errorf("%s: subject %q lacks the site", locale, m.Subject)
		}
		if back := ssDecode(t, encodeSubject(m.Subject)); back != m.Subject {
			t.Errorf("%s: subject %q decodes to %q", locale, m.Subject, back)
		}
		bodies[locale] = m.TextBody
	}
	if bodies["en"] == bodies["bg"] {
		t.Errorf("bg rendered the same body as en: %s", bodies["en"])
	}
	if isASCII(bodies["bg"]) {
		t.Errorf("bg body is plain ASCII, not the translation: %s", bodies["bg"])
	}
}
