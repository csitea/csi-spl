// Package mail sends the hub's transactional email (spec 015: email
// confirmation and password reset). Ported from csi-rel internal/mail/mail.go
// (tree e4612828) without its order/receipt templates.
//
// Every relay setting is an env var with no default host (FR-010). A send is
// best-effort for its callers: they log a failure and keep their
// enumeration-safe answer.
package mail

import (
	"context"
	"crypto/sha256"
	"crypto/tls"
	"encoding/base64"
	"encoding/hex"
	"fmt"
	"net"
	"net/smtp"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/rs/zerolog"
)

// Message is a fully rendered outbound mail (text only).
type Message struct {
	To       string
	Subject  string
	TextBody string
	// Template names the message kind for logs (never the body).
	Template string
	// Locale is the locale the body was rendered in (Render's usedLocale).
	Locale string
	// MessageID, when set, is sent as the Message-ID header ("<id@host>") so
	// one send can be traced in the relay and the sender's mailbox.
	MessageID string
}

// Sender delivers a rendered Message.
type Sender interface {
	Send(ctx context.Context, msg Message) error
}

// TLS modes for SMTP.TLSMode.
const (
	// TLSStartTLS (default) requires a successful STARTTLS upgrade.
	TLSStartTLS = "starttls"
	// TLSImplicit wraps the connection in TLS before the greeting (port 465).
	TLSImplicit = "implicit"
	// TLSNone forbids any upgrade: only for a loopback catcher (MailHog).
	TLSNone = "none"
)

// SMTP delivers via net/smtp. Against a submission relay (Workspace on 587)
// the connection MUST be upgraded before AUTH; csi-rel's recorded bug was a
// relay reached without STARTTLS, which net/smtp surfaces only as an
// "unencrypted connection" error at AUTH. Here the upgrade is required up
// front, and credentials are never offered over plaintext to a non-loopback host.
type SMTP struct {
	Host     string
	Port     int
	User     string
	Pass     string
	From     string
	FromName string
	Timeout  time.Duration
	TLSMode  string
	// TLSConfig overrides the negotiated TLS settings (tests: a private CA).
	TLSConfig *tls.Config
}

func isLoopbackHost(host string) bool {
	switch strings.ToLower(host) {
	case "localhost", "127.0.0.1", "::1":
		return true
	}
	return false
}

// Send implements Sender.
func (s *SMTP) Send(ctx context.Context, msg Message) error {
	from, err := s.check(msg)
	if err != nil {
		return err
	}
	raw := buildRFC822(formatMailbox(s.FromName, from), msg)
	ctx, cancel := context.WithTimeout(ctx, s.timeout())
	defer cancel()
	c, done, err := s.session(ctx)
	if err != nil {
		return err
	}
	defer done()
	return deliver(c, from, msg.To, raw)
}

// Probe runs everything a Send does up to the envelope - dial, TLS, AUTH -
// then QUITs: no mail is sent (spec 047 W7, the relay preflight at start).
func (s *SMTP) Probe(ctx context.Context) error {
	if s == nil || s.Host == "" {
		return fmt.Errorf("mail: SMTP host not configured")
	}
	ctx, cancel := context.WithTimeout(ctx, s.timeout())
	defer cancel()
	c, done, err := s.session(ctx)
	if err != nil {
		return err
	}
	defer done()
	if err := c.Quit(); err != nil {
		return fmt.Errorf("mail: quit: %w", err)
	}
	return nil
}

func (s *SMTP) timeout() time.Duration {
	if s.Timeout == 0 {
		return defaultSMTPTimeout
	}
	return s.Timeout
}

