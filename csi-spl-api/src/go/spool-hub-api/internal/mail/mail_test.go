package mail

import (
	"bufio"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"math/big"
	"net"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/rs/zerolog"
)

// fakeSMTP is a just-enough ESMTP server: EHLO, optional STARTTLS, AUTH PLAIN,
// MAIL/RCPT/DATA/QUIT. It records whether AUTH arrived and on which transport.
type fakeSMTP struct {
	ln       net.Listener
	tlsCfg   *tls.Config // nil = STARTTLS not advertised
	mu       sync.Mutex
	authSeen bool
	authTLS  bool
	authFail bool // answer AUTH with 535 (a wrong relay password)
	data     string
}

func newFakeSMTP(t *testing.T, addr string, tlsCfg *tls.Config) *fakeSMTP {
	t.Helper()
	ln, err := net.Listen("tcp", addr)
	if err != nil {
		t.Skipf("listen %s: %v", addr, err)
	}
	f := &fakeSMTP{ln: ln, tlsCfg: tlsCfg}
	t.Cleanup(func() { ln.Close() })
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			go f.serve(c)
		}
	}()
	return f
}

func (f *fakeSMTP) port() int { return f.ln.Addr().(*net.TCPAddr).Port }

func (f *fakeSMTP) serve(c net.Conn) {
	defer c.Close()
	isTLS := false
	r, w := bufio.NewReader(c), bufio.NewWriter(c)
	say := func(s string) { w.WriteString(s + "\r\n"); w.Flush() }
	say("220 fake ESMTP")
	for {
		line, err := r.ReadString('\n')
		if err != nil {
			return
		}
		cmd := strings.ToUpper(strings.TrimSpace(line))
		switch {
		case strings.HasPrefix(cmd, "EHLO"):
			if f.tlsCfg != nil && !isTLS {
				say("250-fake\r\n250-STARTTLS\r\n250 AUTH PLAIN")
			} else {
				say("250-fake\r\n250 AUTH PLAIN")
			}
		case cmd == "STARTTLS" && f.tlsCfg != nil:
			say("220 go ahead")
			tc := tls.Server(c, f.tlsCfg)
			if tc.Handshake() != nil {
				return
			}
			c, isTLS = tc, true
			r, w = bufio.NewReader(c), bufio.NewWriter(c)
		case strings.HasPrefix(cmd, "AUTH"):
			f.mu.Lock()
			f.authSeen, f.authTLS = true, isTLS
			fail := f.authFail
			f.mu.Unlock()
			if fail {
				say("535 5.7.8 bad credentials")
				continue
			}
			say("235 ok")
		case strings.HasPrefix(cmd, "MAIL"), strings.HasPrefix(cmd, "RCPT"):
			say("250 ok")
		case cmd == "DATA":
			say("354 go")
			var b strings.Builder
			for {
				l, err := r.ReadString('\n')
				if err != nil || l == ".\r\n" {
					break
				}
				b.WriteString(l)
			}
			f.mu.Lock()
			f.data = b.String()
			f.mu.Unlock()
			say("250 queued")
		case cmd == "QUIT":
			say("221 bye")
			return
		default:
			say("250 ok")
		}
	}
}

func selfSigned(t *testing.T) (*tls.Config, *x509.CertPool) {
	t.Helper()
	key, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	tpl := &x509.Certificate{SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: "127.0.0.1"},
		NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(time.Hour),
		IPAddresses: []net.IP{net.ParseIP("127.0.0.1")}, IsCA: true, BasicConstraintsValid: true,
		KeyUsage: x509.KeyUsageDigitalSignature | x509.KeyUsageCertSign, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}}
	der, err := x509.CreateCertificate(rand.Reader, tpl, tpl, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	cert, _ := x509.ParseCertificate(der)
	pool := x509.NewCertPool()
	pool.AddCert(cert)
	return &tls.Config{Certificates: []tls.Certificate{{Certificate: [][]byte{der}, PrivateKey: key}}}, pool
}

var msg, _ = EmailVerification("person@example.com", "en", "https://app.example.com/verify-email?token=abc", 24*time.Hour)

