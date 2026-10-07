package hub

import (
	"context"
	"errors"
	"net/http"
	"strconv"
	"strings"

	"github.com/csitea/csi-spl/spool-hub-api/internal/auth"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// POST /v1/members/{human_id}/password-reset {sign_out?}: a workspace admin
// resets a member's password (owner HUM-10, t1 ea0af569, msg 56dd81ee). The
// admin never sees or sets it: the member gets the password/forgot link, and
// with sign_out (the default) the old password and every session stop
// working at once (auth/admin_reset.go). Who may ask is the member admin's
// rule set: members.invite in THIS workspace, a member of it (404 otherwise,
// existence never leaks), a role the caller covers, never the caller.

// signInLister answers how members sign in (store.SignIns).
type signInLister interface {
	SignIns(ctx context.Context, ids []string) (map[string][]store.SignIn, error)
}

// signIns is the providers of each human in ids; nil when the store keeps
// none, which the WUI reads as "unknown" (the hub still decides on reset).
func (s *Server) signIns(ctx context.Context, ids []string) map[string][]store.SignIn {
	sl, ok := s.o.Store.(signInLister)
	if !ok {
		return nil
	}
	got, err := sl.SignIns(ctx, ids)
	if err != nil {
		s.o.Log.Warn().Err(err).Msg("member.sign_ins unavailable")
		return nil
	}
	return got
}

// providersOf is the sorted, distinct provider list of one human ([] = none).
func providersOf(sis []store.SignIn) []string {
	out := []string{}
	for _, si := range sis {
		if len(out) == 0 || out[len(out)-1] != si.Provider {
			out = append(out, si.Provider)
		}
	}
	return out
}

func (s *Server) handleMemberPasswordReset(w http.ResponseWriter, r *http.Request) {
	t, a, roles, h, ok := s.membersActor(w, r, rbac.MembersInvite)
	if !ok {
		return
	}
	var body struct {
		SignOut *bool `json:"sign_out"`
	}
	if !decodeMembers(w, r, &body) {
		return
	}
	target, _, ok := s.targetRole(w, r, h, t, a, roles)
	if !ok {
		return
	}
	if target == a.HumanID {
		writeErr(w, http.StatusConflict, "self", "change your own password in Settings → Security")
		return
	}
	sl, ok := s.o.Store.(signInLister)
	if !ok {
		writeErr(w, http.StatusNotImplemented, "unsupported", "this hub's store keeps no sign-in identities")
		return
	}
	got, err := sl.SignIns(r.Context(), []string{target})
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "sign-in lookup failed")
		return
	}
	sis := got[target]
	subject := ""
	for _, si := range sis {
		if si.Provider == auth.ProviderPassword {
			subject = si.Subject
		}
	}
	if subject == "" || s.o.Auth == nil {
		noPassword(w, providersOf(sis))
		return
	}
	signOut := body.SignOut == nil || *body.SignOut
	res, err := s.o.Auth.AdminPasswordReset(r.Context(), auth.AdminResetRequest{Subject: subject, HumanID: target,
		ActorID: a.HumanID, Locale: r.Header.Get("X-Locale"), SignOut: signOut})
	if !s.resetAnswered(w, err, res, sis) {
		return
	}
	detail := ""
	if res.SignedOut {
		detail = "signed_out"
	}
	s.o.Log.Info().Str("tenant", t.ID).Str("by", a.HumanID).Str("member", target).Bool("signed_out", res.SignedOut).Msg("member.password_reset")
	s.recordMemberActivity(r.Context(), store.MemberActivity{TenantID: t.ID, SubjectHum: target, ActorHum: a.HumanID,
		Kind: "password_reset", Detail: detail})
	// Never a token or a password, not even on dev (owner HUM-10, 2ca618b9).
	writeJSON(w, http.StatusOK, map[string]any{"human_id": target, "email": res.Email, "signed_out": res.SignedOut})
}

// resetAnswered maps AdminPasswordReset's refusal to its answer; true = no
// refusal, the caller answers.
func (s *Server) resetAnswered(w http.ResponseWriter, err error, res auth.AdminReset, sis []store.SignIn) bool {
	switch {
	case err == nil:
		return true
	case errors.Is(err, auth.ErrNoPassword), errors.Is(err, auth.ErrNativeOff):
		noPassword(w, providersOf(sis))
	case errors.Is(err, auth.ErrResetRateLimited):
		w.Header().Set("Retry-After", strconv.Itoa(int(res.RetryAfter.Seconds())+1))
		writeErr(w, http.StatusTooManyRequests, auth.ErrTokRateLimited, "a reset link was sent recently; try again later")
	case errors.Is(err, auth.ErrMailUndeliverable):
		writeErr(w, http.StatusServiceUnavailable, auth.ErrTokMailUnavailable, "the reset mail cannot be delivered")
	default:
		s.o.Log.Error().Err(err).Msg("member.password_reset failed")
		writeErr(w, http.StatusInternalServerError, "internal", "password not reset")
	}
	return false
}

// noPassword is the 409 of a member who signs in with an identity provider
// only: nothing to reset, and the answer names how they do sign in.
func noPassword(w http.ResponseWriter, providers []string) {
	others := []string{}
	for _, p := range providers {
		if p != auth.ProviderPassword {
			others = append(others, p)
		}
	}
	detail := "this member has no password to reset"
	if len(others) > 0 {
		detail = "signs in with " + strings.Join(others, ", ") + ", no password to reset"
	}
	writeJSON(w, http.StatusConflict, map[string]any{"error": "no_password", "detail": detail, "providers": others})
}