// session dials, secures and authenticates within ctx; done closes it.
func (s *SMTP) session(ctx context.Context) (*smtp.Client, func(), error) {
	addr := net.JoinHostPort(s.Host, strconv.Itoa(s.Port))
	conn, secure, err := s.dial(ctx, addr)
	if err != nil {
		return nil, nil, err
	}
	c, err := smtp.NewClient(conn, s.Host)
	if err != nil {
		conn.Close()
		return nil, nil, fmt.Errorf("mail: smtp client: %w", err)
	}
	done := func() { _ = c.Close(); conn.Close() }
	if err := s.secureAndAuth(c, addr, secure); err != nil {
		done()
		return nil, nil, err
	}
	return c, done, nil
}

// defaultSMTPTimeout bounds one whole Send when SMTP.Timeout is zero.
const defaultSMTPTimeout = 10 * time.Second

// check refuses a Send that cannot be addressed and answers the envelope From.
func (s *SMTP) check(msg Message) (string, error) {
	if s == nil || s.Host == "" {
		return "", fmt.Errorf("mail: SMTP host not configured")
	}
	if msg.To == "" || strings.ContainsAny(msg.To, "\r\n") {
		return "", fmt.Errorf("mail: bad recipient")
	}
	from := strings.TrimSpace(s.From)
	if from == "" {
		return "", fmt.Errorf("mail: empty From")
	}
	return from, nil
}

// mode is the TLS mode, STARTTLS unless set.
func (s *SMTP) mode() string {
	if s.TLSMode == "" {
		return TLSStartTLS
	}
	return s.TLSMode
}

// tlsConfig is a clone of the caller's TLS config with ServerName defaulted
// to the host and at least TLS 1.2.
func (s *SMTP) tlsConfig() *tls.Config {
	cfg := &tls.Config{}
	if s.TLSConfig != nil {
		cfg = s.TLSConfig.Clone()
	}
	if cfg.ServerName == "" {
		cfg.ServerName = s.Host
	}
	if cfg.MinVersion == 0 {
		cfg.MinVersion = tls.VersionTLS12
	}
	return cfg
}

// dial connects within ctx's deadline; in implicit mode it completes the TLS
// handshake first and answers secure.
func (s *SMTP) dial(ctx context.Context, addr string) (net.Conn, bool, error) {
	deadline, _ := ctx.Deadline()
	d := net.Dialer{Deadline: deadline}
	conn, err := d.DialContext(ctx, "tcp", addr)
	if err != nil {
		return nil, false, fmt.Errorf("mail: dial %s: %w", addr, err)
	}
	_ = conn.SetDeadline(deadline)
	if s.mode() != TLSImplicit {
		return conn, false, nil
	}
	tc := tls.Client(conn, s.tlsConfig())
	if err := tc.HandshakeContext(ctx); err != nil {
		conn.Close()
		return nil, false, fmt.Errorf("mail: tls handshake %s: %w", addr, err)
	}
	return tc, true, nil
}

// secureAndAuth upgrades with STARTTLS (that mode requires it) and then
// authenticates; credentials never go to a remote host in clear text.
func (s *SMTP) secureAndAuth(c *smtp.Client, addr string, secure bool) error {
	if s.mode() == TLSStartTLS {
		if ok, _ := c.Extension("STARTTLS"); !ok {
			return fmt.Errorf("mail: %s does not advertise STARTTLS (SPOOL_HUB_MAIL_SMTP_TLS=starttls)", addr)
		}
		if err := c.StartTLS(s.tlsConfig()); err != nil {
			return fmt.Errorf("mail: starttls %s: %w", addr, err)
		}
		secure = true
	}
	if s.User == "" {
		return nil
	}
	if !secure && !isLoopbackHost(s.Host) {
		return fmt.Errorf("mail: refusing to send credentials to %s over an unencrypted connection", addr)
	}
	if err := c.Auth(smtp.PlainAuth("", s.User, s.Pass, s.Host)); err != nil {
		return fmt.Errorf("mail: auth: %w", err)
	}
	return nil
}

