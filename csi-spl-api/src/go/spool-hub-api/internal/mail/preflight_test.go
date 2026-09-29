package mail

import (
	"bytes"
	"context"
	"crypto/tls"
	"net"
	"strings"
	"testing"
	"time"

	"github.com/rs/zerolog"
)

// deadPort is a loopback port nothing listens on (a dead relay).
func deadPort(t *testing.T) int {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Skipf("listen: %v", err)
	}
	p := ln.Addr().(*net.TCPAddr).Port
	ln.Close()
	return p
}

func smtpCnf(port int, preflight string) *Config {
	return &Config{Transport: TransportSMTP, SMTPHost: "127.0.0.1", SMTPPort: port, SMTPUser: "relay-user",
		SMTPPassword: "relay-pass", SMTPTLS: TLSStartTLS, From: "no-reply@example.com",
		Timeout: 2 * time.Second, Preflight: preflight}
}

// Probe goes as far as AUTH over TLS and sends no mail.
func TestProbeAuthsAndSendsNothing(t *testing.T) {
	srvTLS, pool := selfSigned(t)
	f := newFakeSMTP(t, "127.0.0.1:0", srvTLS)
	s := &SMTP{Host: "127.0.0.1", Port: f.port(), User: "relay-user", Pass: "relay-pass",
		From: "no-reply@example.com", TLSConfig: &tls.Config{RootCAs: pool}}
	if err := s.Probe(context.Background()); err != nil {
		t.Fatal(err)
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	if !f.authSeen || !f.authTLS || f.data != "" {
		t.Fatalf("AUTH seen=%v over TLS=%v data=%q; want AUTH over TLS and no mail", f.authSeen, f.authTLS, f.data)
	}
}

// A dead relay and a refused password both fail the probe.
func TestProbeFailsOnDeadRelayAndBadAuth(t *testing.T) {
	s := &SMTP{Host: "127.0.0.1", Port: deadPort(t), From: "no-reply@example.com", Timeout: 2 * time.Second}
	if err := s.Probe(context.Background()); err == nil || !strings.Contains(err.Error(), "dial") {
		t.Fatalf("dead relay: want a dial error, got %v", err)
	}
	srvTLS, pool := selfSigned(t)
	f := newFakeSMTP(t, "127.0.0.1:0", srvTLS)
	f.authFail = true
	s = &SMTP{Host: "127.0.0.1", Port: f.port(), User: "relay-user", Pass: "wrong",
		From: "no-reply@example.com", TLSConfig: &tls.Config{RootCAs: pool}}
	if err := s.Probe(context.Background()); err == nil || !strings.Contains(err.Error(), "auth") {
		t.Fatalf("bad password: want an auth error, got %v", err)
	}
}

func TestPreflightModes(t *testing.T) {
	dead := deadPort(t)
	cases := []struct {
		name, env     string
		cnf           *Config
		wantErr, loud bool
	}{
		{"warn + dead relay: logged, hub starts", "prd", smtpCnf(dead, PreflightWarn), false, true},
		{"require + dead relay: refuses", "prd", smtpCnf(dead, PreflightRequire), true, true},
		{"off + dead relay: silent", "prd", smtpCnf(dead, PreflightOff), false, false},
		{"log transport on prd: no mail leaves", "prd", &Config{Transport: TransportLog, Preflight: PreflightRequire}, true, true},
		{"none transport on prd, warn", "prd", &Config{Transport: TransportNone, Preflight: PreflightWarn}, false, true},
		// CONTROL: the local profile (lde, transport log) is not a problem
		{"log transport on lde", "lde", &Config{Transport: TransportLog, Preflight: PreflightRequire}, false, false},
	}
	for _, c := range cases {
		var buf bytes.Buffer
		err := Preflight(context.Background(), c.cnf, c.env, zerolog.New(&buf))
		if (err != nil) != c.wantErr {
			t.Errorf("%s: err=%v, want error %v", c.name, err, c.wantErr)
		}
		loud := strings.Contains(buf.String(), `"severity":"CRITICAL"`) && strings.Contains(buf.String(), "mail.preflight_failed")
		if loud != c.loud {
			t.Errorf("%s: CRITICAL mail.preflight_failed logged=%v, want %v: %s", c.name, loud, c.loud, buf.String())
		}
		if strings.Contains(buf.String(), "relay-pass") {
			t.Errorf("%s: the relay password reached the log", c.name)
		}
	}
}

func TestPreflightCnf(t *testing.T) {
	c, err := LoadFrom(map[string]string{})
	if err != nil || c.Preflight != PreflightWarn {
		t.Fatalf("default preflight = %q (%v), want warn", c.Preflight, err)
	}
	if _, err := LoadFrom(map[string]string{"SPOOL_HUB_MAIL_PREFLIGHT": "maybe"}); err == nil {
		t.Fatal("SPOOL_HUB_MAIL_PREFLIGHT=maybe was accepted")
	}
	if c, err := LoadFrom(map[string]string{"SPOOL_HUB_MAIL_PREFLIGHT": " Require "}); err != nil || c.Preflight != PreflightRequire {
		t.Fatalf("Require -> %q (%v)", c.Preflight, err)
	}
}
