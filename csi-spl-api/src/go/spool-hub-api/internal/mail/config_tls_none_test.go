package mail

import (
	"strings"
	"testing"
)

// Spec 148 §2.2 (row B4 addendum): the local dev compose hub sends to the
// Mailpit service (host mail) with TLS none. Only local dev mode
// (SPOOL_HUB_ENV=lde) may do that off loopback; dev, prd and an unset env
// keep the loopback-only rule.
func TestMailTLSNoneCatcherLocalDevOnly(t *testing.T) {
	vars := func(hubEnv string) map[string]string {
		m := map[string]string{"SPOOL_HUB_MAIL_TRANSPORT": "smtp", "SPOOL_HUB_MAIL_SMTP_HOST": "mail",
			"SPOOL_HUB_MAIL_SMTP_PORT": "1025", "SPOOL_HUB_MAIL_SMTP_TLS": "none", "SPOOL_HUB_MAIL_FROM": "spool@example.org"}
		if hubEnv != "" {
			m["SPOOL_HUB_ENV"] = hubEnv
		}
		return m
	}
	if c, err := LoadFrom(vars("lde")); err != nil || c.SMTPTLS != TLSNone || c.SMTPHost != "mail" {
		t.Fatalf("local dev mode + host mail + TLS none must load: %v", err)
	}
	for _, env := range []string{"dev", "prd", ""} {
		if _, err := LoadFrom(vars(env)); err == nil || !strings.Contains(err.Error(), "SPOOL_HUB_MAIL_SMTP_TLS=none") {
			t.Fatalf("SPOOL_HUB_ENV=%q + host mail + TLS none must be refused, got %v", env, err)
		}
	}
	loop := vars("prd")
	loop["SPOOL_HUB_MAIL_SMTP_HOST"] = "127.0.0.1"
	if _, err := LoadFrom(loop); err != nil {
		t.Fatalf("a loopback catcher stays allowed in any env: %v", err)
	}
}
