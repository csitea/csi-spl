package mail

import (
	"strconv"
	"strings"
)

// Template names (Message.Template, logs).
const (
	TemplateEmailVerification = "email_verification"
	TemplatePasswordReset     = "password_reset"
)

// EmailVerification renders the confirm-your-address mail. link carries the
// plaintext token; it is never logged.
func EmailVerification(to, link string, ttlHours int) Message {
	return Message{To: to, Template: TemplateEmailVerification,
		Subject: "Confirm your email for spool",
		TextBody: strings.Join([]string{
			"Someone (hopefully you) created a spool sign-in with this address.",
			"",
			"Confirm it by opening this link:",
			link,
			"",
			"The link works once and expires in " + hours(ttlHours) + ".",
			"If this was not you, ignore this mail: nothing happens without the link.",
		}, "\n")}
}

// PasswordReset renders the reset-your-password mail.
func PasswordReset(to, link string, ttlMinutes int) Message {
	return Message{To: to, Template: TemplatePasswordReset,
		Subject: "Reset your spool password",
		TextBody: strings.Join([]string{
			"Someone asked to reset the spool password for this address.",
			"",
			"Choose a new password here:",
			link,
			"",
			"The link works once and expires in " + minutes(ttlMinutes) + ".",
			"If this was not you, ignore this mail: your password is unchanged.",
		}, "\n")}
}

func hours(h int) string {
	if h == 1 {
		return "1 hour"
	}
	return strconv.Itoa(h) + " hours"
}

func minutes(m int) string {
	if m%60 == 0 {
		return hours(m / 60)
	}
	return strconv.Itoa(m) + " minutes"
}