// deliver runs MAIL FROM, RCPT TO and DATA for one message, then QUIT.
func deliver(c *smtp.Client, from, to string, raw []byte) error {
	if err := c.Mail(from); err != nil {
		return fmt.Errorf("mail: MAIL FROM: %w", err)
	}
	if err := c.Rcpt(to); err != nil {
		return fmt.Errorf("mail: RCPT TO: %w", err)
	}
	w, err := c.Data()
	if err != nil {
		return fmt.Errorf("mail: DATA: %w", err)
	}
	if _, err := w.Write(raw); err != nil {
		_ = w.Close()
		return fmt.Errorf("mail: write body: %w", err)
	}
	if err := w.Close(); err != nil {
		return fmt.Errorf("mail: close body: %w", err)
	}
	return c.Quit()
}

func buildRFC822(from string, msg Message) []byte {
	var b strings.Builder
	b.WriteString("From: " + from + "\r\n")
	b.WriteString("To: " + msg.To + "\r\n")
	b.WriteString("Subject: " + encodeSubject(msg.Subject) + "\r\n")
	b.WriteString("Date: " + time.Now().UTC().Format(time.RFC1123Z) + "\r\n")
	if id := msg.MessageID; id != "" && !strings.ContainsAny(id, "\r\n") {
		b.WriteString("Message-ID: " + id + "\r\n")
	}
	b.WriteString("MIME-Version: 1.0\r\n")
	b.WriteString("Content-Type: text/plain; charset=UTF-8\r\n")
	b.WriteString("Content-Transfer-Encoding: 8bit\r\n\r\n")
	b.WriteString(strings.ReplaceAll(strings.ReplaceAll(msg.TextBody, "\r\n", "\n"), "\n", "\r\n"))
	if !strings.HasSuffix(msg.TextBody, "\n") {
		b.WriteString("\r\n")
	}
	return []byte(b.String())
}

func formatMailbox(name, addr string) string {
	name = strings.TrimSpace(name)
	if name == "" {
		return addr
	}
	if !isASCII(name) {
		return encodeWord(name) + " <" + addr + ">"
	}
	if strings.ContainsAny(name, "()<>[]:;@\\,.\"") {
		name = "\"" + strings.NewReplacer("\\", "\\\\", "\"", "\\\"").Replace(name) + "\""
	}
	return name + " <" + addr + ">"
}

func isASCII(s string) bool {
	for i := 0; i < len(s); i++ {
		if s[i] >= 0x80 {
			return false
		}
	}
	return true
}

func encodeWord(s string) string {
	return "=?UTF-8?B?" + base64.StdEncoding.EncodeToString([]byte(s)) + "?="
}

func encodeSubject(s string) string {
	if isASCII(s) {
		return s
	}
	return encodeWord(s)
}

// None discards every message (transport "none").
type None struct{}

func (None) Send(context.Context, Message) error { return nil }

// Log records that a message would have been sent: the template and a digest
// of the recipient, never the body (it carries a bearer link, FR-014).
type Log struct{ Logger zerolog.Logger }

func (l Log) Send(_ context.Context, msg Message) error {
	l.Logger.Info().Str("template", msg.Template).Str("locale", msg.Locale).Str("to", Digest(msg.To)).
		Str("message_id", msg.MessageID).Msg("mail.log_sink")
	return nil
}

// Recorder keeps messages in memory (tests).
type Recorder struct {
	mu   sync.Mutex
	msgs []Message
	Err  error
}

func (r *Recorder) Send(_ context.Context, msg Message) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.Err != nil {
		return r.Err
	}
	r.msgs = append(r.msgs, msg)
	return nil
}

// Messages returns a copy of what was recorded.
func (r *Recorder) Messages() []Message {
	r.mu.Lock()
	defer r.mu.Unlock()
	return append([]Message(nil), r.msgs...)
}

// Digest is a short, stable, non-reversible tag for an address in logs.
func Digest(s string) string {
	sum := sha256.Sum256([]byte(strings.ToLower(strings.TrimSpace(s))))
	return hex.EncodeToString(sum[:6])
}
