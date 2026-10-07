package auth

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"time"
)

// An admin resets a member's password (owner HUM-10, t1 ea0af569: "add the
// ui and the api functionality for the admins to be able to reset the user's
// passwords"). The admin never sees or sets the password: the member gets the
// SAME one-time link as POST password/forgot (token, template, expiry and
// per-account mail floor). With signOut the old password stops working at
// once: it is replaced by the hash of a random secret nobody holds, and every
// session the member has is revoked (revoke.go). The hub's route
// (hub/member_password_reset.go) owns who may ask; this file owns the how.

// Errors from AdminPasswordReset.
var (
	// ErrNativeOff: this hub has no native sign-in, so no password exists.
	ErrNativeOff = errors.New("auth: native sign-in is off")
	// ErrNoPassword: the account has no password credential (it signs in
	// with an identity provider only).
	ErrNoPassword = errors.New("auth: the account has no password")
	// ErrResetRateLimited: the admin's ceiling or the member's mail floor
	// refused; AdminReset.RetryAfter says when to try again.
	ErrResetRateLimited = errors.New("auth: too many password resets")
	// ErrMailUndeliverable: no mail transport (and no debug tokens), or the
	// send failed; nothing was signed out.
	ErrMailUndeliverable = errors.New("auth: the reset mail cannot be delivered")
)

// AdminResetRequest names the member and the asking admin.
type AdminResetRequest struct {
	Subject string // the member's password-credential subject (their e-mail)
	HumanID string // the member, whose sessions signOut revokes
	ActorID string // the admin, the key of the per-admin ceiling
	Locale  string // the admin's WUI locale, the mail's last fallback
	SignOut bool
}

// AdminReset is the outcome of AdminPasswordReset.
type AdminReset struct {
	Email      string
	SignedOut  bool
	RetryAfter time.Duration
	// No token and no password, ever, not even with debug tokens on (owner
	// HUM-10 msg 2ca618b9: "the admin should never be able to see the new
	// password"). The link reaches the member's mailbox only.
}

// AdminPasswordReset mails the member a reset link and, with SignOut, kills
// the old password and every session. Nothing is signed out unless the link
// was issued and the mail left the hub, so a failed reset never locks a
// member out. The token never reaches a log line.
func (h *Handler) AdminPasswordReset(ctx context.Context, req AdminResetRequest) (AdminReset, error) {
	n := h.native
	if n == nil {
		return AdminReset{}, ErrNativeOff
	}
	email := normEmail(req.Subject)
	out := AdminReset{Email: email}
	if email == "" {
		return out, ErrNoPassword
	}
	if ok, retry := n.lim.Allow("admin-reset:"+req.ActorID, n.cfg.FormPerIP); !ok {
		out.RetryAfter = retry
		return out, ErrResetRateLimited
	}
	cred, err := n.store.GetCredential(ctx, email)
	if errors.Is(err, ErrCredNotFound) {
		return out, ErrNoPassword
	}
	if err != nil {
		return out, err
	}
	if !n.delivers {
		return out, ErrMailUndeliverable
	}
	now := h.now()
	_, issued, sent := n.mint(ctx, TokenReset, email, "", now,
		n.mailLocale(ctx, email, cred.Locale, req.Locale))
	if !issued {
		out.RetryAfter = n.cfg.MailMinInterval
		return out, ErrResetRateLimited
	}
	if !sent {
		return out, ErrMailUndeliverable
	}
	if req.SignOut {
		if err := h.signOutEverywhere(ctx, email, req.HumanID, now); err != nil {
			return out, err
		}
		out.SignedOut = true
	}
	n.log.Info().Str("email", digest(email)).Str("by", req.ActorID).Bool("signed_out", out.SignedOut).
		Msg("auth.native_admin_reset")
	return out, nil
}

// signOutEverywhere replaces the password by the hash of a random secret
// (the column holds argon2id only, rdb 0009) and revokes every session of
// the human, so neither the old password nor an open browser gets in.
func (h *Handler) signOutEverywhere(ctx context.Context, email, humanID string, now time.Time) error {
	n := h.native
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		return err
	}
	hash, err := HashPassword(hex.EncodeToString(b), n.cfg.argon2())
	if err != nil {
		return err
	}
	if err := n.store.SetPassword(ctx, email, hash, now); err != nil {
		return err
	}
	return h.RevokeSessions(ctx, humanID, now)
}