// The relay upgrades with STARTTLS before AUTH, and the message arrives.
func TestSMTPStartTLSBeforeAuth(t *testing.T) {
	srvTLS, pool := selfSigned(t)
	f := newFakeSMTP(t, "127.0.0.1:0", srvTLS)
	s := &SMTP{Host: "127.0.0.1", Port: f.port(), User: "relay-user", Pass: "relay-pass",
		From: "no-reply@example.com", FromName: "spool", TLSConfig: &tls.Config{RootCAs: pool}}
	if err := s.Send(context.Background(), msg); err != nil {
		t.Fatal(err)
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	if !f.authSeen || !f.authTLS {
		t.Fatalf("AUTH seen=%v over TLS=%v; want both", f.authSeen, f.authTLS)
	}
	if !strings.Contains(f.data, "Subject: Confirm your email for spool") || !strings.Contains(f.data, "verify-email?token=abc") {
		t.Fatalf("body: %q", f.data)
	}
}

// CONTROL (donor bug): a relay that does not offer STARTTLS gets no AUTH and no mail.
func TestSMTPRefusesAuthWithoutTLS(t *testing.T) {
	f := newFakeSMTP(t, "127.0.0.1:0", nil)
	s := &SMTP{Host: "127.0.0.1", Port: f.port(), User: "relay-user", Pass: "relay-pass", From: "no-reply@example.com"}
	err := s.Send(context.Background(), msg)
	if err == nil || !strings.Contains(err.Error(), "STARTTLS") {
		t.Fatalf("want a STARTTLS refusal, got %v", err)
	}
	// TLS mode none to a non-loopback host: credentials are refused before AUTH.
	g := newFakeSMTP(t, "127.0.0.2:0", nil)
	s2 := &SMTP{Host: "127.0.0.2", Port: g.port(), User: "relay-user", Pass: "relay-pass",
		From: "no-reply@example.com", TLSMode: TLSNone}
	if err := s2.Send(context.Background(), msg); err == nil || !strings.Contains(err.Error(), "unencrypted") {
		t.Fatalf("want an unencrypted-credentials refusal, got %v", err)
	}
	for _, x := range []*fakeSMTP{f, g} {
		x.mu.Lock()
		if x.authSeen || x.data != "" {
			t.Fatalf("server saw AUTH=%v data=%q", x.authSeen, x.data)
		}
		x.mu.Unlock()
	}
}

func TestMailConfigFailFast(t *testing.T) {
	ok := map[string]string{"SPOOL_HUB_MAIL_TRANSPORT": "smtp", "SPOOL_HUB_MAIL_SMTP_HOST": "relay.example.net",
		"SPOOL_HUB_MAIL_SMTP_PORT": "587", "SPOOL_HUB_MAIL_FROM": "no-reply@example.com",
		"SPOOL_HUB_MAIL_SMTP_USER": "u", "SPOOL_HUB_MAIL_SMTP_PASSWORD": "p"}
	if _, err := LoadFrom(ok); err != nil {
		t.Fatalf("valid config refused: %v", err)
	}
	if c, err := LoadFrom(map[string]string{}); err != nil || c.Transport != TransportNone || c.Delivers() {
		t.Fatalf("empty env: want transport none, got %+v %v", c, err)
	}
	for k, v := range map[string]string{
		"SPOOL_HUB_MAIL_TRANSPORT":     "carrier-pigeon",
		"SPOOL_HUB_MAIL_SMTP_HOST":     "",
		"SPOOL_HUB_MAIL_SMTP_PORT":     "0",
		"SPOOL_HUB_MAIL_FROM":          "PLACEHOLDER-from",
		"SPOOL_HUB_MAIL_SMTP_PASSWORD": "PLACEHOLDER-secret",
		"SPOOL_HUB_MAIL_SMTP_TLS":      "none",
	} {
		bad := map[string]string{}
		for a, b := range ok {
			bad[a] = b
		}
		bad[k] = v
		if _, err := LoadFrom(bad); err == nil {
			t.Errorf("%s=%q accepted", k, v)
		}
	}
}

func TestLogSinkNeverLogsTheLink(t *testing.T) {
	var b strings.Builder
	l := Log{Logger: zerolog.New(&b)}
	if err := l.Send(context.Background(), msg); err != nil {
		t.Fatal(err)
	}
	out := b.String()
	if strings.Contains(out, "token=") || strings.Contains(out, "person@example.com") || !strings.Contains(out, TemplateEmailVerification) {
		t.Fatalf("log sink line: %s", out)
	}
}

func TestTemplatesTTLWording(t *testing.T) {
	if m, _ := PasswordReset("a@example.com", "en", "https://x/reset-password?token=t", 60*time.Minute); !strings.Contains(m.TextBody, "1 hour") {
		t.Fatal(m.TextBody)
	}
	if m, _ := PasswordReset("a@example.com", "en", "l", 90*time.Minute); !strings.Contains(m.TextBody, strconv.Itoa(90)+" minutes") {
		t.Fatal(m.TextBody)
	}
}
