package mail

import (
	"bufio"
	"net"
	"net/smtp"
	"strings"
	"testing"
	"time"
)

// Unit tests for the three internal/mail functions under 75% (refactor
// round 24 row 07): macedonian's plural rule, deliver's SMTP steps against a
// scripted in-process listener, and loadAndExec's missing-template errors.

func TestMacedonianPluralRule(t *testing.T) {
	cases := []struct{ n, m10, m100, want int }{
		{1, 1, 1, catOne},
		{21, 1, 21, catOne},
		{11, 1, 11, catOther},
		{2, 2, 2, catOther},
	}
	for _, c := range cases {
		if got := macedonian(c.n, c.m10, c.m100); got != c.want {
			t.Errorf("macedonian(%d, %d, %d) = %d, want %d", c.n, c.m10, c.m100, got, c.want)
		}
	}
	if got, want := Duration("mk", 21*time.Hour), "21 час"; got != want {
		t.Errorf(`Duration("mk", 21h) = %q, want %q`, got, want)
	}
	if got, want := Duration("mk", 11*time.Hour), "11 часа"; got != want {
		t.Errorf(`Duration("mk", 11h) = %q, want %q`, got, want)
	}
}

// ddScript is the reply the scripted server gives per SMTP verb; "BODY" is
// the reply after the body's closing dot.
type ddScript map[string]string

func ddDefaultScript() ddScript {
	return ddScript{"EHLO": "250 ok", "MAIL": "250 ok", "RCPT": "250 ok", "DATA": "354 go", "BODY": "250 queued", "QUIT": "221 bye"}
}

// ddServe answers one connection on ln with the replies of script.
func ddServe(ln net.Listener, script ddScript) {
	conn, err := ln.Accept()
	if err != nil {
		return
	}
	defer conn.Close()
	r := bufio.NewReader(conn)
	reply := func(s string) { _, _ = conn.Write([]byte(s + "\r\n")) }
	reply("220 dd ready")
	for {
		line, err := r.ReadString('\n')
		if err != nil {
			return
		}
		verb := strings.ToUpper(strings.Fields(line + " x")[0])
		reply(script[verb])
		if verb == "DATA" && strings.HasPrefix(script[verb], "354") {
			if !ddReadBody(r) {
				return
			}
			reply(script["BODY"])
		}
	}
}

// ddReadBody reads the DATA body up to its "." line.
func ddReadBody(r *bufio.Reader) bool {
	for {
		line, err := r.ReadString('\n')
		if err != nil {
			return false
		}
		if line == ".\r\n" {
			return true
		}
	}
}

// ddClient starts the scripted server and returns a client connected to it.
func ddClient(t *testing.T, script ddScript) *smtp.Client {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = ln.Close() })
	go ddServe(ln, script)
	conn, err := net.Dial("tcp", ln.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	c, err := smtp.NewClient(conn, "127.0.0.1")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = c.Close() })
	return c
}

func TestDeliverSMTPSteps(t *testing.T) {
	cases := []struct {
		name, verb, reply, wantPrefix string
	}{
		{"mail from refused", "MAIL", "550 no sender", "mail: MAIL FROM:"},
		{"rcpt to refused", "RCPT", "550 no such user", "mail: RCPT TO:"},
		{"data refused", "DATA", "554 no data", "mail: DATA:"},
		{"body refused", "BODY", "554 rejected", "mail: close body:"},
		{"accepted", "", "", ""},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			script := ddDefaultScript()
			if tc.verb != "" {
				script[tc.verb] = tc.reply
			}
			c := ddClient(t, script)
			err := deliver(c, "from@example.com", "to@example.com", []byte("Subject: x\r\n\r\nhi\r\n"))
			if tc.wantPrefix == "" {
				if err != nil {
					t.Fatalf("deliver = %v, want nil", err)
				}
				return
			}
			if err == nil || !strings.HasPrefix(err.Error(), tc.wantPrefix) {
				t.Fatalf("deliver = %v, want prefix %q", err, tc.wantPrefix)
			}
		})
	}
}

func TestLoadAndExecMissingTemplate(t *testing.T) {
	const wantPrefix = "mail: missing templates/"
	if _, _, err := loadAndExec("no_such", "en", TemplateData{}); err == nil || !strings.HasPrefix(err.Error(), wantPrefix) {
		t.Errorf(`loadAndExec("no_such", "en") = %v, want prefix %q`, err, wantPrefix)
	}
	if _, _, err := loadAndExec(TemplatePasswordReset, "zz", TemplateData{}); err == nil || !strings.HasPrefix(err.Error(), wantPrefix) {
		t.Errorf(`loadAndExec(password_reset, "zz") = %v, want prefix %q`, err, wantPrefix)
	}
	_, _, used, err := Render("no_such", "sv", TemplateData{})
	if err == nil || !strings.HasPrefix(err.Error(), wantPrefix) {
		t.Errorf(`Render("no_such", "sv") = %v, want prefix %q`, err, wantPrefix)
	}
	if used != FallbackLocale {
		t.Errorf(`Render("no_such", "sv") used %q, want the fallback %q`, used, FallbackLocale)
	}
	subject, text, err := loadAndExec(TemplatePasswordReset, FallbackLocale, TemplateData{Link: "https://x.example.com/l", TTL: time.Hour})
	if err != nil || subject == "" || text == "" {
		t.Errorf("loadAndExec(password_reset, %q) = (%q, %q, %v), want non-empty and nil", FallbackLocale, subject, text, err)
	}
}
