package mail

import (
	"context"
	"crypto/tls"
	"net"
	"strings"
	"testing"
)

// Pins of (*SMTP).Send taken before it was split into named steps
// (SPL-1029 round 2): the pre-checks, each transport mode and the dial /
// handshake failures, next to the STARTTLS tests in mail_test.go.

func TestSMTPSendPreChecks(t *testing.T) {
	ok := SMTP{Host: "127.0.0.1", Port: 1, From: "no-reply@example.com"}
	cases := []struct {
		s    *SMTP
		to   string
		want string
	}{
		{nil, "a@example.com", "mail: SMTP host not configured"},
		{&SMTP{From: "x@example.com"}, "a@example.com", "mail: SMTP host not configured"},
		{&ok, "", "mail: bad recipient"},
		{&ok, "a@example.com\r\nBcc: b@example.com", "mail: bad recipient"},
		{&SMTP{Host: "127.0.0.1", Port: 1, From: "  "}, "a@example.com", "mail: empty From"},
	}
	for _, c := range cases {
		m := msg
		m.To = c.to
		if err := c.s.Send(context.Background(), m); err == nil || err.Error() != c.want {
			t.Errorf("%+v to %q: got %v, want %q", c.s, c.to, err, c.want)
		}
	}
}

func TestSMTPSendDialFailure(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Skip(err)
	}
	port := ln.Addr().(*net.TCPAddr).Port
	ln.Close()
	s := &SMTP{Host: "127.0.0.1", Port: port, From: "no-reply@example.com"}
	if err := s.Send(context.Background(), msg); err == nil || !strings.HasPrefix(err.Error(), "mail: dial 127.0.0.1:") {
		t.Fatalf("want a dial error, got %v", err)
	}
}

// newFakeSMTPS is fakeSMTP behind implicit TLS (port 465 style).
func newFakeSMTPS(t *testing.T, srvTLS *tls.Config) *fakeSMTP {
	t.Helper()
	ln, err := tls.Listen("tcp", "127.0.0.1:0", srvTLS)
	if err != nil {
		t.Skip(err)
	}
	f := &fakeSMTP{ln: ln}
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

// Implicit TLS: the handshake comes first (ServerName defaults to Host), then
// AUTH and the message; no STARTTLS is asked for.
func TestSMTPSendImplicitTLS(t *testing.T) {
	srvTLS, pool := selfSigned(t)
	f := newFakeSMTPS(t, srvTLS)
	s := &SMTP{Host: "127.0.0.1", Port: f.port(), User: "relay-user", Pass: "relay-pass",
		From: "no-reply@example.com", TLSMode: TLSImplicit, TLSConfig: &tls.Config{RootCAs: pool}}
	if err := s.Send(context.Background(), msg); err != nil {
		t.Fatal(err)
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	if !f.authSeen || !strings.Contains(f.data, "verify-email?token=abc") {
		t.Fatalf("AUTH seen=%v data=%q", f.authSeen, f.data)
	}
	// the caller's TLS config is cloned, never written
	if s.TLSConfig.ServerName != "" || s.TLSConfig.MinVersion != 0 {
		t.Fatalf("caller's TLSConfig mutated: %+v", s.TLSConfig)
	}
}

// Implicit TLS to a plain-text relay fails the handshake, before any SMTP.
func TestSMTPSendImplicitTLSHandshakeFailure(t *testing.T) {
	f := newFakeSMTP(t, "127.0.0.1:0", nil)
	s := &SMTP{Host: "127.0.0.1", Port: f.port(), From: "no-reply@example.com", TLSMode: TLSImplicit}
	if err := s.Send(context.Background(), msg); err == nil || !strings.HasPrefix(err.Error(), "mail: tls handshake 127.0.0.1:") {
		t.Fatalf("want a handshake error, got %v", err)
	}
}

// TLS mode none to a loopback catcher: credentials are allowed in clear text,
// and a relay without credentials gets no AUTH at all.
func TestSMTPSendNoneLoopback(t *testing.T) {
	for _, user := range []string{"relay-user", ""} {
		f := newFakeSMTP(t, "127.0.0.1:0", nil)
		s := &SMTP{Host: "127.0.0.1", Port: f.port(), User: user, Pass: "relay-pass", From: "no-reply@example.com", TLSMode: TLSNone}
		if err := s.Send(context.Background(), msg); err != nil {
			t.Fatalf("user %q: %v", user, err)
		}
		f.mu.Lock()
		if f.authSeen != (user != "") || f.authTLS || !strings.Contains(f.data, "To: person@example.com") {
			t.Fatalf("user %q: AUTH seen=%v tls=%v data=%q", user, f.authSeen, f.authTLS, f.data)
		}
		f.mu.Unlock()
	}
}
