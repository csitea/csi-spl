package mail

import (
	"bytes"
	"context"
	"crypto/tls"
	"errors"
	"net"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/rs/zerolog"
)

// stallRelay accepts and never answers: the IPv6 path of SPL-4491, where the
// connection opened and the first write then timed out (10-27 04:45Z prd).
func stallRelay(t *testing.T) string {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Skipf("listen: %v", err)
	}
	var held []net.Conn
	t.Cleanup(func() {
		ln.Close()
		for _, c := range held {
			c.Close()
		}
	})
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			held = append(held, c)
		}
	}()
	return ln.Addr().String()
}

// fakeDualStack stands in for a relay host with an A and an AAAA record: a
// tcp4 dial reaches v4, any other network the v6 path. It records the
// networks dialled.
func fakeDualStack(t *testing.T, v4, v6 string, seen *[]string) {
	t.Helper()
	prev := dialSMTP
	t.Cleanup(func() { dialSMTP = prev })
	dialSMTP = func(ctx context.Context, network, _ string) (net.Conn, error) {
		*seen = append(*seen, network)
		var d net.Dialer
		if network == "tcp4" {
			if v4 == "" {
				return nil, errors.New("no A record")
			}
			return d.DialContext(ctx, "tcp", v4)
		}
		return d.DialContext(ctx, "tcp", v6)
	}
}

// The IPv6 path stalls and IPv4 works: the preflight passes, and a real Send
// takes the same dial.
func TestPreflightAndSendPreferIPv4(t *testing.T) {
	stall := stallRelay(t)
	plain := newFakeSMTP(t, "127.0.0.1:0", nil)
	var seen []string
	fakeDualStack(t, "127.0.0.1:"+strconv.Itoa(plain.port()), stall, &seen)
	cnf := &Config{Transport: TransportSMTP, SMTPHost: "127.0.0.1", SMTPPort: 587, SMTPUser: "relay-user",
		SMTPPassword: "relay-pass", SMTPTLS: TLSNone, From: "no-reply@example.com",
		Timeout: time.Second, Preflight: PreflightRequire}
	var buf bytes.Buffer
	if err := Preflight(context.Background(), cnf, "prd", zerolog.New(&buf)); err != nil {
		t.Fatalf("preflight over a stalled IPv6 path failed: %v (dialled %v)", err, seen)
	}
	if strings.Contains(buf.String(), "CRITICAL") || !strings.Contains(buf.String(), "mail.preflight_ok") {
		t.Fatalf("preflight log: %s", buf.String())
	}
	srvTLS, pool := selfSigned(t)
	f := newFakeSMTP(t, "127.0.0.1:0", srvTLS)
	fakeDualStack(t, "127.0.0.1:"+strconv.Itoa(f.port()), stall, &seen)
	s := &SMTP{Host: "127.0.0.1", Port: 587, User: "relay-user", Pass: "relay-pass",
		From: "no-reply@example.com", Timeout: time.Second, TLSConfig: &tls.Config{RootCAs: pool, MinVersion: tls.VersionTLS12}}
	seen = nil
	msg := Message{To: "a@example.com", Subject: "s", TextBody: "b"}
	if err := s.Send(context.Background(), msg); err != nil {
		t.Fatalf("send over a stalled IPv6 path: %v (dialled %v)", err, seen)
	}
	if len(seen) != 1 || seen[0] != "tcp4" {
		t.Fatalf("send dialled %v, want [tcp4]", seen)
	}
}

// CONTROL: a host with no IPv4 address still connects, over the other path.
func TestDialFallsBackWithoutIPv4(t *testing.T) {
	srvTLS, pool := selfSigned(t)
	f := newFakeSMTP(t, "127.0.0.1:0", srvTLS)
	var seen []string
	fakeDualStack(t, "", "127.0.0.1:"+strconv.Itoa(f.port()), &seen)
	s := &SMTP{Host: "127.0.0.1", Port: 587, User: "relay-user", Pass: "relay-pass",
		From: "no-reply@example.com", Timeout: time.Second, TLSConfig: &tls.Config{RootCAs: pool, MinVersion: tls.VersionTLS12}}
	if err := s.Probe(context.Background()); err != nil {
		t.Fatalf("IPv6-only relay: %v (dialled %v)", err, seen)
	}
	if strings.Join(seen, ",") != "tcp4,tcp" {
		t.Fatalf("dialled %v, want [tcp4 tcp]", seen)
	}
}
