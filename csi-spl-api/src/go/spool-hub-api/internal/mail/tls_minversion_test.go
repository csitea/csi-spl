package mail

import (
	"crypto/tls"
	"testing"
)

// SPL-1289: the SMTP TLS config never negotiates below TLS 1.2, whether or not
// the caller supplied a TLSConfig. Guards the gosec G402 / semgrep
// missing-ssl-minversion regression: a build that drops the floor reddens here
// before it can reach the gate.
func TestSMTPTLSConfigMinVersion(t *testing.T) {
	t.Run("default", func(t *testing.T) {
		s := &SMTP{Host: "smtp.example.com"}
		if got := s.tlsConfig().MinVersion; got != tls.VersionTLS12 {
			t.Fatalf("MinVersion = %#x, want TLS 1.2 (%#x)", got, tls.VersionTLS12)
		}
	})
	t.Run("caller config without MinVersion is floored", func(t *testing.T) {
		s := &SMTP{Host: "smtp.example.com", TLSConfig: &tls.Config{ServerName: "override.example.com"}}
		cfg := s.tlsConfig()
		if cfg.MinVersion != tls.VersionTLS12 {
			t.Fatalf("MinVersion = %#x, want TLS 1.2 (%#x)", cfg.MinVersion, tls.VersionTLS12)
		}
		if cfg.ServerName != "override.example.com" {
			t.Fatalf("ServerName = %q, want the caller's override", cfg.ServerName)
		}
	})
	t.Run("caller may raise but the clone is isolated", func(t *testing.T) {
		caller := &tls.Config{MinVersion: tls.VersionTLS13}
		s := &SMTP{Host: "smtp.example.com", TLSConfig: caller}
		if got := s.tlsConfig().MinVersion; got != tls.VersionTLS13 {
			t.Fatalf("MinVersion = %#x, want the caller's TLS 1.3 (%#x)", got, tls.VersionTLS13)
		}
		if caller.ServerName != "" {
			t.Fatalf("caller's TLSConfig mutated: ServerName = %q", caller.ServerName)
		}
	})
}
