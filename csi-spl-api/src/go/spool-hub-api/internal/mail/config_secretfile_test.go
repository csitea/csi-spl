package mail

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// SPL-2158: the compose stack hands the SMTP password over as a Docker secret
// file (SPOOL_HUB_MAIL_SMTP_PASSWORD_FILE); the plain env var stays for lde.
func TestMailSMTPPasswordFile(t *testing.T) {
	smtp := func(extra map[string]string) map[string]string {
		m := map[string]string{"SPOOL_HUB_MAIL_TRANSPORT": "smtp", "SPOOL_HUB_MAIL_SMTP_HOST": "relay.example.net",
			"SPOOL_HUB_MAIL_SMTP_PORT": "587", "SPOOL_HUB_MAIL_FROM": "no-reply@example.com", "SPOOL_HUB_MAIL_SMTP_USER": "u"}
		for k, v := range extra {
			m[k] = v
		}
		return m
	}
	f := filepath.Join(t.TempDir(), "mail_smtp_password")
	if err := os.WriteFile(f, []byte("from-file\n"), 0o600); err != nil {
		t.Fatal(err)
	}

	c, err := LoadFrom(smtp(map[string]string{"SPOOL_HUB_MAIL_SMTP_PASSWORD_FILE": f, "SPOOL_HUB_MAIL_SMTP_PASSWORD": "from-env"}))
	if err != nil || c.SMTPPassword != "from-file" {
		t.Fatalf("the file must win over the env var: %v", err)
	}
	c, err = LoadFrom(smtp(map[string]string{"SPOOL_HUB_MAIL_SMTP_PASSWORD": "from-env"}))
	if err != nil || c.SMTPPassword != "from-env" {
		t.Fatalf("the env var is the fallback: %v", err)
	}
	if _, err = LoadFrom(smtp(nil)); err == nil || !strings.Contains(err.Error(), "SPOOL_HUB_MAIL_SMTP_PASSWORD must be set") {
		t.Fatalf("neither set must keep the existing error: %v", err)
	}
	if _, err = LoadFrom(smtp(map[string]string{"SPOOL_HUB_MAIL_SMTP_PASSWORD_FILE": f + ".absent"})); err == nil ||
		!strings.Contains(err.Error(), "SPOOL_HUB_MAIL_SMTP_PASSWORD_FILE") {
		t.Fatalf("an unreadable secret file must fail, naming it: %v", err)
	}
	t.Setenv("SPOOL_HUB_MAIL_TRANSPORT", "smtp")
	for k, v := range smtp(map[string]string{"SPOOL_HUB_MAIL_SMTP_PASSWORD_FILE": f}) {
		t.Setenv(k, v)
	}
	if c, err = Load(); err != nil || c.SMTPPassword != "from-file" {
		t.Fatalf("Load (the process env) must read the file too: %v", err)
	}
}
