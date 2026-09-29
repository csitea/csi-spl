package mail

import (
	"context"
	"fmt"

	"github.com/rs/zerolog"
)

// Preflight modes (SPOOL_HUB_MAIL_PREFLIGHT).
const (
	PreflightOff     = "off"
	PreflightWarn    = "warn"
	PreflightRequire = "require"
)

// Preflight checks at hub start that mail can leave this hub (spec 047 W7):
// before it, a prd hub with a dead relay started healthy and every
// confirmation, reset and invite mail failed later, one request at a time.
//   - transport smtp: SMTP.Probe (dial, TLS, AUTH, QUIT; no mail is sent)
//   - transport none / log on env prd: no mail leaves the hub at all
//
// A problem is logged as one CRITICAL mail.preflight_failed line. It is
// returned only in require mode, so the caller can refuse to start; in warn
// mode the hub keeps serving (the boxes do not need mail).
func Preflight(ctx context.Context, c *Config, env string, log zerolog.Logger) error {
	if c == nil || c.Preflight == PreflightOff {
		return nil
	}
	log = log.With().Str("component", "mail").Str("mail_transport", c.Transport).Logger()
	var problem error
	switch {
	case c.Transport == TransportSMTP:
		s, _ := c.Sender(log).(*SMTP)
		if problem = s.Probe(ctx); problem == nil {
			log.Info().Str("smtp_host", c.SMTPHost).Int("smtp_port", c.SMTPPort).Str("smtp_tls", c.SMTPTLS).
				Msg("mail.preflight_ok: the relay accepted a connection and the credentials")
			return nil
		}
	case env == "prd":
		problem = fmt.Errorf("mail: SPOOL_HUB_MAIL_TRANSPORT is %s on a prd hub: no confirmation, reset or invite mail leaves it", c.Transport)
	default:
		log.Info().Str("env", env).Msg("mail.preflight_skipped: no relay configured, mail is not delivered")
		return nil
	}
	log.Error().Str("severity", "CRITICAL").Str("event", "mail_preflight_failed").Str("preflight", c.Preflight).
		Err(problem).Msg("mail.preflight_failed: mail cannot leave this hub; sign-up confirmation, password reset and invites will fail")
	if c.Preflight == PreflightRequire {
		return fmt.Errorf("mail preflight (SPOOL_HUB_MAIL_PREFLIGHT=require): %w", problem)
	}
	return nil
}
